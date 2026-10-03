// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Test} from "forge-std/Test.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {LibIndexMath} from "../../src/libraries/LibIndexMath.sol";
import {LibRangeGauge} from "../../src/libraries/LibRangeGauge.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {RangeGaugeHarness} from "../helpers/RangeGaugeHarness.sol";

contract RangeGaugeAccountingTest is Test {
    PoolId private constant POOL_ID = PoolId.wrap(bytes32(uint256(0xA11CE)));
    uint256 private constant INDEX_SCALE = 1 << 160;
    uint40 private constant START = 1_000_000;
    uint40 private constant DURATION = 7 days;

    RangeGaugeHarness private gauge;
    MockERC20 private statics;

    function setUp() public {
        gauge = new RangeGaugeHarness();
        statics = new MockERC20("Statics", "STATICS", 18);
        gauge.initialize(address(statics));
        gauge.initializePool(POOL_ID, 0);
    }

    function testFixedDurationBudgetProgressEmitsEntireBudgetAtFinish() public {
        gauge.fundStream(POOL_ID, 0, 700 ether, START, DURATION, 100);
        uint256 first = gauge.checkpointStream(POOL_ID, 0, START + DURATION / 2, 100);
        assertEq(first, 350 ether);
        uint256 second = gauge.checkpointStream(POOL_ID, 0, START + DURATION, 100);
        assertEq(second, 350 ether);

        LibRangeGauge.GaugeRewardStream memory stream = gauge.stream(POOL_ID, 0);
        assertEq(stream.periodEmitted, 700 ether);
        assertEq(stream.indexedLiability, 700 ether);
        assertEq(stream.indexRemainder, 0);
    }

    function testZeroActiveLiquidityPausesScheduleTime() public {
        gauge.fundStream(POOL_ID, 0, 700 ether, START, DURATION, 100);
        assertEq(gauge.checkpointStream(POOL_ID, 0, START + 1 days, 0), 0);

        LibRangeGauge.GaugeRewardStream memory paused = gauge.stream(POOL_ID, 0);
        assertEq(paused.periodStart, START + 1 days);
        assertEq(paused.periodFinish, START + DURATION + 1 days);
        assertEq(paused.periodEmitted, 0);

        uint256 emission = gauge.checkpointStream(POOL_ID, 0, START + 2 days, 100);
        assertEq(emission, 100 ether);
    }

    function testActiveTopUpPreservesFinishAndReschedulesOnlyRemainingBudget() public {
        gauge.fundStream(POOL_ID, 0, 700 ether, START, DURATION, 100);
        gauge.checkpointStream(POOL_ID, 0, START + DURATION / 2, 100);
        (, uint40 remainingDuration) = gauge.fundStream(POOL_ID, 0, 300 ether, START + DURATION / 2, DURATION, 100);

        LibRangeGauge.GaugeRewardStream memory toppedUp = gauge.stream(POOL_ID, 0);
        assertEq(toppedUp.periodStart, START + DURATION / 2);
        assertEq(toppedUp.periodFinish, START + DURATION);
        assertEq(toppedUp.periodBudget, 650 ether);
        assertEq(toppedUp.periodEmitted, 0);
        assertEq(remainingDuration, DURATION / 2);

        assertEq(gauge.checkpointStream(POOL_ID, 0, START + DURATION, 100), 650 ether);
        LibRangeGauge.GaugeRewardStream memory finished = gauge.stream(POOL_ID, 0);
        assertEq(finished.indexedLiability, 1_000 ether);
    }

    function testGlobalDurationChangeDoesNotAlterLiveStreamSnapshot() public {
        gauge.fundStream(POOL_ID, 0, 700 ether, START, DURATION, 100);
        gauge.setRewardDuration(30 days);

        LibRangeGauge.GaugeRewardStream memory stream = gauge.stream(POOL_ID, 0);
        assertEq(stream.periodFinish, START + DURATION);
        assertEq(gauge.rewardDuration(), 30 days);
    }

    function testFundingCapsBudgetAtWorstCaseIndexCapacity() public {
        uint256 maximumBudget = type(uint256).max / INDEX_SCALE;
        gauge.fundStream(POOL_ID, 0, maximumBudget, START, DURATION, 1);
        assertEq(gauge.checkpointStream(POOL_ID, 0, START + DURATION, 1), maximumBudget);

        LibRangeGauge.GaugeRewardStream memory stream = gauge.stream(POOL_ID, 0);
        assertEq(stream.globalIndexRay, maximumBudget * INDEX_SCALE);
        assertEq(gauge.indexCapacityUsed(POOL_ID, 0), maximumBudget);
        assertEq(stream.periodEmitted, maximumBudget);
    }

    function testFundingRejectsBudgetAboveWorstCaseIndexCapacity() public {
        uint256 maximumBudget = type(uint256).max / INDEX_SCALE;
        gauge.fundStream(POOL_ID, 0, maximumBudget, START, DURATION, 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                LibRangeGauge.RewardBudgetExceedsIndexCapacity.selector, maximumBudget, uint256(1), maximumBudget
            )
        );
        gauge.fundStream(POOL_ID, 0, 1, START, DURATION, 1);
    }

    function testFundingRejectsBudgetAfterLifetimeIndexCapacityIsUsed() public {
        uint256 maximumBudget = type(uint256).max / INDEX_SCALE;
        gauge.fundStream(POOL_ID, 0, maximumBudget, START, DURATION, 1);
        gauge.checkpointStream(POOL_ID, 0, START + DURATION, 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                LibRangeGauge.RewardBudgetExceedsIndexCapacity.selector, maximumBudget, uint256(1), maximumBudget
            )
        );
        gauge.fundStream(POOL_ID, 0, 1, START + DURATION, DURATION, 1);
    }

    function testLifetimeIndexCapacityIsIndependentPerRewardSlot() public {
        gauge.fundStream(POOL_ID, 0, 11, START, DURATION, 1);
        gauge.fundStream(POOL_ID, 1, 17, START, DURATION, 1);

        assertEq(gauge.indexCapacityUsed(POOL_ID, 0), 11);
        assertEq(gauge.indexCapacityUsed(POOL_ID, 1), 17);
        assertEq(gauge.indexCapacityUsed(POOL_ID, 2), 0);
    }

    function testPositionAccrualUsesFullPrecisionAndCarriesRemainder() public view {
        uint128 liquidity = type(uint128).max;
        uint256 growth = type(uint256).max - 123;
        uint256 prior = INDEX_SCALE - 1;
        (uint256 claimable, uint256 remainder) = gauge.positionAccrual(liquidity, growth, prior);

        uint256 expected = Math.mulDiv(liquidity, growth, INDEX_SCALE);
        uint256 combined = mulmod(liquidity, growth, INDEX_SCALE) + prior;
        assertEq(claimable, expected + combined / INDEX_SCALE);
        assertEq(remainder, combined % INDEX_SCALE);
    }

    function testSettlementMovesWholeTokensFromIndexedToClaimLiability() public {
        gauge.seedStreamAccounting(POOL_ID, 0, 10 * INDEX_SCALE, 0, 30, 4);
        gauge.seedLegReward(7, POOL_ID, 0, 3, 2 * INDEX_SCALE, INDEX_SCALE - 1);

        uint256 settled = gauge.settleLegSlot(7, POOL_ID, 0, 10 * INDEX_SCALE);
        assertEq(settled, 24);
        LibRangeGauge.GaugeRewardStream memory stream = gauge.stream(POOL_ID, 0);
        assertEq(stream.indexedLiability, 6);
        assertEq(stream.claimLiability, 28);
        (uint256 checkpoint, uint256 remainder, uint256 claimable) = gauge.legReward(7, POOL_ID, 0);
        assertEq(checkpoint, 10 * INDEX_SCALE);
        assertEq(remainder, INDEX_SCALE - 1);
        assertEq(claimable, 24);
    }

    function testDenominatorResetCannotCreateWholeTokenTreasuryDust() public {
        uint128 denominator = uint128(type(int128).max) - 1;
        gauge.fundStream(POOL_ID, 0, 1, START, DURATION, denominator);
        gauge.checkpointStream(POOL_ID, 0, START + DURATION, denominator);
        LibRangeGauge.GaugeRewardStream memory beforeFlush = gauge.stream(POOL_ID, 0);
        assertGt(beforeFlush.globalIndexRay, 0);
        assertGt(beforeFlush.indexRemainder, 0);
        assertLt(beforeFlush.indexRemainder, INDEX_SCALE);
        assertEq(beforeFlush.indexedLiability, 1);

        statics.mint(address(gauge), 1);
        gauge.reserveReward(POOL_ID, 0, address(statics), 1);
        gauge.setActiveGaugeLiquidity(POOL_ID, denominator);
        gauge.registerPositionRange(POOL_ID, -10, 10, 1, 1);

        LibRangeGauge.GaugeRewardStream memory afterFlush = gauge.stream(POOL_ID, 0);
        assertEq(afterFlush.indexRemainder, 0);
        assertEq(afterFlush.indexedLiability, 1);
        assertEq(gauge.rewardReservation(POOL_ID, 0, address(statics)), 1);
        assertEq(gauge.feeReservation(address(statics)), 0);
        assertEq(gauge.treasuryAccrued(address(statics)), 0);
    }

    function testSameTimestampCheckpointCannotEmitTwice() public {
        gauge.fundStream(POOL_ID, 0, 700 ether, START, DURATION, 100);
        assertEq(gauge.checkpointStream(POOL_ID, 0, START + 1 days, 100), 100 ether);
        assertEq(gauge.checkpointStream(POOL_ID, 0, START + 1 days, 100), 0);
    }

    function testFuzzCheckpointFragmentationPreservesCarry(uint96 amount, uint128 denominator, uint8 rawParts)
        public
        pure
    {
        if (denominator == 0) denominator = 1;
        uint256 parts = uint256(rawParts) % 16 + 1;
        (uint256 singleDelta, uint256 singleRemainder) =
            LibIndexMath.indexDeltaAtScale(amount, denominator, 0, INDEX_SCALE);
        uint256 fragmentedDelta;
        uint256 fragmentedRemainder;
        uint256 base = uint256(amount) / parts;
        uint256 extra = uint256(amount) % parts;
        for (uint256 i; i < parts; ++i) {
            uint256 fragment = base + (i < extra ? 1 : 0);
            (uint256 delta, uint256 remainder) =
                LibIndexMath.indexDeltaAtScale(fragment, denominator, fragmentedRemainder, INDEX_SCALE);
            fragmentedDelta += delta;
            fragmentedRemainder = remainder;
        }
        assertEq(fragmentedDelta, singleDelta);
        assertEq(fragmentedRemainder, singleRemainder);
    }
}
