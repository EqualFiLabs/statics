// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {StaticsTimelock} from "../../src/governance/StaticsTimelock.sol";

contract StaticsTimelockTest is Test {
    function testRobinhoodMainnetUsesProductionDelay() public {
        vm.chainId(4_663);
        assertEq(_deploy().getMinDelay(), 7 days);
    }

    function testRobinhoodTestnetUsesDevelopmentDelay() public {
        vm.chainId(46_630);
        assertEq(_deploy().getMinDelay(), 2 minutes);
    }

    function testLocalChainUsesDevelopmentDelay() public {
        vm.chainId(31_337);
        assertEq(_deploy().getMinDelay(), 2 minutes);
    }

    function testUnknownChainDefaultsToProductionDelay() public {
        vm.chainId(1);
        assertEq(_deploy().getMinDelay(), 7 days);
    }

    function _deploy() private returns (StaticsTimelock timelock) {
        address[] memory proposers = new address[](1);
        proposers[0] = makeAddr("proposer");
        address[] memory executors = new address[](1);
        executors[0] = address(0);
        timelock = new StaticsTimelock(proposers, executors, address(0));
    }
}
