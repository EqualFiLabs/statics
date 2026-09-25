// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Test} from "forge-std/Test.sol";
import {SymTest} from "halmos-cheatcodes/SymTest.sol";
import {GaugeReserveFormalHarness} from "./harness/GaugeReserveFormalHarness.sol";

contract GaugeReserveHalmosTest is SymTest, Test {
    uint256 private constant BPS = 10_000;
    uint16 private constant MAX_RELEASE_BPS = 1_000;

    GaugeReserveFormalHarness private reserve;

    function setUp() public {
        reserve = new GaugeReserveFormalHarness();
    }

    function testRepresentativeCommitmentConservation() public {
        check_releaseCommitmentPreservesReservePartition(1_000 ether, 400);
    }

    function testRepresentativeClaimAndRecycleConservation() public {
        check_claimAndRecycleConserveBackedReserve(1_000 ether, 400, 10 ether);
    }

    function testRepresentativeMaturedSchedulePromotion() public {
        check_maturedScheduleCannotBeOverwritten(400, 500, 300);
    }

    function testRepresentativeProRataConservation() public pure {
        check_twoPoolProRataSharesRemainWithinBudget(100 ether, 40 ether, 60 ether);
    }

    function testRepresentativeWeightSplittingCannotIncreaseBudget() public pure {
        check_splittingPoolWeightCannotIncreaseBudget(100 ether, 20 ether, 30 ether, 50 ether);
    }

    function check_releaseCommitmentPreservesReservePartition(uint96 reserveAmount, uint16 releaseBps) public {
        vm.assume(releaseBps <= MAX_RELEASE_BPS);
        reserve.initialize(releaseBps);
        reserve.defer(reserveAmount, 0);
        assertEq(reserve.rollDeferred(1), reserveAmount);

        uint256 budget = Math.mulDiv(reserveAmount, releaseBps, BPS);
        reserve.commit(budget);
        (uint16 storedRate, uint256 available, uint256 deferred, uint256 committed) = reserve.state();
        assertEq(storedRate, releaseBps);
        assertEq(committed, budget);
        assertEq(deferred, 0);
        assertEq(available + committed, reserveAmount);
    }

    function check_claimAndRecycleConserveBackedReserve(uint96 reserveAmount, uint16 releaseBps, uint96 recycledAmount)
        public
    {
        vm.assume(releaseBps <= MAX_RELEASE_BPS);
        uint256 budget = Math.mulDiv(reserveAmount, releaseBps, BPS);
        vm.assume(recycledAmount <= budget);
        reserve.initialize(releaseBps);
        reserve.defer(reserveAmount, 0);
        reserve.rollDeferred(1);
        reserve.commit(budget);

        uint256 claimed = budget - recycledAmount;
        reserve.consumeCommitted(claimed);
        reserve.consumeCommitted(recycledAmount);
        reserve.recycle(recycledAmount, 1, 1);

        (, uint256 available, uint256 deferred, uint256 committed) = reserve.state();
        assertEq(committed, 0);
        assertEq(deferred, recycledAmount);
        assertEq(available + deferred + claimed, reserveAmount);
    }

    function check_maturedScheduleCannotBeOverwritten(uint16 initialBps, uint16 firstBps, uint16 secondBps) public {
        vm.assume(initialBps <= MAX_RELEASE_BPS);
        vm.assume(firstBps <= MAX_RELEASE_BPS);
        vm.assume(secondBps <= MAX_RELEASE_BPS);
        reserve.initialize(initialBps);
        reserve.schedule(firstBps, 11, 10);
        reserve.schedule(secondBps, 12, 11);

        (uint16 current, uint16 pending, uint64 effectiveEpoch) = reserve.scheduleState();
        assertEq(current, firstBps);
        assertEq(pending, secondBps);
        assertEq(effectiveEpoch, 12);
        assertEq(reserve.applyScheduled(11), firstBps);
        assertEq(reserve.applyScheduled(12), secondBps);
    }

    function check_unmaturedScheduleMayBeReplaced(uint16 initialBps, uint16 firstBps, uint16 replacementBps) public {
        vm.assume(initialBps <= MAX_RELEASE_BPS);
        vm.assume(firstBps <= MAX_RELEASE_BPS);
        vm.assume(replacementBps <= MAX_RELEASE_BPS);
        reserve.initialize(initialBps);
        reserve.schedule(firstBps, 11, 10);
        reserve.schedule(replacementBps, 11, 10);

        (uint16 current, uint16 pending, uint64 effectiveEpoch) = reserve.scheduleState();
        assertEq(current, initialBps);
        assertEq(pending, replacementBps);
        assertEq(effectiveEpoch, 11);
    }

    function check_twoPoolProRataSharesRemainWithinBudget(uint96 budget, uint96 firstWeight, uint96 secondWeight)
        public
        pure
    {
        uint256 totalWeight = uint256(firstWeight) + secondWeight;
        vm.assume(totalWeight != 0);
        uint256 firstBudget = Math.mulDiv(budget, firstWeight, totalWeight);
        uint256 secondBudget = Math.mulDiv(budget, secondWeight, totalWeight);
        uint256 activated = firstBudget + secondBudget;
        assertLe(activated, budget);
        assertLt(uint256(budget) - activated, 2);
    }

    function check_splittingPoolWeightCannotIncreaseBudget(
        uint96 budget,
        uint96 firstSplit,
        uint96 secondSplit,
        uint96 otherWeight
    ) public pure {
        uint256 combinedWeight = uint256(firstSplit) + secondSplit;
        uint256 totalWeight = combinedWeight + otherWeight;
        vm.assume(totalWeight != 0);
        uint256 combinedBudget = Math.mulDiv(budget, combinedWeight, totalWeight);
        uint256 splitBudget =
            Math.mulDiv(budget, firstSplit, totalWeight) + Math.mulDiv(budget, secondSplit, totalWeight);
        assertLe(splitBudget, combinedBudget);
    }
}
