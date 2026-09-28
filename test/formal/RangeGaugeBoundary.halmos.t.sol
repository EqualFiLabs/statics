// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {SymTest} from "halmos-cheatcodes/SymTest.sol";
import {RangeGaugeFormalHarness} from "./harness/RangeGaugeFormalHarness.sol";

contract RangeGaugeBoundaryHalmosTest is SymTest, Test, RangeGaugeFormalHarness {
    function testRepresentativeBoundarySymmetry() public {
        check_boundaryAddRemoveSymmetry(1_000);
    }

    function testRepresentativeCrossingInversion() public pure {
        check_rightThenLeftCrossingRestoresLiquidity(1_000, 17);
    }

    function testRepresentativeTopologyRestoration() public pure {
        check_registerThenUnregisterRestoresTopology(1_000, 0);
    }

    function check_boundaryAddRemoveSymmetry(uint32 rawLiquidity) public pure {
        uint128 liquidity = uint128(uint256(rawLiquidity) + 1);
        (uint128 lowerGross, int128 lowerNet) = _addBoundaryValues(0, 0, liquidity, true);
        (uint128 upperGross, int128 upperNet) = _addBoundaryValues(0, 0, liquidity, false);
        assertEq(lowerGross, liquidity);
        assertEq(lowerNet, int128(int256(uint256(liquidity))));
        assertEq(upperGross, liquidity);
        assertEq(upperNet, -int128(int256(uint256(liquidity))));

        (lowerGross, lowerNet) = _removeBoundaryValues(lowerGross, lowerNet, liquidity, true);
        (upperGross, upperNet) = _removeBoundaryValues(upperGross, upperNet, liquidity, false);
        assertEq(lowerGross, 0);
        assertEq(lowerNet, 0);
        assertEq(upperGross, 0);
        assertEq(upperNet, 0);
    }

    function check_rightThenLeftCrossingRestoresLiquidity(uint32 rawActive, uint32 rawNet) public pure {
        uint128 active = uint128(rawActive);
        int128 net = int128(int256(uint256(rawNet)));
        uint128 crossed = _applyCrossing(active, net, true);
        assertEq(_applyCrossing(crossed, net, false), active);
    }

    function check_leftThenRightCrossingRestoresLiquidity(uint32 rawBase, uint32 rawMagnitude) public pure {
        uint128 magnitude = uint128(rawMagnitude);
        uint128 active = uint128(uint256(rawBase) + magnitude);
        int128 net = -int128(int256(uint256(magnitude)));
        uint128 crossed = _applyCrossing(active, net, true);
        assertEq(_applyCrossing(crossed, net, false), active);
    }

    function check_registerThenUnregisterRestoresTopology(uint32 rawLiquidity, int8 rawRegion) public pure {
        uint128 liquidity = uint128(uint256(rawLiquidity) + 1);
        int256 region = int256(rawRegion) % 3;
        int24 referenceTick = region < 0 ? int24(-20) : region > 0 ? int24(20) : int24(0);
        (uint128 lowerGross, int128 lowerNet) = _addBoundaryValues(0, 0, liquidity, true);
        (uint128 upperGross, int128 upperNet) = _addBoundaryValues(0, 0, liquidity, false);
        uint128 activeLiquidity;
        if (_containsTick(-10, 10, referenceTick)) {
            activeLiquidity = _applyCrossing(0, int128(int256(uint256(liquidity))), true);
        }
        assertEq(activeLiquidity, referenceTick == 0 ? liquidity : 0);
        assertEq(lowerGross, liquidity);
        assertEq(lowerNet, int128(int256(uint256(liquidity))));
        assertEq(upperGross, liquidity);
        assertEq(upperNet, -int128(int256(uint256(liquidity))));

        (lowerGross, lowerNet) = _removeBoundaryValues(lowerGross, lowerNet, liquidity, true);
        (upperGross, upperNet) = _removeBoundaryValues(upperGross, upperNet, liquidity, false);
        if (_containsTick(-10, 10, referenceTick)) {
            activeLiquidity = _applyCrossing(activeLiquidity, int128(int256(uint256(liquidity))), false);
        }
        assertEq(activeLiquidity, 0);
        assertEq(lowerGross, 0);
        assertEq(lowerNet, 0);
        assertEq(upperGross, 0);
        assertEq(upperNet, 0);
    }

    function check_insideGrowthMatchesRegionIdentity(
        uint64 rawGlobal,
        uint64 rawLowerOutside,
        uint64 rawUpperOutside,
        int8 rawRegion
    ) public pure {
        uint256 global = rawGlobal;
        uint256 lowerOutside = rawLowerOutside;
        uint256 upperOutside = rawUpperOutside;
        int256 region = int256(rawRegion) % 3;
        int24 currentTick = region < 0 ? int24(-20) : region > 0 ? int24(20) : int24(0);
        uint256 actual = _inside(global, lowerOutside, upperOutside, -10, 10, currentTick);
        uint256 expected;
        unchecked {
            expected = currentTick < -10
                ? lowerOutside - upperOutside
                : currentTick >= 10 ? upperOutside - lowerOutside : global - lowerOutside - upperOutside;
        }
        assertEq(actual, expected);
    }
}
