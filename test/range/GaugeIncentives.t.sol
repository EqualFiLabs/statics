// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IDiamondCut} from "../../src/interfaces/IDiamondCut.sol";
import {IStaticsGaugeIncentives} from "../../src/interfaces/IStaticsGaugeIncentives.sol";
import {IStaticsRangeGauge} from "../../src/interfaces/IStaticsRangeGauge.sol";
import {IStaticsRewardPolicy} from "../../src/interfaces/IStaticsRewardPolicy.sol";
import {GaugeIncentiveFacet} from "../../src/facets/GaugeIncentiveFacet.sol";
import {GaugeIncentiveViewFacet} from "../../src/facets/GaugeIncentiveViewFacet.sol";
import {GlobalRewardsFacet} from "../../src/facets/GlobalRewardsFacet.sol";
import {LibGaugeEpoch} from "../../src/libraries/LibGaugeEpoch.sol";
import {LibGaugeReserve} from "../../src/libraries/LibGaugeReserve.sol";
import {MockERC20, MockFeeOnTransferERC20} from "../mocks/MockERC20.sol";
import {RangeGaugeLifecycleTestBase} from "../helpers/RangeGaugeLifecycleTestBase.sol";

contract GaugeIncentivesTest is RangeGaugeLifecycleTestBase {
    uint128 private constant HIGH_LIQUIDITY = 1e33;
    uint256 private constant HIGH_TOKEN_MAXIMUM = 2e33;

    IStaticsGaugeIncentives private incentives;

    function setUp() public override {
        super.setUp();
        GaugeIncentiveFacet actions = new GaugeIncentiveFacet();
        GaugeIncentiveViewFacet views = new GaugeIncentiveViewFacet();
        IDiamondCut.FacetCut[] memory cut = new IDiamondCut.FacetCut[](2);
        cut[0] = IDiamondCut.FacetCut({
            facetAddress: address(actions),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: _incentiveActionSelectors()
        });
        cut[1] = IDiamondCut.FacetCut({
            facetAddress: address(views),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: _incentiveViewSelectors()
        });
        IDiamondCut(address(diamond)).diamondCut(cut, address(0), "");
        incentives = IStaticsGaugeIncentives(address(diamond));
    }

    function testReserveFundingMaturesAtNextEpochAndCannotDoubleCommit() public {
        _fundReserve(alice, 1_000 ether);
        IStaticsGaugeIncentives.ReserveView memory beforeBoundary = incentives.gaugeReserve();
        assertEq(beforeBoundary.available, 0);
        assertEq(beforeBoundary.deferred, 1_000 ether);
        assertEq(custody.reservedByAccount(custody.gaugeReserveCustodyAccount(), address(stakingAsset)), 1_000 ether);

        _warpNextEpoch();
        (uint64 epoch, uint256 committed, bool finalized) = incentives.checkpointGaugeEpoch();
        assertTrue(finalized);
        assertEq(committed, 0);
        IStaticsGaugeIncentives.EpochView memory state = incentives.gaugeEpoch(epoch);
        assertEq(state.nominalBudget, 40 ether);
        assertEq(state.committedBudget, 0);
        IStaticsGaugeIncentives.ReserveView memory afterBoundary = incentives.gaugeReserve();
        assertEq(afterBoundary.available, 1_000 ether);
        assertEq(afterBoundary.deferred, 0);
        assertEq(afterBoundary.committed, 0);

        (, committed, finalized) = incentives.checkpointGaugeEpoch();
        assertFalse(finalized);
        assertEq(committed, 0);
        assertEq(incentives.gaugeReserve().available, 1_000 ether);
    }

    function testAllocationValidationRejectsInvalidWeightSchedules() public {
        PoolId poolId = _createRangeGaugePool(alice);
        uint256 positionId = _createStakedPosition(alice, 100 ether);
        PoolId[] memory pools = new PoolId[](1);
        pools[0] = poolId;
        uint256[] memory amounts = new uint256[](0);

        vm.startPrank(alice);
        vm.expectRevert(IStaticsGaugeIncentives.GaugeAllocationLengthMismatch.selector);
        incentives.setGaugeAllocations(positionId, pools, amounts);

        PoolId[] memory excessivePools = new PoolId[](17);
        uint256[] memory excessiveAmounts = new uint256[](17);
        vm.expectRevert(abi.encodeWithSelector(IStaticsGaugeIncentives.GaugeAllocationLimitExceeded.selector, 17, 16));
        incentives.setGaugeAllocations(positionId, excessivePools, excessiveAmounts);

        amounts = new uint256[](1);
        vm.expectRevert(abi.encodeWithSelector(IStaticsGaugeIncentives.InvalidGaugeAllocation.selector, poolId, 0));
        incentives.setGaugeAllocations(positionId, pools, amounts);

        amounts[0] = 101 ether;
        vm.expectRevert(
            abi.encodeWithSelector(IStaticsGaugeIncentives.GaugeAllocationExceedsStake.selector, 101 ether, 100 ether)
        );
        incentives.setGaugeAllocations(positionId, pools, amounts);

        pools = new PoolId[](2);
        pools[0] = poolId;
        pools[1] = poolId;
        amounts = new uint256[](2);
        amounts[0] = 40 ether;
        amounts[1] = 40 ether;
        vm.expectRevert(abi.encodeWithSelector(IStaticsGaugeIncentives.DuplicateGaugeAllocation.selector, poolId));
        incentives.setGaugeAllocations(positionId, pools, amounts);
        vm.stopPrank();
    }

    function testStakeLossSyncRejectsExternalCallers() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IStaticsGaugeIncentives.GaugeSelfCallOnly.selector, alice));
        incentives.syncGaugeAllocationsAfterStakeLoss(1, 0);
    }

    function testStakeLossClearsAllocationsOnlyBelowRemainingStake() public {
        PoolId poolId = _createRangeGaugePool(alice);
        uint256 positionId = _createStakedPosition(alice, 100 ether);
        _setAllocation(alice, positionId, poolId, 60 ether);
        uint64 targetEpoch = incentives.currentGaugeEpoch() + 1;

        vm.prank(address(diamond));
        incentives.syncGaugeAllocationsAfterStakeLoss(positionId, 60 ether);
        vm.prank(alice);
        (,,, IStaticsGaugeIncentives.AllocationView[] memory pending, uint256 locked) =
            incentives.gaugePositionAllocations(positionId);
        assertEq(pending.length, 1);
        assertEq(locked, 60 ether);
        vm.prank(alice);
        (uint256 preserved,) = incentives.gaugePositionAllocationAt(positionId, poolId, targetEpoch);
        assertEq(preserved, 60 ether);

        vm.prank(address(diamond));
        incentives.syncGaugeAllocationsAfterStakeLoss(positionId, 59 ether);
        vm.prank(alice);
        (,,, pending, locked) = incentives.gaugePositionAllocations(positionId);
        assertEq(pending.length, 0);
        assertEq(locked, 0);
        vm.prank(alice);
        (uint256 cleared,) = incentives.gaugePositionAllocationAt(positionId, poolId, targetEpoch);
        assertEq(cleared, 0);
    }

    function testReleaseRateChangeIsOwnerBoundedAndProspective() public {
        uint64 currentEpoch = incentives.currentGaugeEpoch();
        vm.prank(alice);
        vm.expectRevert();
        incentives.scheduleGaugeReleaseBps(500);
        vm.expectRevert(abi.encodeWithSelector(LibGaugeReserve.InvalidGaugeReleaseBps.selector, 1_001));
        incentives.scheduleGaugeReleaseBps(1_001);

        incentives.scheduleGaugeReleaseBps(500);
        IStaticsGaugeIncentives.ReserveView memory scheduled = incentives.gaugeReserve();
        assertEq(scheduled.releaseBps, 400);
        assertEq(scheduled.pendingReleaseBps, 500);
        assertEq(scheduled.pendingReleaseEpoch, currentEpoch + 1);
        assertEq(incentives.gaugeEpoch(currentEpoch).releaseBps, 400);

        _fundReserve(alice, 1_000 ether);
        _warpNextEpoch();
        (uint64 activatedEpoch,,) = incentives.checkpointGaugeEpoch();
        IStaticsGaugeIncentives.EpochView memory activated = incentives.gaugeEpoch(activatedEpoch);
        assertEq(activated.releaseBps, 500);
        assertEq(activated.nominalBudget, 50 ether);
        assertEq(incentives.gaugeReserve().releaseBps, 500);
    }

    function testLateCheckpointProratesCurrentEpochBudget() public {
        PoolId poolId = _createRangeGaugePool(alice);
        uint256 positionId = _createStakedPosition(alice, 100 ether);
        _setAllocation(alice, positionId, poolId, 100 ether);
        _fundReserve(alice, 1_000 ether);

        uint40 boundary = LibGaugeEpoch.epochFinish(incentives.currentGaugeEpoch());
        vm.warp(uint256(boundary) + 3 days);
        (uint64 epoch, uint256 committed,) = incentives.checkpointGaugeEpoch();
        IStaticsGaugeIncentives.EpochView memory state = incentives.gaugeEpoch(epoch);
        uint256 expected = uint256(40 ether) * 4 days / 7 days;
        assertEq(state.nominalBudget, 40 ether);
        assertEq(state.activatedAt, boundary + 3 days);
        assertEq(committed, expected);
        assertEq(state.budgets[0], expected);
        assertEq(incentives.gaugeReserve().available, 1_000 ether - expected);
    }

    function testPendingAllocationsLockStakeUntilTheirRemovalBecomesActive() public {
        PoolId poolId = _createRangeGaugePool(alice);
        uint256 positionId = _createStakedPosition(alice, 100 ether);

        _setAllocation(alice, positionId, poolId, 60 ether);
        vm.prank(alice);
        (,,, IStaticsGaugeIncentives.AllocationView[] memory pending, uint256 locked) =
            incentives.gaugePositionAllocations(positionId);
        assertEq(pending.length, 1);
        assertEq(locked, 60 ether);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(GlobalRewardsFacet.InsufficientStake.selector, 41 ether, 40 ether));
        globalRewards.unstake(positionId, 41 ether, alice);
        vm.prank(alice);
        globalRewards.unstake(positionId, 40 ether, alice);

        _warpNextEpoch();
        incentives.checkpointGaugeEpoch();
        vm.prank(alice);
        incentives.setGaugeAllocations(positionId, new PoolId[](0), new uint256[](0));
        vm.prank(alice);
        (,,,, locked) = incentives.gaugePositionAllocations(positionId);
        assertEq(locked, 60 ether);

        _warpNextEpoch();
        incentives.checkpointGaugeEpoch();
        vm.prank(alice);
        (,,,, locked) = incentives.gaugePositionAllocations(positionId);
        assertEq(locked, 0);
        vm.prank(alice);
        globalRewards.unstake(positionId, 60 ether, alice);
    }

    function testTopTenUsesOnlyAllocatedStakeWithDeterministicTieBreak() public {
        PoolId[] memory pools = new PoolId[](11);
        uint256[] memory weights = new uint256[](11);
        uint256 total;
        for (uint256 i; i < pools.length; ++i) {
            MockERC20 paired = new MockERC20("Gauge Asset", "GA", 18);
            pools[i] = _createRangeGaugePool(alice, address(assetA), address(paired));
            weights[i] = (i + 1) * 10 ether;
            total += weights[i];
        }
        uint256 positionId = _createStakedPosition(alice, total);
        vm.prank(alice);
        incentives.setGaugeAllocations(positionId, pools, weights);
        _fundReserve(bob, 1_000_000 ether);

        _warpNextEpoch();
        (uint64 epoch, uint256 committed,) = incentives.checkpointGaugeEpoch();
        IStaticsGaugeIncentives.EpochView memory state = incentives.gaugeEpoch(epoch);
        assertEq(state.winnerCount, 10);
        assertEq(state.totalWeight, total - 10 ether);
        assertEq(state.committedBudget, committed);
        assertLe(committed, 40_000 ether);
        for (uint256 i; i < state.winnerCount; ++i) {
            assertEq(state.weights[i], (11 - i) * 10 ether);
        }
    }

    function testProtocolSlotEmitsToActiveLiquidityAndClaimsFromCommittedReserve() public {
        PoolId poolId = _createRangeGaugePool(alice);
        uint256 lpPosition = _createPosition(alice);
        _provide(lpPosition, poolId, alice);
        uint256 votingPosition = _createStakedPosition(bob, 100 ether);
        _setAllocation(bob, votingPosition, poolId, 100 ether);
        _fundReserve(bob, 1_000 ether);

        _warpNextEpoch();
        (, uint256 committed,) = incentives.checkpointGaugeEpoch();
        assertEq(committed, 40 ether);
        vm.warp(block.timestamp + 1 days);
        uint8[] memory slots = new uint8[](1);
        slots[0] = 0;
        uint256[] memory minimums = new uint256[](1);
        vm.prank(alice);
        uint256[] memory claimed = rangeGauge.claimLpRewards(lpPosition, poolId, slots, minimums, alice);
        assertApproxEqAbs(claimed[0], uint256(40 ether) / 7, 1);
        assertEq(incentives.gaugeReserve().committed, 40 ether - claimed[0]);
    }

    function testProtocolSlotFrequentClaimsPreserveCommittedBudget() public {
        PoolId poolId = _createRangeGaugePool(alice);
        uint256 lpPosition = _createPosition(alice);
        _provideHighLiquidity(lpPosition, poolId, alice);
        uint256 votingPosition = _createStakedPosition(bob, 100 ether);
        _setAllocation(bob, votingPosition, poolId, 100 ether);
        _fundReserve(bob, 1_000 ether);

        _warpNextEpoch();
        (uint64 epoch, uint256 committed,) = incentives.checkpointGaugeEpoch();
        assertEq(committed, 40 ether);
        uint256 claimed;
        uint8[] memory slots = new uint8[](1);
        uint256[] memory minimums = new uint256[](1);
        while (block.timestamp < LibGaugeEpoch.epochFinish(epoch)) {
            vm.warp(block.timestamp + 1 hours);
            vm.prank(alice);
            uint256[] memory amounts = rangeGauge.claimLpRewards(lpPosition, poolId, slots, minimums, alice);
            claimed += amounts[0];
        }

        IStaticsRangeGauge.GaugeRewardStreamView memory stream = rangeGauge.poolRewardStream(poolId, 0);
        (bytes32 account,) = rangeGauge.poolRewardCustodyAccount(poolId, 0);
        uint256 reserved = custody.reservedByAccount(account, address(stakingAsset));
        assertApproxEqAbs(claimed, committed, 1);
        assertEq(stream.periodEmitted, committed);
        assertEq(reserved, stream.indexedLiability + stream.claimLiability);
        assertEq(incentives.gaugeReserve().committed, reserved);
    }

    function testMidEpochRestrictionTerminatesAndRecyclesProtocolStream() public {
        PoolId poolId = _createRangeGaugePool(alice);
        uint256 lpPosition = _createPosition(alice);
        _provide(lpPosition, poolId, alice);
        uint256 votingPosition = _createStakedPosition(bob, 100 ether);
        _setAllocation(bob, votingPosition, poolId, 100 ether);
        _fundReserve(bob, 1_000 ether);

        _warpNextEpoch();
        incentives.checkpointGaugeEpoch();
        vm.warp(block.timestamp + 1 days);
        vm.prank(guardian);
        IStaticsRewardPolicy(address(diamond)).addRewardRestriction(address(assetA));

        uint8[] memory slots = new uint8[](1);
        slots[0] = 0;
        uint256[] memory minimums = new uint256[](1);
        vm.prank(alice);
        uint256[] memory claimed = rangeGauge.claimLpRewards(lpPosition, poolId, slots, minimums, alice);
        IStaticsRangeGauge.GaugeRewardStreamView memory stream = rangeGauge.poolRewardStream(poolId, 0);
        uint256 expectedEmission = uint256(40 ether) / 7;
        assertApproxEqAbs(stream.periodEmitted, expectedEmission, 1);
        assertEq(stream.periodEmitted + stream.periodRecycled, 40 ether);
        assertApproxEqAbs(claimed[0], expectedEmission, 1);
        assertLe(incentives.gaugeReserve().committed, 1);
        assertApproxEqAbs(incentives.gaugeReserve().deferred, 40 ether - expectedEmission, 1);
    }

    function testZeroLiquidityProtocolBudgetRecyclesAndDoesNotCarryPoolEntitlement() public {
        PoolId poolId = _createRangeGaugePool(alice);
        uint256 positionId = _createStakedPosition(alice, 100 ether);
        _setAllocation(alice, positionId, poolId, 100 ether);
        _fundReserve(alice, 1_000 ether);

        _warpNextEpoch();
        (, uint256 committed,) = incentives.checkpointGaugeEpoch();
        assertEq(committed, 40 ether);
        vm.prank(alice);
        incentives.setGaugeAllocations(positionId, new PoolId[](0), new uint256[](0));

        _warpNextEpoch();
        incentives.checkpointGaugeEpoch();
        IStaticsRangeGauge.GaugeRewardStreamView memory stream = rangeGauge.poolRewardStream(poolId, 0);
        assertEq(stream.periodEmitted, 0);
        assertEq(stream.periodRecycled, 40 ether);
        IStaticsGaugeIncentives.ReserveView memory reserve = incentives.gaugeReserve();
        assertEq(reserve.committed, 0);
        assertEq(reserve.available, 1_000 ether);
    }

    function testRestrictionInvalidatesWeightAndRequiresExplicitRefresh() public {
        PoolId poolId = _createRangeGaugePool(alice);
        uint256 positionId = _createStakedPosition(alice, 100 ether);
        _setAllocation(alice, positionId, poolId, 100 ether);
        _fundReserve(alice, 1_000 ether);
        vm.prank(guardian);
        IStaticsRewardPolicy(address(diamond)).addRewardRestriction(address(assetA));

        _warpNextEpoch();
        vm.expectPartialRevert(IStaticsGaugeIncentives.StaleGaugePoolWeight.selector);
        incentives.checkpointGaugeEpoch();
        assertEq(incentives.refreshGaugePoolWeight(poolId), 100 ether);
        (, uint256 committed, bool finalized) = incentives.checkpointGaugeEpoch();
        assertTrue(finalized);
        assertEq(committed, 0);
        vm.prank(alice);
        (,,,, uint256 locked) = incentives.gaugePositionAllocations(positionId);
        assertEq(locked, 0);

        IStaticsRewardPolicy(address(diamond)).removeRewardRestriction(address(assetA));
        assertEq(incentives.gaugePoolWeight(poolId).scheduledWeight, 0);

        _setAllocation(alice, positionId, poolId, 100 ether);
        assertEq(incentives.gaugePoolWeight(poolId).scheduledWeight, 100 ether);
        vm.prank(alice);
        (,,, IStaticsGaugeIncentives.AllocationView[] memory pending,) = incentives.gaugePositionAllocations(positionId);
        assertEq(pending.length, 1);
        assertEq(pending[0].eligibilityVersion, incentives.gaugePoolWeight(poolId).currentVersion);
    }

    function testAllocatorRewardsPayEveryHistoricalAllocatorProRata() public {
        PoolId poolId = _createRangeGaugePool(alice);
        uint256 alicePosition = _createStakedPosition(alice, 60 ether);
        uint256 bobPosition = _createStakedPosition(bob, 40 ether);
        _setAllocation(alice, alicePosition, poolId, 60 ether);
        _setAllocation(bob, bobPosition, poolId, 40 ether);
        MockERC20 reward = new MockERC20("Allocator Reward", "AR", 18);
        (uint8 slot, uint64 epoch) = _fundAllocatorReward(poolId, reward, 100 ether, 10_000, alice);

        vm.warp(LibGaugeEpoch.epochFinish(epoch));
        assertEq(incentives.finalizeGaugeAllocatorReward(poolId, slot, epoch), 100 ether);
        IStaticsGaugeIncentives.AllocatorRewardView memory state = incentives.gaugeAllocatorReward(poolId, slot, epoch);
        assertEq(state.funded, 100 ether);
        assertEq(state.totalWeight, 100 ether);
        assertEq(state.distributable, 100 ether);
        assertEq(state.remainingLiability, 100 ether);

        assertEq(_claimAllocatorReward(alice, alicePosition, poolId, epoch, slot, alice), 60 ether);
        assertEq(_claimAllocatorReward(bob, bobPosition, poolId, epoch, slot, bob), 40 ether);
        assertEq(reward.balanceOf(alice), 60 ether);
        assertEq(reward.balanceOf(bob), 40 ether);
        assertEq(incentives.gaugeAllocatorReward(poolId, slot, epoch).remainingLiability, 0);
    }

    function testAllocatorRewardUsesDelayedAllocationAfterLaterDeallocation() public {
        PoolId poolId = _createRangeGaugePool(alice);
        uint256 positionId = _createStakedPosition(alice, 100 ether);
        _setAllocation(alice, positionId, poolId, 100 ether);
        MockERC20 reward = new MockERC20("Historical Reward", "HIST", 18);
        (uint8 slot, uint64 epoch) = _fundAllocatorReward(poolId, reward, 50 ether, 10_000, bob);

        vm.warp(LibGaugeEpoch.epochStart(epoch));
        incentives.checkpointGaugeEpoch();
        vm.prank(alice);
        incentives.setGaugeAllocations(positionId, new PoolId[](0), new uint256[](0));
        vm.prank(alice);
        (uint256 historical,) = incentives.gaugePositionAllocationAt(positionId, poolId, epoch);
        assertEq(historical, 100 ether);

        vm.warp(LibGaugeEpoch.epochFinish(epoch));
        assertEq(_claimAllocatorReward(alice, positionId, poolId, epoch, slot, alice), 50 ether);
    }

    function testMidEpochRestrictionProratesAllocatorBudgetToTreasury() public {
        PoolId poolId = _createRangeGaugePool(alice);
        uint256 positionId = _createStakedPosition(alice, 100 ether);
        _setAllocation(alice, positionId, poolId, 100 ether);
        MockERC20 reward = new MockERC20("Prorated Reward", "PRO", 18);
        (uint8 slot, uint64 epoch) = _fundAllocatorReward(poolId, reward, 700 ether, 10_000, bob);

        vm.warp(uint256(LibGaugeEpoch.epochStart(epoch)) + 2 days);
        vm.prank(guardian);
        IStaticsRewardPolicy(address(diamond)).addRewardRestriction(address(assetA));
        vm.warp(LibGaugeEpoch.epochFinish(epoch));
        assertEq(incentives.finalizeGaugeAllocatorReward(poolId, slot, epoch), 200 ether);
        assertEq(globalRewards.treasuryAccrued(address(reward)), 500 ether);
        assertEq(_claimAllocatorReward(alice, positionId, poolId, epoch, slot, alice), 200 ether);
    }

    function testRepeatedFundingEpochRestrictionInvalidatesAllocatorBudget() public {
        PoolId poolId = _createRangeGaugePool(alice);
        vm.prank(guardian);
        IStaticsRewardPolicy(address(diamond)).addRewardRestriction(address(assetA));
        IStaticsRewardPolicy(address(diamond)).removeRewardRestriction(address(assetA));

        uint256 positionId = _createStakedPosition(alice, 100 ether);
        _setAllocation(alice, positionId, poolId, 100 ether);
        MockERC20 reward = new MockERC20("Invalidated Reward", "INVALID", 18);
        (uint8 slot, uint64 epoch) = _fundAllocatorReward(poolId, reward, 100 ether, 10_000, bob);

        vm.prank(guardian);
        IStaticsRewardPolicy(address(diamond)).addRewardRestriction(address(assetA));
        vm.warp(LibGaugeEpoch.epochFinish(epoch));
        assertEq(incentives.finalizeGaugeAllocatorReward(poolId, slot, epoch), 0);
        assertEq(globalRewards.treasuryAccrued(address(reward)), 100 ether);
    }

    function testAllocatorClaimsFollowPositionOwnershipAndDustExpiresToTreasury() public {
        PoolId poolId = _createRangeGaugePool(alice);
        uint256 firstPosition = _createStakedPosition(alice, 2 ether);
        uint256 secondPosition = _createStakedPosition(bob, 1 ether);
        _setAllocation(alice, firstPosition, poolId, 2 ether);
        _setAllocation(bob, secondPosition, poolId, 1 ether);
        MockERC20 reward = new MockERC20("Dust Reward", "DUST", 18);
        (uint8 slot, uint64 epoch) = _fundAllocatorReward(poolId, reward, 100, 10_000, alice);

        vm.warp(LibGaugeEpoch.epochFinish(epoch));
        incentives.finalizeGaugeAllocatorReward(poolId, slot, epoch);
        vm.prank(alice);
        IERC721(address(diamond)).transferFrom(alice, bob, firstPosition);
        assertEq(_claimAllocatorReward(bob, firstPosition, poolId, epoch, slot, bob), 66);
        assertEq(_claimAllocatorReward(bob, secondPosition, poolId, epoch, slot, bob), 33);
        assertEq(incentives.gaugeAllocatorReward(poolId, slot, epoch).remainingLiability, 1);

        vm.warp(LibGaugeEpoch.epochFinish(epoch + incentives.gaugeAllocatorClaimWindow()));
        assertEq(incentives.expireGaugeAllocatorReward(poolId, slot, epoch), 1);
        assertEq(globalRewards.treasuryAccrued(address(reward)), 1);
    }

    function testZeroWeightAllocatorBudgetRoutesEntirelyToTreasury() public {
        PoolId poolId = _createRangeGaugePool(alice);
        MockERC20 reward = new MockERC20("No Weight Reward", "ZERO", 18);
        (uint8 slot, uint64 epoch) = _fundAllocatorReward(poolId, reward, 25 ether, 10_000, bob);

        vm.warp(LibGaugeEpoch.epochFinish(epoch));
        assertEq(incentives.finalizeGaugeAllocatorReward(poolId, slot, epoch), 0);
        IStaticsGaugeIncentives.AllocatorRewardView memory state = incentives.gaugeAllocatorReward(poolId, slot, epoch);
        assertEq(state.totalWeight, 0);
        assertEq(state.remainingLiability, 0);
        assertEq(globalRewards.treasuryAccrued(address(reward)), 25 ether);
    }

    function testAllocatorClaimMinimumProtectsFeeOnTransferPayout() public {
        PoolId poolId = _createRangeGaugePool(alice);
        uint256 positionId = _createStakedPosition(alice, 100 ether);
        _setAllocation(alice, positionId, poolId, 100 ether);
        MockFeeOnTransferERC20 reward = new MockFeeOnTransferERC20();
        (uint8 slot, uint64 epoch) = _fundAllocatorReward(poolId, reward, 100 ether, 10_000, bob);
        vm.warp(LibGaugeEpoch.epochFinish(epoch));

        uint8[] memory slots = new uint8[](1);
        slots[0] = slot;
        uint256[] memory minimums = new uint256[](1);
        minimums[0] = 99 ether;
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                IStaticsGaugeIncentives.GaugeAllocatorAmountBelowMinimum.selector,
                address(reward),
                98.01 ether,
                99 ether
            )
        );
        incentives.claimGaugeAllocatorRewards(positionId, poolId, epoch, slots, minimums, alice);

        minimums[0] = 98 ether;
        vm.prank(alice);
        uint256[] memory received =
            incentives.claimGaugeAllocatorRewards(positionId, poolId, epoch, slots, minimums, alice);
        assertEq(received[0], 98.01 ether);
        assertEq(reward.balanceOf(alice), 98.01 ether);
    }

    function _createStakedPosition(address owner, uint256 amount) private returns (uint256 positionId) {
        stakingAsset.mint(owner, amount);
        vm.startPrank(owner);
        stakingAsset.approve(address(diamond), amount);
        positionId = globalRewards.createAndStake(amount, owner, new address[](0));
        vm.stopPrank();
    }

    function _provideHighLiquidity(uint256 positionId, PoolId poolId, address payer) private {
        _fundAndApprovePoolAssets(_poolKey(poolId), payer, HIGH_TOKEN_MAXIMUM);
        vm.prank(payer);
        rangeGauge.provideLiquidity(
            positionId,
            IStaticsRangeGauge.ProvideLiquidityParams({
                poolId: poolId,
                tickLower: TickMath.minUsableTick(10),
                tickUpper: TickMath.maxUsableTick(10),
                liquidity: HIGH_LIQUIDITY,
                amount0Maximum: HIGH_TOKEN_MAXIMUM,
                amount1Maximum: HIGH_TOKEN_MAXIMUM,
                deadline: block.timestamp + 1 hours
            })
        );
    }

    function _setAllocation(address owner, uint256 positionId, PoolId poolId, uint256 amount) private {
        PoolId[] memory pools = new PoolId[](1);
        pools[0] = poolId;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;
        vm.prank(owner);
        incentives.setGaugeAllocations(positionId, pools, amounts);
    }

    function _fundReserve(address funder, uint256 amount) private {
        stakingAsset.mint(funder, amount);
        vm.startPrank(funder);
        stakingAsset.approve(address(diamond), amount);
        incentives.fundGaugeReserve(amount);
        vm.stopPrank();
    }

    function _fundAllocatorReward(
        PoolId poolId,
        MockERC20 reward,
        uint256 amount,
        uint16 allocatorShareBps,
        address funder
    ) private returns (uint8 slot, uint64 epoch) {
        slot = _ensureOrdinaryRewardSlot(poolId, address(reward));
        vm.prank(alice);
        rangeGauge.setPoolRewardAllocatorShare(poolId, slot, allocatorShareBps);
        reward.mint(funder, amount);
        vm.startPrank(funder);
        reward.approve(address(diamond), amount);
        epoch = incentives.currentGaugeEpoch() + 1;
        rangeGauge.fundPoolReward(poolId, slot, amount, 0, allocatorShareBps, epoch);
        vm.stopPrank();
    }

    function _claimAllocatorReward(
        address caller,
        uint256 positionId,
        PoolId poolId,
        uint64 epoch,
        uint8 slot,
        address receiver
    ) private returns (uint256 amount) {
        uint8[] memory slots = new uint8[](1);
        slots[0] = slot;
        uint256[] memory minimums = new uint256[](1);
        vm.prank(caller);
        uint256[] memory amounts =
            incentives.claimGaugeAllocatorRewards(positionId, poolId, epoch, slots, minimums, receiver);
        amount = amounts[0];
    }

    function _warpNextEpoch() private {
        vm.warp(LibGaugeEpoch.epochFinish(incentives.currentGaugeEpoch()));
    }

    function _incentiveActionSelectors() private pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](8);
        selectors[0] = GaugeIncentiveFacet.fundGaugeReserve.selector;
        selectors[1] = GaugeIncentiveFacet.setGaugeAllocations.selector;
        selectors[2] = GaugeIncentiveFacet.checkpointGaugeEpoch.selector;
        selectors[3] = GaugeIncentiveFacet.refreshGaugePoolWeight.selector;
        selectors[4] = GaugeIncentiveFacet.scheduleGaugeReleaseBps.selector;
        selectors[5] = GaugeIncentiveFacet.finalizeGaugeAllocatorReward.selector;
        selectors[6] = GaugeIncentiveFacet.claimGaugeAllocatorRewards.selector;
        selectors[7] = GaugeIncentiveFacet.expireGaugeAllocatorReward.selector;
    }

    function _incentiveViewSelectors() private pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](13);
        selectors[0] = GaugeIncentiveViewFacet.currentGaugeEpoch.selector;
        selectors[1] = GaugeIncentiveViewFacet.gaugeEpochAt.selector;
        selectors[2] = GaugeIncentiveViewFacet.gaugeReserve.selector;
        selectors[3] = GaugeIncentiveViewFacet.gaugePoolWeight.selector;
        selectors[4] = GaugeIncentiveViewFacet.gaugePositionAllocations.selector;
        selectors[5] = GaugeIncentiveViewFacet.gaugeEpoch.selector;
        selectors[6] = GaugeIncentiveViewFacet.previewGaugeTopTen.selector;
        selectors[7] = GaugeIncentiveViewFacet.maxGaugeAllocationsPerPosition.selector;
        selectors[8] = GaugeIncentiveViewFacet.maxWeeklyGaugeReleaseBps.selector;
        selectors[9] = GaugeIncentiveViewFacet.gaugeAllocatorReward.selector;
        selectors[10] = GaugeIncentiveViewFacet.gaugePositionAllocationAt.selector;
        selectors[11] = GaugeIncentiveViewFacet.previewGaugeAllocatorRewards.selector;
        selectors[12] = GaugeIncentiveViewFacet.gaugeAllocatorClaimWindow.selector;
    }
}
