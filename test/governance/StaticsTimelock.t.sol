// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {StaticsTimelock} from "../../src/governance/StaticsTimelock.sol";

contract StaticsTimelockTest is Test {
    function testRobinhoodMainnetUsesProductionDelay() public {
        vm.chainId(4_663);
        assertEq(_deploy().getMinDelay(), 24 hours);
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
        assertEq(_deploy().getMinDelay(), 24 hours);
    }

    function testExplicitCancellerDoesNotReceiveProposalAuthority() public {
        address guardian = makeAddr("guardian");
        address[] memory proposers = new address[](1);
        proposers[0] = makeAddr("proposer");
        address[] memory executors = new address[](1);
        executors[0] = address(0);
        address[] memory cancellers = new address[](1);
        cancellers[0] = guardian;
        StaticsTimelock timelock = new StaticsTimelock(proposers, executors, cancellers, address(0));

        assertTrue(timelock.hasRole(timelock.CANCELLER_ROLE(), guardian));
        assertFalse(timelock.hasRole(timelock.PROPOSER_ROLE(), guardian));
        assertFalse(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), guardian));
    }

    function testRejectsPublicCancellationRole() public {
        address[] memory proposers = new address[](1);
        proposers[0] = makeAddr("proposer");
        address[] memory executors = new address[](1);
        executors[0] = address(0);
        address[] memory cancellers = new address[](1);
        cancellers[0] = address(0);
        vm.expectRevert(abi.encodeWithSelector(StaticsTimelock.InvalidCanceller.selector, address(0)));
        new StaticsTimelock(proposers, executors, cancellers, address(0));
    }

    function _deploy() private returns (StaticsTimelock timelock) {
        address[] memory proposers = new address[](1);
        proposers[0] = makeAddr("proposer");
        address[] memory executors = new address[](1);
        executors[0] = address(0);
        timelock = new StaticsTimelock(proposers, executors, new address[](0), address(0));
    }
}
