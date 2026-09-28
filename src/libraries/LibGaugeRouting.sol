// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IStaticsGaugeIncentives} from "../interfaces/IStaticsGaugeIncentives.sol";
import {LibCustody} from "./LibCustody.sol";
import {LibGaugeBribes} from "./LibGaugeBribes.sol";
import {LibGaugeEligibility} from "./LibGaugeEligibility.sol";
import {LibGaugeReserve} from "./LibGaugeReserve.sol";
import {LibRangeGauge} from "./LibRangeGauge.sol";
import {LibRewardPolicy} from "./LibRewardPolicy.sol";

library LibGaugeRouting {
    bytes32 internal constant STORAGE_POSITION = keccak256("statics.storage.gauge.routing.v2");
    uint8 internal constant MAX_ALLOCATIONS_PER_POSITION = 16;
    uint16 internal constant MAX_CATCHUP_PERIODS = 52;
    uint40 internal constant DEFAULT_ALLOCATION_COOLDOWN = 4 hours;
    uint40 internal constant WEEK = 7 days;
    uint256 internal constant INDEX_SCALE = 1 << 160;

    struct Allocation {
        PoolId poolId;
        uint256 amount;
        bytes32 eligibilityVersion;
    }

    struct PositionAllocations {
        uint40 nextAllocationAt;
        uint256 totalAllocated;
        Allocation[] active;
    }

    struct PoolWeight {
        uint256 weight;
        bytes32 eligibilityVersion;
        uint64 restrictionSequence;
        uint256 indexCursorX160;
        uint256 entitlementRemainderX160;
    }

    struct RoutingStorage {
        bool initialized;
        bool activated;
        uint40 allocationCooldown;
        uint40 scheduleStart;
        uint40 lastCheckpoint;
        uint40 periodStart;
        uint40 periodFinish;
        uint64 currentPeriod;
        uint256 periodBudget;
        uint256 periodAccounted;
        uint256 totalAllocatedWeight;
        uint256 globalIndexX160;
        uint256 globalIndexRemainder;
        uint256 unsettledRoutingLiability;
        uint256 abstainingWeight;
        uint256 abstainingIndexCursorX160;
        uint256 abstainingRemainderX160;
        mapping(uint256 positionId => PositionAllocations allocations) positions;
        mapping(PoolId poolId => PoolWeight weight) poolWeights;
    }

    error GaugeRoutingAlreadyInitialized();
    error GaugeScheduleAlreadyActivated();
    error GaugeScheduleCatchupRequired(uint40 checkpointedAt, uint40 requestedAt);
    error GaugeCatchupLimitInvalid(uint256 requested, uint256 maximum);
    error GaugeAllocationIncreaseDuringCooldown(PoolId poolId, uint256 priorAmount, uint256 nextAmount);
    error GaugeWeightUnderflow(PoolId poolId, uint256 requested, uint256 available);
    error GaugeTotalWeightUnderflow(uint256 requested, uint256 available);
    error GaugeRoutingLiabilityUnderflow(uint256 requested, uint256 available);
    error GaugeTimestampRegression(uint40 prior, uint40 currentTime);

    function routingStorage() internal pure returns (RoutingStorage storage rs) {
        bytes32 position = STORAGE_POSITION;
        assembly ("memory-safe") {
            rs.slot := position
        }
    }

    function initialize(uint16 releaseBps) internal {
        RoutingStorage storage rs = routingStorage();
        if (rs.initialized) revert GaugeRoutingAlreadyInitialized();
        rs.initialized = true;
        rs.allocationCooldown = DEFAULT_ALLOCATION_COOLDOWN;
        LibGaugeReserve.initialize(releaseBps);
    }

    function activate(uint40 currentTime) internal returns (uint256 budget) {
        RoutingStorage storage rs = routingStorage();
        if (rs.activated) revert GaugeScheduleAlreadyActivated();
        rs.activated = true;
        rs.scheduleStart = currentTime;
        rs.lastCheckpoint = currentTime;
        rs.periodStart = currentTime;
        rs.periodFinish = _addWeek(currentTime);
        rs.abstainingIndexCursorX160 = rs.globalIndexX160;
        budget = _commitPeriodBudget(rs);
    }

    function setAllocationCooldown(uint40 cooldown) internal {
        routingStorage().allocationCooldown = cooldown;
    }

    function allocationCooldown() internal view returns (uint40) {
        return routingStorage().allocationCooldown;
    }

    function applyStakeIngressCooldown(uint256 positionId, uint40 currentTime)
        internal
        returns (uint40 nextAllocationAt, bool extended)
    {
        RoutingStorage storage rs = routingStorage();
        PositionAllocations storage position = rs.positions[positionId];
        uint40 candidate = _addTime(currentTime, rs.allocationCooldown);
        nextAllocationAt = position.nextAllocationAt;
        if (candidate > nextAllocationAt) {
            position.nextAllocationAt = candidate;
            nextAllocationAt = candidate;
            extended = true;
        }
    }

    function eligibilityVersion(PoolId poolId) internal view returns (bytes32 version) {
        return LibGaugeEligibility.version(poolId);
    }

    function checkpointSchedule(uint40 currentTime, uint16 maxPeriods)
        internal
        returns (uint16 periodsProcessed, uint256 newlyAccounted)
    {
        RoutingStorage storage rs = routingStorage();
        if (!rs.activated) return (0, 0);
        if (currentTime < rs.lastCheckpoint) revert GaugeTimestampRegression(rs.lastCheckpoint, currentTime);
        if (maxPeriods == 0 || maxPeriods > MAX_CATCHUP_PERIODS) {
            revert GaugeCatchupLimitInvalid(maxPeriods, MAX_CATCHUP_PERIODS);
        }

        while (currentTime >= rs.periodFinish && periodsProcessed < maxPeriods) {
            newlyAccounted += _accrueTo(rs, rs.periodFinish);
            _startNextPeriod(rs);
            ++periodsProcessed;
        }
        if (currentTime >= rs.periodFinish) return (periodsProcessed, newlyAccounted);
        newlyAccounted += _accrueTo(rs, currentTime);
    }

    function enforceScheduleCurrent(uint40 currentTime) internal view {
        RoutingStorage storage rs = routingStorage();
        if (rs.activated && currentTime >= rs.periodFinish) {
            revert GaugeScheduleCatchupRequired(rs.lastCheckpoint, currentTime);
        }
    }

    function setAllocations(
        uint256 positionId,
        PoolId[] calldata poolIds,
        uint256[] calldata amounts,
        uint256 staked,
        uint40 currentTime
    ) internal returns (uint40 nextAllocationAt, uint256 totalAllocated) {
        if (poolIds.length != amounts.length) {
            revert IStaticsGaugeIncentives.GaugeAllocationLengthMismatch();
        }
        if (poolIds.length > MAX_ALLOCATIONS_PER_POSITION) {
            revert IStaticsGaugeIncentives.GaugeAllocationLimitExceeded(poolIds.length, MAX_ALLOCATIONS_PER_POSITION);
        }
        RoutingStorage storage rs = routingStorage();
        checkpointSchedule(currentTime, MAX_CATCHUP_PERIODS);
        enforceScheduleCurrent(currentTime);
        PositionAllocations storage position = rs.positions[positionId];
        bool cooling = currentTime < position.nextAllocationAt;

        for (uint256 i; i < poolIds.length; ++i) {
            if (amounts[i] == 0) revert IStaticsGaugeIncentives.InvalidGaugeAllocation(poolIds[i], 0);
            for (uint256 prior; prior < i; ++prior) {
                if (PoolId.unwrap(poolIds[prior]) == PoolId.unwrap(poolIds[i])) {
                    revert IStaticsGaugeIncentives.DuplicateGaugeAllocation(poolIds[i]);
                }
            }
            bytes32 version = eligibilityVersion(poolIds[i]);
            if (version == bytes32(0)) revert IStaticsGaugeIncentives.InvalidGaugeAllocation(poolIds[i], amounts[i]);
            if (cooling) {
                uint256 priorAmount = _positionAmount(position, poolIds[i]);
                if (priorAmount == 0 || amounts[i] > priorAmount) {
                    revert GaugeAllocationIncreaseDuringCooldown(poolIds[i], priorAmount, amounts[i]);
                }
            }
            totalAllocated += amounts[i];
        }
        if (totalAllocated > staked) {
            revert IStaticsGaugeIncentives.GaugeAllocationExceedsStake(totalAllocated, staked);
        }

        _replacePositionAllocations(rs, positionId, position, poolIds, amounts, currentTime, totalAllocated);
        if (!cooling) position.nextAllocationAt = _addTime(currentTime, rs.allocationCooldown);
        nextAllocationAt = position.nextAllocationAt;
    }

    function checkpointPool(PoolId poolId, uint40 currentTime) internal returns (uint256 credited, uint256 recycled) {
        checkpointSchedule(currentTime, MAX_CATCHUP_PERIODS);
        enforceScheduleCurrent(currentTime);
        return _settlePool(routingStorage(), poolId, currentTime);
    }

    function checkpointPoolWithLimit(PoolId poolId, uint40 currentTime, uint16 maxPeriods)
        internal
        returns (uint256 credited, uint256 recycled)
    {
        checkpointSchedule(currentTime, maxPeriods);
        enforceScheduleCurrent(currentTime);
        return _settlePool(routingStorage(), poolId, currentTime);
    }

    function recycleProtocolClaim(uint256 amount, uint40 currentTime) internal {
        if (amount == 0) return;
        checkpointSchedule(currentTime, MAX_CATCHUP_PERIODS);
        enforceScheduleCurrent(currentTime);
        LibGaugeReserve.consumeCommitted(amount);
        LibGaugeReserve.defer(amount, routingStorage().periodFinish);
    }

    function invalidatePool(PoolId poolId, uint40 currentTime) internal returns (uint256 credited, uint256 recycled) {
        RoutingStorage storage rs = routingStorage();
        checkpointSchedule(currentTime, MAX_CATCHUP_PERIODS);
        enforceScheduleCurrent(currentTime);
        LibGaugeBribes.checkpointPool(poolId, currentTime, rs.poolWeights[poolId].weight);
        (credited, recycled) = _settlePool(rs, poolId, currentTime);
        PoolWeight storage stored = rs.poolWeights[poolId];
        uint256 weight = stored.weight;
        if (weight != 0) {
            _settleAbstaining(rs, currentTime);
            rs.abstainingWeight += weight;
            stored.weight = 0;
            stored.eligibilityVersion = bytes32(0);
            stored.indexCursorX160 = rs.globalIndexX160;
            stored.entitlementRemainderX160 = 0;
        }
    }

    function lockedStake(uint256 positionId) internal view returns (uint256 locked) {
        PositionAllocations storage position = routingStorage().positions[positionId];
        for (uint256 i; i < position.active.length; ++i) {
            Allocation storage allocation = position.active[i];
            if (eligibilityVersion(allocation.poolId) == allocation.eligibilityVersion) locked += allocation.amount;
        }
    }

    function positionAllocation(uint256 positionId, PoolId poolId)
        internal
        view
        returns (uint256 amount, bytes32 version)
    {
        PositionAllocations storage position = routingStorage().positions[positionId];
        for (uint256 i; i < position.active.length; ++i) {
            Allocation storage allocation = position.active[i];
            if (PoolId.unwrap(allocation.poolId) == PoolId.unwrap(poolId)) {
                return (allocation.amount, allocation.eligibilityVersion);
            }
        }
    }

    function periodAt(uint256 timestamp) internal view returns (uint64 period, bool active) {
        RoutingStorage storage rs = routingStorage();
        if (!rs.activated || timestamp < rs.scheduleStart) return (0, false);
        period = uint64((timestamp - rs.scheduleStart) / WEEK);
        active = true;
    }

    function clearForStakeLoss(uint256 positionId, uint256 remainingStake) internal {
        RoutingStorage storage rs = routingStorage();
        PositionAllocations storage position = rs.positions[positionId];
        if (remainingStake >= position.totalAllocated) return;
        uint40 currentTime = LibRangeGauge.timestamp40(block.timestamp);
        checkpointSchedule(currentTime, MAX_CATCHUP_PERIODS);
        enforceScheduleCurrent(currentTime);
        PoolId[] memory priorPools = _copyPoolIds(position);
        _checkpointAffectedPoolsMemory(rs, positionId, position, currentTime);
        _removePositionWeights(rs, position);
        delete position.active;
        position.totalAllocated = 0;
        _syncPositionLegs(positionId, position, priorPools);
        emit IStaticsGaugeIncentives.PositionGaugeAllocationsClearedByStakeLoss(positionId, remainingStake);
    }

    function _accrueTo(RoutingStorage storage rs, uint40 target) private returns (uint256 amount) {
        if (target == rs.lastCheckpoint) return 0;
        uint256 targetAccounted = target == rs.periodFinish
            ? rs.periodBudget
            : Math.mulDiv(rs.periodBudget, uint256(target) - rs.periodStart, WEEK);
        amount = targetAccounted - rs.periodAccounted;
        rs.periodAccounted = targetAccounted;
        rs.lastCheckpoint = target;
        if (amount == 0) return 0;
        uint256 denominator = rs.totalAllocatedWeight;
        if (denominator == 0) {
            _recycle(rs, amount);
            return amount;
        }
        (uint256 delta, uint256 remainder) = _indexDelta(amount, denominator, rs.globalIndexRemainder);
        rs.globalIndexX160 += delta;
        rs.globalIndexRemainder = remainder;
        rs.unsettledRoutingLiability += amount;
        _settleAbstaining(rs, target);
    }

    function _startNextPeriod(RoutingStorage storage rs) private {
        uint40 boundary = rs.periodFinish;
        rs.periodStart = boundary;
        rs.periodFinish = _addWeek(boundary);
        rs.lastCheckpoint = boundary;
        rs.periodAccounted = 0;
        ++rs.currentPeriod;
        LibGaugeReserve.rollDeferred(boundary);
        LibGaugeReserve.applyScheduledRelease(boundary);
        _commitPeriodBudget(rs);
    }

    function _commitPeriodBudget(RoutingStorage storage rs) private returns (uint256 budget) {
        LibGaugeReserve.ReserveStorage storage reserve = LibGaugeReserve.reserveStorage();
        budget = Math.mulDiv(reserve.available, reserve.releaseBps, LibGaugeReserve.BPS);
        rs.periodBudget = budget;
        LibGaugeReserve.commit(budget);
        emit IStaticsGaugeIncentives.GaugePeriodStarted(
            rs.currentPeriod, rs.periodStart, rs.periodFinish, reserve.releaseBps, budget, rs.totalAllocatedWeight
        );
    }

    function _settlePool(RoutingStorage storage rs, PoolId poolId, uint40 currentTime)
        private
        returns (uint256 credited, uint256 recycled)
    {
        PoolWeight storage stored = rs.poolWeights[poolId];
        uint256 weight = stored.weight;
        uint256 cursor = stored.indexCursorX160;
        uint256 index = rs.globalIndexX160;
        if (weight == 0) {
            stored.indexCursorX160 = index;
            return (0, 0);
        }

        bytes32 currentVersion = eligibilityVersion(poolId);
        if (currentVersion == stored.eligibilityVersion) {
            (uint256 amount, uint256 remainder) =
                _positionAccrual(weight, index - cursor, stored.entitlementRemainderX160);
            stored.indexCursorX160 = index;
            stored.entitlementRemainderX160 = remainder;
            (credited, recycled) = _deliverPoolAmount(rs, poolId, amount);
            return (credited, recycled);
        }

        return _settleInvalidPool(rs, stored, poolId, weight, cursor, index, currentTime);
    }

    function _settleInvalidPool(
        RoutingStorage storage rs,
        PoolWeight storage stored,
        PoolId poolId,
        uint256 weight,
        uint256 cursor,
        uint256 index,
        uint40 currentTime
    ) private returns (uint256 credited, uint256 recycled) {
        (bool found,, uint256 cutoffIndex) =
            LibGaugeEligibility.firstRestrictionAfter(poolId, stored.restrictionSequence);
        if (!found || cutoffIndex > index) cutoffIndex = index;
        if (cutoffIndex > cursor) {
            (uint256 eligibleAmount, uint256 eligibleRemainder) =
                _positionAccrual(weight, cutoffIndex - cursor, stored.entitlementRemainderX160);
            stored.entitlementRemainderX160 = eligibleRemainder;
            (credited, recycled) = _deliverPoolAmount(rs, poolId, eligibleAmount);
        }
        if (index > cutoffIndex) {
            (uint256 ineligibleAmount,) = _positionAccrual(weight, index - cutoffIndex, 0);
            _consumeRoutingLiability(rs, ineligibleAmount);
            _recycle(rs, ineligibleAmount);
            recycled += ineligibleAmount;
        }
        _settleAbstaining(rs, currentTime);
        rs.abstainingWeight += weight;
        stored.weight = 0;
        stored.eligibilityVersion = bytes32(0);
        stored.indexCursorX160 = index;
        stored.entitlementRemainderX160 = 0;
    }

    function _deliverPoolAmount(RoutingStorage storage rs, PoolId poolId, uint256 amount)
        private
        returns (uint256 credited, uint256 recycled)
    {
        if (amount == 0) return (0, 0);
        _consumeRoutingLiability(rs, amount);
        LibRangeGauge.GaugePool storage gauge = LibRangeGauge.rangeGaugeStorage().gauges[poolId];
        if (gauge.stopped || gauge.activeGaugeLiquidity == 0 || !LibRangeGauge.canCreditProtocolReward(poolId, amount))
        {
            _recycle(rs, amount);
            return (0, amount);
        }
        LibCustody.moveReservation(
            LibCustody.gaugeReserveAccount(),
            LibRangeGauge.rewardAccount(poolId, LibRangeGauge.STATICS_SLOT),
            LibRangeGauge.staticsToken(),
            amount
        );
        LibRangeGauge.creditProtocolReward(poolId, amount);
        credited = amount;
    }

    function _settleAbstaining(RoutingStorage storage rs, uint40) private {
        uint256 index = rs.globalIndexX160;
        uint256 weight = rs.abstainingWeight;
        if (weight == 0) {
            rs.abstainingIndexCursorX160 = index;
            return;
        }
        (uint256 amount, uint256 remainder) =
            _positionAccrual(weight, index - rs.abstainingIndexCursorX160, rs.abstainingRemainderX160);
        rs.abstainingIndexCursorX160 = index;
        rs.abstainingRemainderX160 = remainder;
        if (amount != 0) {
            _consumeRoutingLiability(rs, amount);
            _recycle(rs, amount);
        }
    }

    function _recycle(RoutingStorage storage rs, uint256 amount) private {
        if (amount == 0) return;
        LibGaugeReserve.consumeCommitted(amount);
        LibGaugeReserve.defer(amount, rs.periodFinish);
    }

    function _consumeRoutingLiability(RoutingStorage storage rs, uint256 amount) private {
        uint256 liability = rs.unsettledRoutingLiability;
        if (amount > liability) revert GaugeRoutingLiabilityUnderflow(amount, liability);
        rs.unsettledRoutingLiability = liability - amount;
    }

    function _checkpointAffectedPools(
        RoutingStorage storage rs,
        uint256 positionId,
        PositionAllocations storage position,
        PoolId[] calldata nextPools,
        uint40 currentTime
    ) private {
        for (uint256 i; i < position.active.length; ++i) {
            Allocation storage allocation = position.active[i];
            LibGaugeBribes.checkpointPool(allocation.poolId, currentTime, rs.poolWeights[allocation.poolId].weight);
            LibGaugeBribes.checkpointPosition(
                positionId, allocation.poolId, allocation.amount, allocation.eligibilityVersion
            );
            _settlePool(rs, allocation.poolId, currentTime);
        }
        for (uint256 i; i < nextPools.length; ++i) {
            bool seen;
            for (uint256 prior; prior < position.active.length; ++prior) {
                if (PoolId.unwrap(position.active[prior].poolId) == PoolId.unwrap(nextPools[i])) {
                    seen = true;
                    break;
                }
            }
            if (!seen) {
                LibGaugeBribes.checkpointPool(nextPools[i], currentTime, rs.poolWeights[nextPools[i]].weight);
                // A newly allocated position starts at the current pool index and cannot
                // inherit creator-funded rewards emitted before it supplied routing weight.
                LibGaugeBribes.checkpointPosition(positionId, nextPools[i], 0, eligibilityVersion(nextPools[i]));
                _settlePool(rs, nextPools[i], currentTime);
            }
        }
    }

    function _replacePositionAllocations(
        RoutingStorage storage rs,
        uint256 positionId,
        PositionAllocations storage position,
        PoolId[] calldata poolIds,
        uint256[] calldata amounts,
        uint40 currentTime,
        uint256 totalAllocated
    ) private {
        PoolId[] memory priorPools = _copyPoolIds(position);
        _checkpointAffectedPools(rs, positionId, position, poolIds, currentTime);
        _removePositionWeights(rs, position);
        delete position.active;
        for (uint256 i; i < poolIds.length; ++i) {
            bytes32 version = eligibilityVersion(poolIds[i]);
            position.active.push(Allocation({poolId: poolIds[i], amount: amounts[i], eligibilityVersion: version}));
            _increasePoolWeight(rs, poolIds[i], version, amounts[i]);
            LibGaugeBribes.checkpointPosition(positionId, poolIds[i], amounts[i], version);
        }
        position.totalAllocated = totalAllocated;
        _syncPositionLegs(positionId, position, priorPools);
    }

    function _checkpointAffectedPoolsMemory(
        RoutingStorage storage rs,
        uint256 positionId,
        PositionAllocations storage position,
        uint40 currentTime
    ) private {
        for (uint256 i; i < position.active.length; ++i) {
            Allocation storage allocation = position.active[i];
            LibGaugeBribes.checkpointPool(allocation.poolId, currentTime, rs.poolWeights[allocation.poolId].weight);
            LibGaugeBribes.checkpointPosition(
                positionId, allocation.poolId, allocation.amount, allocation.eligibilityVersion
            );
            _settlePool(rs, allocation.poolId, currentTime);
        }
    }

    function _copyPoolIds(PositionAllocations storage position) private view returns (PoolId[] memory poolIds) {
        poolIds = new PoolId[](position.active.length);
        for (uint256 i; i < poolIds.length; ++i) {
            poolIds[i] = position.active[i].poolId;
        }
    }

    function _syncPositionLegs(uint256 positionId, PositionAllocations storage position, PoolId[] memory priorPools)
        private
    {
        for (uint256 i; i < priorPools.length; ++i) {
            LibGaugeBribes.syncPositionLeg(positionId, priorPools[i], _positionAmount(position, priorPools[i]));
        }
        for (uint256 i; i < position.active.length; ++i) {
            Allocation storage allocation = position.active[i];
            LibGaugeBribes.syncPositionLeg(positionId, allocation.poolId, allocation.amount);
        }
    }

    function _removePositionWeights(RoutingStorage storage rs, PositionAllocations storage position) private {
        _settleAbstaining(rs, rs.lastCheckpoint);
        for (uint256 i; i < position.active.length; ++i) {
            Allocation storage allocation = position.active[i];
            PoolWeight storage stored = rs.poolWeights[allocation.poolId];
            if (stored.eligibilityVersion == allocation.eligibilityVersion) {
                if (allocation.amount > stored.weight) {
                    revert GaugeWeightUnderflow(allocation.poolId, allocation.amount, stored.weight);
                }
                stored.weight -= allocation.amount;
            } else {
                if (allocation.amount > rs.abstainingWeight) {
                    revert GaugeWeightUnderflow(allocation.poolId, allocation.amount, rs.abstainingWeight);
                }
                rs.abstainingWeight -= allocation.amount;
            }
            if (allocation.amount > rs.totalAllocatedWeight) {
                revert GaugeTotalWeightUnderflow(allocation.amount, rs.totalAllocatedWeight);
            }
            rs.totalAllocatedWeight -= allocation.amount;
        }
        rs.globalIndexRemainder = 0;
    }

    function _increasePoolWeight(RoutingStorage storage rs, PoolId poolId, bytes32 version, uint256 amount) private {
        PoolWeight storage stored = rs.poolWeights[poolId];
        if (stored.eligibilityVersion != version) {
            stored.eligibilityVersion = version;
            stored.restrictionSequence = LibRewardPolicy.restrictionSequence();
            stored.indexCursorX160 = rs.globalIndexX160;
            stored.entitlementRemainderX160 = 0;
        }
        stored.weight += amount;
        rs.totalAllocatedWeight += amount;
        rs.globalIndexRemainder = 0;
    }

    function _positionAmount(PositionAllocations storage position, PoolId poolId)
        private
        view
        returns (uint256 amount)
    {
        for (uint256 i; i < position.active.length; ++i) {
            if (PoolId.unwrap(position.active[i].poolId) == PoolId.unwrap(poolId)) {
                return position.active[i].amount;
            }
        }
    }

    function _indexDelta(uint256 amount, uint256 denominator, uint256 priorRemainder)
        private
        pure
        returns (uint256 delta, uint256 remainder)
    {
        delta = Math.mulDiv(amount, INDEX_SCALE, denominator);
        remainder = mulmod(amount, INDEX_SCALE, denominator);
        uint256 combined = remainder + priorRemainder;
        if (combined >= denominator) {
            ++delta;
            combined -= denominator;
        }
        remainder = combined;
    }

    function _positionAccrual(uint256 weight, uint256 growth, uint256 priorRemainder)
        private
        pure
        returns (uint256 amount, uint256 remainder)
    {
        amount = Math.mulDiv(weight, growth, INDEX_SCALE);
        remainder = mulmod(weight, growth, INDEX_SCALE);
        uint256 combined = remainder + priorRemainder;
        if (combined >= INDEX_SCALE) {
            ++amount;
            combined -= INDEX_SCALE;
        }
        remainder = combined;
    }

    function _addWeek(uint40 timestamp) private pure returns (uint40 result) {
        return _addTime(timestamp, WEEK);
    }

    function _addTime(uint40 timestamp, uint40 duration) private pure returns (uint40 result) {
        uint256 sum = uint256(timestamp) + duration;
        if (sum > type(uint40).max) revert IStaticsGaugeIncentives.InvalidGaugeTimestamp(sum);
        result = uint40(sum);
    }
}
