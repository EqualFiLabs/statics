// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IStaticsGaugeIncentives} from "../interfaces/IStaticsGaugeIncentives.sol";
import {LibCustody} from "./LibCustody.sol";
import {LibGaugeEligibility} from "./LibGaugeEligibility.sol";
import {LibGaugeEpoch} from "./LibGaugeEpoch.sol";
import {LibGaugeHeap} from "./LibGaugeHeap.sol";
import {LibGaugeReserve} from "./LibGaugeReserve.sol";
import {LibRangeGauge} from "./LibRangeGauge.sol";

library LibGaugeRouting {
    using LibGaugeHeap for LibGaugeHeap.Heap;

    bytes32 internal constant STORAGE_POSITION = keccak256("statics.storage.gauge.routing.v1");
    uint8 internal constant MAX_ALLOCATIONS_PER_POSITION = 16;
    uint8 internal constant TOP_POOL_COUNT = 10;

    struct Allocation {
        PoolId poolId;
        uint256 amount;
        bytes32 eligibilityVersion;
    }

    struct PositionAllocations {
        uint64 activeEpoch;
        uint64 pendingEpoch;
        Allocation[] active;
        Allocation[] pending;
    }

    struct PoolWeight {
        uint256 weight;
        bytes32 eligibilityVersion;
    }

    struct PoolWeightCheckpoint {
        uint64 epoch;
        uint256 weight;
        bytes32 eligibilityVersion;
    }

    struct PositionAllocationCheckpoint {
        uint64 epoch;
        uint256 amount;
        bytes32 eligibilityVersion;
    }

    struct EpochState {
        bool finalized;
        uint16 releaseBps;
        uint8 winnerCount;
        uint40 activatedAt;
        uint40 finish;
        uint256 nominalBudget;
        uint256 committedBudget;
        uint256 totalWeight;
        PoolId[10] pools;
        uint256[10] weights;
        uint256[10] budgets;
    }

    struct RoutingStorage {
        bool initialized;
        uint64 lastFinalizedEpoch;
        mapping(uint256 positionId => PositionAllocations allocations) positions;
        mapping(PoolId poolId => PoolWeight weight) poolWeights;
        LibGaugeHeap.Heap heap;
        mapping(uint64 epoch => EpochState state) epochs;
        mapping(PoolId poolId => PoolWeightCheckpoint[] checkpoints) poolWeightHistory;
        mapping(uint256 positionId => mapping(PoolId poolId => PositionAllocationCheckpoint[] checkpoints))
            positionAllocationHistory;
    }

    error GaugeRoutingAlreadyInitialized();
    error GaugeWeightUnderflow(PoolId poolId, uint256 requested, uint256 available);

    function routingStorage() internal pure returns (RoutingStorage storage rs) {
        bytes32 position = STORAGE_POSITION;
        assembly ("memory-safe") {
            rs.slot := position
        }
    }

    function initialize(uint16 releaseBps) internal {
        RoutingStorage storage rs = routingStorage();
        if (rs.initialized) revert GaugeRoutingAlreadyInitialized();
        uint64 currentEpoch = LibGaugeEpoch.epochAt(block.timestamp);
        rs.initialized = true;
        rs.lastFinalizedEpoch = currentEpoch;
        EpochState storage current = rs.epochs[currentEpoch];
        current.finalized = true;
        current.releaseBps = releaseBps;
        current.activatedAt = uint40(block.timestamp);
        current.finish = LibGaugeEpoch.epochFinish(currentEpoch);
        LibGaugeReserve.initialize(releaseBps);
    }

    function eligibilityVersion(PoolId poolId) internal view returns (bytes32 version) {
        LibRangeGauge.GaugePool storage gauge = LibRangeGauge.rangeGaugeStorage().gauges[poolId];
        if (!gauge.initialized || gauge.stopped) return bytes32(0);
        return LibGaugeEligibility.version(poolId);
    }

    function setAllocations(uint256 positionId, PoolId[] calldata poolIds, uint256[] calldata amounts, uint256 staked)
        internal
        returns (uint64 effectiveEpoch, uint256 totalAllocated)
    {
        if (poolIds.length != amounts.length) revert IStaticsGaugeIncentives.GaugeAllocationLengthMismatch();
        if (poolIds.length > MAX_ALLOCATIONS_PER_POSITION) {
            revert IStaticsGaugeIncentives.GaugeAllocationLimitExceeded(poolIds.length, MAX_ALLOCATIONS_PER_POSITION);
        }
        RoutingStorage storage rs = routingStorage();
        uint64 currentEpoch = LibGaugeEpoch.epochAt(block.timestamp);
        if (rs.lastFinalizedEpoch != currentEpoch) {
            revert IStaticsGaugeIncentives.GaugeEpochNotFinalized(currentEpoch);
        }
        PositionAllocations storage position = rs.positions[positionId];
        _promote(position, currentEpoch);
        effectiveEpoch = currentEpoch + 1;
        _removeScheduledWeights(rs, positionId, position, currentEpoch, effectiveEpoch);

        delete position.pending;
        totalAllocated = _setPendingAllocations(rs, position, positionId, poolIds, amounts, effectiveEpoch);

        if (totalAllocated > staked) {
            revert IStaticsGaugeIncentives.GaugeAllocationExceedsStake(totalAllocated, staked);
        }
        position.pendingEpoch = effectiveEpoch;
    }

    function _setPendingAllocations(
        RoutingStorage storage rs,
        PositionAllocations storage position,
        uint256 positionId,
        PoolId[] calldata poolIds,
        uint256[] calldata amounts,
        uint64 effectiveEpoch
    ) private returns (uint256 totalAllocated) {
        for (uint256 i; i < poolIds.length; ++i) {
            PoolId poolId = poolIds[i];
            uint256 amount = amounts[i];
            if (amount == 0) revert IStaticsGaugeIncentives.InvalidGaugeAllocation(poolId, amount);
            for (uint256 prior; prior < i; ++prior) {
                if (PoolId.unwrap(poolIds[prior]) == PoolId.unwrap(poolId)) {
                    revert IStaticsGaugeIncentives.DuplicateGaugeAllocation(poolId);
                }
            }
            bytes32 version = eligibilityVersion(poolId);
            if (version == bytes32(0)) revert IStaticsGaugeIncentives.InvalidGaugeAllocation(poolId, amount);
            position.pending.push(Allocation({poolId: poolId, amount: amount, eligibilityVersion: version}));
            _increasePoolWeight(rs, poolId, version, amount);
            _writePositionCheckpoint(rs, positionId, poolId, effectiveEpoch, amount, version);
            _writePoolWeightCheckpoint(rs, poolId, effectiveEpoch);
            totalAllocated += amount;
        }
    }

    function checkpointEpoch(uint40 currentTime)
        internal
        returns (uint64 epoch, uint256 committedBudget, bool finalized)
    {
        epoch = LibGaugeEpoch.epochAt(currentTime);
        RoutingStorage storage rs = routingStorage();
        if (epoch <= rs.lastFinalizedEpoch) return (epoch, 0, false);

        _settlePreviousEpoch(rs, currentTime);
        LibGaugeReserve.rollDeferred(epoch);
        uint16 releaseBps = LibGaugeReserve.applyScheduledRelease(epoch);
        LibGaugeHeap.Node[] memory winners = rs.heap.top(TOP_POOL_COUNT);
        uint256 totalWeight = _validateWinners(rs, winners);

        EpochState storage state = rs.epochs[epoch];
        state.finalized = true;
        state.releaseBps = releaseBps;
        state.winnerCount = uint8(winners.length);
        state.activatedAt = currentTime;
        state.finish = LibGaugeEpoch.epochFinish(epoch);
        state.totalWeight = totalWeight;
        uint256 available = LibGaugeReserve.reserveStorage().available;
        state.nominalBudget = Math.mulDiv(available, releaseBps, LibGaugeReserve.BPS);
        uint256 distributable =
            Math.mulDiv(state.nominalBudget, uint256(state.finish) - currentTime, LibGaugeEpoch.WEEK);

        for (uint256 i; i < winners.length; ++i) {
            LibGaugeHeap.Node memory winner = winners[i];
            uint256 budget = totalWeight == 0 ? 0 : Math.mulDiv(distributable, winner.weight, totalWeight);
            state.pools[i] = winner.poolId;
            state.weights[i] = winner.weight;
            state.budgets[i] = budget;
            committedBudget += budget;
        }
        state.committedBudget = committedBudget;
        rs.lastFinalizedEpoch = epoch;

        LibGaugeReserve.commit(committedBudget);
        _commitWinnerStreams(state, epoch, currentTime, winners);
        finalized = true;
    }

    function _commitWinnerStreams(
        EpochState storage state,
        uint64 epoch,
        uint40 currentTime,
        LibGaugeHeap.Node[] memory winners
    ) private {
        address statics = LibRangeGauge.staticsToken();
        for (uint256 i; i < winners.length; ++i) {
            uint256 budget = state.budgets[i];
            if (budget == 0) continue;
            PoolId poolId = winners[i].poolId;
            LibCustody.moveReservation(
                LibCustody.gaugeReserveAccount(),
                LibRangeGauge.rewardAccount(poolId, LibRangeGauge.STATICS_SLOT),
                statics,
                budget
            );
            LibRangeGauge.startProtocolStream(poolId, epoch, currentTime, state.finish, budget);
        }
    }

    function refreshPoolWeight(PoolId poolId)
        internal
        returns (uint256 removedWeight, bytes32 previous, bytes32 current)
    {
        RoutingStorage storage rs = routingStorage();
        PoolWeight storage stored = rs.poolWeights[poolId];
        previous = stored.eligibilityVersion;
        current = eligibilityVersion(poolId);
        if (previous == current && (current != bytes32(0) || stored.weight == 0)) {
            revert IStaticsGaugeIncentives.GaugePoolWeightCurrent(poolId);
        }
        removedWeight = stored.weight;
        stored.weight = 0;
        stored.eligibilityVersion = current;
        rs.heap.set(poolId, 0);
        _writePoolWeightCheckpoint(rs, poolId, LibGaugeEpoch.epochAt(block.timestamp) + 1);
    }

    function lockedStake(uint256 positionId) internal view returns (uint256 locked) {
        PositionAllocations storage position = routingStorage().positions[positionId];
        uint64 currentEpoch = LibGaugeEpoch.epochAt(block.timestamp);
        uint256 active = _validAllocationTotal(
            position.pendingEpoch != 0 && position.pendingEpoch <= currentEpoch ? position.pending : position.active
        );
        uint256 pending = position.pendingEpoch > currentEpoch ? _validAllocationTotal(position.pending) : active;
        locked = active > pending ? active : pending;
    }

    function clearForStakeLoss(uint256 positionId, uint256 remainingStake) internal {
        RoutingStorage storage rs = routingStorage();
        PositionAllocations storage position = rs.positions[positionId];
        if (position.active.length == 0 && position.pending.length == 0) return;
        if (remainingStake >= lockedStake(positionId)) return;
        uint64 currentEpoch = LibGaugeEpoch.epochAt(block.timestamp);
        _promote(position, currentEpoch);
        for (uint256 i; i < position.active.length; ++i) {
            Allocation storage active = position.active[i];
            _writePositionCheckpoint(rs, positionId, active.poolId, currentEpoch, 0, active.eligibilityVersion);
        }
        _removeScheduledWeights(rs, positionId, position, currentEpoch, currentEpoch + 1);
        delete position.active;
        delete position.pending;
        position.activeEpoch = currentEpoch;
        position.pendingEpoch = 0;
        emit IStaticsGaugeIncentives.PositionGaugeAllocationsClearedByStakeLoss(positionId, remainingStake);
    }

    function topTen() internal view returns (LibGaugeHeap.Node[] memory winners, bool stale, PoolId stalePool) {
        RoutingStorage storage rs = routingStorage();
        winners = rs.heap.top(TOP_POOL_COUNT);
        for (uint256 i; i < winners.length; ++i) {
            PoolId poolId = winners[i].poolId;
            PoolWeight storage stored = rs.poolWeights[poolId];
            bytes32 current = eligibilityVersion(poolId);
            if (current == bytes32(0) || stored.eligibilityVersion != current || stored.weight != winners[i].weight) {
                return (winners, true, poolId);
            }
        }
    }

    function poolWeightAt(PoolId poolId, uint64 epoch)
        internal
        view
        returns (uint256 weight, bytes32 checkpointVersion)
    {
        PoolWeightCheckpoint[] storage checkpoints = routingStorage().poolWeightHistory[poolId];
        uint256 low;
        uint256 high = checkpoints.length;
        while (low < high) {
            uint256 mid = (low + high) >> 1;
            if (checkpoints[mid].epoch <= epoch) low = mid + 1;
            else high = mid;
        }
        if (low == 0) return (0, bytes32(0));
        PoolWeightCheckpoint storage checkpoint = checkpoints[low - 1];
        return (checkpoint.weight, checkpoint.eligibilityVersion);
    }

    function positionAllocationAt(uint256 positionId, PoolId poolId, uint64 epoch)
        internal
        view
        returns (uint256 amount, bytes32 checkpointVersion)
    {
        PositionAllocationCheckpoint[] storage checkpoints =
            routingStorage().positionAllocationHistory[positionId][poolId];
        uint256 low;
        uint256 high = checkpoints.length;
        while (low < high) {
            uint256 mid = (low + high) >> 1;
            if (checkpoints[mid].epoch <= epoch) low = mid + 1;
            else high = mid;
        }
        if (low == 0) return (0, bytes32(0));
        PositionAllocationCheckpoint storage checkpoint = checkpoints[low - 1];
        return (checkpoint.amount, checkpoint.eligibilityVersion);
    }

    function _settlePreviousEpoch(RoutingStorage storage rs, uint40 currentTime) private {
        EpochState storage previous = rs.epochs[rs.lastFinalizedEpoch];
        for (uint256 i; i < previous.winnerCount; ++i) {
            LibRangeGauge.checkpointProtocolStream(previous.pools[i], currentTime);
        }
    }

    function _validateWinners(RoutingStorage storage rs, LibGaugeHeap.Node[] memory winners)
        private
        view
        returns (uint256 totalWeight)
    {
        for (uint256 i; i < winners.length; ++i) {
            PoolId poolId = winners[i].poolId;
            PoolWeight storage stored = rs.poolWeights[poolId];
            bytes32 current = eligibilityVersion(poolId);
            if (current == bytes32(0) || stored.eligibilityVersion != current || stored.weight != winners[i].weight) {
                revert IStaticsGaugeIncentives.StaleGaugePoolWeight(poolId, stored.eligibilityVersion, current);
            }
            totalWeight += winners[i].weight;
        }
    }

    function _promote(PositionAllocations storage position, uint64 currentEpoch) private {
        uint64 pendingEpoch = position.pendingEpoch;
        if (pendingEpoch == 0 || pendingEpoch > currentEpoch) return;
        delete position.active;
        for (uint256 i; i < position.pending.length; ++i) {
            position.active.push(position.pending[i]);
        }
        position.activeEpoch = pendingEpoch;
        delete position.pending;
        position.pendingEpoch = 0;
    }

    function _removeScheduledWeights(
        RoutingStorage storage rs,
        uint256 positionId,
        PositionAllocations storage position,
        uint64 currentEpoch,
        uint64 effectiveEpoch
    ) private {
        Allocation[] storage scheduled = position.pendingEpoch == currentEpoch + 1 ? position.pending : position.active;
        for (uint256 i; i < scheduled.length; ++i) {
            Allocation storage allocation = scheduled[i];
            _writePositionCheckpoint(
                rs, positionId, allocation.poolId, effectiveEpoch, 0, allocation.eligibilityVersion
            );
            bytes32 current = eligibilityVersion(allocation.poolId);
            if (current == bytes32(0) || allocation.eligibilityVersion != current) continue;
            PoolWeight storage stored = rs.poolWeights[allocation.poolId];
            if (stored.eligibilityVersion != current) continue;
            uint256 weight = stored.weight;
            if (allocation.amount > weight) {
                revert GaugeWeightUnderflow(allocation.poolId, allocation.amount, weight);
            }
            stored.weight = weight - allocation.amount;
            rs.heap.set(allocation.poolId, stored.weight);
            _writePoolWeightCheckpoint(rs, allocation.poolId, effectiveEpoch);
        }
    }

    function _increasePoolWeight(RoutingStorage storage rs, PoolId poolId, bytes32 version, uint256 amount) private {
        PoolWeight storage stored = rs.poolWeights[poolId];
        if (stored.eligibilityVersion != version) {
            stored.weight = 0;
            stored.eligibilityVersion = version;
            rs.heap.set(poolId, 0);
        }
        stored.weight += amount;
        rs.heap.set(poolId, stored.weight);
    }

    function _validAllocationTotal(Allocation[] storage allocations) private view returns (uint256 total) {
        for (uint256 i; i < allocations.length; ++i) {
            Allocation storage allocation = allocations[i];
            bytes32 current = eligibilityVersion(allocation.poolId);
            if (current != bytes32(0) && allocation.eligibilityVersion == current) total += allocation.amount;
        }
    }

    function _writePoolWeightCheckpoint(RoutingStorage storage rs, PoolId poolId, uint64 epoch) private {
        PoolWeight storage weight = rs.poolWeights[poolId];
        PoolWeightCheckpoint[] storage checkpoints = rs.poolWeightHistory[poolId];
        uint256 length = checkpoints.length;
        if (length != 0 && checkpoints[length - 1].epoch == epoch) {
            checkpoints[length - 1].weight = weight.weight;
            checkpoints[length - 1].eligibilityVersion = weight.eligibilityVersion;
            return;
        }
        checkpoints.push(
            PoolWeightCheckpoint({epoch: epoch, weight: weight.weight, eligibilityVersion: weight.eligibilityVersion})
        );
    }

    function _writePositionCheckpoint(
        RoutingStorage storage rs,
        uint256 positionId,
        PoolId poolId,
        uint64 epoch,
        uint256 amount,
        bytes32 recordedVersion
    ) private {
        PositionAllocationCheckpoint[] storage checkpoints = rs.positionAllocationHistory[positionId][poolId];
        uint256 length = checkpoints.length;
        PositionAllocationCheckpoint memory next =
            PositionAllocationCheckpoint({epoch: epoch, amount: amount, eligibilityVersion: recordedVersion});
        if (length == 0) {
            checkpoints.push(next);
            return;
        }
        PositionAllocationCheckpoint storage last = checkpoints[length - 1];
        if (last.epoch == epoch) {
            last.amount = amount;
            last.eligibilityVersion = recordedVersion;
            return;
        }
        if (last.epoch < epoch) {
            checkpoints.push(next);
            return;
        }
        // Forced stake loss may clear the current epoch while a next-epoch update is pending.
        if (last.epoch != epoch + 1) revert();
        if (length > 1 && checkpoints[length - 2].epoch == epoch) {
            checkpoints[length - 2].amount = amount;
            checkpoints[length - 2].eligibilityVersion = recordedVersion;
            return;
        }
        PositionAllocationCheckpoint memory future = last;
        checkpoints.push(future);
        checkpoints[length] = future;
        checkpoints[length - 1] = next;
    }
}
