// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IStaticsGaugeIncentives} from "../interfaces/IStaticsGaugeIncentives.sol";
import {LibGaugeBribes} from "../libraries/LibGaugeBribes.sol";
import {LibGaugeEpoch} from "../libraries/LibGaugeEpoch.sol";
import {LibGaugeHeap} from "../libraries/LibGaugeHeap.sol";
import {LibGaugeReserve} from "../libraries/LibGaugeReserve.sol";
import {LibGaugeRouting} from "../libraries/LibGaugeRouting.sol";
import {LibPosition} from "../position/LibPosition.sol";
import {LibRangeGauge} from "../libraries/LibRangeGauge.sol";

contract GaugeIncentiveViewFacet {
    function currentGaugeEpoch() external view returns (uint64 epoch) {
        return LibGaugeEpoch.epochAt(block.timestamp);
    }

    function gaugeEpochAt(uint256 timestamp) external pure returns (uint64 epoch) {
        return LibGaugeEpoch.epochAt(timestamp);
    }

    function gaugeReserve() external view returns (IStaticsGaugeIncentives.ReserveView memory state) {
        LibGaugeReserve.ReserveStorage storage stored = LibGaugeReserve.reserveStorage();
        uint64 currentEpoch = LibGaugeEpoch.epochAt(block.timestamp);
        uint16 releaseBps = stored.releaseBps;
        uint16 pendingReleaseBps = stored.pendingReleaseBps;
        uint64 pendingReleaseEpoch = stored.pendingReleaseEpoch;
        if (pendingReleaseEpoch != 0 && pendingReleaseEpoch <= currentEpoch) {
            releaseBps = pendingReleaseBps;
            pendingReleaseBps = 0;
            pendingReleaseEpoch = 0;
        }
        uint256 available = stored.available;
        uint256 deferred = stored.deferred;
        uint64 maturity = stored.deferredMaturityEpoch;
        if (maturity != 0 && maturity <= currentEpoch) {
            available += deferred;
            deferred = 0;
            maturity = 0;
        }
        state = IStaticsGaugeIncentives.ReserveView({
            releaseBps: releaseBps,
            pendingReleaseBps: pendingReleaseBps,
            pendingReleaseEpoch: pendingReleaseEpoch,
            deferredMaturityEpoch: maturity,
            available: available,
            deferred: deferred,
            committed: stored.committed
        });
    }

    function gaugePoolWeight(PoolId poolId)
        external
        view
        returns (IStaticsGaugeIncentives.PoolWeightView memory state)
    {
        LibGaugeRouting.PoolWeight storage stored = LibGaugeRouting.routingStorage().poolWeights[poolId];
        bytes32 current = LibGaugeRouting.eligibilityVersion(poolId);
        state = IStaticsGaugeIncentives.PoolWeightView({
            scheduledWeight: stored.weight,
            storedVersion: stored.eligibilityVersion,
            currentVersion: current,
            stale: stored.weight != 0 && (current == bytes32(0) || stored.eligibilityVersion != current)
        });
    }

    function gaugePositionAllocations(uint256 positionId)
        external
        view
        returns (
            uint64 activeEpoch,
            IStaticsGaugeIncentives.AllocationView[] memory active,
            uint64 pendingEpoch,
            IStaticsGaugeIncentives.AllocationView[] memory pending,
            uint256 lockedStake
        )
    {
        LibPosition.enforceAuthorized(positionId, msg.sender);
        LibGaugeRouting.PositionAllocations storage stored = LibGaugeRouting.routingStorage().positions[positionId];
        activeEpoch = stored.activeEpoch;
        pendingEpoch = stored.pendingEpoch;
        active = _copy(stored.active);
        pending = _copy(stored.pending);
        lockedStake = LibGaugeRouting.lockedStake(positionId);
    }

    function gaugeEpoch(uint64 epoch) external view returns (IStaticsGaugeIncentives.EpochView memory state) {
        LibGaugeRouting.EpochState storage stored = LibGaugeRouting.routingStorage().epochs[epoch];
        state = IStaticsGaugeIncentives.EpochView({
            finalized: stored.finalized,
            releaseBps: stored.releaseBps,
            winnerCount: stored.winnerCount,
            activatedAt: stored.activatedAt,
            finish: stored.finish,
            nominalBudget: stored.nominalBudget,
            committedBudget: stored.committedBudget,
            totalWeight: stored.totalWeight,
            pools: stored.pools,
            weights: stored.weights,
            budgets: stored.budgets
        });
    }

    function previewGaugeTopTen()
        external
        view
        returns (PoolId[] memory pools, uint256[] memory weights, bool stale, PoolId stalePool)
    {
        LibGaugeHeap.Node[] memory winners;
        (winners, stale, stalePool) = LibGaugeRouting.topTen();
        pools = new PoolId[](winners.length);
        weights = new uint256[](winners.length);
        for (uint256 i; i < winners.length; ++i) {
            pools[i] = winners[i].poolId;
            weights[i] = winners[i].weight;
        }
    }

    function maxGaugeAllocationsPerPosition() external pure returns (uint256) {
        return LibGaugeRouting.MAX_ALLOCATIONS_PER_POSITION;
    }

    function maxWeeklyGaugeReleaseBps() external pure returns (uint16) {
        return LibGaugeReserve.MAX_WEEKLY_RELEASE_BPS;
    }

    function gaugeAllocatorReward(PoolId poolId, uint8 slot, uint64 epoch)
        external
        view
        returns (IStaticsGaugeIncentives.AllocatorRewardView memory state)
    {
        _validateAllocatorSlot(poolId, slot);
        LibGaugeBribes.Budget storage stored = LibGaugeBribes.bribeStorage().budgets[poolId][slot][epoch];
        state = IStaticsGaugeIncentives.AllocatorRewardView({
            asset: stored.asset,
            eligibilityVersion: stored.eligibilityVersion,
            finalized: stored.finalized,
            expired: stored.expired || (stored.finalized && block.timestamp >= stored.expiresAt),
            fundedAt: stored.fundedAt,
            expiresAt: stored.expiresAt,
            funded: stored.funded,
            totalWeight: stored.totalWeight,
            distributable: stored.distributable,
            remainingLiability: stored.remainingLiability
        });
    }

    function gaugePositionAllocationAt(uint256 positionId, PoolId poolId, uint64 epoch)
        external
        view
        returns (uint256 amount, bytes32 eligibilityVersion)
    {
        LibPosition.enforceAuthorized(positionId, msg.sender);
        return LibGaugeRouting.positionAllocationAt(positionId, poolId, epoch);
    }

    function previewGaugeAllocatorRewards(uint256 positionId, PoolId poolId, uint64 epoch, uint8[] calldata slots)
        external
        view
        returns (IStaticsGaugeIncentives.AllocatorClaimPreview[] memory rewards)
    {
        LibPosition.enforceAuthorized(positionId, msg.sender);
        rewards = new IStaticsGaugeIncentives.AllocatorClaimPreview[](slots.length);
        for (uint256 i; i < slots.length; ++i) {
            uint8 slot = slots[i];
            _validateAllocatorSlot(poolId, slot);
            LibGaugeBribes.Budget storage budget = LibGaugeBribes.bribeStorage().budgets[poolId][slot][epoch];
            (uint256 allocation, uint256 amount, bool claimed) = LibGaugeBribes.preview(positionId, poolId, slot, epoch);
            rewards[i] = IStaticsGaugeIncentives.AllocatorClaimPreview({
                slot: slot,
                asset: budget.asset,
                allocation: allocation,
                amount: amount,
                finalized: budget.finalized,
                claimed: claimed,
                expired: budget.expired || (budget.finalized && block.timestamp >= budget.expiresAt)
            });
        }
    }

    function gaugeAllocatorClaimWindow() external pure returns (uint64 epochs) {
        return LibGaugeBribes.CLAIM_WINDOW_EPOCHS;
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

    function _validateAllocatorSlot(PoolId poolId, uint8 slot) private view {
        if (slot == LibRangeGauge.STATICS_SLOT) {
            revert IStaticsGaugeIncentives.InvalidGaugeAllocatorSlot(poolId, slot);
        }
        (, bool assigned) = LibRangeGauge.rewardAsset(poolId, slot);
        if (!assigned) revert IStaticsGaugeIncentives.InvalidGaugeAllocatorSlot(poolId, slot);
    }
}
