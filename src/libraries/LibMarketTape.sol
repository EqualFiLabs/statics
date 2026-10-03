// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IStaticsMarketTape} from "../interfaces/IStaticsMarketTape.sol";
import {IStaticsMarketObservations} from "../interfaces/IStaticsMarketObservations.sol";

library LibMarketTape {
    bytes32 internal constant MARKET_TAPE_STORAGE_POSITION = keccak256("statics.storage.market.tape.v1");

    uint8 internal constant FLAG_ZERO_FOR_ONE = 1 << 0;
    uint8 internal constant FLAG_EXACT_OUTPUT = 1 << 1;
    uint8 internal constant FLAG_PERMISSIONED = 1 << 2;
    uint8 internal constant FLAG_INTERNAL = 1 << 3;
    uint8 internal constant FLAG_PARTIAL = 1 << 4;
    uint8 internal constant VALID_FLAGS =
        FLAG_ZERO_FOR_ONE | FLAG_EXACT_OUTPUT | FLAG_PERMISSIONED | FLAG_INTERNAL | FLAG_PARTIAL;

    uint8 private constant SAT_EXTERNAL_VOLUME0 = 1 << 0;
    uint8 private constant SAT_EXTERNAL_VOLUME1 = 1 << 1;
    uint8 private constant SAT_INTERNAL_VOLUME0 = 1 << 2;
    uint8 private constant SAT_INTERNAL_VOLUME1 = 1 << 3;
    uint8 private constant SAT_STATICS_FEES0 = 1 << 4;
    uint8 private constant SAT_STATICS_FEES1 = 1 << 5;
    uint8 private constant SAT_EXTERNAL_COUNT = 1 << 6;
    uint8 private constant SAT_INTERNAL_COUNT = 1 << 7;

    uint32 internal constant DEFAULT_OBSERVATION_CADENCE = 15 minutes;
    uint16 internal constant DEFAULT_OBSERVATION_CARDINALITY = 96;
    uint16 internal constant MAX_OBSERVATION_CARDINALITY = 672;
    uint32 internal constant MIN_OBSERVATION_CADENCE = 1 minutes;
    uint32 internal constant MAX_OBSERVATION_CADENCE = 1 days;

    struct ObservationState {
        bool initialized;
        bool enabled;
        uint32 cadence;
        uint16 cardinality;
        uint16 cardinalityNext;
        uint64 stored;
        uint64 latestId;
        uint40 lastObservationTimestamp;
    }

    struct ObservationFailures {
        uint256 count;
        uint256 lastSequence;
    }

    struct MarketTapeStorage {
        mapping(PoolId poolId => IStaticsMarketTape.CanonicalMarketState state) canonical;
        mapping(PoolId poolId => ObservationState state) observationState;
        mapping(
            PoolId poolId => mapping(uint64 observationId => IStaticsMarketObservations.MarketObservation value)
        ) observations;
        mapping(PoolId poolId => ObservationFailures failures) observationFailures;
    }

    error InvalidMarketFlags(uint8 flags);
    error InvalidInternalMarketFlags(uint8 flags);
    error MarketTimestampOverflow(uint256 timestamp);
    error InvalidObservationCadence(uint256 cadence);
    error InvalidObservationCardinality(uint256 cardinality);

    function marketTapeStorage() internal pure returns (MarketTapeStorage storage mts) {
        bytes32 position = MARKET_TAPE_STORAGE_POSITION;
        assembly ("memory-safe") {
            mts.slot := position
        }
    }

    function record(
        PoolId poolId,
        uint256 amount0,
        uint256 amount1,
        uint256 fee0,
        uint256 fee1,
        int24 finalTick,
        uint24 nativeLpFee,
        uint8 flags,
        uint256 timestamp
    ) internal returns (uint256 sequence) {
        if (flags & ~VALID_FLAGS != 0) revert InvalidMarketFlags(flags);
        if (flags & FLAG_INTERNAL != 0 && flags & FLAG_PERMISSIONED == 0) revert InvalidInternalMarketFlags(flags);
        if (timestamp > type(uint40).max) revert MarketTimestampOverflow(timestamp);

        IStaticsMarketTape.CanonicalMarketState storage state = marketTapeStorage().canonical[poolId];
        uint40 currentTime = uint40(timestamp);
        if (state.sequence != 0) {
            state.tickCumulative += int256(state.lastTick) * int256(uint256(currentTime - state.lastTimestamp));
        }

        uint8 saturated = state.saturatedFields;
        if (flags & FLAG_INTERNAL == 0) {
            (state.externalVolume0, saturated) =
                saturatingAdd(state.externalVolume0, amount0, saturated, SAT_EXTERNAL_VOLUME0);
            (state.externalVolume1, saturated) =
                saturatingAdd(state.externalVolume1, amount1, saturated, SAT_EXTERNAL_VOLUME1);
            (state.staticsFees0, saturated) = saturatingAdd(state.staticsFees0, fee0, saturated, SAT_STATICS_FEES0);
            (state.staticsFees1, saturated) = saturatingAdd(state.staticsFees1, fee1, saturated, SAT_STATICS_FEES1);
            (state.externalSwapCount, saturated) =
                saturatingAdd(state.externalSwapCount, 1, saturated, SAT_EXTERNAL_COUNT);
        } else {
            (state.internalVolume0, saturated) =
                saturatingAdd(state.internalVolume0, amount0, saturated, SAT_INTERNAL_VOLUME0);
            (state.internalVolume1, saturated) =
                saturatingAdd(state.internalVolume1, amount1, saturated, SAT_INTERNAL_VOLUME1);
            (state.internalSwapCount, saturated) =
                saturatingAdd(state.internalSwapCount, 1, saturated, SAT_INTERNAL_COUNT);
        }

        sequence = nextSequence(state.sequence);
        state.sequence = sequence;
        state.lastTimestamp = currentTime;
        state.lastTick = finalTick;
        state.lastNativeLpFee = nativeLpFee;
        state.lastFlags = flags;
        state.saturatedFields = saturated;
    }

    function currentTickCumulative(IStaticsMarketTape.CanonicalMarketState storage state, uint256 timestamp)
        internal
        view
        returns (int256 cumulative)
    {
        cumulative = state.tickCumulative;
        if (state.sequence == 0 || timestamp <= state.lastTimestamp) return cumulative;
        cumulative += int256(state.lastTick) * int256(timestamp - state.lastTimestamp);
    }

    function configureObservations(PoolId poolId, bool enabled, uint32 cadence, uint16 cardinalityNext) internal {
        ObservationState storage state = marketTapeStorage().observationState[poolId];
        state.initialized = true;
        state.enabled = enabled;
        if (enabled) {
            if (cadence < MIN_OBSERVATION_CADENCE || cadence > MAX_OBSERVATION_CADENCE) {
                revert InvalidObservationCadence(cadence);
            }
            if (
                cardinalityNext == 0 || cardinalityNext > MAX_OBSERVATION_CARDINALITY
                    || cardinalityNext < state.cardinality
            ) revert InvalidObservationCardinality(cardinalityNext);
            state.cadence = cadence;
            state.cardinalityNext = cardinalityNext;
        }
    }

    function initializeObservationDefaults(ObservationState storage state) internal {
        if (state.initialized) return;
        state.initialized = true;
        state.enabled = true;
        state.cadence = DEFAULT_OBSERVATION_CADENCE;
        state.cardinalityNext = DEFAULT_OBSERVATION_CARDINALITY;
    }

    function recordObservationFailure(PoolId poolId, uint256 sequence) internal {
        ObservationFailures storage failures = marketTapeStorage().observationFailures[poolId];
        if (failures.count != type(uint256).max) ++failures.count;
        failures.lastSequence = sequence;
    }

    function saturatingAdd(uint256 current, uint256 amount, uint8 saturated, uint8 field)
        internal
        pure
        returns (uint256 next, uint8 nextSaturated)
    {
        if (type(uint256).max - current < amount) return (type(uint256).max, saturated | field);
        return (current + amount, saturated);
    }

    function nextSequence(uint256 current) internal pure returns (uint256 next) {
        next = current == type(uint256).max ? type(uint256).max : current + 1;
    }
}
