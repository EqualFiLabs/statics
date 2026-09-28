// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.26 <0.9.0;

import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @notice Permanent hook-to-Diamond swap envelope for Statics protocol pools.
/// @dev The raw PoolManager delta and exact Statics fees are irrecoverable after the callback.
/// Pool state such as the final tick and current native LP fee is resolved by the Diamond.
interface IStaticsSwapCallback {
    function afterStaticsPoolSwap(PoolId poolId, BalanceDelta poolDelta, uint256 staticsFeesPacked, uint8 flags)
        external;
}
