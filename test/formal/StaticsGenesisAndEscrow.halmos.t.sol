// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";
import {SymTest} from "halmos-cheatcodes/SymTest.sol";
import {StaticsLaunchAllocationEscrow} from "../../src/genesis/StaticsLaunchAllocationEscrow.sol";
import {FormalGenesisEnvironment, FormalGenesisProtocol, FormalToken} from "./mocks/FormalGenesisMocks.sol";

contract StaticsGenesisHalmosTest is SymTest, FormalGenesisEnvironment {
    address private alice;
    address private bob;

    function setUp() public {
        alice = makeAddr("formalAlice");
        bob = makeAddr("formalBob");
        _deployGenesis(block.timestamp + 7 days);
        statics.mint(alice, 1_000_000 ether);
        _acquire(1, alice);
    }

    function check_fixedCollectionAndOneTimeBindings() public {
        assertEq(genesis.COLLECTION_SIZE(), 5_555);
        assertEq(genesis.mintedSupply(), 5_555);
        assertEq(genesis.balanceOf(address(vault)) + genesis.balanceOf(alice), 5_555);
        assertTrue(genesis.launchFinalized());

        (bool finalizeAgain,) =
            address(vault).call(abi.encodeWithSelector(vault.finalizeGenesisCollection.selector, address(genesis)));
        assertFalse(finalizeAgain);
        (bool bindRegistryAgain,) =
            address(registry).call(abi.encodeWithSelector(registry.bindGenesisCollection.selector, address(genesis)));
        assertFalse(bindRegistryAgain);

        FormalGenesisProtocol protocol = new FormalGenesisProtocol(address(genesis));
        genesis.bindProtocol(address(protocol));
        assertEq(genesis.protocol(), address(protocol));
        FormalGenesisProtocol replacement = new FormalGenesisProtocol(address(genesis));
        (bool bindProtocolAgain,) =
            address(genesis).call(abi.encodeWithSelector(genesis.bindProtocol.selector, address(replacement)));
        assertFalse(bindProtocolAgain);
        assertEq(genesis.protocol(), address(protocol));
    }

    function check_activationChargesExactCumulativeCost(uint256 targetTier) public {
        vm.assume(targetTier >= 1 && targetTier <= registry.MAX_TIER());
        uint256 expectedCost;
        for (uint256 tier = 1; tier <= targetTier; ++tier) {
            expectedCost += registry.tierCost(uint8(tier));
        }
        uint256 treasuryBefore = statics.balanceOf(treasury);
        vm.startPrank(alice);
        statics.approve(address(registry), expectedCost);
        uint256 paid = registry.activate(1, uint8(targetTier));
        vm.stopPrank();
        assertEq(paid, expectedCost);
        assertEq(registry.tierOf(1), targetTier);
        assertEq(statics.balanceOf(treasury) - treasuryBefore, expectedCost);
        assertLe(registry.tierOf(1), registry.MAX_TIER());
    }

    function check_activationIsMonotonicWithoutTransfer(uint256 firstTier, uint256 secondTier) public {
        vm.assume(firstTier >= 1 && firstTier < registry.MAX_TIER());
        vm.assume(secondTier > firstTier && secondTier <= registry.MAX_TIER());
        _activate(firstTier);
        uint256 previous = registry.tierOf(1);
        _activate(secondTier);
        assertEq(previous, firstTier);
        assertEq(registry.tierOf(1), secondTier);
        assertGe(registry.tierOf(1), previous);
    }

    function check_ownerChangingTransferResetsActivation(uint256 targetTier) public {
        vm.assume(targetTier >= 1 && targetTier <= registry.MAX_TIER());
        _activate(targetTier);
        vm.prank(alice);
        genesis.transferFrom(alice, bob, 1);
        assertEq(genesis.ownerOf(1), bob);
        assertEq(registry.tierOf(1), 0);
        assertEq(registry.multiplierBps(1), registry.multiplierForTier(0));
        assertEq(genesis.mintedSupply(), 5_555);
    }

    function check_noCallableBurnPath(uint256 genesisId) public {
        vm.assume(genesisId >= 1 && genesisId <= genesis.COLLECTION_SIZE());
        (bool success,) = address(genesis).call(abi.encodeWithSignature("burn(uint256)", genesisId));
        assertFalse(success);
        assertEq(genesis.mintedSupply(), 5_555);
    }

    function _activate(uint256 targetTier) private {
        uint256 current = registry.tierOf(1);
        uint256 cost;
        for (uint256 tier = current + 1; tier <= targetTier; ++tier) {
            cost += registry.tierCost(uint8(tier));
        }
        vm.startPrank(alice);
        statics.approve(address(registry), cost);
        registry.activate(1, uint8(targetTier));
        vm.stopPrank();
    }
}

contract StaticsLaunchAllocationEscrowHalmosTest is SymTest, Test {
    uint256 private constant TREASURY_ALLOCATION = 200_000_000 ether;

    function check_releaseIsExactAndOneTime(uint128 residual) public {
        FormalToken token = new FormalToken("Formal STATICS", "FSTATICS");
        address treasury = makeAddr("escrowTreasury");
        address residualReceiver = makeAddr("escrowResidualReceiver");
        StaticsLaunchAllocationEscrow escrow = new StaticsLaunchAllocationEscrow(treasury, address(this));
        token.mint(address(escrow), TREASURY_ALLOCATION + residual);

        uint256 reportedResidual = escrow.release(IERC20(address(token)), residualReceiver);
        assertEq(reportedResidual, residual);
        assertEq(token.balanceOf(treasury), TREASURY_ALLOCATION);
        assertEq(token.balanceOf(residualReceiver), residual);
        assertEq(token.balanceOf(address(escrow)), 0);
        assertTrue(escrow.released());
        assertEq(escrow.bootstrapper(), address(0));

        (bool secondRelease,) = address(escrow)
            .call(abi.encodeWithSelector(escrow.release.selector, IERC20(address(token)), residualReceiver));
        assertFalse(secondRelease);
        assertEq(token.balanceOf(treasury), TREASURY_ALLOCATION);
        assertEq(token.balanceOf(address(escrow)), 0);
    }
}
