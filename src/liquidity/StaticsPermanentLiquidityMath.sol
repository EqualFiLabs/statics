// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IStaticsPermanentLiquidityMath} from "../interfaces/IStaticsPermanentLiquidityMath.sol";

/// @notice Stateless full-range liquidity calculator used by the permanent swap-fee hook.
contract StaticsPermanentLiquidityMath is IStaticsPermanentLiquidityMath {
    function fullRangeLiquidity(uint160 sqrtPriceX96, int24 tickSpacing, uint256 amount0, uint256 amount1)
        external
        pure
        override
        returns (uint128 liquidity, int24 tickLower, int24 tickUpper)
    {
        tickLower = TickMath.minUsableTick(tickSpacing);
        tickUpper = TickMath.maxUsableTick(tickSpacing);
        liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            amount0,
            amount1
        );
    }
}
