// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Test} from "forge-std/Test.sol";
import {SymTest} from "halmos-cheatcodes/SymTest.sol";

contract GaugeAllocatorRewardsHalmosTest is SymTest, Test {
    uint256 private constant BPS = 10_000;
    uint256 private constant WEEK = 7 days;

    function testRepresentativeFundingSplitConservation() public pure {
        check_fundingSplitConservesReceived(100 ether, 2_500);
    }

    function testRepresentativeClaimRoundingConservation() public pure {
        check_claimRoundingCannotExceedBudget(100 ether, 60 ether, 40 ether);
    }

    function testRepresentativeProrationConservation() public pure {
        check_prorationAndTreasuryConserveBudget(700 ether, 2 days);
    }

    function check_fundingSplitConservesReceived(uint128 received, uint16 allocatorShareBps) public pure {
        vm.assume(allocatorShareBps <= BPS);
        uint256 allocatorAmount = Math.mulDiv(received, allocatorShareBps, BPS);
        uint256 lpAmount = uint256(received) - allocatorAmount;
        assertLe(allocatorAmount, received);
        assertEq(lpAmount + allocatorAmount, received);
    }

    function check_claimRoundingCannotExceedBudget(uint128 budget, uint96 firstWeight, uint96 secondWeight)
        public
        pure
    {
        uint256 totalWeight = uint256(firstWeight) + secondWeight;
        vm.assume(totalWeight != 0);
        uint256 firstClaim = Math.mulDiv(budget, firstWeight, totalWeight);
        uint256 secondClaim = Math.mulDiv(budget, secondWeight, totalWeight);
        uint256 claimed = firstClaim + secondClaim;
        assertLe(claimed, budget);
        assertLe(uint256(budget) - claimed, 1);
    }

    function check_prorationAndTreasuryConserveBudget(uint128 budget, uint32 eligibleDuration) public pure {
        vm.assume(eligibleDuration <= WEEK);
        uint256 distributable = Math.mulDiv(budget, eligibleDuration, WEEK);
        uint256 treasuryAmount = uint256(budget) - distributable;
        assertLe(distributable, budget);
        assertEq(distributable + treasuryAmount, budget);
    }
}
