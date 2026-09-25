// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Test} from "forge-std/Test.sol";
import {SymTest} from "halmos-cheatcodes/SymTest.sol";

contract GaugeAllocatorRewardsHalmosTest is SymTest, Test {
    uint256 private constant BPS = 10_000;
    uint256 private constant WEEK = 7 days;

    function testRepresentativeFundingSplitConservation() public pure {
        check_fundingSplitConservesReceived(10 ether, 2_500);
    }

    function testRepresentativeClaimRoundingConservation() public pure {
        check_claimRoundingCannotExceedBudget(10_000, 6_000, 4_000);
    }

    function testRepresentativeProrationConservation() public pure {
        check_prorationAndTreasuryConserveBudget(10 ether, 2 days);
    }

    function testFuzzFundingSplitConservation(uint256 received, uint16 allocatorShareBps) public pure {
        vm.assume(allocatorShareBps <= BPS);
        _assertFundingSplit(received, allocatorShareBps);
    }

    function testFuzzClaimRoundingConservation(uint256 budget, uint128 firstWeight, uint128 secondWeight) public pure {
        _assertClaimRounding(budget, firstWeight, secondWeight);
    }

    function testFuzzProrationConservation(uint256 budget, uint32 eligibleDuration) public pure {
        vm.assume(eligibleDuration <= WEEK);
        _assertProration(budget, eligibleDuration);
    }

    function check_fundingSplitConservesReceived(uint64 received, uint16 allocatorShareBps) public pure {
        vm.assume(allocatorShareBps <= BPS);
        _assertFundingSplit(received, allocatorShareBps);
    }

    function check_claimRoundingCannotExceedBudget(uint16 budget, uint16 firstWeight, uint16 secondWeight) public pure {
        _assertClaimRounding(budget, firstWeight, secondWeight);
    }

    function check_prorationAndTreasuryConserveBudget(uint64 budget, uint32 eligibleDuration) public pure {
        vm.assume(eligibleDuration <= WEEK);
        _assertProration(budget, eligibleDuration);
    }

    function _assertFundingSplit(uint256 received, uint16 allocatorShareBps) private pure {
        uint256 allocatorAmount = Math.mulDiv(received, allocatorShareBps, BPS);
        uint256 lpAmount = received - allocatorAmount;
        assertLe(allocatorAmount, received);
        assertEq(lpAmount + allocatorAmount, received);
    }

    function _assertClaimRounding(uint256 budget, uint256 firstWeight, uint256 secondWeight) private pure {
        uint256 totalWeight = firstWeight + secondWeight;
        vm.assume(totalWeight != 0);
        uint256 firstClaim = Math.mulDiv(budget, firstWeight, totalWeight);
        uint256 secondClaim = Math.mulDiv(budget, secondWeight, totalWeight);
        uint256 claimed = firstClaim + secondClaim;
        assertLe(claimed, budget);
        assertLe(budget - claimed, 1);
    }

    function _assertProration(uint256 budget, uint32 eligibleDuration) private pure {
        uint256 distributable = Math.mulDiv(budget, eligibleDuration, WEEK);
        uint256 treasuryAmount = budget - distributable;
        assertLe(distributable, budget);
        assertEq(distributable + treasuryAmount, budget);
    }
}
