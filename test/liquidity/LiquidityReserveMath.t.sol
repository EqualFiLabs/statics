// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {LibBasketLiquidityMath} from "../../src/libraries/LibBasketLiquidityMath.sol";

contract LiquidityReserveMathHarness {
    function fullRange(uint160 sqrtPriceX96, bool assetIsCurrency0, uint256 available)
        external
        pure
        returns (uint128 liquidity, uint256 basketAmount, uint256 assetAmount)
    {
        return LibBasketLiquidityMath.fullRangeAmounts(sqrtPriceX96, assetIsCurrency0, available);
    }
}

contract LiquidityReserveMathTest is Test {
    uint160 private constant SQRT_PRICE_1_1 = 1 << 96;

    LiquidityReserveMathHarness private harness = new LiquidityReserveMathHarness();

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
}
