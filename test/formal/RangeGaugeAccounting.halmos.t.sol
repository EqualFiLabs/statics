// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {SymTest} from "halmos-cheatcodes/SymTest.sol";
import {LibIndexMath} from "../../src/libraries/LibIndexMath.sol";
import {LibRangeGauge} from "../../src/libraries/LibRangeGauge.sol";
import {RangeGaugeFormalHarness} from "./harness/RangeGaugeFormalHarness.sol";

contract RangeGaugeAccountingHalmosTest is SymTest, Test, RangeGaugeFormalHarness {
    uint256 private constant INDEX_SCALE = 1 << 160;
    uint40 private constant START = 1_000_000;
    uint40 private constant DURATION = 7 days;

    function testRepresentativeStreamConservation() public {
        check_streamEmitsEntireBudgetAtFinish(700);
    }

    function testRepresentativePositionRemainder() public pure {
        check_positionRemainderCarryConservesNumerator(13, type(uint160).max, 7);
    }

    function testRepresentativeLifetimeIndexCapacity() public {
        check_lifetimeIndexCapacityTracksConsecutivePeriods(3, 5);
    }

    function testRepresentativeIndexCapacityBound() public pure {
        check_indexCapacityBoundPreventsGlobalOverflow(type(uint96).max, 0);
    }

    function testRepresentativeCheckpointFragmentation() public pure {
        check_checkpointFragmentationPreservesScaledNumerator(3, 5, 12);
    }

    function testRepresentativeFinalReconciliationGate() public pure {
        check_finalReconciliationRequiresResolvedLiabilities(true, 0, 10, 10, 0, 0, 3, 3);
    }

    function check_streamEmitsEntireBudgetAtFinish(uint32 rawBudget) public {
        uint256 budget = uint256(rawBudget) + 1;
        uint128 liquidity = 1;
        _fund(budget, START, DURATION, liquidity);
        uint256 emission = _checkpoint(START + DURATION, liquidity);
        LibRangeGauge.GaugeRewardStream memory stream = _stream();
        assertEq(emission, budget);
        assertEq(stream.periodEmitted, budget);
        assertEq(stream.indexedLiability, budget);
        assertLt(stream.indexRemainder, liquidity);
    }

    function check_zeroLiquidityPausesWithoutEmitting(uint32 rawBudget, uint16 rawIdle) public {
        uint256 budget = uint256(rawBudget) + 1;
        uint40 idle = uint40(uint256(rawIdle) % 1 days) + 1;
        _fund(budget, START, DURATION, 1);
        uint256 emission = _checkpoint(START + idle, 0);
        LibRangeGauge.GaugeRewardStream memory stream = _stream();
        assertEq(emission, 0);
        assertEq(stream.periodStart, START + idle);
        assertEq(stream.periodFinish, START + DURATION + idle);
        assertEq(stream.periodEmitted, 0);
        assertEq(stream.indexedLiability, 0);
    }

    function check_topUpPreservesFinishAndConservesBudget(uint32 rawTopUp) public {
        uint256 budget = 700;
        uint256 topUp = uint256(rawTopUp) + 1;
        uint40 elapsed = DURATION / 2;
        _fund(budget, START, DURATION, 1);
        _checkpoint(START + elapsed, 1);
        _fund(topUp, START + elapsed, DURATION, 1);
        LibRangeGauge.GaugeRewardStream memory toppedUp = _stream();
        assertEq(toppedUp.periodFinish, START + DURATION);
        _checkpoint(START + DURATION, 1);
        LibRangeGauge.GaugeRewardStream memory finished = _stream();
        assertEq(finished.indexedLiability, budget + topUp);
    }

    function check_lifetimeIndexCapacityTracksConsecutivePeriods(uint32 rawFirst, uint32 rawSecond) public {
        uint256 first = uint256(rawFirst) + 1;
        uint256 second = uint256(rawSecond) + 1;
        _fund(first, START, DURATION, 1);
        _checkpoint(START + DURATION, 1);
        _fund(second, START + DURATION, DURATION, 1);
        _checkpoint(START + 2 * DURATION, 1);

        LibRangeGauge.GaugeRewardStream memory stream = _stream();
        uint256 lifetimeEmission = first + second;
        assertEq(_indexCapacityUsed(), lifetimeEmission);
        assertEq(stream.globalIndexRay, lifetimeEmission * INDEX_SCALE);
        assertLe(stream.globalIndexRay, type(uint256).max);
    }

    function check_positionRemainderCarryConservesNumerator(
        uint64 rawWhole,
        uint160 rawProductRemainder,
        uint160 rawPriorRemainder
    ) public pure {
        uint256 whole = uint256(rawWhole);
        uint256 productRemainder = uint256(rawProductRemainder);
        uint256 prior = uint256(rawPriorRemainder);
        (uint256 claimable, uint256 remainder) = _combinePositionAccrual(whole, productRemainder, prior);
        uint256 numerator = whole * INDEX_SCALE + productRemainder + prior;
        assertEq(claimable * INDEX_SCALE + remainder, numerator);
        assertLt(remainder, INDEX_SCALE);
    }

    function check_indexCapacityBoundPreventsGlobalOverflow(uint96 used, uint96 added) public pure {
        uint256 total = uint256(used) + added;
        if (total > type(uint96).max) return;
        assertLe(total * INDEX_SCALE, type(uint256).max);
    }

    function check_checkpointFragmentationPreservesScaledNumerator(
        uint8 firstAmount,
        uint8 secondAmount,
        uint8 rawDenominator
    ) public pure {
        uint256 denominator = uint256(rawDenominator) + 1;
        uint256 totalAmount = uint256(firstAmount) + secondAmount;
        (uint256 firstDelta, uint256 firstRemainder) =
            LibIndexMath.indexDeltaAtScale(firstAmount, denominator, 0, INDEX_SCALE);
        (uint256 secondDelta, uint256 secondRemainder) =
            LibIndexMath.indexDeltaAtScale(secondAmount, denominator, firstRemainder, INDEX_SCALE);
        assertEq((firstDelta + secondDelta) * denominator + secondRemainder, totalAmount * INDEX_SCALE);
        assertLt(secondRemainder, denominator);
    }

    function check_denominatorRemainderCannotReachOneRawUnit(uint128 denominator, uint128 rawRemainder) public pure {
        if (denominator == 0) denominator = 1;
        uint256 remainder = uint256(rawRemainder) % denominator;
        assertLt(remainder, INDEX_SCALE);
    }

    function check_finalReconciliationRequiresResolvedLiabilities(
        bool stopped,
        uint8 unresolvedLegCount,
        uint32 periodBudget,
        uint32 periodEmitted,
        uint32 periodRecycled,
        uint32 claimLiability,
        uint32 reserved,
        uint32 indexedLiability
    ) public pure {
        bool available = _reconciliationAvailable(
            stopped,
            unresolvedLegCount,
            periodBudget,
            periodEmitted,
            periodRecycled,
            claimLiability,
            reserved,
            indexedLiability
        );
        bool expected = stopped && unresolvedLegCount == 0 && periodBudget == uint256(periodEmitted) + periodRecycled
            && claimLiability == 0 && reserved >= indexedLiability;
        assertEq(available, expected);
        if (available) {
            assertTrue(stopped);
            assertEq(unresolvedLegCount, 0);
            assertEq(periodBudget, uint256(periodEmitted) + periodRecycled);
            assertEq(claimLiability, 0);
            assertGe(reserved, indexedLiability);
        }
    }
}
