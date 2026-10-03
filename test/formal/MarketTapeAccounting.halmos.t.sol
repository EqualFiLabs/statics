// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {SymTest} from "halmos-cheatcodes/SymTest.sol";
import {LibMarketTape} from "../../src/libraries/LibMarketTape.sol";

contract MarketTapeAccountingHalmosTest is SymTest, Test {
    function testRepresentativeSaturation() public {
        check_externalVolumeSaturatesWithoutWrapping(type(uint256).max - 5, 6, type(uint256).max - 1);
    }

    function check_externalVolumeSaturatesWithoutWrapping(uint256 current, uint256 amount, uint256 sequence)
        public
        pure
    {
        (uint256 recorded, uint8 saturatedFields) = LibMarketTape.saturatingAdd(current, amount, 0, 1);

        if (amount > type(uint256).max - current) {
            assertEq(recorded, type(uint256).max);
            assertEq(saturatedFields & 1, 1);
        } else {
            assertEq(recorded, current + amount);
            assertEq(saturatedFields & 1, 0);
        }
        assertEq(LibMarketTape.nextSequence(sequence), sequence == type(uint256).max ? type(uint256).max : sequence + 1);
    }
}
