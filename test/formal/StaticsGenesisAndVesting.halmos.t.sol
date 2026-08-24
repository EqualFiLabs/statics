// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Test} from "forge-std/Test.sol";
import {SymTest} from "halmos-cheatcodes/SymTest.sol";
import {StaticsTreasuryVesting} from "../../src/genesis/StaticsTreasuryVesting.sol";
import {
    FormalBootstrapGenesis,
    FormalBootstrapVault,
    FormalGenesisEnvironment,
    FormalGenesisProtocol,
    FormalToken
} from "./mocks/FormalGenesisMocks.sol";

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
        assertEq(
            genesis.balanceOf(address(vault)) + genesis.balanceOf(address(vesting)) + genesis.balanceOf(alice), 5_555
        );
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

contract StaticsTreasuryVestingHalmosTest is SymTest, FormalGenesisEnvironment {
    uint256 private constant PROTOCOL_ALLOCATION = 200_000_000 ether;
    uint256 private constant DOPPLER_INVENTORY = 800_000_000 ether;
    uint256 private constant BACKING_COMMITMENT = 99_900_000 ether;
    uint256 private constant STATICS_PRINCIPAL = 100_100_000 ether;
    uint256 private constant GENESIS_PRINCIPAL = 555;
    uint256 private constant DURATION = 60 days;

    function setUp() public {
        _deployGenesis(block.timestamp + 365 days);
    }

    function check_bootstrapSplitsBackingVestingAndResidual(uint96 residual) public {
        vm.assume(residual <= 100 ether);
        FormalToken token = new FormalToken("Residual STATICS", "RSTATICS");
        address recipient = makeAddr("formalVestingRecipient");
        StaticsTreasuryVesting residualVesting = new StaticsTreasuryVesting(address(this), address(this), recipient);
        FormalBootstrapVault residualVault = new FormalBootstrapVault(token);
        FormalBootstrapGenesis residualGenesis =
            new FormalBootstrapGenesis(address(residualVault), address(residualVesting));
        token.mint(address(residualVesting), PROTOCOL_ALLOCATION + residual);
        token.mint(makeAddr("formalResidualInventory"), DOPPLER_INVENTORY - residual);

        uint256 reported =
            residualVesting.finalizeBootstrap(address(token), address(residualVault), address(residualGenesis));

        assertEq(reported, residual);
        assertEq(token.balanceOf(address(residualVesting)), STATICS_PRINCIPAL);
        assertEq(token.balanceOf(address(residualVault)), BACKING_COMMITMENT + residual);
        assertEq(residualVesting.bootstrapper(), address(0));
        assertEq(residualVesting.releasedStatics(), 0);
        assertEq(residualVesting.releasedGenesis(), 0);
        assertTrue(residualVault.finalized());

        (bool secondBootstrap,) = address(residualVesting)
            .call(
                abi.encodeWithSelector(
                    residualVesting.finalizeBootstrap.selector,
                    address(token),
                    address(residualVault),
                    address(residualGenesis)
                )
            );
        assertFalse(secondBootstrap);
    }

    function check_vestingFormulaIsLinearAndCapped(uint64 elapsed) public view {
        uint256 timestamp = vesting.vestingStart() + elapsed;
        uint256 expectedStatics =
            elapsed >= DURATION ? STATICS_PRINCIPAL : Math.mulDiv(STATICS_PRINCIPAL, elapsed, DURATION);
        uint256 expectedGenesis =
            elapsed >= DURATION ? GENESIS_PRINCIPAL : Math.mulDiv(GENESIS_PRINCIPAL, elapsed, DURATION);
        assertEq(vesting.vestedStaticsAt(timestamp), expectedStatics);
        assertEq(vesting.vestedGenesisAt(timestamp), expectedGenesis);
        assertLe(vesting.vestedStaticsAt(timestamp), STATICS_PRINCIPAL);
        assertLe(vesting.vestedGenesisAt(timestamp), GENESIS_PRINCIPAL);
    }

    function check_staticsReleaseEqualsCurrentVesting(uint64 elapsed) public {
        vm.assume(elapsed > 0);
        vm.warp(vesting.vestingStart() + elapsed);
        uint256 vested = vesting.vestedStaticsAt(block.timestamp);
        uint256 recipientBefore = statics.balanceOf(treasury);

        uint256 amount = vesting.releaseStatics();

        assertEq(amount, vested);
        assertEq(vesting.releasedStatics(), vested);
        assertEq(statics.balanceOf(treasury) - recipientBefore, vested);
        assertEq(statics.balanceOf(address(vesting)), STATICS_PRINCIPAL - vested);
        assertLe(vesting.releasedStatics(), STATICS_PRINCIPAL);
    }

    function check_genesisReleaseUsesAscendingCappedRange() public {
        vm.warp(vesting.vestingStart() + DURATION);

        uint256 count = vesting.releaseGenesis(51);

        assertEq(count, 50);
        assertEq(vesting.releasedGenesis(), 50);
        assertEq(vesting.nextGenesisId(), 5_051);
        assertEq(genesis.ownerOf(5_001), treasury);
        assertEq(genesis.ownerOf(5_050), treasury);
        assertEq(genesis.ownerOf(5_051), address(vesting));
        assertEq(genesis.balanceOf(address(vesting)), GENESIS_PRINCIPAL - 50);
    }

    function check_recipientRotationPreservesImmutableSchedule(address nextRecipient) public {
        vm.assume(nextRecipient != address(0) && nextRecipient != address(vesting));
        uint256 start = vesting.vestingStart();
        uint256 end = vesting.vestingEnd();
        uint256 staticsReleased = vesting.releasedStatics();
        uint256 genesisReleased = vesting.releasedGenesis();

        vesting.setWithdrawalRecipient(nextRecipient);

        assertEq(vesting.withdrawalRecipient(), nextRecipient);
        assertEq(vesting.recipientAdmin(), address(this));
        assertEq(vesting.vestingStart(), start);
        assertEq(vesting.vestingEnd(), end);
        assertEq(vesting.releasedStatics(), staticsReleased);
        assertEq(vesting.releasedGenesis(), genesisReleased);
        assertEq(address(vesting.statics()), address(statics));
        assertEq(address(vesting.genesisVault()), address(vault));
        assertEq(address(vesting.genesis()), address(genesis));
    }

    function check_noReleaseAtVestingStart() public {
        vm.warp(vesting.vestingStart());
        (bool staticsReleased,) = address(vesting).call(abi.encodeWithSelector(vesting.releaseStatics.selector));
        (bool genesisReleased,) = address(vesting).call(abi.encodeWithSelector(vesting.releaseGenesis.selector, 1));
        assertFalse(staticsReleased);
        assertFalse(genesisReleased);
        assertEq(vesting.releasedStatics(), 0);
        assertEq(vesting.releasedGenesis(), 0);
    }
}
