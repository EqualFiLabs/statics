// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {LibBasket} from "../../src/libraries/LibBasket.sol";
import {LibBasketLiquidityMath} from "../../src/libraries/LibBasketLiquidityMath.sol";

contract LiquidityReserveMathHarness {
    function maxShares(uint256 reserve, uint256 bundleAmount) external pure returns (uint256) {
        return LibBasketLiquidityMath.maxSharesForMatchedReserve(reserve, bundleAmount);
    }

    function backingIncrease(uint256 bundleAmount, uint256 supply, uint256 shares) external pure returns (uint256) {
        return LibBasket.backingIncrease(bundleAmount, supply, shares);
    }

    function fullRange(uint160 sqrtPriceX96, bool assetIsCurrency0, uint256 available)
        external
        pure
        returns (uint128 liquidity, uint256 basketAmount, uint256 assetAmount)
    {
        return LibBasketLiquidityMath.fullRangeAmounts(sqrtPriceX96, assetIsCurrency0, available);
    }

    function scale(uint160 sqrtPriceX96, bool assetIsCurrency0, uint128 liquidity, uint256 budget, uint256 demand)
        external
        pure
        returns (uint128 scaledLiquidity, uint256 basketAmount, uint256 assetAmount)
    {
        return
            LibBasketLiquidityMath.scaleLiquidityToBasketBudget(
                sqrtPriceX96, assetIsCurrency0, liquidity, budget, demand
            );
    }
}

contract LiquidityReserveMathTest is Test {
    uint160 private constant SQRT_PRICE_1_1 = 1 << 96;

    LiquidityReserveMathHarness private harness = new LiquidityReserveMathHarness();

    function testLimitingShareQuoteNeverUsesMoreThanHalfTheReserve(
        uint256 reserve,
        uint256 bundleAmount,
        uint256 supply
    ) public view {
        reserve = bound(reserve, 2, type(uint128).max);
        bundleAmount = bound(bundleAmount, 1, type(uint96).max);
        supply = bound(supply, 0, type(uint96).max);
        uint256 shares = harness.maxShares(reserve, bundleAmount);
        uint256 backing = harness.backingIncrease(bundleAmount, supply, shares);
        assertLe(backing, reserve / 2);
    }

    function testFullRangeSizingRespectsMeasuredAssetLimitInEitherOrdering() public view {
        uint256 available = 7 ether;
        (uint128 liquidity0, uint256 basket0, uint256 asset0) = harness.fullRange(SQRT_PRICE_1_1, true, available);
        (uint128 liquidity1, uint256 basket1, uint256 asset1) = harness.fullRange(SQRT_PRICE_1_1, false, available);

        assertGt(liquidity0, 0);
        assertGt(liquidity1, 0);
        assertLe(asset0, available);
        assertLe(asset1, available);
        assertApproxEqAbs(basket0, available, 2);
        assertApproxEqAbs(basket1, available, 2);
    }

    function testScalingLeavesRoundingRoomForEveryPool() public view {
        (uint128 liquidity, uint256 demand,) = harness.fullRange(SQRT_PRICE_1_1, true, 10 ether);
        uint256 poolCount = 16;
        uint256 shares = 10 ether;
        uint256 totalDemand = demand * poolCount;
        uint256 aggregate;
        for (uint256 i; i < poolCount; ++i) {
            (, uint256 scaledDemand,) = harness.scale(SQRT_PRICE_1_1, true, liquidity, shares - poolCount, totalDemand);
            aggregate += scaledDemand;
        }
        assertLe(aggregate, shares);
    }
}
