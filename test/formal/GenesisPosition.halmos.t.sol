// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {SymTest} from "halmos-cheatcodes/SymTest.sol";
import {IStaticsGenesisProtocol} from "../../src/interfaces/IStaticsGenesis.sol";
import {
    FormalGenesisLinkCollection,
    FormalGenesisLinkFeeReceiver,
    FormalGenesisLinkRegistry,
    GenesisPositionHarness
} from "./harness/GenesisPositionHarness.sol";

contract GenesisPositionHalmosTest is SymTest, Test {
    GenesisPositionHarness private harness;
    FormalGenesisLinkCollection private genesis;
    FormalGenesisLinkRegistry private registry;
    FormalGenesisLinkFeeReceiver private feeReceiver;
    address private alice;

    function setUp() public {
        alice = makeAddr("formalLinkedOwner");
        genesis = new FormalGenesisLinkCollection();
        registry = new FormalGenesisLinkRegistry();
        feeReceiver = new FormalGenesisLinkFeeReceiver();
        harness = new GenesisPositionHarness();
        genesis.setOwner(1, alice);
        harness.initializeHarness(address(genesis), address(registry), address(feeReceiver), alice, 123 ether, 12_500);
        genesis.configure(address(harness));
        registry.configure(address(harness), 12_500);
        feeReceiver.configure(address(harness));
    }

    function testLinkRepresentative() public {
        check_linkCreatesBijectionWithoutMovingEitherOwner();
    }

    function testUnlinkRepresentative() public {
        check_unlinkClearsOnlyGenesisRelationship();
    }

    function testRecoveryRepresentative() public {
        check_recoveryRemovesDirectWeightAndBoostBeforeAcknowledgement();
    }

    function check_linkCreatesBijectionWithoutMovingEitherOwner() public {
        vm.prank(alice);
        harness.linkGenesis(1, 1);

        assertEq(harness.linkedPosition(1), 1);
        assertEq(harness.linkedGenesis(1), 1);
        assertEq(genesis.ownerOf(1), alice);
        assertEq(harness.positionOwner(1), alice);
        assertTrue(harness.genesisLegActive(1, 1));
        assertTrue(harness.otherLegActive(1));
        assertEq(harness.activeLegCount(1), 2);
        assertEq(harness.positionMultiplier(1), 12_500);
        assertEq(harness.positionRawStake(1), 123 ether);
    }

    function check_unlinkClearsOnlyGenesisRelationship() public {
        vm.startPrank(alice);
        harness.linkGenesis(1, 1);
        harness.unlinkGenesis(1, 1);
        vm.stopPrank();

        assertEq(harness.linkedPosition(1), 0);
        assertEq(harness.linkedGenesis(1), 0);
        assertFalse(harness.genesisLegActive(1, 1));
        assertTrue(harness.otherLegActive(1));
        assertEq(harness.activeLegCount(1), 1);
        assertEq(genesis.ownerOf(1), alice);
        assertEq(harness.positionOwner(1), alice);
        assertEq(harness.positionMultiplier(1), 10_000);
        assertEq(harness.positionRawStake(1), 123 ether);
    }

    function check_recoveryRemovesDirectWeightAndBoostBeforeAcknowledgement() public {
        vm.prank(alice);
        harness.linkGenesis(1, 1);
        vm.prank(address(genesis));
        bytes4 acknowledgement = harness.onGenesisRecovery(1, alice);

        assertEq(acknowledgement, IStaticsGenesisProtocol.onGenesisRecovery.selector);
        assertEq(harness.genesisWeight(1), 0);
        assertEq(harness.totalGenesisWeight(), 0);
        assertEq(harness.linkedPosition(1), 0);
        assertEq(harness.linkedGenesis(1), 0);
        assertFalse(harness.genesisLegActive(1, 1));
        assertTrue(harness.otherLegActive(1));
        assertEq(harness.activeLegCount(1), 1);
        assertEq(harness.positionMultiplier(1), 10_000);
        assertEq(harness.positionRawStake(1), 123 ether);
        assertEq(genesis.ownerOf(1), alice);
        assertEq(harness.positionOwner(1), alice);
    }
}
