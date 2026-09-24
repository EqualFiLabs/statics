// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IStaticsProtocolPools} from "../interfaces/IStaticsProtocolPools.sol";
import {IStaticsRangeGauge} from "../interfaces/IStaticsRangeGauge.sol";
import {IStaticsSwapFeeHook} from "../interfaces/IStaticsSwapFeeHook.sol";
import {LibBasketLiquidity} from "../libraries/LibBasketLiquidity.sol";
import {LibCustody} from "../libraries/LibCustody.sol";
import {LibDiamond} from "../libraries/LibDiamond.sol";
import {LibGaugeBribes} from "../libraries/LibGaugeBribes.sol";
import {LibGaugeEligibility} from "../libraries/LibGaugeEligibility.sol";
import {LibGaugeEpoch} from "../libraries/LibGaugeEpoch.sol";
import {LibGovernance} from "../libraries/LibGovernance.sol";
import {LibProtocolPools} from "../libraries/LibProtocolPools.sol";
import {LibRangeGauge} from "../libraries/LibRangeGauge.sol";
import {LibRewardPolicy} from "../libraries/LibRewardPolicy.sol";

/// @notice Governance, creator configuration, and permissionless funding for public range gauges.
contract RangeGaugeFacet is ReentrancyGuard {
    uint16 private constant BPS = 10_000;

    struct FundingContext {
        address asset;
        uint16 allocatorShareBps;
        bytes32 eligibilityVersion;
        uint64 allocatorEpoch;
        uint40 currentTime;
        uint256 lpAmount;
        uint256 allocatorAmount;
    }

    function setGaugeRewardAssetAllowed(address asset, bool allowed) external {
        LibDiamond.enforceIsContractOwner();
        LibRangeGauge.setRewardAssetAllowed(asset, allowed);
        emit IStaticsRangeGauge.GaugeRewardAssetAllowedSet(asset, allowed);
    }

    function setGaugeRewardDuration(uint40 duration) external {
        LibDiamond.enforceIsContractOwner();
        LibRangeGauge.setRewardDuration(duration);
        emit IStaticsRangeGauge.GaugeRewardDurationSet(duration);
    }

    function appendPoolRewardAsset(PoolId poolId, address asset) external returns (uint8 slot) {
        _enforceLiquidityAvailable();
        _enforceActivePublicGauge(poolId);
        address creator = LibProtocolPools.creatorOf(poolId);
        if (msg.sender != creator) revert IStaticsRangeGauge.NotPoolCreator(poolId, msg.sender, creator);
        _enforceRewardAssetAvailable(asset);
        slot = LibRangeGauge.appendRewardAsset(poolId, asset);
        emit IStaticsRangeGauge.PoolRewardAssetAppended(poolId, asset, slot);
    }

    function setPoolRewardAllocatorShare(PoolId poolId, uint8 slot, uint16 allocatorShareBps) external {
        _enforceLiquidityAvailable();
        _enforceActivePublicGauge(poolId);
        address creator = LibProtocolPools.creatorOf(poolId);
        if (msg.sender != creator) revert IStaticsRangeGauge.NotPoolCreator(poolId, msg.sender, creator);
        if (slot == LibRangeGauge.STATICS_SLOT) revert IStaticsRangeGauge.ProtocolRewardSlotReserved(poolId);
        (, bool assigned) = LibRangeGauge.rewardAsset(poolId, slot);
        if (!assigned) revert IStaticsRangeGauge.GaugeRewardSlotNotAssigned(poolId, slot);
        if (allocatorShareBps > BPS) revert IStaticsRangeGauge.InvalidAllocatorShareBps(allocatorShareBps);
        LibRangeGauge.rangeGaugeStorage().rewardConfig[poolId].allocatorShareBps[slot] = allocatorShareBps;
        emit IStaticsRangeGauge.PoolRewardAllocatorShareSet(poolId, slot, allocatorShareBps);
    }

    function fundPoolReward(
        PoolId poolId,
        uint8 slot,
        uint256 amount,
        uint40 minRemainingDuration,
        uint16 expectedAllocatorShareBps
    ) external nonReentrant returns (uint256 received) {
        _enforceLiquidityAvailable();
        _enforceActivePublicGauge(poolId);
        if (slot == LibRangeGauge.STATICS_SLOT) revert IStaticsRangeGauge.ProtocolRewardSlotReserved(poolId);
        FundingContext memory context = _fundingContext(poolId, slot, expectedAllocatorShareBps);
        received = _pullReward(poolId, slot, context.asset, amount);
        context.allocatorAmount = Math.mulDiv(received, context.allocatorShareBps, BPS);
        context.lpAmount = received - context.allocatorAmount;
        _applyFunding(poolId, slot, minRemainingDuration, context);
        _emitFunding(poolId, slot, received, context);
    }

    function _emitFunding(PoolId poolId, uint8 slot, uint256 received, FundingContext memory context) private {
        emit IStaticsRangeGauge.PoolRewardFunded(
            poolId,
            context.asset,
            msg.sender,
            slot,
            received,
            context.lpAmount,
            LibRangeGauge.rangeGaugeStorage().gauges[poolId].streams[slot].periodFinish
        );
        if (context.allocatorAmount != 0) {
            emit IStaticsRangeGauge.PoolAllocatorRewardFunded(
                poolId, context.asset, msg.sender, slot, context.allocatorAmount, context.allocatorEpoch
            );
        }
    }

    function _fundingContext(PoolId poolId, uint8 slot, uint16 expectedAllocatorShareBps)
        private
        view
        returns (FundingContext memory context)
    {
        bool assigned;
        (context.asset, assigned) = LibRangeGauge.rewardAsset(poolId, slot);
        if (!assigned) revert IStaticsRangeGauge.GaugeRewardSlotNotAssigned(poolId, slot);
        _enforceRewardAssetAvailable(context.asset);
        context.allocatorShareBps = LibRangeGauge.rangeGaugeStorage().rewardConfig[poolId].allocatorShareBps[slot];
        if (context.allocatorShareBps != expectedAllocatorShareBps) {
            revert IStaticsRangeGauge.AllocatorShareChanged(expectedAllocatorShareBps, context.allocatorShareBps);
        }
        context.currentTime = LibRangeGauge.timestamp40(block.timestamp);
        if (context.allocatorShareBps == 0) return context;
        context.eligibilityVersion = LibGaugeEligibility.version(poolId);
        if (context.eligibilityVersion == bytes32(0)) {
            revert IStaticsRangeGauge.GaugeAllocatorPoolIneligible(poolId);
        }
        context.allocatorEpoch = LibGaugeEpoch.epochAt(block.timestamp) + 1;
    }

    function _applyFunding(PoolId poolId, uint8 slot, uint40 minRemainingDuration, FundingContext memory context)
        private
    {
        LibRangeGauge.RangeGaugeStorage storage rgs = LibRangeGauge.rangeGaugeStorage();
        LibRangeGauge.GaugePool storage gauge = rgs.gauges[poolId];
        LibRangeGauge.GaugeRewardStream storage stream = gauge.streams[slot];
        LibRangeGauge.checkpointStream(stream, context.currentTime, gauge.activeGaugeLiquidity);
        if (context.lpAmount != 0) {
            uint256 remainingBudget = stream.periodBudget - stream.periodEmitted;
            uint40 availableDuration =
                remainingBudget == 0 ? rgs.gaugeRewardDuration : stream.periodFinish - context.currentTime;
            if (minRemainingDuration != 0 && availableDuration < minRemainingDuration) {
                revert IStaticsRangeGauge.MinimumRemainingDurationNotMet(availableDuration, minRemainingDuration);
            }
            LibRangeGauge.fundStream(
                stream,
                gauge.capacities[slot],
                context.lpAmount,
                context.currentTime,
                rgs.gaugeRewardDuration,
                gauge.activeGaugeLiquidity
            );
        }
        if (context.allocatorAmount == 0) return;
        bytes32 allocatorAccount = LibGaugeBribes.account(poolId, slot, context.allocatorEpoch);
        LibCustody.moveReservation(
            LibRangeGauge.rewardAccount(poolId, slot), allocatorAccount, context.asset, context.allocatorAmount
        );
        LibGaugeBribes.recordFunding(
            poolId,
            slot,
            context.allocatorEpoch,
            context.asset,
            context.eligibilityVersion,
            context.currentTime,
            context.allocatorAmount
        );
    }

    function _pullReward(PoolId poolId, uint8 slot, address asset, uint256 amount) private returns (uint256 received) {
        uint256 funderBalanceBefore = IERC20(asset).balanceOf(msg.sender);
        received = LibCustody.pullAndReserve(LibRangeGauge.rewardAccount(poolId, slot), asset, msg.sender, amount);
        uint256 funderBalanceAfter = IERC20(asset).balanceOf(msg.sender);
        uint256 funderDebit = funderBalanceBefore > funderBalanceAfter ? funderBalanceBefore - funderBalanceAfter : 0;
        if (funderDebit > amount) {
            revert IStaticsRangeGauge.InputDebitExceedsMaximum(asset, funderDebit, amount);
        }
    }

    function _enforceActivePublicGauge(PoolId poolId) private view {
        (IStaticsProtocolPools.ProtocolPoolKind kind, PoolKey memory key,,) = LibProtocolPools.enforceRegistered(poolId);
        if (
            kind != IStaticsProtocolPools.ProtocolPoolKind.General
                && kind != IStaticsProtocolPools.ProtocolPoolKind.BasketCanonical
        ) revert IStaticsRangeGauge.InvalidPublicPool(poolId);

        LibBasketLiquidity.LiquidityStorage storage ls = LibBasketLiquidity.liquidityStorage();
        if (address(key.hooks) != ls.hook) revert IStaticsRangeGauge.InvalidPublicPool(poolId);
        LibRangeGauge.GaugePool storage gauge = LibRangeGauge.rangeGaugeStorage().gauges[poolId];
        if (!gauge.initialized) revert IStaticsRangeGauge.InvalidPublicPool(poolId);
        if (gauge.stopped) revert IStaticsRangeGauge.GaugeStopped(poolId);
        if (IStaticsSwapFeeHook(ls.hook).poolDecommissioned(poolId)) {
            revert IStaticsRangeGauge.PublicPoolDecommissioned(poolId);
        }
    }

    function _enforceRewardAssetAvailable(address asset) private view {
        if (!LibRangeGauge.rangeGaugeStorage().rewardAssetAllowed[asset]) {
            revert IStaticsRangeGauge.GaugeRewardAssetNotAllowed(asset);
        }
        if (LibRewardPolicy.isRestricted(asset)) revert IStaticsRangeGauge.GaugeRewardAssetRestricted(asset);
    }

    function _enforceLiquidityAvailable() private view {
        if (LibGovernance.governanceStorage().pausedActions & LibGovernance.PAUSE_LIQUIDITY != 0) {
            revert IStaticsRangeGauge.ActionPaused(LibGovernance.PAUSE_LIQUIDITY);
        }
    }
}
