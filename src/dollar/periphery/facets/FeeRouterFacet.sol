// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IStaticsDollarCoreTypes} from "../../interfaces/IStaticsDollarCoreTypes.sol";
import {IStaticsDollarCore} from "../../core/interfaces/IStaticsDollarCore.sol";
import {LibDiamond} from "../../../libraries/LibDiamond.sol";
import {LibCustody} from "../../../libraries/LibCustody.sol";
import {LibGlobalRewards} from "../../../libraries/LibGlobalRewards.sol";
import {LibPeriphery} from "../libraries/LibPeriphery.sol";

contract FeeRouterFacet is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 internal constant GLOBAL_REWARD_SHARE_BPS = 3_000;

    event PoolFeeIndexed(
        uint256 indexed seriesId,
        uint256 indexed profileId,
        address indexed token,
        IStaticsDollarCoreTypes.FeeKind kind,
        uint256 toRewards,
        uint256 queuedForInsurance
    );
    event PeggedProfileFeeRouted(
        uint256 indexed profileId, address indexed token, IStaticsDollarCoreTypes.FeeKind indexed kind, uint256 amount
    );
    event PendingInsuranceRouted(uint256 indexed profileId, address indexed token, uint256 amount, address caller);
    event SplitSet(uint16 baseBps, uint16 insuranceBps);

    error OnlyPool(address caller);
    error InvalidSplit(uint16 baseBps, uint16 insuranceBps);
    error InvalidSeriesFeeToken(uint256 seriesId, address expected, address provided);
    error InvalidProfileFeeToken(uint256 profileId, address expected, address provided);
    error InvalidProfileKind(
        uint256 profileId, IStaticsDollarCoreTypes.ProfileKind expected, IStaticsDollarCoreTypes.ProfileKind actual
    );
    error NothingToRoute(uint256 profileId);

    function onSeriesFee(uint256 seriesId, address token, uint256 amount, IStaticsDollarCoreTypes.FeeKind kind)
        external
    {
        LibPeriphery.PS storage ps = LibPeriphery.s();
        if (msg.sender != ps.pool) revert OnlyPool(msg.sender);
        IStaticsDollarCoreTypes.RiskSeries memory series = IStaticsDollarCore(ps.pool).riskSeries(seriesId);
        if (token != series.collateralToken) revert InvalidSeriesFeeToken(seriesId, series.collateralToken, token);
        IStaticsDollarCoreTypes.StableCollateralProfile memory profile =
            IStaticsDollarCore(ps.pool).collateralProfile(series.profileId);

        if (profile.kind != IStaticsDollarCoreTypes.ProfileKind.Volatile) {
            revert InvalidProfileKind(series.profileId, IStaticsDollarCoreTypes.ProfileKind.Volatile, profile.kind);
        }
        uint256 insuranceShare = Math.mulDiv(amount, ps.insuranceBps, LibPeriphery.BPS);
        uint256 rewardShare = amount - insuranceShare;
        bool rewardableMode = profile.mode == IStaticsDollarCoreTypes.ProfileMode.Active
            || profile.mode == IStaticsDollarCoreTypes.ProfileMode.ReduceOnly;
        if (series.status != IStaticsDollarCoreTypes.SeriesStatus.Active || !rewardableMode) {
            insuranceShare += rewardShare;
            rewardShare = 0;
        } else if (rewardShare != 0) {
            LibPeriphery.SeriesBook storage book = ps.series[seriesId];
            uint256 globalAmount = Math.mulDiv(rewardShare, GLOBAL_REWARD_SHARE_BPS, LibPeriphery.BPS);
            uint256 optInAmount = rewardShare - globalAmount;
            if (globalAmount != 0) {
                LibCustody.reserve(LibCustody.dollarAccount(), token, globalAmount);
                LibGlobalRewards.accrueNonSwapFee(LibCustody.dollarAccount(), token, globalAmount);
            }
            if (optInAmount != 0) {
                LibPeriphery.reserve(ps, token, optInAmount);
                book.collateralOptInReserve += optInAmount;
            }
        }
        if (insuranceShare != 0) {
            LibCustody.reserve(LibCustody.dollarAccount(), token, insuranceShare);
        }
        ps.pendingInsurance[series.profileId] += insuranceShare;
        ps.pendingInsuranceByToken[token] += insuranceShare;
        emit PoolFeeIndexed(seriesId, series.profileId, token, kind, rewardShare, insuranceShare);
    }

    function onPeggedProfileFee(uint256 profileId, address token, uint256 amount, IStaticsDollarCoreTypes.FeeKind kind)
        external
    {
        LibPeriphery.PS storage ps = LibPeriphery.s();
        if (msg.sender != ps.pool) revert OnlyPool(msg.sender);
        IStaticsDollarCoreTypes.StableCollateralProfile memory profile =
            IStaticsDollarCore(ps.pool).collateralProfile(profileId);
        if (profile.kind != IStaticsDollarCoreTypes.ProfileKind.Pegged) {
            revert InvalidProfileKind(profileId, IStaticsDollarCoreTypes.ProfileKind.Pegged, profile.kind);
        }
        if (token != profile.collateralToken) {
            revert InvalidProfileFeeToken(profileId, profile.collateralToken, token);
        }
        LibCustody.reserve(LibCustody.dollarAccount(), token, amount);
        LibGlobalRewards.accrueNonSwapFee(LibCustody.dollarAccount(), token, amount);
        emit PeggedProfileFeeRouted(profileId, token, kind, amount);
    }

    function routePendingInsurance(uint256 profileId) external nonReentrant returns (uint256 amount) {
        LibPeriphery.PS storage ps = LibPeriphery.s();
        IStaticsDollarCoreTypes.StableCollateralProfile memory profile =
            IStaticsDollarCore(ps.pool).collateralProfile(profileId);
        amount = ps.pendingInsurance[profileId];
        if (amount == 0) revert NothingToRoute(profileId);
        ps.pendingInsurance[profileId] = 0;
        ps.pendingInsuranceByToken[profile.collateralToken] -= amount;
        LibCustody.release(LibCustody.dollarAccount(), profile.collateralToken, amount);
        IERC20(profile.collateralToken).forceApprove(ps.pool, amount);
        IStaticsDollarCore(ps.pool).topUpInsurance(profileId, amount);
        emit PendingInsuranceRouted(profileId, profile.collateralToken, amount, msg.sender);
    }

    function setSplit(uint16 baseBps, uint16 insuranceBps) external {
        LibDiamond.enforceIsContractOwner();
        if (uint256(baseBps) + uint256(insuranceBps) != LibPeriphery.BPS) revert InvalidSplit(baseBps, insuranceBps);
        LibPeriphery.PS storage ps = LibPeriphery.s();
        ps.baseBps = baseBps;
        ps.insuranceBps = insuranceBps;
        emit SplitSet(baseBps, insuranceBps);
    }

    function splits() external view returns (uint16 baseBps, uint16 insuranceBps) {
        LibPeriphery.PS storage ps = LibPeriphery.s();
        return (ps.baseBps, ps.insuranceBps);
    }

    function pendingInsurance(uint256 profileId) external view returns (uint256) {
        return LibPeriphery.s().pendingInsurance[profileId];
    }

}
