// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {SqrtPriceMath} from "@v4-core/libraries/SqrtPriceMath.sol";
import {TickMath} from "@v4-core/libraries/TickMath.sol";
import {Curve} from "doppler/libraries/Multicurve.sol";
import {Position} from "doppler/types/Position.sol";
import {DopplerLaunchTypes} from "@statics/genesis/doppler/DopplerLaunchTypes.sol";
import {StaticsLaunchCurves} from "@statics/genesis/doppler/StaticsLaunchCurves.sol";
import {PinnedMulticurveHarness} from "../harness/PinnedMulticurveHarness.sol";

contract DopplerLaunchGeometryHalmosTest is Test {
    uint256 private constant TARGET_INVENTORY = 800_000_000 ether;
    uint256 private constant TAIL_INVENTORY = 120_000_000 ether;
    uint256 private constant MAX_RESIDUAL = 100 ether;
    int24 private constant TICK_SPACING = 100;
    int24 private constant FAR_TICK = StaticsLaunchCurves.FAR_TICK;

    PinnedMulticurveHarness private harness;

    function setUp() public {
        harness = new PinnedMulticurveHarness();
    }

    function check_exactSixCurveGeometryToken0() public view {
        _assertGeometry(true);
    }

    function check_exactSixCurveGeometryToken1() public view {
        _assertGeometry(false);
    }

    function testExactSixCurveGeometryToken0() public view {
        _assertGeometry(true);
    }

    function testExactSixCurveGeometryToken1() public view {
        _assertGeometry(false);
    }

    function _assertGeometry(bool isToken0) private view {
        Curve[] memory curves = _canonicalCurves();
        (Curve[] memory adjusted, int24 lowerBoundary, int24 upperBoundary) =
            harness.adjustCurves(curves, 0, TICK_SPACING, isToken0);
        Position[] memory positions = harness.calculatePositions(adjusted, TICK_SPACING, TARGET_INVENTORY, 0, isToken0);

        assertEq(curves.length, 6);
        assertEq(adjusted.length, 6);
        assertEq(positions.length, 56);
        assertLt(FAR_TICK, curves[5].tickUpper);
        assertGe(FAR_TICK, curves[5].tickLower);
        assertEq(curves[4].tickUpper, curves[5].tickLower);
        assertEq(curves[5].shares, 0.15 ether);
        assertEq((TARGET_INVENTORY * curves[5].shares) / 1 ether, TAIL_INVENTORY);
        assertEq(int256(lowerBoundary), isToken0 ? int256(-168_800) : int256(-887_200));
        assertEq(int256(upperBoundary), isToken0 ? int256(887_200) : int256(168_800));

        uint256 totalShares;
        uint256 consumed;
        for (uint256 i; i < adjusted.length; ++i) {
            Curve memory curve = adjusted[i];
            totalShares += curve.shares;
            assertGt(curve.numPositions, 0);
            assertGt(curve.shares, 0);
            assertLt(curve.tickLower, curve.tickUpper);
            assertEq(int256(curve.tickLower % TICK_SPACING), 0);
            assertEq(int256(curve.tickUpper % TICK_SPACING), 0);
        }
        assertEq(totalShares, 1 ether);

        for (uint256 i; i < positions.length; ++i) {
            Position memory position = positions[i];
            assertLt(position.tickLower, position.tickUpper);
            assertEq(int256(position.tickLower % TICK_SPACING), 0);
            assertEq(int256(position.tickUpper % TICK_SPACING), 0);
            assertGt(position.liquidity, 0);
            uint160 sqrtLower = TickMath.getSqrtPriceAtTick(position.tickLower);
            uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(position.tickUpper);
            consumed += isToken0
                ? SqrtPriceMath.getAmount0Delta(sqrtLower, sqrtUpper, position.liquidity, false)
                : SqrtPriceMath.getAmount1Delta(sqrtLower, sqrtUpper, position.liquidity, false);
        }

        assertLe(consumed, TARGET_INVENTORY);
        assertLe(TARGET_INVENTORY - consumed, MAX_RESIDUAL);
    }

    function _canonicalCurves() private pure returns (Curve[] memory curves) {
        DopplerLaunchTypes.Curve[] memory configured = StaticsLaunchCurves.defaultCurves();
        curves = new Curve[](configured.length);
        for (uint256 i; i < configured.length; ++i) {
            curves[i] = Curve({
                tickLower: configured[i].tickLower,
                tickUpper: configured[i].tickUpper,
                numPositions: configured[i].numPositions,
                shares: configured[i].shares
            });
        }
    }
}
