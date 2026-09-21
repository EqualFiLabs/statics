// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";

import {LibPermissionedFeeMath} from "../../src/libraries/LibPermissionedFeeMath.sol";

contract PermissionedFeeMathHarness {
    function feeFromGross(uint256 grossOutput, uint16 feeBps) external pure returns (uint256 fee) {
        return LibPermissionedFeeMath.feeFromGross(grossOutput, feeBps);
    }
}

contract PermissionedFeeMathTest is Test {
    PermissionedFeeMathHarness private feeMath;

    function setUp() public {
        feeMath = new PermissionedFeeMathHarness();
    }

    function testZeroGrossOrZeroBpsChargesZero() public view {
        assertEq(feeMath.feeFromGross(0, 1), 0);
        assertEq(feeMath.feeFromGross(1, 0), 0);
    }

    function testPositiveFeeRoundsUpToOne() public view {
        assertEq(feeMath.feeFromGross(1, 1), 1);
        assertEq(feeMath.feeFromGross(9_999, 1), 1);
    }

    function testExactDivisionIsUnchanged() public view {
        assertEq(feeMath.feeFromGross(10_000, 100), 100);
    }

    function testFullBpsNeverExceedsGrossOutput() public view {
        assertEq(feeMath.feeFromGross(37, 10_000), 37);
    }

    function testFuzzSplitSwapsCannotReduceFee(uint64 firstGrossOutput, uint64 secondGrossOutput, uint16 feeBps)
        public
        view
    {
        feeBps = uint16(bound(feeBps, 0, 10_000));
        uint256 splitFee =
            feeMath.feeFromGross(firstGrossOutput, feeBps) + feeMath.feeFromGross(secondGrossOutput, feeBps);
        uint256 combinedFee = feeMath.feeFromGross(uint256(firstGrossOutput) + secondGrossOutput, feeBps);
        assertGe(splitFee, combinedFee);
    }
}
