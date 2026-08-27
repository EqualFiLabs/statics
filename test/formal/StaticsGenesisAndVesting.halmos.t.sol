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

contract StaticsTreasuryVestingHalmosTest is SymTest, Test {
    uint256 private constant DOPPLER_INVENTORY = 800_000_000 ether;
    uint256 private constant BACKING_COMMITMENT = 99_900_000 ether;
    uint256 private constant NATIVE_VESTING_PRINCIPAL = 100_100_000 ether;
    uint256 private constant GENESIS_PRINCIPAL = 555;
    uint256 private constant DURATION = 60 days;

    FormalToken private token;
    FormalBootstrapVault private vault;
    FormalBootstrapGenesis private genesis;
    StaticsTreasuryVesting private vesting;
    address private recipient;

    function setUp() public {
        token = new FormalToken("Formal STATICS", "FSTATICS");
        recipient = makeAddr("formalVestingRecipient");
        vesting = new StaticsTreasuryVesting(address(this), address(this), recipient);
        vault = new FormalBootstrapVault(token);
        genesis = new FormalBootstrapGenesis(address(vault), address(vesting));
        token.mint(address(vesting), BACKING_COMMITMENT);
        token.mint(makeAddr("formalNativeVesting"), NATIVE_VESTING_PRINCIPAL);
        token.mint(makeAddr("formalVestingInventory"), DOPPLER_INVENTORY);
        vesting.finalizeBootstrap(address(token), address(vault), address(genesis));
    }

    function check_bootstrapRetainsRepresentativeSurplus() public {
        uint256 surplus = 1_000_000 ether;
        FormalToken surplusToken = new FormalToken("Surplus STATICS", "SSTATICS");
        address surplusRecipient = makeAddr("formalSurplusRecipient");
        StaticsTreasuryVesting surplusVesting =
            new StaticsTreasuryVesting(address(this), address(this), surplusRecipient);
        FormalBootstrapVault surplusVault = new FormalBootstrapVault(surplusToken);
        FormalBootstrapGenesis surplusGenesis =
            new FormalBootstrapGenesis(address(surplusVault), address(surplusVesting));
        surplusToken.mint(address(surplusVesting), BACKING_COMMITMENT + surplus);
        surplusToken.mint(makeAddr("formalSurplusNativeVesting"), NATIVE_VESTING_PRINCIPAL);
        surplusToken.mint(makeAddr("formalSurplusInventory"), DOPPLER_INVENTORY - surplus);

        surplusVesting.finalizeBootstrap(address(surplusToken), address(surplusVault), address(surplusGenesis));

        assertEq(surplusToken.balanceOf(address(surplusVesting)), surplus);
        assertEq(surplusVesting.bootstrapper(), address(0));
        assertEq(surplusVesting.releasedGenesis(), 0);
        assertTrue(surplusVault.finalized());

        (bool secondBootstrap,) = address(surplusVesting)
            .call(
                abi.encodeWithSelector(
                    surplusVesting.finalizeBootstrap.selector,
                    address(surplusToken),
                    address(surplusVault),
                    address(surplusGenesis)
                )
            );
        assertFalse(secondBootstrap);
    }

    /// @dev uint24 covers every second through the 60-day schedule and more than
    ///      130 days after its cap while keeping symbolic multiplication tractable.
    function check_vestingFormulaIsLinearAndCapped(uint24 elapsed) public view {
        uint256 timestamp = vesting.vestingStart() + elapsed;
        uint256 expectedGenesis =
            elapsed >= DURATION ? GENESIS_PRINCIPAL : Math.mulDiv(GENESIS_PRINCIPAL, elapsed, DURATION);
        assertEq(vesting.vestedGenesisAt(timestamp), expectedGenesis);
        assertLe(vesting.vestedGenesisAt(timestamp), GENESIS_PRINCIPAL);
    }

    /// @dev The adjacent real-contract Foundry regression executes the full
    ///      50-transfer cap; this symbolic transition keeps a representative
    ///      ordered batch tractable while binding that immutable cap.
    function check_genesisReleaseUsesAscendingRange() public {
        vm.warp(vesting.vestingStart() + DURATION);

        uint256 count = vesting.releaseGenesis(4);

        assertEq(vesting.MAX_GENESIS_RELEASE_BATCH(), 50);
        assertEq(count, 4);
        assertEq(vesting.releasedGenesis(), 4);
        assertEq(vesting.nextGenesisId(), 5_005);
        assertEq(genesis.ownerOf(5_001), recipient);
        assertEq(genesis.ownerOf(5_004), recipient);
        assertEq(genesis.ownerOf(5_005), address(vesting));
        assertEq(genesis.balanceOf(address(vesting)), GENESIS_PRINCIPAL - 4);
    }

    function check_nonAdminCannotSweepSurplus() public {
        token.mint(address(vesting), 1_000_000 ether);
        vm.prank(makeAddr("formalUnauthorizedSweeper"));
        (bool swept,) = address(vesting).call(abi.encodeWithSelector(vesting.sweepStaticsSurplus.selector));

        assertFalse(swept);
    }

    function check_surplusSweepPreservesVestingState() public {
        token.mint(address(vesting), 1_000_000 ether);
        uint256 genesisReleasedBefore = vesting.releasedGenesis();
        address staticsBefore = address(vesting.statics());
        address vaultBefore = address(vesting.genesisVault());
        address genesisBefore = address(vesting.genesis());

        vesting.sweepStaticsSurplus();

        assertEq(vesting.releasedGenesis(), genesisReleasedBefore);
        assertEq(address(vesting.statics()), staticsBefore);
        assertEq(address(vesting.genesisVault()), vaultBefore);
        assertEq(address(vesting.genesis()), genesisBefore);
    }

    function check_recipientRotationPreservesImmutableSchedule(address nextRecipient) public {
        vm.assume(nextRecipient != address(0) && nextRecipient != address(vesting));
        uint256 start = vesting.vestingStart();
        uint256 end = vesting.vestingEnd();
        uint256 genesisReleased = vesting.releasedGenesis();

        vesting.setWithdrawalRecipient(nextRecipient);

        assertEq(vesting.withdrawalRecipient(), nextRecipient);
        assertEq(vesting.recipientAdmin(), address(this));
        assertEq(vesting.vestingStart(), start);
        assertEq(vesting.vestingEnd(), end);
        assertEq(vesting.releasedGenesis(), genesisReleased);
        assertEq(address(vesting.statics()), address(token));
        assertEq(address(vesting.genesisVault()), address(vault));
        assertEq(address(vesting.genesis()), address(genesis));
    }

    function check_noReleaseAtVestingStart() public {
        vm.warp(vesting.vestingStart());
        (bool genesisReleased,) = address(vesting).call(abi.encodeWithSelector(vesting.releaseGenesis.selector, 1));
        assertFalse(genesisReleased);
        assertEq(vesting.releasedGenesis(), 0);
    }
}
