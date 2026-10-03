// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

interface IStaticsMarketObservations {
    struct ObservationConfig {
        bool initialized;
        bool enabled;
        uint32 cadence;
        uint16 cardinality;
        uint16 cardinalityNext;
        uint64 stored;
        uint64 latestId;
        uint40 lastObservationTimestamp;
        uint256 failedWriteCount;
        uint256 lastFailedSequence;
    }

    struct MarketObservation {
        uint40 timestamp;
        int24 tick;
        uint24 nativeLpFee;
        uint8 flags;
        uint256 sequence;
        int256 tickCumulative;
        uint256 externalVolume0;
        uint256 externalVolume1;
        uint256 internalVolume0;
        uint256 internalVolume1;
        uint256 staticsFees0;
        uint256 staticsFees1;
        uint256 externalSwapCount;
        uint256 internalSwapCount;
    }

    event MarketObservationConfigSet(PoolId indexed poolId, bool enabled, uint32 cadence, uint16 cardinalityNext);
    event MarketObservationCommitted(PoolId indexed poolId, uint64 indexed observationId, uint256 sequence);
    event MarketObservationWriteFailed(PoolId indexed poolId, uint256 indexed sequence);

    function setMarketObservationConfig(PoolId poolId, bool enabled, uint32 cadence, uint16 cardinalityNext) external;

    function recordMarketObservation(PoolId poolId, uint256 expectedSequence) external;

    function marketObservationConfig(PoolId poolId) external view returns (ObservationConfig memory config);

    function marketObservation(PoolId poolId, uint64 observationId)
        external
        view
        returns (MarketObservation memory observation);

    function observeMarket(PoolId poolId, uint32[] calldata secondsAgo)
        external
        view
        returns (MarketObservation[] memory observations);
}
