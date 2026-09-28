// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IStaticsGaugeIncentives} from "../interfaces/IStaticsGaugeIncentives.sol";
import {LibGaugeBribes} from "../libraries/LibGaugeBribes.sol";
import {LibGaugeEligibility} from "../libraries/LibGaugeEligibility.sol";
import {LibGaugeReserve} from "../libraries/LibGaugeReserve.sol";
import {LibGaugeRouting} from "../libraries/LibGaugeRouting.sol";
import {LibPosition} from "../position/LibPosition.sol";
import {LibRangeGauge} from "../libraries/LibRangeGauge.sol";

contract GaugeIncentiveViewFacet {
    uint256 private constant INDEX_SCALE = 1 << 160;

    function currentGaugePeriod() external view returns (uint64 period) {
        return LibGaugeRouting.routingStorage().currentPeriod;
    }

    function gaugePeriodAt(uint256 timestamp) external view returns (uint64 period, bool active) {
        return LibGaugeRouting.periodAt(timestamp);
    }

    function gaugeReserve() external view returns (IStaticsGaugeIncentives.ReserveView memory state) {
        LibGaugeReserve.ReserveStorage storage reserve = LibGaugeReserve.reserveStorage();
        LibGaugeRouting.RoutingStorage storage routing = LibGaugeRouting.routingStorage();
        state = IStaticsGaugeIncentives.ReserveView({
            activated: routing.activated,
            releaseBps: reserve.releaseBps,
            pendingReleaseBps: reserve.pendingReleaseBps,
            pendingReleaseAt: reserve.pendingReleaseAt,
            deferredMaturityAt: reserve.deferredMaturityAt,
            scheduleStart: routing.scheduleStart,
            lastCheckpoint: routing.lastCheckpoint,
            periodStart: routing.periodStart,
            periodFinish: routing.periodFinish,
            currentPeriod: routing.currentPeriod,
            allocationCooldown: routing.allocationCooldown,
            available: reserve.available,
            deferred: reserve.deferred,
            committed: reserve.committed,
            periodBudget: routing.periodBudget,
            periodAccounted: routing.periodAccounted,
            totalAllocatedWeight: routing.totalAllocatedWeight,
            globalIndexX160: routing.globalIndexX160,
            unsettledRoutingLiability: routing.unsettledRoutingLiability
        });
    }

    function gaugePoolWeight(PoolId poolId)
        external
        view
        returns (IStaticsGaugeIncentives.PoolWeightView memory state)
    {
        LibGaugeRouting.RoutingStorage storage routing = LibGaugeRouting.routingStorage();
        LibGaugeRouting.PoolWeight storage stored = routing.poolWeights[poolId];
        bytes32 current = LibGaugeRouting.eligibilityVersion(poolId);
        bool stale = stored.weight != 0 && current != stored.eligibilityVersion;
        state = IStaticsGaugeIncentives.PoolWeightView({
            weight: stored.weight,
            storedVersion: stored.eligibilityVersion,
            currentVersion: current,
            restrictionSequence: stored.restrictionSequence,
            indexCursorX160: stored.indexCursorX160,
            pendingReward: _pendingReward(poolId, routing, stored, stale),
            stale: stale
        });
    }

    function gaugePositionAllocations(uint256 positionId)
        external
        view
        returns (
            uint40 nextAllocationAt,
            uint256 totalAllocated,
            IStaticsGaugeIncentives.AllocationView[] memory active,
            uint256 lockedStake
        )
    {
        LibPosition.enforceAuthorized(positionId, msg.sender);
        LibGaugeRouting.PositionAllocations storage stored = LibGaugeRouting.routingStorage().positions[positionId];
        nextAllocationAt = stored.nextAllocationAt;
        totalAllocated = stored.totalAllocated;
        active = _copy(stored.active);
        lockedStake = LibGaugeRouting.lockedStake(positionId);
    }

    function previewGaugePoolReward(PoolId poolId) external view returns (uint256 amount, bool eligible) {
        LibGaugeRouting.RoutingStorage storage routing = LibGaugeRouting.routingStorage();
        LibGaugeRouting.PoolWeight storage stored = routing.poolWeights[poolId];
        bool stale = stored.weight != 0 && LibGaugeRouting.eligibilityVersion(poolId) != stored.eligibilityVersion;
        eligible = stored.weight != 0 && !stale;
        amount = _pendingReward(poolId, routing, stored, stale);
    }

    function maxGaugeAllocationsPerPosition() external pure returns (uint256) {
        return LibGaugeRouting.MAX_ALLOCATIONS_PER_POSITION;
    }

    function maxWeeklyGaugeReleaseBps() external pure returns (uint16) {
        return LibGaugeReserve.MAX_WEEKLY_RELEASE_BPS;
    }

    function maxGaugeCatchupPeriods() external pure returns (uint16) {
        return LibGaugeRouting.MAX_CATCHUP_PERIODS;
    }

    function gaugeAllocationCooldown() external view returns (uint40 cooldown) {
        return LibGaugeRouting.allocationCooldown();
    }

    function gaugeAllocatorReward(PoolId poolId, uint8 slot)
        external
        view
        returns (IStaticsGaugeIncentives.AllocatorRewardView memory state)
    {
        _validateAllocatorSlot(poolId, slot);
        LibGaugeBribes.Stream storage stored = LibGaugeBribes.bribeStorage().streams[poolId][slot];
        state = IStaticsGaugeIncentives.AllocatorRewardView({
            asset: stored.asset,
            eligibilityVersion: stored.eligibilityVersion,
            fundingRestrictionSequence: stored.fundingRestrictionSequence,
            periodStart: stored.periodStart,
            periodFinish: stored.periodFinish,
            lastUpdate: stored.lastUpdate,
            periodBudget: stored.periodBudget,
            periodEmitted: stored.periodEmitted,
            globalIndexX160: stored.globalIndexX160,
            indexedLiability: stored.indexedLiability,
            claimLiability: stored.claimLiability,
            terminated: stored.terminated
        });
    }

    function previewGaugeAllocatorRewards(uint256 positionId, PoolId poolId, uint8[] calldata slots)
        external
        view
        returns (IStaticsGaugeIncentives.AllocatorClaimPreview[] memory rewards)
    {
        LibPosition.enforceAuthorized(positionId, msg.sender);
        (uint256 allocation, bytes32 allocationVersion) = LibGaugeRouting.positionAllocation(positionId, poolId);
        rewards = new IStaticsGaugeIncentives.AllocatorClaimPreview[](slots.length);
        for (uint256 i; i < slots.length; ++i) {
            uint8 slot = slots[i];
            _validateAllocatorSlot(poolId, slot);
            (address asset, uint256 amount) =
                LibGaugeBribes.preview(positionId, poolId, slot, allocation, allocationVersion);
            rewards[i] = IStaticsGaugeIncentives.AllocatorClaimPreview({
                slot: slot, asset: asset, allocation: allocation, amount: amount
            });
        }
    }

    function _copy(LibGaugeRouting.Allocation[] storage stored)
        private
        view
        returns (IStaticsGaugeIncentives.AllocationView[] memory values)
    {
        values = new IStaticsGaugeIncentives.AllocationView[](stored.length);
        for (uint256 i; i < stored.length; ++i) {
            values[i] = IStaticsGaugeIncentives.AllocationView({
                poolId: stored[i].poolId, amount: stored[i].amount, eligibilityVersion: stored[i].eligibilityVersion
            });
        }
    }

    function _pendingReward(
        PoolId poolId,
        LibGaugeRouting.RoutingStorage storage routing,
        LibGaugeRouting.PoolWeight storage stored,
        bool stale
    ) private view returns (uint256 amount) {
        uint256 settlementIndex = routing.globalIndexX160;
        if (stale) {
            // Match settlement: a stale pool owns growth only through its first restriction cutoff.
            (bool found,, uint256 cutoffIndex) =
                LibGaugeEligibility.firstRestrictionAfter(poolId, stored.restrictionSequence);
            if (found && cutoffIndex < settlementIndex) settlementIndex = cutoffIndex;
        }
        if (stored.weight == 0 || settlementIndex <= stored.indexCursorX160) return 0;

        uint256 delta = settlementIndex - stored.indexCursorX160;
        amount = Math.mulDiv(stored.weight, delta, INDEX_SCALE);
        amount += (mulmod(stored.weight, delta, INDEX_SCALE) + stored.entitlementRemainderX160) / INDEX_SCALE;
    }

    function _validateAllocatorSlot(PoolId poolId, uint8 slot) private view {
        if (slot == LibRangeGauge.STATICS_SLOT) {
            revert IStaticsGaugeIncentives.InvalidGaugeAllocatorSlot(poolId, slot);
        }
        (, bool assigned) = LibRangeGauge.rewardAsset(poolId, slot);
        if (!assigned) revert IStaticsGaugeIncentives.InvalidGaugeAllocatorSlot(poolId, slot);
    }
}
