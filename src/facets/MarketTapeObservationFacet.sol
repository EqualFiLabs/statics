// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IStaticsMarketObservations} from "../interfaces/IStaticsMarketObservations.sol";
import {IStaticsMarketTape} from "../interfaces/IStaticsMarketTape.sol";
import {LibDiamond} from "../libraries/LibDiamond.sol";
import {LibMarketTape} from "../libraries/LibMarketTape.sol";
import {LibProtocolPools} from "../libraries/LibProtocolPools.sol";

/// @notice Bounded, replaceable historical observations derived from canonical market counters.
/// @dev The swap dispatcher calls the recorder through a gas-bounded self-call and ignores failure.
contract MarketTapeObservationFacet is IStaticsMarketObservations {
    uint256 private constant MAX_OBSERVE_QUERIES = 64;

    error OnlyDiamondSelf(address caller);
    error CanonicalSequenceMismatch(PoolId poolId, uint256 expected, uint256 actual);
    error NoMarketObservations(PoolId poolId);
    error MarketObservationNotFound(PoolId poolId, uint64 observationId);
    error ObservationQueryInFuture(uint256 secondsAgo, uint256 timestamp);
    error ObservationTooOld(PoolId poolId, uint256 target, uint256 oldest);
    error TooManyObservationQueries(uint256 requested, uint256 maximum);

    function setMarketObservationConfig(PoolId poolId, bool enabled, uint32 cadence, uint16 cardinalityNext) external {
        LibDiamond.enforceIsContractOwner();
        LibProtocolPools.enforceRegistered(poolId);
        LibMarketTape.configureObservations(poolId, enabled, cadence, cardinalityNext);
        emit MarketObservationConfigSet(poolId, enabled, cadence, cardinalityNext);
    }

    function recordMarketObservation(PoolId poolId, uint256 expectedSequence) public virtual {
        if (msg.sender != address(this)) revert OnlyDiamondSelf(msg.sender);
        LibMarketTape.MarketTapeStorage storage mts = LibMarketTape.marketTapeStorage();
        IStaticsMarketTape.CanonicalMarketState storage canonical = mts.canonical[poolId];
        if (canonical.sequence != expectedSequence || expectedSequence == 0) {
            revert CanonicalSequenceMismatch(poolId, expectedSequence, canonical.sequence);
        }

        LibMarketTape.ObservationState storage state = mts.observationState[poolId];
        LibMarketTape.initializeObservationDefaults(state);
        if (!state.enabled) return;
        if (
            state.stored != 0
                && uint256(canonical.lastTimestamp) < uint256(state.lastObservationTimestamp) + state.cadence
        ) return;

        _commitObservation(poolId, state, canonical);
    }

    function marketObservationConfig(PoolId poolId) external view returns (ObservationConfig memory config) {
        LibMarketTape.MarketTapeStorage storage mts = LibMarketTape.marketTapeStorage();
        LibMarketTape.ObservationState storage state = mts.observationState[poolId];
        LibMarketTape.ObservationFailures storage failures = mts.observationFailures[poolId];
        config = ObservationConfig({
            initialized: state.initialized,
            enabled: state.enabled,
            cadence: state.cadence,
            cardinality: state.cardinality,
            cardinalityNext: state.cardinalityNext,
            stored: state.stored,
            latestId: state.latestId,
            lastObservationTimestamp: state.lastObservationTimestamp,
            failedWriteCount: failures.count,
            lastFailedSequence: failures.lastSequence
        });
    }

    function marketObservation(PoolId poolId, uint64 observationId)
        external
        view
        returns (MarketObservation memory observation)
    {
        observation = LibMarketTape.marketTapeStorage().observations[poolId][observationId];
        if (observation.timestamp == 0) revert MarketObservationNotFound(poolId, observationId);
    }

    /// @notice Returns the newest retained observation at or before each requested timestamp.
    /// @dev A zero lookback synthesizes the current canonical state. Historical cumulative volume
    /// values are stepwise snapshots and are not interpolated between observation commits.
    function observeMarket(PoolId poolId, uint32[] calldata secondsAgo)
        external
        view
        returns (MarketObservation[] memory observations)
    {
        uint256 queryCount = secondsAgo.length;
        if (queryCount > MAX_OBSERVE_QUERIES) revert TooManyObservationQueries(queryCount, MAX_OBSERVE_QUERIES);

        LibMarketTape.MarketTapeStorage storage mts = LibMarketTape.marketTapeStorage();
        LibMarketTape.ObservationState storage state = mts.observationState[poolId];
        if (state.stored == 0) revert NoMarketObservations(poolId);
        uint64 oldestId = state.latestId - state.stored + 1;
        MarketObservation storage oldest = mts.observations[poolId][oldestId];
        observations = new MarketObservation[](queryCount);

        for (uint256 i; i < queryCount; ++i) {
            uint256 lookback = secondsAgo[i];
            if (lookback > block.timestamp) revert ObservationQueryInFuture(lookback, block.timestamp);
            if (lookback == 0) {
                observations[i] = _currentObservation(mts.canonical[poolId]);
                continue;
            }
            uint256 target = block.timestamp - lookback;
            if (target < oldest.timestamp) revert ObservationTooOld(poolId, target, oldest.timestamp);
            observations[i] = _atOrBefore(mts, poolId, state.latestId, oldestId, target);
        }
    }

    function _commitObservation(
        PoolId poolId,
        LibMarketTape.ObservationState storage state,
        IStaticsMarketTape.CanonicalMarketState storage canonical
    ) private {
        if (state.latestId == type(uint64).max) {
            state.enabled = false;
            return;
        }
        uint16 cardinality = state.cardinality;
        if (cardinality < state.cardinalityNext) {
            cardinality += 1;
            state.cardinality = cardinality;
        }

        uint64 nextId = state.latestId + 1;
        if (state.stored < cardinality) ++state.stored;
        else delete LibMarketTape.marketTapeStorage().observations[poolId][nextId - cardinality];

        state.latestId = nextId;
        state.lastObservationTimestamp = canonical.lastTimestamp;
        LibMarketTape.marketTapeStorage().observations[poolId][nextId] = _copyCanonical(canonical);
        emit MarketObservationCommitted(poolId, nextId, canonical.sequence);
    }

    function _atOrBefore(
        LibMarketTape.MarketTapeStorage storage mts,
        PoolId poolId,
        uint64 latestId,
        uint64 oldestId,
        uint256 target
    ) private view returns (MarketObservation memory observation) {
        uint64 lower = oldestId;
        uint64 upper = latestId;
        while (lower < upper) {
            uint64 midpoint = lower + (upper - lower + 1) / 2;
            if (mts.observations[poolId][midpoint].timestamp <= target) lower = midpoint;
            else upper = midpoint - 1;
        }
        observation = mts.observations[poolId][lower];
        if (observation.timestamp > target) revert ObservationTooOld(poolId, target, observation.timestamp);
    }

    function _currentObservation(IStaticsMarketTape.CanonicalMarketState storage canonical)
        private
        view
        returns (MarketObservation memory observation)
    {
        observation = _copyCanonical(canonical);
        observation.timestamp = _timestamp40(block.timestamp);
        observation.tickCumulative = LibMarketTape.currentTickCumulative(canonical, block.timestamp);
    }

    function _copyCanonical(IStaticsMarketTape.CanonicalMarketState storage canonical)
        private
        view
        returns (MarketObservation memory observation)
    {
        observation = MarketObservation({
            timestamp: canonical.lastTimestamp,
            tick: canonical.lastTick,
            nativeLpFee: canonical.lastNativeLpFee,
            flags: canonical.lastFlags,
            sequence: canonical.sequence,
            tickCumulative: canonical.tickCumulative,
            externalVolume0: canonical.externalVolume0,
            externalVolume1: canonical.externalVolume1,
            internalVolume0: canonical.internalVolume0,
            internalVolume1: canonical.internalVolume1,
            staticsFees0: canonical.staticsFees0,
            staticsFees1: canonical.staticsFees1,
            externalSwapCount: canonical.externalSwapCount,
            internalSwapCount: canonical.internalSwapCount
        });
    }

    function _timestamp40(uint256 timestamp) private pure returns (uint40 narrowed) {
        if (timestamp > type(uint40).max) revert LibMarketTape.MarketTimestampOverflow(timestamp);
        narrowed = uint40(timestamp);
    }
}
