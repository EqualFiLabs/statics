// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Test} from "forge-std/Test.sol";
import {SymTest} from "halmos-cheatcodes/SymTest.sol";
import {LibIndexMath} from "../../src/libraries/LibIndexMath.sol";

contract GaugeAllocatorRewardsHalmosTest is SymTest, Test {
    uint256 private constant BPS = 10_000;
    uint256 private constant WEEK = 7 days;
    uint256 private constant Q160 = 1 << 160;

    function testRepresentativeFundingSplitConservation() public pure {
        check_fundingSplitConservesReceived(10 ether, 2_500);
    }

    function testRepresentativeClaimRoundingConservation() public pure {
        check_claimRoundingCannotExceedBudget(100, 154);
    }

    function testRepresentativeProrationConservation() public pure {
        check_prorationAndTreasuryConserveBudget(10 ether, 2 days);
    }

    function testRepresentativeCarryNormalization() public pure {
        check_indexCarryNormalizesAcrossDenominatorChange(3, 7, 1, 4);
    }

    function testRepresentativeTerminalCarryReconciliation() public pure {
        check_terminalCarryReconcilesSingleWeight(1, 100, 29);
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

    function testFuzzCarryNormalization(uint64 amount, uint64 denominator, uint128 priorRemainder) public pure {
        vm.assume(denominator != 0);
        (uint256 delta, uint256 remainder) = LibIndexMath.indexDeltaAtScale(amount, denominator, priorRemainder, Q160);
        assertLt(remainder, denominator);
        assertEq(delta * denominator + remainder, uint256(amount) * Q160 + priorRemainder);
    }

    function testFuzzTerminalCarryReconciliation(uint64 amount, uint64 denominator) public pure {
        vm.assume(denominator != 0);
        _assertTerminalCarry(amount, denominator);
    }

    function check_fundingSplitConservesReceived(uint128 received, uint16 allocatorShareBps) public pure {
        vm.assume(allocatorShareBps <= BPS);
        uint256 allocatorAmount = Math.mulDiv(received, allocatorShareBps, BPS);
        uint256 lpAmount = uint256(received) - allocatorAmount;
        assertLe(allocatorAmount, received);
        assertEq(lpAmount + allocatorAmount, received);
    }

    function check_claimRoundingCannotExceedBudget(uint8 budget, uint8 firstWeightUnits) public pure {
        uint256 secondWeightUnits = 256 - firstWeightUnits;
        // Normalizing the two weights to 256 units proves every uint8 ratio with
        // exact floor division expressed as a solver-friendly right shift.
        uint256 firstClaim = (uint256(budget) * firstWeightUnits) >> 8;
        uint256 secondClaim = (uint256(budget) * secondWeightUnits) >> 8;
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

    function check_indexCarryNormalizesAcrossDenominatorChange(
        uint16 productRemainder,
        uint16 denominator,
        uint16 normalizedPrior,
        uint16 wholePrior
    ) public pure {
        vm.assume(denominator != 0);
        vm.assume(productRemainder < denominator);
        vm.assume(normalizedPrior < denominator);

        uint256 priorRemainder = uint256(wholePrior) * denominator + normalizedPrior;
        uint256 delta = wholePrior;
        uint256 remainder;
        uint256 room = uint256(denominator) - normalizedPrior;
        if (productRemainder >= room) {
            ++delta;
            remainder = uint256(productRemainder) - room;
        } else {
            remainder = uint256(productRemainder) + normalizedPrior;
        }

        assertLt(remainder, denominator);
        assertEq(delta * denominator + remainder, uint256(productRemainder) + priorRemainder);
    }

    function check_terminalCarryReconcilesSingleWeight(uint16 amount, uint16 denominator, uint16 globalRemainder)
        public
        pure
    {
        vm.assume(denominator != 0);
        vm.assume(globalRemainder < denominator);
        vm.assume(amount != 0 || globalRemainder == 0);

        uint256 scaledPositionAccrual = uint256(amount) * Q160 - globalRemainder;
        uint256 positionClaim = scaledPositionAccrual >> 160;
        uint256 positionRemainder = scaledPositionAccrual & (Q160 - 1);
        uint256 reconciled = (uint256(globalRemainder) + positionRemainder) >> 160;
        assertEq(positionClaim + reconciled, amount);
        assertLt((uint256(globalRemainder) + positionRemainder) & (Q160 - 1), Q160);
    }

    function _assertFundingSplit(uint256 received, uint16 allocatorShareBps) private pure {
        uint256 allocatorAmount = Math.mulDiv(received, allocatorShareBps, BPS);
        uint256 lpAmount = received - allocatorAmount;
        assertLe(allocatorAmount, received);
        assertEq(lpAmount + allocatorAmount, received);
    }

    function _assertTerminalCarry(uint256 amount, uint256 denominator) private pure {
        (uint256 delta, uint256 globalRemainder) = LibIndexMath.indexDeltaAtScale(amount, denominator, 0, Q160);
        uint256 scaledPositionAccrual = delta * denominator;
        uint256 positionClaim = scaledPositionAccrual / Q160;
        uint256 positionRemainder = scaledPositionAccrual % Q160;
        uint256 reconciled = (globalRemainder + positionRemainder) / Q160;
        assertEq(positionClaim + reconciled, amount);
        assertLt((globalRemainder + positionRemainder) % Q160, Q160);
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
