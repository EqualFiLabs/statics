// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

library LibBasketLiquidityMath {
    uint256 internal constant SHARE_SCALE = 1e18;

    function maxSharesForMatchedReserve(uint256 reserve, uint256 bundleAmount) internal pure returns (uint256 shares) {
        return Math.mulDiv(reserve / 2, SHARE_SCALE, bundleAmount);
    }

    function fullRangeAmounts(uint160 sqrtPriceX96, bool assetIsCurrency0, uint256 assetAvailable)
        internal
        pure
        returns (uint128 liquidity, uint256 basketAmount, uint256 assetAmount)
    {
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(TickMath.minUsableTick(10));
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(TickMath.maxUsableTick(10));
        if (assetIsCurrency0) {
            liquidity = LiquidityAmounts.getLiquidityForAmount0(sqrtPriceX96, sqrtUpper, assetAvailable);
            assetAmount = SqrtPriceMath.getAmount0Delta(sqrtPriceX96, sqrtUpper, liquidity, true);
            basketAmount = SqrtPriceMath.getAmount1Delta(sqrtLower, sqrtPriceX96, liquidity, true);
        } else {
            liquidity = LiquidityAmounts.getLiquidityForAmount1(sqrtLower, sqrtPriceX96, assetAvailable);
            assetAmount = SqrtPriceMath.getAmount1Delta(sqrtLower, sqrtPriceX96, liquidity, true);
            basketAmount = SqrtPriceMath.getAmount0Delta(sqrtPriceX96, sqrtUpper, liquidity, true);
        }
    }

    function scaleLiquidityToBasketBudget(
        uint160 sqrtPriceX96,
        bool assetIsCurrency0,
        uint128 liquidity,
        uint256 basketBudget,
        uint256 totalBasketDemand
    ) internal pure returns (uint128 scaledLiquidity, uint256 basketAmount, uint256 assetAmount) {
        scaledLiquidity = uint128(Math.mulDiv(liquidity, basketBudget, totalBasketDemand));
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(TickMath.minUsableTick(10));
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(TickMath.maxUsableTick(10));
        if (assetIsCurrency0) {
            assetAmount = SqrtPriceMath.getAmount0Delta(sqrtPriceX96, sqrtUpper, scaledLiquidity, true);
            basketAmount = SqrtPriceMath.getAmount1Delta(sqrtLower, sqrtPriceX96, scaledLiquidity, true);
        } else {
            assetAmount = SqrtPriceMath.getAmount1Delta(sqrtLower, sqrtPriceX96, scaledLiquidity, true);
            basketAmount = SqrtPriceMath.getAmount0Delta(sqrtPriceX96, sqrtUpper, scaledLiquidity, true);
        }
    }

    function rangeAmounts(uint160 sqrtPriceX96, int24 tickLower, int24 tickUpper, uint128 liquidity)
        internal
        pure
        returns (uint256 amount0, uint256 amount1)
    {
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(tickUpper);
        if (sqrtPriceX96 <= sqrtLower) {
            amount0 = SqrtPriceMath.getAmount0Delta(sqrtLower, sqrtUpper, liquidity, true);
        } else if (sqrtPriceX96 < sqrtUpper) {
            amount0 = SqrtPriceMath.getAmount0Delta(sqrtPriceX96, sqrtUpper, liquidity, true);
            amount1 = SqrtPriceMath.getAmount1Delta(sqrtLower, sqrtPriceX96, liquidity, true);
        } else {
            amount1 = SqrtPriceMath.getAmount1Delta(sqrtLower, sqrtUpper, liquidity, true);
        }
    }
}
