// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

interface IStaticsMarketTape {
    /// @notice Emitted once for every swap accepted into canonical MarketTape accounting.
    /// @dev `staticsFeesPacked` stores currency0 in the low 128 bits and currency1 in the high 128 bits.
    event MarketSwapRecorded(
        PoolId indexed poolId,
        uint256 indexed sequence,
        BalanceDelta poolDelta,
        uint256 staticsFeesPacked,
        int24 finalTick,
        uint24 nativeLpFee,
        uint8 flags
    );

    struct CanonicalMarketState {
        uint256 externalVolume0;
        uint256 externalVolume1;
        uint256 internalVolume0;
        uint256 internalVolume1;
        uint256 staticsFees0;
        uint256 staticsFees1;
        uint256 externalSwapCount;
        uint256 internalSwapCount;
        uint256 sequence;
        int256 tickCumulative;
        uint40 lastTimestamp;
        int24 lastTick;
        uint24 lastNativeLpFee;
        uint8 lastFlags;
        uint8 saturatedFields;
    }

    function canonicalMarketState(PoolId poolId) external view returns (CanonicalMarketState memory state);
}
