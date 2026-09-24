// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IStaticsRangeGauge} from "../interfaces/IStaticsRangeGauge.sol";
import {LibBasketLiquidity} from "../libraries/LibBasketLiquidity.sol";
import {LibGaugeEligibility} from "../libraries/LibGaugeEligibility.sol";
import {LibIndexMath} from "../libraries/LibIndexMath.sol";
import {LibRangeGauge} from "../libraries/LibRangeGauge.sol";

/// @notice Read-only discovery and accounting previews for public range gauges.
contract RangeGaugeViewFacet {
    function gaugeRewardDuration() external view returns (uint40 duration) {
        duration = LibRangeGauge.rangeGaugeStorage().gaugeRewardDuration;
    }

    function gaugeRewardAssetAllowed(address asset) external view returns (bool allowed) {
        allowed = LibRangeGauge.rangeGaugeStorage().rewardAssetAllowed[asset];
    }

    function poolRewardConfig(PoolId poolId)
        external
        view
        returns (IStaticsRangeGauge.PoolRewardConfigView memory config)
    {
        LibRangeGauge.PoolRewardConfig storage stored = LibRangeGauge.rangeGaugeStorage().rewardConfig[poolId];
        config = IStaticsRangeGauge.PoolRewardConfigView({
            initialized: stored.initialized,
            slotCount: stored.slotCount,
            assets: stored.assets,
            allocatorShareBps: stored.allocatorShareBps
        });
    }

    function gaugePool(PoolId poolId) external view returns (IStaticsRangeGauge.GaugePoolView memory pool) {
        LibRangeGauge.GaugePool storage stored = LibRangeGauge.rangeGaugeStorage().gauges[poolId];
        pool = IStaticsRangeGauge.GaugePoolView({
            initialized: stored.initialized,
            stopped: stored.stopped,
            stoppedAt: stored.stoppedAt,
            referenceTick: stored.referenceTick,
            activeGaugeLiquidity: stored.activeGaugeLiquidity,
            managedLegCount: stored.managedLegCount,
            unresolvedLegCount: stored.unresolvedLegCount
        });
    }

    function poolRewardStream(PoolId poolId, uint8 slot)
        external
        view
        returns (IStaticsRangeGauge.GaugeRewardStreamView memory stream)
    {
        (address asset, bool assigned) = LibRangeGauge.rewardAsset(poolId, slot);
        if (!assigned) {
            stream.slot = slot;
            return stream;
        }
        LibRangeGauge.GaugeRewardStream storage stored = LibRangeGauge.rangeGaugeStorage().gauges[poolId].streams[slot];
        stream = IStaticsRangeGauge.GaugeRewardStreamView({
            assigned: assigned,
            slot: slot,
            asset: asset,
            protocolEpoch: stored.protocolEpoch,
            periodStart: stored.periodStart,
            periodFinish: stored.periodFinish,
            lastUpdate: stored.lastUpdate,
            periodBudget: stored.periodBudget,
            periodEmitted: stored.periodEmitted,
            periodRecycled: stored.periodRecycled,
            globalIndexRay: stored.globalIndexRay,
            indexRemainder: stored.indexRemainder,
            indexedLiability: stored.indexedLiability,
            claimLiability: stored.claimLiability,
            indexCapacityUsed: LibRangeGauge.rangeGaugeStorage().gauges[poolId].capacities[slot].used
        });
    }

    function poolRewardCustodyAccount(PoolId poolId, uint8 slot)
        external
        view
        returns (bytes32 account, bool assigned)
    {
        (, bool found) = LibRangeGauge.rewardAsset(poolId, slot);
        if (!found) return (bytes32(0), false);
        return (LibRangeGauge.rewardAccount(poolId, slot), true);
    }

    function gaugeBoundary(PoolId poolId, int24 tick)
        external
        view
        returns (IStaticsRangeGauge.GaugeBoundaryView memory boundary)
    {
        LibRangeGauge.GaugeBoundary storage stored = LibRangeGauge.rangeGaugeStorage().gauges[poolId].boundaries[tick];
        boundary = IStaticsRangeGauge.GaugeBoundaryView({
            grossLiquidity: stored.grossLiquidity,
            netLiquidity: stored.netLiquidity,
            rewardOutsideRay: stored.rewardOutsideRay
        });
    }

    function lpLeg(uint256 positionId, PoolId poolId) external view returns (IStaticsRangeGauge.LpLegView memory leg) {
        LibRangeGauge.LpLeg storage stored = LibRangeGauge.rangeGaugeStorage().lpLegs[positionId][poolId];
        leg = IStaticsRangeGauge.LpLegView({
            manager: stored.manager,
            posmTokenId: stored.posmTokenId,
            tickLower: stored.tickLower,
            tickUpper: stored.tickUpper,
            liquidity: stored.liquidity,
            checkpointInsideRay: stored.checkpointInsideRay,
            rewardRemainderRay: stored.rewardRemainderRay,
            claimable: stored.claimable
        });
    }

    function positionGaugePools(uint256 positionId, uint256 cursor, uint256 size)
        external
        view
        returns (PoolId[] memory poolIds, uint256 nextCursor)
    {
        return LibRangeGauge.positionPools(positionId, cursor, size);
    }

    function posmBinding(uint256 posmTokenId) external view returns (bytes32 binding) {
        binding = LibRangeGauge.rangeGaugeStorage().posmBinding[posmTokenId];
    }

    function liquidityManager() external view returns (address manager, bool installed) {
        LibBasketLiquidity.LiquidityStorage storage ls = LibBasketLiquidity.liquidityStorage();
        return (ls.manager, ls.managerInstalled);
    }

    function recordedLiquidityManager(uint256 positionId, PoolId poolId) external view returns (address manager) {
        manager = LibRangeGauge.rangeGaugeStorage().lpLegs[positionId][poolId].manager;
    }

    function previewLpRewards(uint256 positionId, PoolId poolId)
        external
        view
        returns (IStaticsRangeGauge.PendingRewardsView memory pending)
    {
        LibRangeGauge.RangeGaugeStorage storage rgs = LibRangeGauge.rangeGaugeStorage();
        LibRangeGauge.PoolRewardConfig storage config = rgs.rewardConfig[poolId];
        LibRangeGauge.GaugePool storage gauge = rgs.gauges[poolId];
        LibRangeGauge.LpLeg storage leg = rgs.lpLegs[positionId][poolId];
        pending.slotCount = config.slotCount;
        pending.assets = config.assets;
        for (uint8 slot; slot < config.slotCount; ++slot) {
            uint256 amount = leg.claimable[slot];
            if (leg.liquidity != 0) {
                uint256 globalIndexRay = _previewGlobalIndex(poolId, slot, gauge.streams[slot], gauge, block.timestamp);
                uint256 insideGrowthRay = LibRangeGauge.growthInsideValues(
                    globalIndexRay,
                    gauge.boundaries[leg.tickLower].rewardOutsideRay[slot],
                    gauge.boundaries[leg.tickUpper].rewardOutsideRay[slot],
                    leg.tickLower,
                    leg.tickUpper,
                    gauge.referenceTick
                );
                uint256 growthDeltaRay;
                unchecked {
                    growthDeltaRay = insideGrowthRay - leg.checkpointInsideRay[slot];
                }
                (uint256 unsettled,) =
                    LibRangeGauge.positionAccrual(leg.liquidity, growthDeltaRay, leg.rewardRemainderRay[slot]);
                amount += unsettled;
            }
            pending.amounts[slot] = amount;
        }
    }

    function _previewGlobalIndex(
        PoolId poolId,
        uint8 slot,
        LibRangeGauge.GaugeRewardStream storage stream,
        LibRangeGauge.GaugePool storage gauge,
        uint256 timestamp
    ) private view returns (uint256 globalIndexRay) {
        globalIndexRay = stream.globalIndexRay;
        if (
            gauge.stopped || gauge.activeGaugeLiquidity == 0
                || stream.periodBudget == stream.periodEmitted + stream.periodRecycled || timestamp <= stream.lastUpdate
        ) return globalIndexRay;
        uint40 currentTime = LibRangeGauge.timestamp40(timestamp);
        uint40 effectiveNow = currentTime < stream.periodFinish ? currentTime : stream.periodFinish;
        if (slot == LibRangeGauge.STATICS_SLOT && stream.protocolEpoch != 0) {
            uint40 restrictedAt = LibGaugeEligibility.restrictionTimestamp(poolId, stream.protocolEpoch);
            if (restrictedAt != 0 && restrictedAt < effectiveNow) effectiveNow = restrictedAt;
            if (effectiveNow < stream.periodStart) effectiveNow = stream.periodStart;
        }
        uint256 elapsed = uint256(effectiveNow) - stream.periodStart;
        uint256 duration = uint256(stream.periodFinish) - stream.periodStart;
        uint256 targetEmitted = effectiveNow == stream.periodFinish
            ? stream.periodBudget
            : Math.mulDiv(stream.periodBudget, elapsed, duration);
        uint256 emission = targetEmitted - stream.periodEmitted - stream.periodRecycled;
        if (emission == 0) return globalIndexRay;
        (uint256 delta,) = LibIndexMath.indexDelta(emission, gauge.activeGaugeLiquidity, stream.indexRemainder);
        unchecked {
            globalIndexRay += delta;
        }
    }
}
