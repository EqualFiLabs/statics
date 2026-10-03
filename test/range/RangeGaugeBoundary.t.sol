// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {LibRangeGauge} from "../../src/libraries/LibRangeGauge.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {RangeGaugeHarness} from "../helpers/RangeGaugeHarness.sol";

contract RangeGaugeBoundaryTest is Test {
    PoolId private constant POOL_ID = PoolId.wrap(bytes32(uint256(0xB0A7D)));
    int24 private constant SPACING = 1;
    uint256 private constant RAY = 1e27;

    RangeGaugeHarness private gauge;

    function setUp() public {
        gauge = new RangeGaugeHarness();
        MockERC20 statics = new MockERC20("Statics", "STATICS", 18);
        gauge.initialize(address(statics));
        gauge.initializePool(POOL_ID, 0);
    }

    function testBoundaryAddAndRemoveAreSymmetric() public {
        gauge.seedStreamAccounting(POOL_ID, 0, 9 * RAY, 0, 0, 0);
        gauge.addRangeBoundaries(POOL_ID, -100, 100, SPACING, 0, 1_000);

        (uint128 lowerGross, int128 lowerNet, uint256[5] memory lowerOutside) = gauge.boundary(POOL_ID, -100);
        (uint128 upperGross, int128 upperNet, uint256[5] memory upperOutside) = gauge.boundary(POOL_ID, 100);
        assertEq(lowerGross, 1_000);
        assertEq(lowerNet, 1_000);
        assertEq(lowerOutside[0], 9 * RAY);
        assertEq(upperGross, 1_000);
        assertEq(upperNet, -1_000);
        assertEq(upperOutside[0], 0);

        gauge.removeRangeBoundaries(POOL_ID, -100, 100, SPACING, 1_000);
        (lowerGross, lowerNet,) = gauge.boundary(POOL_ID, -100);
        (upperGross, upperNet,) = gauge.boundary(POOL_ID, 100);
        assertEq(lowerGross, 0);
        assertEq(lowerNet, 0);
        assertEq(upperGross, 0);
        assertEq(upperNet, 0);
        assertEq(gauge.boundarySummary(POOL_ID), 0);
    }

    function testSharedNetZeroBoundaryRemainsInitializedUntilGrossIsZero() public {
        gauge.addRangeBoundaries(POOL_ID, -100, 0, SPACING, -50, 100);
        gauge.addRangeBoundaries(POOL_ID, 0, 100, SPACING, -50, 100);

        (uint128 gross, int128 net,) = gauge.boundary(POOL_ID, 0);
        assertEq(gross, 200);
        assertEq(net, 0);
        (int24 next, bool initialized) = gauge.nextInitializedBoundary(POOL_ID, -1, SPACING, false);
        assertTrue(initialized);
        assertEq(next, 0);

        gauge.removeRangeBoundaries(POOL_ID, -100, 0, SPACING, 100);
        (gross, net,) = gauge.boundary(POOL_ID, 0);
        assertEq(gross, 100);
        assertEq(net, 100);
        gauge.removeRangeBoundaries(POOL_ID, 0, 100, SPACING, 100);
        (gross, net,) = gauge.boundary(POOL_ID, 0);
        assertEq(gross, 0);
        assertEq(net, 0);
    }

    function testCrossingBothDirectionsInvertsOutsideGrowthAndLiquidity() public {
        gauge.addRangeBoundaries(POOL_ID, 0, 100, SPACING, -1, 1_000);
        gauge.seedStreamAccounting(POOL_ID, 0, 10 * RAY, 0, 0, 0);

        assertEq(gauge.crossBoundary(POOL_ID, 0, true), 1_000);
        (, int128 lowerNet, uint256[5] memory lowerOutside) = gauge.boundary(POOL_ID, 0);
        assertEq(lowerNet, 1_000);
        assertEq(lowerOutside[0], 10 * RAY);

        gauge.seedStreamAccounting(POOL_ID, 0, 20 * RAY, 0, 0, 0);
        assertEq(gauge.crossBoundary(POOL_ID, 100, true), 0);
        (,, uint256[5] memory upperOutside) = gauge.boundary(POOL_ID, 100);
        assertEq(upperOutside[0], 20 * RAY);

        assertEq(gauge.crossBoundary(POOL_ID, 100, false), 1_000);
        (,, upperOutside) = gauge.boundary(POOL_ID, 100);
        assertEq(upperOutside[0], 0);
        assertEq(gauge.crossBoundary(POOL_ID, 0, false), 0);
        (,, lowerOutside) = gauge.boundary(POOL_ID, 0);
        assertEq(lowerOutside[0], 10 * RAY);
    }

    function testInsideGrowthIdentitiesAcrossTickRegions() public {
        gauge.seedStreamAccounting(POOL_ID, 0, 100 * RAY, 0, 0, 0);
        gauge.addRangeBoundaries(POOL_ID, -10, 10, SPACING, 0, 1);
        gauge.seedStreamAccounting(POOL_ID, 0, 130 * RAY, 0, 0, 0);

        assertEq(gauge.growthInside(POOL_ID, -10, 10, 0, 0), 30 * RAY);
        assertEq(gauge.growthInside(POOL_ID, -10, 10, -20, 0), 100 * RAY);
        assertEq(gauge.growthInside(POOL_ID, -10, 10, 20, 0), type(uint256).max - 100 * RAY + 1);
    }

    function testSummaryBitmapFindsSparseBoundariesWithoutLinearWordScan() public {
        gauge.addRangeBoundaries(POOL_ID, -800_000, 800_000, SPACING, 0, 1);

        uint256 gasBefore = gasleft();
        (int24 right, bool rightInitialized) = gauge.nextInitializedBoundary(POOL_ID, 0, SPACING, false);
        uint256 rightGas = gasBefore - gasleft();
        gasBefore = gasleft();
        (int24 left, bool leftInitialized) = gauge.nextInitializedBoundary(POOL_ID, 0, SPACING, true);
        uint256 leftGas = gasBefore - gasleft();

        emit log_named_uint("sparse right boundary lookup gas", rightGas);
        emit log_named_uint("sparse left boundary lookup gas", leftGas);
        assertTrue(rightInitialized);
        assertTrue(leftInitialized);
        assertEq(right, 800_000);
        assertEq(left, -800_000);
        assertLt(rightGas, 100_000);
        assertLt(leftGas, 100_000);
    }

    function testTraversalReturnsBoundariesInDirectionOrder() public {
        gauge.addRangeBoundaries(POOL_ID, -300, -100, SPACING, 0, 1);
        gauge.addRangeBoundaries(POOL_ID, 100, 300, SPACING, 0, 1);

        (int24 next, bool initialized) = gauge.nextInitializedBoundary(POOL_ID, -301, SPACING, false);
        assertTrue(initialized);
        assertEq(next, -300);
        (next, initialized) = gauge.nextInitializedBoundary(POOL_ID, next, SPACING, false);
        assertTrue(initialized);
        assertEq(next, -100);
        (next, initialized) = gauge.nextInitializedBoundary(POOL_ID, 301, SPACING, true);
        assertTrue(initialized);
        assertEq(next, 300);
        (next, initialized) = gauge.nextInitializedBoundary(POOL_ID, next - 1, SPACING, true);
        assertTrue(initialized);
        assertEq(next, 100);
    }

    function testRejectsBoundaryLiquidityThatCannotFitSignedNet() public {
        uint128 tooLarge = uint128(type(int128).max) + 1;
        vm.expectRevert(LibRangeGauge.InvalidLiquidity.selector);
        gauge.addRangeBoundaries(POOL_ID, -10, 10, SPACING, 0, tooLarge);
    }

    function testRejectsBoundaryMutationBeforeGaugeInitialization() public {
        PoolId unknownPool = PoolId.wrap(bytes32(uint256(0xBAD)));
        vm.expectRevert(abi.encodeWithSelector(LibRangeGauge.GaugeNotInitialized.selector, unknownPool));
        gauge.addRangeBoundaries(unknownPool, -10, 10, SPACING, 0, 1);
    }
}
