// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IStaticsDollarCoreTypes} from "../../interfaces/IStaticsDollarCoreTypes.sol";
import {IStaticsDollarCore} from "../../core/interfaces/IStaticsDollarCore.sol";
import {LibDiamond} from "../../../libraries/LibDiamond.sol";
import {LibBasket} from "../../../libraries/LibBasket.sol";
import {LibCustody} from "../../../libraries/LibCustody.sol";
import {LibPeriphery} from "../libraries/LibPeriphery.sol";

contract FeeRouterFacet is ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 internal constant SOURCE_POOL_FEE = "POOL_FEE";

    event PoolFeeIndexed(
        uint256 indexed seriesId,
        uint256 indexed profileId,
        address indexed token,
        IStaticsDollarCoreTypes.FeeKind kind,
        uint256 toRewards,
        uint256 queuedForInsurance
    );
    event PeggedProfileFeeAccrued(
        uint256 indexed profileId, address indexed token, IStaticsDollarCoreTypes.FeeKind indexed kind, uint256 amount
    );
    event PeggedProtocolRevenueClaimed(
        uint256 indexed profileId, address indexed token, address indexed receiver, uint256 amount
    );
    event PendingInsuranceRouted(uint256 indexed profileId, address indexed token, uint256 amount, address caller);
    event SplitSet(uint16 baseBps, uint16 insuranceBps);
    event RewardSplitSet(uint16 passiveBps, uint16 optInBps);

    error OnlyPool(address caller);
    error InvalidSplit(uint16 baseBps, uint16 insuranceBps);
    error InvalidSeriesFeeToken(uint256 seriesId, address expected, address provided);
    error InvalidProfileFeeToken(uint256 profileId, address expected, address provided);
    error InvalidProfileKind(
        uint256 profileId, IStaticsDollarCoreTypes.ProfileKind expected, IStaticsDollarCoreTypes.ProfileKind actual
    );
    error NothingToRoute(uint256 profileId);
    error InvalidRewardSplit(uint16 passiveBps);
    error OnlyTreasury(address caller, address expected);
    error ZeroAddress();
    error ZeroAmount();
    error RevenueAboveAvailable(uint256 requested, uint256 available);

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
            uint256 passiveAmount = Math.mulDiv(rewardShare, ps.passiveRewardBps, LibPeriphery.BPS);
            uint256 optInAmount = rewardShare - passiveAmount;
            if (passiveAmount != 0) {
                if (book.eligiblePrincipal == 0) {
                    insuranceShare += passiveAmount;
                    rewardShare -= passiveAmount;
                } else {
                    LibPeriphery.accruePassive(ps, seriesId, token, passiveAmount, SOURCE_POOL_FEE, false);
                }
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
        ps.peggedProtocolRevenue[profileId][token] += amount;
        emit PeggedProfileFeeAccrued(profileId, token, kind, amount);
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

    function setRewardSplit(uint16 passiveBps) external {
        LibDiamond.enforceIsContractOwner();
        if (passiveBps > LibPeriphery.BPS) revert InvalidRewardSplit(passiveBps);
        LibPeriphery.s().passiveRewardBps = passiveBps;
        emit RewardSplitSet(passiveBps, uint16(LibPeriphery.BPS - passiveBps));
    }

    function rewardSplit() external view returns (uint16 passiveBps, uint16 optInBps) {
        passiveBps = LibPeriphery.s().passiveRewardBps;
        optInBps = uint16(LibPeriphery.BPS - passiveBps);
    }

    function pendingInsurance(uint256 profileId) external view returns (uint256) {
        return LibPeriphery.s().pendingInsurance[profileId];
    }

    function peggedProtocolRevenue(uint256 profileId, address token) external view returns (uint256) {
        return LibPeriphery.s().peggedProtocolRevenue[profileId][token];
    }

    function claimPeggedProtocolRevenue(uint256 profileId, uint256 amount, address receiver)
        external
        nonReentrant
        returns (uint256 spent, uint256 received)
    {
        if (amount == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();
        address treasury_ = LibBasket.basketStorage().treasury;
        if (msg.sender != treasury_) revert OnlyTreasury(msg.sender, treasury_);
        LibPeriphery.PS storage ps = LibPeriphery.s();
        address token = IStaticsDollarCore(ps.pool).collateralProfile(profileId).collateralToken;
        uint256 available = ps.peggedProtocolRevenue[profileId][token];
        if (amount > available) revert RevenueAboveAvailable(amount, available);
        ps.peggedProtocolRevenue[profileId][token] = available - amount;
        (spent, received) = LibCustody.pushReserved(LibCustody.dollarAccount(), token, receiver, amount, amount);
        emit PeggedProtocolRevenueClaimed(profileId, token, receiver, amount);
    }
}
