// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {SymTest} from "halmos-cheatcodes/SymTest.sol";
import {LibRangeGauge} from "../../src/libraries/LibRangeGauge.sol";
import {RangeGaugeFormalHarness} from "./harness/RangeGaugeFormalHarness.sol";

contract RangeGaugeAccountingHalmosTest is SymTest, Test, RangeGaugeFormalHarness {
    uint256 private constant RAY = 1e27;
    uint40 private constant START = 1_000_000;
    uint40 private constant DURATION = 7 days;

    function testRepresentativeStreamConservation() public {
        check_streamEmitsEntireBudgetAtFinish(700);
    }

    function testRepresentativePositionRemainder() public pure {
        check_positionRemainderCarryConservesNumerator(13, 7, uint96(RAY - 1));
    }

    function testRepresentativeFinalReconciliationGate() public pure {
        check_finalReconciliationRequiresResolvedLiabilities(true, 0, 10, 10, 0, 3, 3);
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

    function check_positionRemainderCarryConservesNumerator(
        uint96 rawWhole,
        uint96 rawProductRemainder,
        uint96 rawPriorRemainder
    ) public pure {
        uint256 whole = uint256(rawWhole);
        uint256 productRemainder = uint256(rawProductRemainder) % RAY;
        uint256 prior = uint256(rawPriorRemainder) % RAY;
        (uint256 claimable, uint256 remainder) = _combinePositionAccrual(whole, productRemainder, prior);
        uint256 numerator = whole * RAY + productRemainder + prior;
        assertEq(claimable * RAY + remainder, numerator);
        assertLt(remainder, RAY);
    }

    function check_finalReconciliationRequiresResolvedLiabilities(
        bool stopped,
        uint8 unresolvedLegCount,
        uint32 periodBudget,
        uint32 periodEmitted,
        uint32 claimLiability,
        uint32 reserved,
        uint32 indexedLiability
    ) public pure {
        bool available = _reconciliationAvailable(
            stopped, unresolvedLegCount, periodBudget, periodEmitted, claimLiability, reserved, indexedLiability
        );
        bool expected = stopped && unresolvedLegCount == 0 && periodBudget == periodEmitted && claimLiability == 0
            && reserved >= indexedLiability;
        assertEq(available, expected);
        if (available) {
            assertTrue(stopped);
            assertEq(unresolvedLegCount, 0);
            assertEq(periodBudget, periodEmitted);
            assertEq(claimLiability, 0);
            assertGe(reserved, indexedLiability);
        }
    }
}
