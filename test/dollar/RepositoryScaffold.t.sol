// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";

contract RepositoryScaffoldTest is Test {
    function testScaffoldCompiles() public pure {
        assertEq(uint256(1), uint256(1));
    }
}
