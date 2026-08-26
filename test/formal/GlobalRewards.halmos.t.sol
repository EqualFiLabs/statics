// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Test} from "forge-std/Test.sol";
import {SymTest} from "halmos-cheatcodes/SymTest.sol";
import {LibGlobalRewards} from "../../src/libraries/LibGlobalRewards.sol";
import {GlobalRewardsHarness} from "./harness/GlobalRewardsHarness.sol";

contract GlobalRewardsHalmosTest is SymTest, Test, GlobalRewardsHarness {
    function testMultiplierRepresentative() public {
        check_multiplierAlwaysDerivesFromRawStake(0.5 ether);
    }

    function testStepwiseRepresentative() public {
        check_stepwiseMultiplierMatchesDirectTransition(0.5 ether);
    }

    function testLazyMigrationRepresentative() public {
        check_lazyMigrationInitializesOneToOneAndIsIdempotent(0.5 ether);
    }

    function testBucketMaturityRepresentative() public {
        _assertBucketMaturity(uint256(1) << 87, 0);
        _assertBucketMaturity(0, uint256(1) << 87);
        _assertBucketMaturity(uint256(1) << 87, uint256(1) << 87);
    }

    function check_multiplierAlwaysDerivesFromRawStake(uint256 rawStake) public {
        rawStake %= 1 ether;
        uint256 multiplier = 12_500;
        seedCurrent(rawStake, rawStake, 17);
        transition(multiplier);

        (uint256 eligible, uint256 pending, uint256 eligibleWeight, uint256 pendingWeight,,,,) = selection();
        assertEq(eligible, rawStake);
        assertEq(pending, rawStake);
        uint256 expectedWeight = Math.mulDiv(rawStake, multiplier, LibGlobalRewards.BASE_REWARD_MULTIPLIER_BPS);
        assertEq(eligibleWeight, expectedWeight);
        assertEq(pendingWeight, expectedWeight);
        (uint256 bookEligible, uint256 bookPending, uint256 bookEligibleWeight, uint256 bookPendingWeight,,,,,) = book();
        assertEq(bookEligible, eligible);
        assertEq(bookPending, pending);
        assertEq(bookEligibleWeight, eligibleWeight);
        assertEq(bookPendingWeight, pendingWeight);
    }

    function check_stepwiseMultiplierMatchesDirectTransition(uint256 rawStake) public {
        rawStake %= 1 ether;
        seedCurrent(rawStake, rawStake, 29);
        transition(11_000);
        transition(12_500);

        (
            uint256 steppedEligible,
            uint256 steppedPending,
            uint256 steppedEligibleWeight,
            uint256 steppedPendingWeight,,,,
        ) = selection();
        seedCurrent(rawStake, rawStake, 29);
        transition(12_500);
        (uint256 directEligible, uint256 directPending, uint256 directEligibleWeight, uint256 directPendingWeight,,,,) =
            selection();
        assertEq(steppedEligible, directEligible);
        assertEq(steppedPending, directPending);
        assertEq(steppedEligibleWeight, directEligibleWeight);
        assertEq(steppedPendingWeight, directPendingWeight);
    }

    function check_lazyMigrationInitializesOneToOneAndIsIdempotent(uint256 rawStake) public {
        rawStake %= 1 ether;
        seedLegacy(rawStake, rawStake, 41);
        (, uint256 bucketWeightBefore) = bucket();
        assertEq(bucketWeightBefore, 0);

        settle();
        _assertLazySelection(rawStake, rawStake);
        _assertLazyBook(rawStake, rawStake);

        settle();
        _assertLazySelection(rawStake, rawStake);
        _assertLazyBook(rawStake, rawStake);
    }

    function check_bucketMaturityConservesRawStakeAndWeight(uint256 rawStake) public {
        rawStake %= 1 ether;
        _assertBucketMaturity(rawStake, rawStake);
    }

    function _assertBucketMaturity(uint256 eligibleStake, uint256 pendingStake) private {
        seedCurrent(eligibleStake, pendingStake, 0);
        (,,,,, uint40 eligibleAt,,) = selection();
        vm.warp(eligibleAt);
        settle();

        (uint256 eligible, uint256 pending, uint256 eligibleWeight, uint256 pendingWeight,,,,) = selection();
        assertEq(eligible, uint256(eligibleStake) + pendingStake);
        assertEq(pending, 0);
        assertEq(eligibleWeight, uint256(eligibleStake) + pendingStake);
        assertEq(pendingWeight, 0);
        (uint256 bookEligible, uint256 bookPending, uint256 bookEligibleWeight, uint256 bookPendingWeight,,,,,) = book();
        assertEq(bookEligible, eligible);
        assertEq(bookPending, 0);
        assertEq(bookEligibleWeight, eligibleWeight);
        assertEq(bookPendingWeight, 0);
    }

    function _assertLazySelection(uint256 eligibleStake, uint256 pendingStake) private view {
        (
            uint256 eligible,
            uint256 pending,
            uint256 eligibleWeight,
            uint256 pendingWeight,,
            uint40 eligibleAt,,
            bool initialized
        ) = selection();
        assertTrue(initialized);
        assertEq(eligible, eligibleStake);
        assertEq(pending, pendingStake);
        assertEq(eligibleWeight, eligibleStake);
        assertEq(pendingWeight, pendingStake);
        assertGt(eligibleAt, block.timestamp);
    }

    function _assertLazyBook(uint256 eligibleStake, uint256 pendingStake) private view {
        (
            uint256 bookEligible,
            uint256 bookPending,
            uint256 bookEligibleWeight,
            uint256 bookPendingWeight,
            uint256 indexRay,,,,
            bool initialized
        ) = book();
        (uint256 bucketStake, uint256 bucketWeight) = bucket();
        assertTrue(initialized);
        assertEq(bookEligible, eligibleStake);
        assertEq(bookPending, pendingStake);
        assertEq(bookEligibleWeight, eligibleStake);
        assertEq(bookPendingWeight, pendingStake);
        assertEq(bucketStake, pendingStake);
        assertEq(bucketWeight, pendingStake);
        assertEq(indexRay, 41);
    }
}
