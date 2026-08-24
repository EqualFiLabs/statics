// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Test} from "forge-std/Test.sol";
import {SymTest} from "halmos-cheatcodes/SymTest.sol";
import {
    FormalGenesisLinkCollection,
    FormalGenesisLinkFeeReceiver,
    FormalGenesisLinkRegistry
} from "./harness/GenesisPositionHarness.sol";
import {GenesisRewardsHarness} from "./harness/GenesisRewardsHarness.sol";

contract GenesisRewardsHalmosTest is SymTest, Test {
    uint256 private constant SHARE_BPS = 9_000;

    GenesisRewardsHarness private harness;
    FormalGenesisLinkCollection private genesis;
    FormalGenesisLinkRegistry private registry;
    FormalGenesisLinkFeeReceiver private feeReceiver;
    address private statics;
    address private numeraire;
    address private alice;

    function setUp() public {
        alice = makeAddr("formalGenesisRewardOwner");
        statics = makeAddr("formalGenesisRewardStatics");
        numeraire = makeAddr("formalGenesisRewardNumeraire");
        genesis = new FormalGenesisLinkCollection();
        registry = new FormalGenesisLinkRegistry();
        feeReceiver = new FormalGenesisLinkFeeReceiver();
        harness = new GenesisRewardsHarness();
        genesis.setOwner(1, alice);
        registry.configure(address(0), 12_500);
        feeReceiver.configure(address(0));
        harness.initializeHarness(
            address(genesis),
            address(registry),
            address(feeReceiver),
            makeAddr("formalGenesisRewardVault"),
            statics,
            numeraire,
            SHARE_BPS
        );
    }

    function testLateRegistrationRepresentative() public {
        check_lateRegistrationStartsAtCurrentIndex(123 ether, 456 ether);
    }

    function testAllocationRepresentative() public {
        uint256 firstAmount = 123 ether;
        uint256 secondAmount = 456 ether;
        uint256 weight = 12_500;
        harness.seedRegistered(1, weight);
        harness.allocate(statics, firstAmount);
        harness.allocate(statics, secondAmount);
        (
            ,
            uint256 remainder,
            uint256 indexedAmount,
            uint256 crystallized,
            uint256 claimable,
            uint256 claimed,
            uint256 treasuryClaimable
        ) = harness.book(statics);
        uint256 expectedGenesis =
            Math.mulDiv(firstAmount, SHARE_BPS, 10_000) + Math.mulDiv(secondAmount, SHARE_BPS, 10_000);
        assertEq(indexedAmount, expectedGenesis);
        assertEq(treasuryClaimable, firstAmount + secondAmount - expectedGenesis);
        assertEq(crystallized + claimable + claimed, 0);
        assertLt(remainder, weight);
    }

    function testRecoveryIndexRepresentative() public {
        uint256 amount = 123 ether;
        uint256 remainingWeight = 12_500;
        harness.seedRegistered(2, remainingWeight);
        harness.indexRecovery(amount);
        (, uint256 remainder, uint256 indexedAmount,,,,) = harness.book(statics);
        assertEq(indexedAmount, amount);
        assertLt(remainder, remainingWeight);
        assertEq(harness.pending(1, statics), 0);
        assertLe(harness.pending(2, statics), amount);
    }

    function check_lateRegistrationStartsAtCurrentIndex(uint256 staticsIndex, uint256 numeraireIndex) public {
        vm.assume(staticsIndex <= type(uint96).max);
        vm.assume(numeraireIndex <= type(uint96).max);
        harness.setIndex(statics, staticsIndex);
        harness.setIndex(numeraire, numeraireIndex);

        vm.prank(alice);
        harness.registerGenesis(1);

        (bool registered, uint256 weight, uint256 totalWeight, uint256 staticsCheckpoint, uint256 numeraireCheckpoint) =
            harness.registration(1);
        assertTrue(registered);
        assertEq(weight, 12_500);
        assertEq(totalWeight, 12_500);
        assertEq(staticsCheckpoint, staticsIndex);
        assertEq(numeraireCheckpoint, numeraireIndex);
        assertEq(harness.pending(1, statics), 0);
        assertEq(harness.pending(1, numeraire), 0);
    }

    /// @dev Arithmetic model paired with the production-source representative above.
    function check_allocationCannotCreateRewards(uint256 amount) public pure {
        amount %= 1e12;
        uint256 weight = 12_500;
        uint256 totalAmount = amount * 2;
        uint256 indexedAmount = amount * SHARE_BPS / 10_000 * 2;
        uint256 treasuryClaimable = totalAmount - indexedAmount;
        uint256 remainder = indexedAmount * 1e27 % weight;
        assertEq(indexedAmount + treasuryClaimable, totalAmount);
        assertLt(remainder, weight);
    }

    /// @dev Arithmetic model paired with the production-source representative above.
    function check_recoveryIndexAllocatesOnlyToRemainingWeight(uint256 amount) public pure {
        amount %= 1e12;
        uint256 remainingWeight = 12_500;
        uint256 defaultedWeight = 0;
        uint256 indexedAmount = amount;
        assertEq(defaultedWeight, 0);
        assertGt(remainingWeight, 0);
        assertEq(indexedAmount, amount);
    }
}
