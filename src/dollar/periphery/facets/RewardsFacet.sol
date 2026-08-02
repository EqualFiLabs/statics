// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IStaticsDollarCoreTypes} from "../../interfaces/IStaticsDollarCoreTypes.sol";
import {IStaticsDollarCore} from "../../core/interfaces/IStaticsDollarCore.sol";
import {IStaticsDollarRiskSeriesRewards} from "../../interfaces/IStaticsDollarRiskSeriesRewards.sol";
import {LibCustody} from "../../../libraries/LibCustody.sol";
import {LibPosition} from "../../../position/LibPosition.sol";
import {LibPeriphery} from "../libraries/LibPeriphery.sol";

contract RewardsFacet is IStaticsDollarRiskSeriesRewards, ReentrancyGuard {
    bytes32 internal constant SOURCE_DONATION = "DONATION";

    error ZeroAddress();
    error ZeroAmount();
    error NoRewards(uint256 positionId, uint256 seriesId);
    error PositionNotAuthorized(uint256 positionId, address caller);
    error SeriesNotRewardable(uint256 seriesId);
    error SeriesNotRetired(uint256 seriesId);
    error AlreadyFinalized(uint256 seriesId);

    function donateCollateralRewards(uint256 seriesId, uint256 passiveAmount, uint256 optInAmount)
        external
        nonReentrant
    {
        LibPeriphery.PS storage ps = LibPeriphery.s();
        address token = _requireRewardable(ps, seriesId).collateralToken;
        _donate(ps, seriesId, token, passiveAmount, optInAmount, false);
    }

    function donateStaticsDollarRewards(uint256 seriesId, uint256 passiveAmount, uint256 optInAmount)
        external
        nonReentrant
    {
        LibPeriphery.PS storage ps = LibPeriphery.s();
        _requireRewardable(ps, seriesId);
        _donate(ps, seriesId, ps.staticsDollar, passiveAmount, optInAmount, true);
    }

    function claimSeriesRewards(uint256 positionId, uint256 seriesId, address receiver)
        external
        nonReentrant
        returns (uint256 collateralAmount, uint256 staticsDollarAmount)
    {
        if (receiver == address(0)) revert ZeroAddress();
        LibPeriphery.PS storage ps = LibPeriphery.s();
        _enforceAuthorized(ps, positionId);
        LibPeriphery.settleLeg(ps, positionId, seriesId);
        LibPeriphery.PositionLeg storage leg = ps.leg[positionId][seriesId];
        collateralAmount = leg.accruedCollateral;
        staticsDollarAmount = leg.accruedStaticsDollar;
        if (collateralAmount == 0 && staticsDollarAmount == 0) revert NoRewards(positionId, seriesId);
        leg.accruedCollateral = 0;
        leg.accruedStaticsDollar = 0;

        address collateralToken = IStaticsDollarCore(ps.pool).riskSeries(seriesId).collateralToken;
        if (collateralToken == ps.staticsDollar) {
            uint256 total = collateralAmount + staticsDollarAmount;
            ps.reservedByToken[ps.staticsDollar] -= total;
            LibCustody.pushReserved(LibCustody.dollarAccount(), ps.staticsDollar, receiver, total, total);
        } else {
            if (collateralAmount != 0) {
                ps.reservedByToken[collateralToken] -= collateralAmount;
                LibCustody.pushReserved(
                    LibCustody.dollarAccount(), collateralToken, receiver, collateralAmount, collateralAmount
                );
            }
            if (staticsDollarAmount != 0) {
                ps.reservedByToken[ps.staticsDollar] -= staticsDollarAmount;
                LibCustody.pushReserved(
                    LibCustody.dollarAccount(), ps.staticsDollar, receiver, staticsDollarAmount, staticsDollarAmount
                );
            }
        }
        emit SeriesRewardsClaimed(
            positionId, seriesId, receiver, collateralToken, collateralAmount, staticsDollarAmount
        );
    }

    function pendingSeriesRewards(uint256 positionId, uint256 seriesId)
        external
        view
        returns (uint256 collateralAmount, uint256 staticsDollarAmount)
    {
        return LibPeriphery.pendingRewards(LibPeriphery.s(), positionId, seriesId);
    }

    function finalizeRetiredSeriesRewards(uint256 seriesId) external nonReentrant {
        LibPeriphery.PS storage ps = LibPeriphery.s();
        IStaticsDollarCoreTypes.RiskSeries memory series = IStaticsDollarCore(ps.pool).riskSeries(seriesId);
        if (
            series.status != IStaticsDollarCoreTypes.SeriesStatus.Recoverable
                && series.status != IStaticsDollarCoreTypes.SeriesStatus.Retired
                && series.status != IStaticsDollarCoreTypes.SeriesStatus.Closed
        ) {
            revert SeriesNotRetired(seriesId);
        }
        LibPeriphery.SeriesBook storage book = ps.series[seriesId];
        if (book.retiredRewardsFinalized) revert AlreadyFinalized(seriesId);
        LibPeriphery.finalizeRetiredRewards(ps, seriesId, series);
    }

    function seriesRewardState(uint256 seriesId) external view returns (SeriesRewardState memory state) {
        LibPeriphery.SeriesBook storage book = LibPeriphery.s().series[seriesId];
        state = SeriesRewardState({
            eligiblePrincipal: book.eligiblePrincipal,
            collateralPassiveIndexRay: book.collateralPassive.accPerStoredRay,
            staticsDollarPassiveIndexRay: book.staticsDollarPassive.accPerStoredRay,
            collateralOptInReserve: book.collateralOptInReserve,
            staticsDollarOptInReserve: book.staticsDollarOptInReserve,
            optInEffectivePrincipal: book.optInPrincipal,
            retiredRewardsFinalized: book.retiredRewardsFinalized
        });
    }

    function reservedBalance(address token) external view returns (uint256) {
        return LibPeriphery.s().reservedByToken[token];
    }

    function _donate(
        LibPeriphery.PS storage ps,
        uint256 seriesId,
        address token,
        uint256 passiveAmount,
        uint256 optInAmount,
        bool isStaticsDollar
    ) internal {
        uint256 total = passiveAmount + optInAmount;
        if (total == 0) revert ZeroAmount();
        uint256 received = LibCustody.pull(token, msg.sender, total);
        uint256 receivedPassive = Math.mulDiv(received, passiveAmount, total);
        uint256 receivedOptIn = received - receivedPassive;

        if (receivedPassive != 0) {
            LibPeriphery.accruePassive(ps, seriesId, token, receivedPassive, SOURCE_DONATION, false);
        }
        if (receivedOptIn != 0) {
            LibPeriphery.reserve(ps, token, receivedOptIn);
            LibPeriphery.SeriesBook storage book = ps.series[seriesId];
            if (isStaticsDollar) book.staticsDollarOptInReserve += receivedOptIn;
            else book.collateralOptInReserve += receivedOptIn;
        }
        emit SeriesRewardsDonated(seriesId, token, msg.sender, receivedPassive, receivedOptIn);
    }

    function _requireRewardable(LibPeriphery.PS storage ps, uint256 seriesId)
        internal
        view
        returns (IStaticsDollarCoreTypes.RiskSeries memory series)
    {
        series = IStaticsDollarCore(ps.pool).riskSeries(seriesId);
        IStaticsDollarCoreTypes.ProfileMode mode = IStaticsDollarCore(ps.pool).collateralProfile(series.profileId).mode;
        if (
            series.status != IStaticsDollarCoreTypes.SeriesStatus.Active
                || (mode != IStaticsDollarCoreTypes.ProfileMode.Active
                    && mode != IStaticsDollarCoreTypes.ProfileMode.ReduceOnly)
        ) revert SeriesNotRewardable(seriesId);
    }

    function _enforceAuthorized(LibPeriphery.PS storage, uint256 positionId) internal view {
        if (!LibPosition.isAuthorized(positionId, msg.sender)) {
            revert PositionNotAuthorized(positionId, msg.sender);
        }
    }
}
