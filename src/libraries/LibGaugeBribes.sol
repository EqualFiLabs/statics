// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IStaticsGaugeIncentives} from "../interfaces/IStaticsGaugeIncentives.sol";
import {LibCustody} from "./LibCustody.sol";
import {LibGaugeEligibility} from "./LibGaugeEligibility.sol";
import {LibGlobalRewards} from "./LibGlobalRewards.sol";
import {LibIndexMath} from "./LibIndexMath.sol";
import {LibRangeGauge} from "./LibRangeGauge.sol";
import {LibPosition} from "../position/LibPosition.sol";

/// @notice Continuous creator-funded rewards for STATICS stake allocated to a pool.
library LibGaugeBribes {
    bytes32 internal constant STORAGE_POSITION = keccak256("statics.storage.gauge.bribes.v1");
    bytes32 internal constant ACCOUNT_DOMAIN = keccak256("statics.custody.account.gauge.bribes.v1");
    uint256 internal constant INDEX_SCALE = 1 << 160;
    uint256 internal constant MAX_INDEXABLE_REWARD = type(uint256).max / INDEX_SCALE;
    uint256 internal constant MAX_POSITION_POOL_PAGE_SIZE = 100;

    struct Stream {
        address asset;
        bytes32 eligibilityVersion;
        uint64 fundingRestrictionSequence;
        uint40 periodStart;
        uint40 periodFinish;
        uint40 lastUpdate;
        uint256 periodBudget;
        uint256 periodEmitted;
        uint256 generationStartIndexX160;
        uint256 globalIndexX160;
        uint256 indexRemainder;
        uint256 indexedLiability;
        uint256 claimLiability;
        uint256 capacityUsed;
        uint256 forfeitedRemainderX160;
        bool terminated;
    }

    struct Generation {
        uint256 startIndexX160;
        uint256 terminalIndexX160;
        bool initialized;
        bool finalized;
    }

    struct PositionLeg {
        bytes32[5] checkpointVersion;
        uint256[5] checkpointIndexX160;
        uint256[5] rewardRemainderX160;
        uint256[5] claimable;
    }

    struct PoolIndex {
        PoolId[] values;
        mapping(PoolId poolId => uint256 indexPlusOne) indexPlusOne;
    }

    struct BribeStorage {
        mapping(PoolId poolId => mapping(uint8 slot => Stream stream)) streams;
        mapping(uint256 positionId => mapping(PoolId poolId => PositionLeg leg)) legs;
        mapping(PoolId poolId => mapping(uint8 slot => mapping(bytes32 version => Generation generation))) generations;
        mapping(uint256 positionId => PoolIndex index) positionPools;
    }

    error GaugeBribeAssetMismatch(address expected, address actual);
    error GaugeBribeTimestampRegression(uint40 previousTimestamp, uint40 currentTimestamp);
    error GaugeBribeCapacityExceeded(uint256 used, uint256 amount, uint256 maximum);
    error GaugeBribeInvalidDuration(uint40 duration);

    function bribeStorage() internal pure returns (BribeStorage storage bs) {
        bytes32 position = STORAGE_POSITION;
        assembly ("memory-safe") {
            bs.slot := position
        }
    }

    function account(PoolId poolId, uint8 slot) internal pure returns (bytes32) {
        return keccak256(abi.encode(ACCOUNT_DOMAIN, PoolId.unwrap(poolId), slot));
    }

    function checkpointPool(PoolId poolId, uint40 currentTime, uint256 poolWeight) internal {
        uint8 slotCount = LibRangeGauge.rangeGaugeStorage().rewardConfig[poolId].slotCount;
        for (uint8 slot = 1; slot < slotCount; ++slot) {
            checkpointStream(poolId, slot, currentTime, poolWeight);
        }
    }

    function checkpointStream(PoolId poolId, uint8 slot, uint40 currentTime, uint256 poolWeight)
        internal
        returns (uint256 emitted, uint256 treasuryAmount)
    {
        Stream storage stream = bribeStorage().streams[poolId][slot];
        if (stream.asset == address(0)) return (0, 0);
        if (currentTime < stream.lastUpdate) {
            revert GaugeBribeTimestampRegression(stream.lastUpdate, currentTime);
        }

        bool terminate;
        if (!stream.terminated && LibGaugeEligibility.version(poolId) != stream.eligibilityVersion) {
            terminate = true;
        }
        if (currentTime == stream.lastUpdate && !terminate) return (0, 0);

        // A zero-weight interval pauses the entire remaining schedule. Advancing only to the
        // stale finish would let the first later allocator receive rewards for an idle period.
        if (poolWeight == 0 && !terminate && !stream.terminated) {
            uint40 elapsed = currentTime - stream.lastUpdate;
            stream.periodFinish = _addTime(stream.periodFinish, elapsed);
            stream.lastUpdate = currentTime;
            return (0, 0);
        }

        uint40 accrualEnd = currentTime < stream.periodFinish ? currentTime : stream.periodFinish;
        if (terminate) {
            (bool found, uint40 restrictedAt,) =
                LibGaugeEligibility.firstRestrictionAfter(poolId, stream.fundingRestrictionSequence);
            if (found && restrictedAt < accrualEnd) accrualEnd = restrictedAt;
        }

        if (accrualEnd > stream.lastUpdate) {
            uint40 elapsed = accrualEnd - stream.lastUpdate;
            if (poolWeight != 0) {
                uint256 remaining = stream.periodBudget - stream.periodEmitted;
                uint40 remainingTime = stream.periodFinish - stream.lastUpdate;
                emitted = accrualEnd == stream.periodFinish ? remaining : Math.mulDiv(remaining, elapsed, remainingTime);
                stream.periodEmitted += emitted;
                _increaseIndex(stream, emitted, poolWeight);
            }
            stream.lastUpdate = accrualEnd;
        }

        if (terminate && !stream.terminated) {
            stream.terminated = true;
            _finalizeGeneration(poolId, slot, stream.eligibilityVersion, stream.globalIndexX160);
            treasuryAmount = stream.periodBudget - stream.periodEmitted;
            stream.periodBudget = stream.periodEmitted;
            stream.periodFinish = stream.lastUpdate;
            _toTreasury(poolId, slot, stream.asset, treasuryAmount);
        } else if (currentTime > stream.lastUpdate && stream.lastUpdate == stream.periodFinish) {
            stream.lastUpdate = currentTime;
        }
    }

    function recordFunding(
        PoolId poolId,
        uint8 slot,
        address asset,
        bytes32 eligibilityVersion,
        uint64 fundingRestrictionSequence,
        uint40 currentTime,
        uint40 duration,
        uint256 poolWeight,
        uint256 amount
    ) internal {
        if (duration == 0) revert GaugeBribeInvalidDuration(duration);
        BribeStorage storage bs = bribeStorage();
        Stream storage stream = bs.streams[poolId][slot];
        if (stream.asset != address(0) && stream.asset != asset) {
            revert GaugeBribeAssetMismatch(stream.asset, asset);
        }
        checkpointStream(poolId, slot, currentTime, poolWeight);
        uint256 used = stream.capacityUsed;
        if (used > MAX_INDEXABLE_REWARD || amount > MAX_INDEXABLE_REWARD - used) {
            revert GaugeBribeCapacityExceeded(used, amount, MAX_INDEXABLE_REWARD);
        }
        stream.capacityUsed = used + amount;
        stream.asset = asset;
        if (stream.eligibilityVersion != eligibilityVersion) {
            Generation storage generation = bs.generations[poolId][slot][eligibilityVersion];
            if (!generation.initialized) {
                generation.startIndexX160 = stream.globalIndexX160;
                generation.initialized = true;
            }
            stream.generationStartIndexX160 = generation.startIndexX160;
        }
        stream.eligibilityVersion = eligibilityVersion;
        stream.fundingRestrictionSequence = fundingRestrictionSequence;
        stream.terminated = false;

        uint256 remaining = stream.periodBudget - stream.periodEmitted;
        stream.periodBudget = stream.periodEmitted + remaining + amount;
        stream.periodStart = currentTime;
        stream.lastUpdate = currentTime;
        if (remaining == 0) stream.periodFinish = _addTime(currentTime, duration);
    }

    function checkpointPosition(uint256 positionId, PoolId poolId, uint256 allocation, bytes32 allocationVersion)
        internal
    {
        BribeStorage storage bs = bribeStorage();
        PositionLeg storage leg = bs.legs[positionId][poolId];
        uint8 slotCount = LibRangeGauge.rangeGaugeStorage().rewardConfig[poolId].slotCount;
        for (uint8 slot = 1; slot < slotCount; ++slot) {
            Stream storage stream = bs.streams[poolId][slot];
            _ensureGeneration(bs, stream, poolId, slot, allocationVersion);
            bytes32 checkpointVersion = leg.checkpointVersion[slot];
            uint256 index = _indexForVersion(bs, stream, poolId, slot, allocationVersion);
            if (checkpointVersion != allocationVersion) {
                leg.checkpointVersion[slot] = allocationVersion;
                if (checkpointVersion == bytes32(0) && allocation != 0) {
                    leg.checkpointIndexX160[slot] = _generationStartIndex(bs, stream, poolId, slot, allocationVersion);
                } else {
                    leg.checkpointIndexX160[slot] = index;
                    continue;
                }
            }
            uint256 checkpoint = leg.checkpointIndexX160[slot];
            if (allocation != 0 && index != checkpoint) {
                (uint256 amount, uint256 remainder) =
                    _positionAccrual(allocation, index - checkpoint, leg.rewardRemainderX160[slot]);
                leg.rewardRemainderX160[slot] = remainder;
                if (amount != 0) {
                    leg.claimable[slot] += amount;
                    stream.indexedLiability -= amount;
                    stream.claimLiability += amount;
                }
            }
            leg.checkpointIndexX160[slot] = index;
        }
    }

    function claimAmount(
        uint256 positionId,
        PoolId poolId,
        uint8 slot,
        uint256 allocation,
        bytes32 allocationVersion,
        uint40 currentTime,
        uint256 poolWeight
    ) internal returns (address asset, uint256 amount) {
        checkpointStream(poolId, slot, currentTime, poolWeight);
        checkpointPosition(positionId, poolId, allocation, allocationVersion);
        BribeStorage storage bs = bribeStorage();
        Stream storage stream = bs.streams[poolId][slot];
        PositionLeg storage leg = bs.legs[positionId][poolId];
        asset = stream.asset;
        amount = leg.claimable[slot];
        if (amount == 0) return (asset, 0);
        leg.claimable[slot] = 0;
        uint256 liability = stream.claimLiability;
        if (amount > liability) {
            revert IStaticsGaugeIncentives.GaugeAllocatorLiabilityUnderflow(poolId, slot, liability, amount);
        }
        stream.claimLiability = liability - amount;
    }

    function preview(uint256 positionId, PoolId poolId, uint8 slot, uint256 allocation, bytes32 allocationVersion)
        internal
        view
        returns (address asset, uint256 amount)
    {
        BribeStorage storage bs = bribeStorage();
        Stream storage stream = bs.streams[poolId][slot];
        PositionLeg storage leg = bs.legs[positionId][poolId];
        asset = stream.asset;
        amount = leg.claimable[slot];
        uint256 index = _indexForVersion(bs, stream, poolId, slot, allocationVersion);
        bytes32 checkpointVersion = leg.checkpointVersion[slot];
        uint256 checkpoint = leg.checkpointIndexX160[slot];
        if (checkpointVersion != allocationVersion) {
            if (checkpointVersion != bytes32(0) || allocation == 0) {
                return (asset, amount);
            }
            checkpoint = _generationStartIndex(bs, stream, poolId, slot, allocationVersion);
        }
        if (allocation != 0 && index != checkpoint) {
            (uint256 pending,) = _positionAccrual(allocation, index - checkpoint, leg.rewardRemainderX160[slot]);
            amount += pending;
        }
    }

    function _increaseIndex(Stream storage stream, uint256 amount, uint256 denominator) private {
        if (amount == 0) return;
        (uint256 delta, uint256 remainder) =
            LibIndexMath.indexDeltaAtScale(amount, denominator, stream.indexRemainder, INDEX_SCALE);
        stream.indexRemainder = remainder;
        stream.globalIndexX160 += delta;
        stream.indexedLiability += amount;
    }

    function forfeitAmount(
        uint256 positionId,
        PoolId poolId,
        uint8 slot,
        uint256 allocation,
        bytes32 allocationVersion,
        uint40 currentTime,
        uint256 poolWeight
    ) internal returns (address asset, uint256 amount, uint256 fractionalAmount) {
        checkpointStream(poolId, slot, currentTime, poolWeight);
        checkpointPosition(positionId, poolId, allocation, allocationVersion);
        BribeStorage storage bs = bribeStorage();
        Stream storage stream = bs.streams[poolId][slot];
        PositionLeg storage leg = bs.legs[positionId][poolId];
        asset = stream.asset;
        amount = leg.claimable[slot];
        leg.claimable[slot] = 0;
        if (amount != 0) {
            uint256 liability = stream.claimLiability;
            if (amount > liability) {
                revert IStaticsGaugeIncentives.GaugeAllocatorLiabilityUnderflow(poolId, slot, liability, amount);
            }
            stream.claimLiability = liability - amount;
        }
        if (allocation == 0) {
            uint256 combined = stream.forfeitedRemainderX160 + leg.rewardRemainderX160[slot];
            // Once the live denominator reaches zero, its numerator carry belongs to the
            // completed allocation set. Aggregate it with forfeited position dust instead of
            // leaving a whole raw token permanently reserved in indexed liability.
            if (poolWeight == 0) {
                combined += stream.indexRemainder;
                stream.indexRemainder = 0;
            }
            fractionalAmount = combined / INDEX_SCALE;
            stream.forfeitedRemainderX160 = combined % INDEX_SCALE;
            leg.rewardRemainderX160[slot] = 0;
            if (fractionalAmount != 0) {
                uint256 indexedLiability = stream.indexedLiability;
                if (fractionalAmount > indexedLiability) {
                    revert IStaticsGaugeIncentives.GaugeAllocatorLiabilityUnderflow(
                        poolId, slot, indexedLiability, fractionalAmount
                    );
                }
                stream.indexedLiability = indexedLiability - fractionalAmount;
            }
        }
    }

    function syncPositionLeg(uint256 positionId, PoolId poolId, uint256 allocation) internal {
        PositionLeg storage leg = bribeStorage().legs[positionId][poolId];
        bool unresolved = allocation != 0;
        if (!unresolved) {
            uint8 slotCount = LibRangeGauge.rangeGaugeStorage().rewardConfig[poolId].slotCount;
            for (uint8 slot = 1; slot < slotCount; ++slot) {
                if (leg.claimable[slot] != 0 || leg.rewardRemainderX160[slot] != 0) {
                    unresolved = true;
                    break;
                }
            }
        }
        bytes32 key = LibPosition.gaugeAllocatorLegKey(poolId);
        bool active = LibPosition.positionStorage().activeLeg[positionId][key];
        if (unresolved && !active) {
            LibPosition.activateLeg(positionId, LibPosition.GAUGE_ALLOCATOR_MODULE, PoolId.unwrap(poolId));
            _addPositionPool(positionId, poolId);
        } else if (!unresolved && active) {
            LibPosition.deactivateLeg(positionId, key);
            _removePositionPool(positionId, poolId);
        }
    }

    function positionPools(uint256 positionId, uint256 cursor, uint256 limit)
        internal
        view
        returns (PoolId[] memory poolIds, uint256 nextCursor)
    {
        if (limit == 0 || limit > MAX_POSITION_POOL_PAGE_SIZE) {
            revert IStaticsGaugeIncentives.InvalidGaugeAllocatorPoolPageSize(limit, MAX_POSITION_POOL_PAGE_SIZE);
        }
        PoolId[] storage values = bribeStorage().positionPools[positionId].values;
        uint256 length = values.length;
        if (cursor >= length) return (new PoolId[](0), length);
        uint256 pageLength = length - cursor;
        if (pageLength > limit) pageLength = limit;
        poolIds = new PoolId[](pageLength);
        for (uint256 i; i < pageLength; ++i) {
            poolIds[i] = values[cursor + i];
        }
        nextCursor = cursor + pageLength;
    }

    function _addPositionPool(uint256 positionId, PoolId poolId) private {
        PoolIndex storage index = bribeStorage().positionPools[positionId];
        if (index.indexPlusOne[poolId] != 0) return;
        index.values.push(poolId);
        index.indexPlusOne[poolId] = index.values.length;
    }

    function _removePositionPool(uint256 positionId, PoolId poolId) private {
        PoolIndex storage index = bribeStorage().positionPools[positionId];
        uint256 indexPlusOne = index.indexPlusOne[poolId];
        if (indexPlusOne == 0) {
            revert IStaticsGaugeIncentives.GaugeAllocatorPoolIndexCorrupted(positionId, poolId);
        }
        uint256 valueIndex = indexPlusOne - 1;
        if (valueIndex >= index.values.length || PoolId.unwrap(index.values[valueIndex]) != PoolId.unwrap(poolId)) {
            revert IStaticsGaugeIncentives.GaugeAllocatorPoolIndexCorrupted(positionId, poolId);
        }
        uint256 lastIndex = index.values.length - 1;
        if (valueIndex != lastIndex) {
            PoolId moved = index.values[lastIndex];
            index.values[valueIndex] = moved;
            index.indexPlusOne[moved] = indexPlusOne;
        }
        index.values.pop();
        delete index.indexPlusOne[poolId];
    }

    function _indexForVersion(
        BribeStorage storage bs,
        Stream storage stream,
        PoolId poolId,
        uint8 slot,
        bytes32 version
    ) private view returns (uint256 index) {
        if (stream.eligibilityVersion == version) return stream.globalIndexX160;
        Generation storage generation = bs.generations[poolId][slot][version];
        if (generation.finalized) return generation.terminalIndexX160;
        if (generation.initialized) return generation.startIndexX160;
    }

    function _generationStartIndex(
        BribeStorage storage bs,
        Stream storage stream,
        PoolId poolId,
        uint8 slot,
        bytes32 version
    ) private view returns (uint256 index) {
        if (stream.eligibilityVersion == version) return stream.generationStartIndexX160;
        return bs.generations[poolId][slot][version].startIndexX160;
    }

    function _ensureGeneration(
        BribeStorage storage bs,
        Stream storage stream,
        PoolId poolId,
        uint8 slot,
        bytes32 version
    ) private {
        if (version == bytes32(0)) return;
        Generation storage generation = bs.generations[poolId][slot][version];
        if (generation.initialized) return;
        generation.startIndexX160 = stream.globalIndexX160;
        generation.initialized = true;
        if (stream.eligibilityVersion == version) {
            stream.generationStartIndexX160 = stream.globalIndexX160;
        }
    }

    function _finalizeGeneration(PoolId poolId, uint8 slot, bytes32 version, uint256 terminalIndexX160) private {
        if (version == bytes32(0)) return;
        Generation storage generation = bribeStorage().generations[poolId][slot][version];
        if (!generation.initialized) {
            generation.startIndexX160 = terminalIndexX160;
            generation.initialized = true;
        }
        if (generation.finalized) return;
        generation.terminalIndexX160 = terminalIndexX160;
        generation.finalized = true;
    }

    function _positionAccrual(uint256 weight, uint256 indexDelta, uint256 priorRemainder)
        private
        pure
        returns (uint256 amount, uint256 remainder)
    {
        amount = Math.mulDiv(weight, indexDelta, INDEX_SCALE);
        uint256 combined = mulmod(weight, indexDelta, INDEX_SCALE) + priorRemainder;
        amount += combined / INDEX_SCALE;
        remainder = combined % INDEX_SCALE;
    }

    function _toTreasury(PoolId poolId, uint8 slot, address asset, uint256 amount) private {
        if (amount == 0) return;
        LibCustody.moveReservation(account(poolId, slot), LibCustody.feeAccount(), asset, amount);
        LibGlobalRewards.accrueReservedTreasuryFee(asset, amount);
    }

    function _addTime(uint40 timestamp, uint40 delta) private pure returns (uint40 result) {
        uint256 sum = uint256(timestamp) + delta;
        if (sum > type(uint40).max) revert GaugeBribeTimestampRegression(timestamp, type(uint40).max);
        result = uint40(sum);
    }
}
