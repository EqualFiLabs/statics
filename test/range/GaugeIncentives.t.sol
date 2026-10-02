// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Vm} from "forge-std/Vm.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IDiamondCut} from "../../src/interfaces/IDiamondCut.sol";
import {IStaticsGaugeIncentives} from "../../src/interfaces/IStaticsGaugeIncentives.sol";
import {IStaticsProtocolPools} from "../../src/interfaces/IStaticsProtocolPools.sol";
import {IStaticsRangeGauge} from "../../src/interfaces/IStaticsRangeGauge.sol";
import {IStaticsRewardPolicy} from "../../src/interfaces/IStaticsRewardPolicy.sol";
import {IStaticsPosition} from "../../src/interfaces/IStaticsPosition.sol";
import {GaugeIncentiveFacet} from "../../src/facets/GaugeIncentiveFacet.sol";
import {GaugeIncentiveViewFacet} from "../../src/facets/GaugeIncentiveViewFacet.sol";
import {PositionNFTFacet} from "../../src/position/PositionNFTFacet.sol";
import {LibGaugeBribes} from "../../src/libraries/LibGaugeBribes.sol";
import {LibGaugeRouting} from "../../src/libraries/LibGaugeRouting.sol";
import {LibRangeGauge} from "../../src/libraries/LibRangeGauge.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {RangeGaugeLifecycleTestBase} from "../helpers/RangeGaugeLifecycleTestBase.sol";

contract GaugeIncentivesTest is RangeGaugeLifecycleTestBase {
    bytes32 private constant COOLDOWN_EXTENDED_TOPIC =
        keccak256("PositionGaugeAllocationCooldownExtended(uint256,uint40)");

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

    function testScheduleAnchorsAtActivationAndCommitsFirstBudget() public {
        _fundReserve(alice, 1_000 ether);
        IStaticsGaugeIncentives.ReserveView memory beforeActivation = incentives.gaugeReserve();
        assertFalse(beforeActivation.activated);
        assertEq(beforeActivation.available, 1_000 ether);
        assertEq(beforeActivation.deferred, 0);

        uint40 start = uint40(block.timestamp);
        assertEq(incentives.activateGaugeSchedule(), 40 ether);
        IStaticsGaugeIncentives.ReserveView memory active = incentives.gaugeReserve();
        assertTrue(active.activated);
        assertEq(active.scheduleStart, start);
        assertEq(active.periodStart, start);
        assertEq(active.periodFinish, start + 7 days);
        assertEq(active.periodBudget, 40 ether);
        assertEq(active.available, 960 ether);
        assertEq(active.committed, 40 ether);
    }

    function testContinuousProtocolRewardUsesPersistentAllocation() public {
        PoolId poolId = _createRangeGaugePool(alice);
        uint256 positionId = _createStakedPosition(alice, 100 ether);
        _provide(positionId, poolId, alice);
        _setAllocation(alice, positionId, poolId, 100 ether);
        _fundReserve(alice, 1_000 ether);
        incentives.activateGaugeSchedule();

        vm.warp(block.timestamp + 3.5 days);
        (uint256 credited, uint256 recycled) = incentives.checkpointGaugePool(poolId);
        assertApproxEqAbs(credited, 20 ether, 1);
        assertEq(recycled, 0);

        IStaticsRangeGauge.GaugeRewardStreamView memory stream = rangeGauge.poolRewardStream(poolId, 0);
        assertApproxEqAbs(stream.periodBudget, 20 ether, 1);
        assertApproxEqAbs(stream.periodEmitted, 20 ether, 1);
        assertEq(stream.periodRecycled, 0);

        uint8[] memory slots = new uint8[](1);
        slots[0] = 0;
        uint256[] memory minimums = new uint256[](1);
        vm.prank(alice);
        uint256[] memory claimed = rangeGauge.claimLpRewards(positionId, poolId, slots, minimums, alice);
        assertApproxEqAbs(claimed[0], 20 ether, 2);
        assertApproxEqAbs(stakingAsset.balanceOf(alice), 20 ether, 2);
    }

    function testProtocolRoutingSettlesOldWeightBeforeImmediateReallocation() public {
        PoolId firstPool = _createRangeGaugePool(alice);
        MockERC20 thirdAsset = new MockERC20("Third", "THIRD", 18);
        PoolId secondPool = _createRangeGaugePool(alice, address(assetA), address(thirdAsset));
        uint256 positionId = _createStakedPosition(alice, 100 ether);
        _provide(positionId, firstPool, alice);
        _provide(positionId, secondPool, alice);
        _setAllocation(alice, positionId, firstPool, 100 ether);
        _fundReserve(alice, 1_000 ether);
        incentives.activateGaugeSchedule();

        vm.warp(block.timestamp + 3.5 days);
        incentives.checkpointGaugePool(firstPool);
        _setAllocation(alice, positionId, secondPool, 100 ether);

        vm.warp(block.timestamp + 3.5 days);
        incentives.checkpointGaugePool(firstPool);
        incentives.checkpointGaugePool(secondPool);

        uint256 firstBudget = rangeGauge.poolRewardStream(firstPool, 0).periodBudget;
        uint256 secondBudget = rangeGauge.poolRewardStream(secondPool, 0).periodBudget;
        assertApproxEqAbs(firstBudget, 20 ether, 2);
        assertApproxEqAbs(secondBudget, 20 ether, 2);
        assertApproxEqAbs(firstBudget + secondBudget, 40 ether, 2);
    }

    function testZeroActiveLiquidityRecyclesWithoutCreatingPoolClaim() public {
        PoolId poolId = _createRangeGaugePool(alice);
        uint256 positionId = _createStakedPosition(alice, 100 ether);
        _setAllocation(alice, positionId, poolId, 100 ether);
        _fundReserve(alice, 1_000 ether);
        incentives.activateGaugeSchedule();

        vm.warp(block.timestamp + 1 days);
        (uint256 credited, uint256 recycled) = incentives.checkpointGaugePool(poolId);
        assertEq(credited, 0);
        assertApproxEqAbs(recycled, uint256(40 ether) / 7, 1);
        assertEq(rangeGauge.poolRewardStream(poolId, 0).periodBudget, 0);
        IStaticsGaugeIncentives.ReserveView memory reserve = incentives.gaugeReserve();
        assertEq(reserve.deferred, recycled);
        assertEq(reserve.committed, uint256(40 ether) - recycled);
    }

    function testAllocationChangesAreImmediateAndCooldownAllowsOnlyReductions() public {
        PoolId poolId = _createRangeGaugePool(alice);
        MockERC20 thirdAsset = new MockERC20("Third", "THIRD", 18);
        PoolId secondPool = _createRangeGaugePool(alice, address(assetA), address(thirdAsset));
        uint256 positionId = _createStakedPosition(alice, 100 ether);
        _setAllocation(alice, positionId, poolId, 100 ether);

        vm.prank(alice);
        (uint40 nextAllocationAt, uint256 totalAllocated, IStaticsGaugeIncentives.AllocationView[] memory active,) =
            incentives.gaugePositionAllocations(positionId);
        assertEq(totalAllocated, 100 ether);
        assertEq(active[0].amount, 100 ether);
        assertEq(nextAllocationAt, block.timestamp + 4 hours);

        _setAllocation(alice, positionId, poolId, 60 ether);
        assertEq(incentives.gaugePoolWeight(poolId).weight, 60 ether);

        PoolId[] memory pools = new PoolId[](1);
        pools[0] = poolId;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 61 ether;
        vm.prank(alice);
        vm.expectPartialRevert(LibGaugeRouting.GaugeAllocationIncreaseDuringCooldown.selector);
        incentives.setGaugeAllocations(positionId, pools, amounts);

        pools[0] = secondPool;
        amounts[0] = 1 ether;
        vm.prank(alice);
        vm.expectPartialRevert(LibGaugeRouting.GaugeAllocationIncreaseDuringCooldown.selector);
        incentives.setGaugeAllocations(positionId, pools, amounts);

        pools = new PoolId[](0);
        amounts = new uint256[](0);
        vm.prank(alice);
        incentives.setGaugeAllocations(positionId, pools, amounts);
        assertEq(incentives.gaugePoolWeight(poolId).weight, 0);
    }

    function testStakeIngressStartsCooldownAndBlocksInitialAllocation() public {
        PoolId poolId = _createRangeGaugePool(alice);
        uint40 expectedDeadline = uint40(block.timestamp + 4 hours);

        vm.recordLogs();
        uint256 positionId = _createCoolingStakedPosition(alice, 100 ether);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        _assertCooldownExtended(logs, positionId, expectedDeadline);

        vm.prank(alice);
        (uint40 nextAllocationAt, uint256 totalAllocated,,) = incentives.gaugePositionAllocations(positionId);
        assertEq(nextAllocationAt, expectedDeadline);
        assertEq(totalAllocated, 0);

        PoolId[] memory pools = new PoolId[](1);
        pools[0] = poolId;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100 ether;
        vm.prank(alice);
        vm.expectPartialRevert(LibGaugeRouting.GaugeAllocationIncreaseDuringCooldown.selector);
        incentives.setGaugeAllocations(positionId, pools, amounts);

        vm.warp(expectedDeadline);
        vm.prank(alice);
        incentives.setGaugeAllocations(positionId, pools, amounts);
        assertEq(incentives.gaugePoolWeight(poolId).weight, 100 ether);
    }

    function testStakeMigrationCannotBypassAllocationCooldown() public {
        PoolId poolId = _createRangeGaugePool(alice);
        uint256 firstPositionId = _createStakedPosition(alice, 100 ether);
        _setAllocation(alice, firstPositionId, poolId, 100 ether);
        _clearAllocations(alice, firstPositionId);

        vm.prank(alice);
        globalRewards.unstake(firstPositionId, 100 ether, alice);

        uint256 secondPositionId = _createCoolingStakedPosition(alice, 100 ether);
        PoolId[] memory pools = new PoolId[](1);
        pools[0] = poolId;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100 ether;
        vm.prank(alice);
        vm.expectPartialRevert(LibGaugeRouting.GaugeAllocationIncreaseDuringCooldown.selector);
        incentives.setGaugeAllocations(secondPositionId, pools, amounts);

        vm.prank(alice);
        (uint40 nextAllocationAt,,,) = incentives.gaugePositionAllocations(secondPositionId);
        vm.warp(nextAllocationAt);
        vm.prank(alice);
        incentives.setGaugeAllocations(secondPositionId, pools, amounts);
        assertEq(incentives.gaugePoolWeight(poolId).weight, 100 ether);
    }

    function testStakeTopUpExtendsCooldownWithoutInterruptingAllocation() public {
        PoolId poolId = _createRangeGaugePool(alice);
        uint256 positionId = _createStakedPosition(alice, 100 ether);
        _setAllocation(alice, positionId, poolId, 60 ether);
        vm.prank(alice);
        (uint40 priorDeadline,,,) = incentives.gaugePositionAllocations(positionId);

        vm.warp(block.timestamp + 1 hours);
        stakingAsset.mint(alice, 20 ether);
        vm.startPrank(alice);
        stakingAsset.approve(address(diamond), 20 ether);
        globalRewards.stake(positionId, 20 ether);
        vm.stopPrank();

        vm.prank(alice);
        (uint40 extendedDeadline, uint256 totalAllocated,, uint256 lockedStake) =
            incentives.gaugePositionAllocations(positionId);
        assertEq(extendedDeadline, block.timestamp + 4 hours);
        assertGt(extendedDeadline, priorDeadline);
        assertEq(totalAllocated, 60 ether);
        assertEq(lockedStake, 60 ether);
        assertEq(incentives.gaugePoolWeight(poolId).weight, 60 ether);

        _setAllocation(alice, positionId, poolId, 50 ether);
        PoolId[] memory pools = new PoolId[](1);
        pools[0] = poolId;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 51 ether;
        vm.prank(alice);
        vm.expectPartialRevert(LibGaugeRouting.GaugeAllocationIncreaseDuringCooldown.selector);
        incentives.setGaugeAllocations(positionId, pools, amounts);

        vm.prank(alice);
        globalRewards.unstake(positionId, 70 ether, alice);
        vm.prank(alice);
        assertEq(globalRewards.stakePosition(positionId).stakedBalance, 50 ether);
        assertEq(incentives.gaugePoolWeight(poolId).weight, 50 ether);
    }

    function testZeroCooldownAllowsImmediateAllocationAfterStake() public {
        incentives.setGaugeAllocationCooldown(0);
        PoolId poolId = _createRangeGaugePool(alice);
        uint256 positionId = _createCoolingStakedPosition(alice, 100 ether);

        vm.prank(alice);
        (uint40 nextAllocationAt,,,) = incentives.gaugePositionAllocations(positionId);
        assertEq(nextAllocationAt, block.timestamp);
        _setAllocation(alice, positionId, poolId, 100 ether);
        assertEq(incentives.gaugePoolWeight(poolId).weight, 100 ether);
    }

    function testCooldownConfigurationIsProspectiveForExistingPosition() public {
        PoolId poolId = _createRangeGaugePool(alice);
        uint256 positionId = _createStakedPosition(alice, 100 ether);
        _setAllocation(alice, positionId, poolId, 100 ether);
        vm.prank(alice);
        (uint40 existingDeadline,,,) = incentives.gaugePositionAllocations(positionId);

        incentives.setGaugeAllocationCooldown(0);
        assertEq(incentives.gaugeAllocationCooldown(), 0);
        vm.prank(alice);
        (uint40 unchangedDeadline,,,) = incentives.gaugePositionAllocations(positionId);
        assertEq(unchangedDeadline, existingDeadline);

        stakingAsset.mint(alice, 1 ether);
        vm.startPrank(alice);
        stakingAsset.approve(address(diamond), 1 ether);
        globalRewards.stake(positionId, 1 ether);
        vm.stopPrank();
        vm.prank(alice);
        (uint40 deadlineAfterTopUp,,,) = incentives.gaugePositionAllocations(positionId);
        assertEq(deadlineAfterTopUp, existingDeadline);

        vm.warp(existingDeadline);
        _setAllocation(alice, positionId, poolId, 99 ether);
        vm.prank(alice);
        (uint40 nextDeadline,,,) = incentives.gaugePositionAllocations(positionId);
        assertEq(nextDeadline, block.timestamp);
    }

    function testReleaseChangeAppliesAtNextAnchoredBoundary() public {
        _fundReserve(alice, 1_000 ether);
        incentives.activateGaugeSchedule();
        IStaticsGaugeIncentives.ReserveView memory first = incentives.gaugeReserve();
        incentives.scheduleGaugeReleaseBps(500);
        IStaticsGaugeIncentives.ReserveView memory scheduled = incentives.gaugeReserve();
        assertEq(scheduled.releaseBps, 400);
        assertEq(scheduled.pendingReleaseBps, 500);
        assertEq(scheduled.pendingReleaseAt, first.periodFinish);

        vm.warp(first.periodFinish);
        incentives.checkpointGaugeSchedule(1);
        IStaticsGaugeIncentives.ReserveView memory second = incentives.gaugeReserve();
        assertEq(second.currentPeriod, 1);
        assertEq(second.releaseBps, 500);
        assertEq(second.pendingReleaseAt, 0);
        assertEq(second.periodBudget, 50 ether);
    }

    function testReserveDepositAfterActivationMaturesAtNextBoundary() public {
        _fundReserve(alice, 1_000 ether);
        incentives.activateGaugeSchedule();
        IStaticsGaugeIncentives.ReserveView memory first = incentives.gaugeReserve();

        vm.warp(block.timestamp + 1 days);
        _fundReserve(bob, 500 ether);
        IStaticsGaugeIncentives.ReserveView memory funded = incentives.gaugeReserve();
        assertEq(funded.available, 960 ether);
        assertApproxEqAbs(funded.deferred, 500 ether + uint256(40 ether) / 7, 1);
        assertEq(funded.deferredMaturityAt, first.periodFinish);
        assertEq(funded.periodBudget, 40 ether);

        vm.warp(first.periodFinish);
        incentives.checkpointGaugeSchedule(1);
        IStaticsGaugeIncentives.ReserveView memory second = incentives.gaugeReserve();
        assertEq(second.periodBudget, 60 ether);
        assertEq(second.deferred, 0);
        assertEq(second.available, 1_440 ether);
    }

    function testMissedPeriodsCatchUpExactlyWithinCallerBound() public {
        _fundReserve(alice, 1_000 ether);
        incentives.activateGaugeSchedule();
        uint40 firstFinish = incentives.gaugeReserve().periodFinish;
        vm.warp(uint256(firstFinish) + 14 days);

        (uint64 firstPeriod, uint16 firstProcessed,) = incentives.checkpointGaugeSchedule(1);
        assertEq(firstPeriod, 1);
        assertEq(firstProcessed, 1);
        assertEq(incentives.gaugeReserve().lastCheckpoint, firstFinish);

        (uint64 period, uint16 processed,) = incentives.checkpointGaugeSchedule(2);
        assertEq(period, 3);
        assertEq(processed, 2);
        IStaticsGaugeIncentives.ReserveView memory reserve = incentives.gaugeReserve();
        assertEq(reserve.lastCheckpoint, block.timestamp);
        assertEq(reserve.periodStart, firstFinish + 14 days);
    }

    function testCatchUpBeyondMaximumUsesMultipleBoundedCalls() public {
        _fundReserve(alice, 1_000 ether);
        incentives.activateGaugeSchedule();
        vm.warp(block.timestamp + 53 weeks);

        (uint64 period, uint16 processed,) = incentives.checkpointGaugeSchedule(52);
        assertEq(period, 52);
        assertEq(processed, 52);

        (period, processed,) = incentives.checkpointGaugeSchedule(1);
        assertEq(period, 53);
        assertEq(processed, 1);
        assertEq(incentives.gaugeReserve().lastCheckpoint, block.timestamp);
    }

    function testCreatorAllocatorRewardAccruesContinuouslyAndNeverUsesSlotZero() public {
        PoolId poolId = _createRangeGaugePool(alice);
        uint256 positionId = _createStakedPosition(alice, 100 ether);
        _setAllocation(alice, positionId, poolId, 100 ether);
        MockERC20 reward = new MockERC20("Reward", "RWD", 18);
        uint8 slot = _ensureOrdinaryRewardSlot(poolId, address(reward));
        vm.prank(alice);
        rangeGauge.setPoolRewardAllocatorShare(poolId, slot, 5_000);

        reward.mint(bob, 100 ether);
        vm.startPrank(bob);
        reward.approve(address(diamond), 100 ether);
        rangeGauge.fundPoolReward(poolId, slot, 100 ether, 0, 5_000);
        vm.stopPrank();

        vm.warp(block.timestamp + 3.5 days);
        uint8[] memory slots = new uint8[](1);
        slots[0] = slot;
        uint256[] memory minimums = new uint256[](1);
        vm.prank(alice);
        uint256[] memory claimed = incentives.claimGaugeAllocatorRewards(positionId, poolId, slots, minimums, alice);
        assertApproxEqAbs(claimed[0], 25 ether, 1);
        assertApproxEqAbs(reward.balanceOf(alice), 25 ether, 1);

        vm.expectRevert(abi.encodeWithSelector(IStaticsGaugeIncentives.InvalidGaugeAllocatorSlot.selector, poolId, 0));
        incentives.gaugeAllocatorReward(poolId, 0);
    }

    function testLaterAllocatorDoesNotReceiveHistoricalCreatorRewards() public {
        PoolId poolId = _createRangeGaugePool(alice);
        uint256 alicePosition = _createStakedPosition(alice, 100 ether);
        uint256 bobPosition = _createStakedPosition(bob, 100 ether);
        _setAllocation(alice, alicePosition, poolId, 100 ether);

        MockERC20 reward = new MockERC20("Reward", "RWD", 18);
        uint8 slot = _ensureOrdinaryRewardSlot(poolId, address(reward));
        vm.prank(alice);
        rangeGauge.setPoolRewardAllocatorShare(poolId, slot, 10_000);
        reward.mint(alice, 100 ether);
        vm.startPrank(alice);
        reward.approve(address(diamond), 100 ether);
        rangeGauge.fundPoolReward(poolId, slot, 100 ether, 0, 10_000);
        vm.stopPrank();

        vm.warp(block.timestamp + 3.5 days);
        _setAllocation(bob, bobPosition, poolId, 100 ether);
        vm.warp(block.timestamp + 3.5 days);

        uint8[] memory slots = new uint8[](1);
        slots[0] = slot;
        uint256[] memory minimums = new uint256[](1);
        vm.prank(alice);
        uint256[] memory aliceClaim =
            incentives.claimGaugeAllocatorRewards(alicePosition, poolId, slots, minimums, alice);
        vm.prank(bob);
        uint256[] memory bobClaim = incentives.claimGaugeAllocatorRewards(bobPosition, poolId, slots, minimums, bob);

        assertApproxEqAbs(aliceClaim[0], 75 ether, 2);
        assertApproxEqAbs(bobClaim[0], 25 ether, 2);
        assertApproxEqAbs(aliceClaim[0] + bobClaim[0], 100 ether, 2);
    }

    function testAllocatorStreamPausesUntilPoolHasAllocatedWeight() public {
        PoolId poolId = _createRangeGaugePool(alice);
        uint256 positionId = _createStakedPosition(alice, 100 ether);
        MockERC20 reward = new MockERC20("Reward", "RWD", 18);
        uint8 slot = _ensureOrdinaryRewardSlot(poolId, address(reward));
        vm.prank(alice);
        rangeGauge.setPoolRewardAllocatorShare(poolId, slot, 10_000);
        reward.mint(alice, 100 ether);
        vm.startPrank(alice);
        reward.approve(address(diamond), 100 ether);
        rangeGauge.fundPoolReward(poolId, slot, 100 ether, 0, 10_000);
        vm.stopPrank();

        vm.warp(block.timestamp + 3.5 days);
        _setAllocation(alice, positionId, poolId, 100 ether);
        vm.warp(block.timestamp + 7 days);

        uint8[] memory slots = new uint8[](1);
        slots[0] = slot;
        uint256[] memory minimums = new uint256[](1);
        vm.prank(alice);
        uint256[] memory claimed = incentives.claimGaugeAllocatorRewards(positionId, poolId, slots, minimums, alice);
        assertApproxEqAbs(claimed[0], 100 ether, 2);
        assertApproxEqAbs(reward.balanceOf(alice), 100 ether, 2);
    }

    function testLongIdleAllocatorStreamDoesNotBackdateRewardsToFirstAllocator() public {
        PoolId poolId = _createRangeGaugePool(alice);
        uint256 positionId = _createStakedPosition(alice, 100 ether);
        MockERC20 reward = new MockERC20("Reward", "RWD", 18);
        uint8 slot = _ensureOrdinaryRewardSlot(poolId, address(reward));
        vm.prank(alice);
        rangeGauge.setPoolRewardAllocatorShare(poolId, slot, 10_000);
        _fundAllocatorReward(poolId, reward, 100 ether);

        vm.warp(block.timestamp + 30 days);
        _setAllocation(alice, positionId, poolId, 100 ether);
        assertEq(_claimAllocator(alice, positionId, poolId, slot), 0);

        vm.warp(block.timestamp + 7 days);
        assertApproxEqAbs(_claimAllocator(alice, positionId, poolId, slot), 100 ether, 2);
    }

    function testLongIdleAllocatorTopUpKeepsScheduleLive() public {
        PoolId poolId = _createRangeGaugePool(alice);
        uint256 positionId = _createStakedPosition(alice, 100 ether);
        MockERC20 reward = new MockERC20("Reward", "RWD", 18);
        uint8 slot = _ensureOrdinaryRewardSlot(poolId, address(reward));
        vm.prank(alice);
        rangeGauge.setPoolRewardAllocatorShare(poolId, slot, 10_000);
        _fundAllocatorReward(poolId, reward, 100 ether);

        vm.warp(block.timestamp + 30 days);
        _fundAllocatorReward(poolId, reward, 100 ether);
        IStaticsGaugeIncentives.AllocatorRewardView memory stream = incentives.gaugeAllocatorReward(poolId, slot);
        assertEq(stream.lastUpdate, block.timestamp);
        assertEq(stream.periodFinish, block.timestamp + 7 days);

        _setAllocation(alice, positionId, poolId, 100 ether);
        vm.warp(block.timestamp + 7 days);
        assertApproxEqAbs(_claimAllocator(alice, positionId, poolId, slot), 200 ether, 2);
    }

    function testAllocatorRewardClaimDoesNotExpire() public {
        PoolId poolId = _createRangeGaugePool(alice);
        uint256 positionId = _createStakedPosition(alice, 100 ether);
        _setAllocation(alice, positionId, poolId, 100 ether);
        MockERC20 reward = new MockERC20("Reward", "RWD", 18);
        uint8 slot = _ensureOrdinaryRewardSlot(poolId, address(reward));
        vm.prank(alice);
        rangeGauge.setPoolRewardAllocatorShare(poolId, slot, 10_000);
        reward.mint(alice, 100 ether);
        vm.startPrank(alice);
        reward.approve(address(diamond), 100 ether);
        rangeGauge.fundPoolReward(poolId, slot, 100 ether, 0, 10_000);
        vm.stopPrank();

        vm.warp(block.timestamp + 90 days);
        uint8[] memory slots = new uint8[](1);
        slots[0] = slot;
        uint256[] memory minimums = new uint256[](1);
        vm.prank(alice);
        uint256[] memory claimed = incentives.claimGaugeAllocatorRewards(positionId, poolId, slots, minimums, alice);
        assertApproxEqAbs(claimed[0], 100 ether, 2);
        assertApproxEqAbs(reward.balanceOf(alice), 100 ether, 2);
    }

    function testGaugeStopTerminatesAllocatorStreamAtTheStopTimestamp() public {
        PoolId poolId = _createRangeGaugePool(alice);
        uint256 positionId = _createStakedPosition(alice, 100 ether);
        _setAllocation(alice, positionId, poolId, 100 ether);
        MockERC20 reward = new MockERC20("Reward", "RWD", 18);
        uint8 slot = _ensureOrdinaryRewardSlot(poolId, address(reward));
        vm.prank(alice);
        rangeGauge.setPoolRewardAllocatorShare(poolId, slot, 10_000);
        reward.mint(alice, 100 ether);
        vm.startPrank(alice);
        reward.approve(address(diamond), 100 ether);
        rangeGauge.fundPoolReward(poolId, slot, 100 ether, 0, 10_000);
        vm.stopPrank();

        uint256 treasuryBefore = globalRewards.treasuryAccrued(address(reward));
        IStaticsProtocolPools(address(diamond)).beginGeneralPoolDecommission(poolId);

        assertTrue(rangeGauge.gaugePool(poolId).stopped);
        IStaticsGaugeIncentives.PoolWeightView memory weight = incentives.gaugePoolWeight(poolId);
        assertEq(weight.currentVersion, bytes32(0));
        assertEq(weight.weight, 0);

        IStaticsGaugeIncentives.AllocatorRewardView memory stream = incentives.gaugeAllocatorReward(poolId, slot);
        assertTrue(stream.terminated);
        assertEq(stream.periodBudget, 0);
        assertEq(stream.periodEmitted, 0);
        assertEq(globalRewards.treasuryAccrued(address(reward)) - treasuryBefore, 100 ether);
    }

    function testRestrictionStopsFutureAllocatorAccrualAndPreservesEarnedClaim() public {
        PoolId poolId = _createRangeGaugePool(alice);
        uint256 positionId = _createStakedPosition(alice, 100 ether);
        _setAllocation(alice, positionId, poolId, 100 ether);

        MockERC20 reward = new MockERC20("Reward", "RWD", 18);
        uint8 slot = _ensureOrdinaryRewardSlot(poolId, address(reward));
        vm.prank(alice);
        rangeGauge.setPoolRewardAllocatorShare(poolId, slot, 10_000);
        reward.mint(alice, 100 ether);
        vm.startPrank(alice);
        reward.approve(address(diamond), 100 ether);
        rangeGauge.fundPoolReward(poolId, slot, 100 ether, 0, 10_000);
        vm.stopPrank();

        vm.warp(block.timestamp + 3.5 days);
        IStaticsRewardPolicy(address(diamond)).addRewardRestriction(address(assetA));
        vm.warp(block.timestamp + 7 days);

        uint8[] memory slots = new uint8[](1);
        slots[0] = slot;
        uint256[] memory minimums = new uint256[](1);
        vm.prank(alice);
        uint256[] memory claimed = incentives.claimGaugeAllocatorRewards(positionId, poolId, slots, minimums, alice);
        assertApproxEqAbs(claimed[0], 50 ether, 2);
        assertApproxEqAbs(reward.balanceOf(alice), 50 ether, 2);
        assertApproxEqAbs(
            custody.reservedByAccount(keccak256("statics.custody.account.fees"), address(reward)), 50 ether, 2
        );
    }

    function testRestrictedPoolPreviewMatchesCreditableRewardAtCutoff() public {
        PoolId poolId = _createRangeGaugePool(alice);
        uint256 positionId = _createStakedPosition(alice, 100 ether);
        _provide(positionId, poolId, alice);
        _setAllocation(alice, positionId, poolId, 100 ether);
        _fundReserve(alice, 1_000 ether);
        incentives.activateGaugeSchedule();

        vm.warp(block.timestamp + 1 days);
        IStaticsRewardPolicy(address(diamond)).addRewardRestriction(address(assetA));
        vm.warp(block.timestamp + 1 days);
        incentives.checkpointGaugeSchedule(1);

        IStaticsGaugeIncentives.PoolWeightView memory weight = incentives.gaugePoolWeight(poolId);
        (uint256 preview, bool eligible) = incentives.previewGaugePoolReward(poolId);
        assertTrue(weight.stale);
        assertFalse(eligible);
        assertEq(weight.pendingReward, preview);

        (uint256 credited, uint256 recycled) = incentives.checkpointGaugePool(poolId);
        assertEq(preview, credited);
        assertGt(recycled, 0);
    }

    function testEligiblePoolPreviewMatchesCreditableReward() public {
        PoolId poolId = _createRangeGaugePool(alice);
        uint256 positionId = _createStakedPosition(alice, 100 ether);
        _provide(positionId, poolId, alice);
        _setAllocation(alice, positionId, poolId, 100 ether);
        _fundReserve(alice, 1_000 ether);
        incentives.activateGaugeSchedule();

        vm.warp(block.timestamp + 1 days);
        incentives.checkpointGaugeSchedule(1);

        IStaticsGaugeIncentives.PoolWeightView memory weight = incentives.gaugePoolWeight(poolId);
        (uint256 preview, bool eligible) = incentives.previewGaugePoolReward(poolId);
        assertFalse(weight.stale);
        assertTrue(eligible);
        assertEq(weight.pendingReward, preview);

        (uint256 credited, uint256 recycled) = incentives.checkpointGaugePool(poolId);
        assertEq(preview, credited);
        assertEq(recycled, 0);
    }

    function testRestrictionGenerationCannotClaimLaterCreatorFunding() public {
        PoolId poolId = _createRangeGaugePool(alice);
        uint256 alicePosition = _createStakedPosition(alice, 100 ether);
        uint256 bobPosition = _createStakedPosition(bob, 100 ether);
        _setAllocation(alice, alicePosition, poolId, 100 ether);
        MockERC20 reward = new MockERC20("Reward", "RWD", 18);
        uint8 slot = _ensureOrdinaryRewardSlot(poolId, address(reward));
        vm.prank(alice);
        rangeGauge.setPoolRewardAllocatorShare(poolId, slot, 10_000);
        _fundAllocatorReward(poolId, reward, 100 ether);

        vm.warp(block.timestamp + 3.5 days);
        IStaticsRewardPolicy(address(diamond)).addRewardRestriction(address(assetA));
        IStaticsRewardPolicy(address(diamond)).removeRewardRestriction(address(assetA));
        _fundAllocatorReward(poolId, reward, 100 ether);
        _setAllocation(bob, bobPosition, poolId, 100 ether);

        vm.warp(block.timestamp + 7 days);
        uint256 aliceClaim = _claimAllocator(alice, alicePosition, poolId, slot);
        uint256 bobClaim = _claimAllocator(bob, bobPosition, poolId, slot);
        assertApproxEqAbs(aliceClaim, 50 ether, 2);
        assertApproxEqAbs(bobClaim, 100 ether, 2);
        assertApproxEqAbs(aliceClaim + bobClaim, 150 ether, 3);
    }

    function testAllocationBeforeGenerationFundingStartsAtCurrentIndex() public {
        PoolId poolId = _createRangeGaugePool(alice);
        uint256 alicePosition = _createStakedPosition(alice, 100 ether);
        uint256 bobPosition = _createStakedPosition(bob, 100 ether);
        _setAllocation(alice, alicePosition, poolId, 100 ether);
        MockERC20 reward = new MockERC20("Reward", "RWD", 18);
        uint8 slot = _ensureOrdinaryRewardSlot(poolId, address(reward));
        vm.prank(alice);
        rangeGauge.setPoolRewardAllocatorShare(poolId, slot, 10_000);
        _fundAllocatorReward(poolId, reward, 100 ether);

        vm.warp(block.timestamp + 3.5 days);
        IStaticsRewardPolicy(address(diamond)).addRewardRestriction(address(assetA));
        IStaticsRewardPolicy(address(diamond)).removeRewardRestriction(address(assetA));
        _setAllocation(bob, bobPosition, poolId, 100 ether);
        _fundAllocatorReward(poolId, reward, 100 ether);

        vm.warp(block.timestamp + 7 days);
        uint256 aliceClaim = _claimAllocator(alice, alicePosition, poolId, slot);
        uint256 bobClaim = _claimAllocator(bob, bobPosition, poolId, slot);
        assertApproxEqAbs(aliceClaim, 50 ether, 2);
        assertApproxEqAbs(bobClaim, 100 ether, 2);
        assertApproxEqAbs(aliceClaim + bobClaim, 150 ether, 3);
    }

    function testUnresolvedAllocatorRewardBlocksCloseUntilExplicitForfeit() public {
        PoolId poolId = _createRangeGaugePool(alice);
        uint256 positionId = _createStakedPosition(alice, 100 ether);
        _setAllocation(alice, positionId, poolId, 100 ether);
        MockERC20 reward = new MockERC20("Reward", "RWD", 18);
        uint8 slot = _ensureOrdinaryRewardSlot(poolId, address(reward));
        vm.prank(alice);
        rangeGauge.setPoolRewardAllocatorShare(poolId, slot, 10_000);
        _fundAllocatorReward(poolId, reward, 100 ether);
        vm.warp(block.timestamp + 3.5 days);

        _clearAllocations(alice, positionId);
        vm.prank(alice);
        globalRewards.unstake(positionId, 100 ether, alice);
        vm.prank(alice);
        vm.expectPartialRevert(PositionNFTFacet.PositionHasActiveLegs.selector);
        IStaticsPosition(address(diamond)).closePosition(positionId);

        uint256 treasuryBefore = globalRewards.treasuryAccrued(address(reward));
        vm.prank(alice);
        uint256 forfeited = incentives.forfeitGaugeAllocatorReward(positionId, poolId, slot);
        assertApproxEqAbs(forfeited, 50 ether, 2);
        assertApproxEqAbs(globalRewards.treasuryAccrued(address(reward)) - treasuryBefore, forfeited, 1);
        vm.prank(alice);
        IStaticsPosition(address(diamond)).closePosition(positionId);
    }

    function testClaimedAllocatorRewardReleasesPositionLegAfterDeallocation() public {
        PoolId poolId = _createRangeGaugePool(alice);
        uint256 positionId = _createStakedPosition(alice, 100 ether);
        _setAllocation(alice, positionId, poolId, 100 ether);
        MockERC20 reward = new MockERC20("Reward", "RWD", 18);
        uint8 slot = _ensureOrdinaryRewardSlot(poolId, address(reward));
        vm.prank(alice);
        rangeGauge.setPoolRewardAllocatorShare(poolId, slot, 10_000);
        _fundAllocatorReward(poolId, reward, 100 ether);
        vm.warp(block.timestamp + 7 days);

        _clearAllocations(alice, positionId);
        vm.prank(bob);
        (PoolId[] memory unresolvedPools, uint256 nextCursor) =
            incentives.positionGaugeAllocatorPools(positionId, 0, 100);
        assertEq(unresolvedPools.length, 1);
        assertEq(PoolId.unwrap(unresolvedPools[0]), PoolId.unwrap(poolId));
        assertEq(nextCursor, 1);
        assertApproxEqAbs(_claimAllocator(alice, positionId, poolId, slot), 100 ether, 2);
        (PoolId[] memory resolvedPools, uint256 resolvedCursor) =
            incentives.positionGaugeAllocatorPools(positionId, 0, 100);
        assertEq(resolvedPools.length, 0);
        assertEq(resolvedCursor, 0);
        vm.prank(alice);
        globalRewards.unstake(positionId, 100 ether, alice);
        vm.prank(alice);
        IStaticsPosition(address(diamond)).closePosition(positionId);
    }

    function testAllocatorIndexCarryNormalizesAfterWeightReduction() public {
        PoolId poolId = _createRangeGaugePool(alice);
        uint256 positionId = _createStakedPosition(alice, 100);
        _setAllocation(alice, positionId, poolId, 100);
        MockERC20 reward = new MockERC20("Reward", "RWD", 18);
        uint8 slot = _ensureOrdinaryRewardSlot(poolId, address(reward));
        vm.prank(alice);
        rangeGauge.setPoolRewardAllocatorShare(poolId, slot, 10_000);
        _fundAllocatorReward(poolId, reward, 1);

        vm.warp(block.timestamp + 7 days);
        _setAllocation(alice, positionId, poolId, 1);
        assertEq(rangeGaugeState.allocatorIndexRemainder(poolId, slot), uint256(1 << 160) % 100);
        _fundAllocatorReward(poolId, reward, 1);
        vm.warp(block.timestamp + 7 days);
        incentives.checkpointGaugePool(poolId);
        assertEq(rangeGaugeState.allocatorIndexRemainder(poolId, slot), 0);
    }

    function testFinalAllocatorForfeitReconcilesGlobalAndPositionCarry() public {
        PoolId poolId = _createRangeGaugePool(alice);
        uint256 positionId = _createStakedPosition(alice, 100);
        _setAllocation(alice, positionId, poolId, 100);
        MockERC20 reward = new MockERC20("Reward", "RWD", 0);
        uint8 slot = _ensureOrdinaryRewardSlot(poolId, address(reward));
        vm.prank(alice);
        rangeGauge.setPoolRewardAllocatorShare(poolId, slot, 10_000);
        _fundAllocatorReward(poolId, reward, 1);

        vm.warp(block.timestamp + 7 days);
        _clearAllocations(alice, positionId);
        vm.prank(alice);
        uint256 forfeited = incentives.forfeitGaugeAllocatorReward(positionId, poolId, slot);
        assertEq(forfeited, 1);
        IStaticsGaugeIncentives.AllocatorRewardView memory stream = incentives.gaugeAllocatorReward(poolId, slot);
        assertEq(stream.indexedLiability, 0);
        assertEq(stream.claimLiability, 0);
        assertEq(custody.reservedByAccount(LibGaugeBribes.account(poolId, slot), address(reward)), 0);

        vm.prank(alice);
        globalRewards.unstake(positionId, 100, alice);
        vm.prank(alice);
        IStaticsPosition(address(diamond)).closePosition(positionId);
    }

    function testStaggeredForfeitAndReallocationPreserveCarry() public {
        PoolId poolId = _createRangeGaugePool(alice);
        uint256 alicePosition = _createStakedPosition(alice, 50);
        uint256 bobPosition = _createStakedPosition(bob, 50);
        _setAllocation(alice, alicePosition, poolId, 50);
        _setAllocation(bob, bobPosition, poolId, 50);
        MockERC20 reward = new MockERC20("Reward", "RWD", 0);
        uint8 slot = _ensureOrdinaryRewardSlot(poolId, address(reward));
        vm.prank(alice);
        rangeGauge.setPoolRewardAllocatorShare(poolId, slot, 10_000);
        _fundAllocatorReward(poolId, reward, 1);

        vm.warp(block.timestamp + 7 days);
        _clearAllocations(alice, alicePosition);
        vm.prank(alice);
        assertEq(incentives.forfeitGaugeAllocatorReward(alicePosition, poolId, slot), 0);
        _clearAllocations(bob, bobPosition);
        vm.prank(bob);
        assertEq(incentives.forfeitGaugeAllocatorReward(bobPosition, poolId, slot), 1);

        vm.warp(block.timestamp + 4 hours);
        _setAllocation(alice, alicePosition, poolId, 50);
        _fundAllocatorReward(poolId, reward, 1);
        vm.warp(block.timestamp + 7 days);
        _clearAllocations(alice, alicePosition);
        vm.prank(alice);
        assertEq(incentives.forfeitGaugeAllocatorReward(alicePosition, poolId, slot), 1);

        IStaticsGaugeIncentives.AllocatorRewardView memory stream = incentives.gaugeAllocatorReward(poolId, slot);
        assertEq(stream.indexedLiability, 0);
        assertEq(stream.claimLiability, 0);
        assertEq(custody.reservedByAccount(LibGaugeBribes.account(poolId, slot), address(reward)), 0);
        assertEq(globalRewards.treasuryAccrued(address(reward)), 2);
    }

    function testProtocolReserveNeverFundsAllocatorCustody() public {
        PoolId poolId = _createRangeGaugePool(alice);
        uint256 positionId = _createStakedPosition(alice, 100 ether);
        _provide(positionId, poolId, alice);
        _setAllocation(alice, positionId, poolId, 100 ether);
        _fundReserve(alice, 1_000 ether);
        incentives.activateGaugeSchedule();
        vm.warp(block.timestamp + 1 days);
        incentives.checkpointGaugePool(poolId);

        (bytes32 rewardAccount,) = rangeGauge.poolRewardCustodyAccount(poolId, 0);
        assertGt(custody.reservedByAccount(rewardAccount, address(stakingAsset)), 0);
        for (uint8 slot = 1; slot < 5; ++slot) {
            bytes32 allocatorAccount = keccak256(
                abi.encode(keccak256("statics.custody.account.gauge.bribes.v1"), PoolId.unwrap(poolId), slot)
            );
            assertEq(custody.reservedByAccount(allocatorAccount, address(stakingAsset)), 0);
        }
    }

    function testAllocationValidation() public {
        PoolId poolId = _createRangeGaugePool(alice);
        uint256 positionId = _createStakedPosition(alice, 100 ether);
        PoolId[] memory pools = new PoolId[](1);
        pools[0] = poolId;
        uint256[] memory amounts = new uint256[](0);
        vm.startPrank(alice);
        vm.expectRevert(IStaticsGaugeIncentives.GaugeAllocationLengthMismatch.selector);
        incentives.setGaugeAllocations(positionId, pools, amounts);
        amounts = new uint256[](1);
        amounts[0] = 101 ether;
        vm.expectRevert(
            abi.encodeWithSelector(
                IStaticsGaugeIncentives.GaugeAllocationExceedsStake.selector, uint256(101 ether), uint256(100 ether)
            )
        );
        incentives.setGaugeAllocations(positionId, pools, amounts);
        vm.stopPrank();
    }

    function _createStakedPosition(address owner, uint256 amount) private returns (uint256 positionId) {
        positionId = _createCoolingStakedPosition(owner, amount);
        vm.prank(owner);
        (uint40 nextAllocationAt,,,) = incentives.gaugePositionAllocations(positionId);
        if (block.timestamp < nextAllocationAt) vm.warp(nextAllocationAt);
    }

    function _createCoolingStakedPosition(address owner, uint256 amount) private returns (uint256 positionId) {
        stakingAsset.mint(owner, amount);
        vm.startPrank(owner);
        stakingAsset.approve(address(diamond), amount);
        positionId = globalRewards.createAndStake(amount, owner, new address[](0));
        vm.stopPrank();
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

    function _fundAllocatorReward(PoolId poolId, MockERC20 reward, uint256 amount) private {
        uint8 slot = _ensureOrdinaryRewardSlot(poolId, address(reward));
        reward.mint(alice, amount);
        vm.startPrank(alice);
        reward.approve(address(diamond), amount);
        rangeGauge.fundPoolReward(poolId, slot, amount, 0, 10_000);
        vm.stopPrank();
    }

    function _claimAllocator(address owner, uint256 positionId, PoolId poolId, uint8 slot)
        private
        returns (uint256 amount)
    {
        uint8[] memory slots = new uint8[](1);
        slots[0] = slot;
        uint256[] memory minimums = new uint256[](1);
        vm.prank(owner);
        uint256[] memory claimed = incentives.claimGaugeAllocatorRewards(positionId, poolId, slots, minimums, owner);
        amount = claimed[0];
    }

    function _clearAllocations(address owner, uint256 positionId) private {
        vm.prank(owner);
        incentives.setGaugeAllocations(positionId, new PoolId[](0), new uint256[](0));
    }

    function _assertCooldownExtended(Vm.Log[] memory logs, uint256 positionId, uint40 nextAllocationAt) private view {
        uint256 matches;
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory entry = logs[i];
            if (
                entry.emitter != address(diamond) || entry.topics.length != 3
                    || entry.topics[0] != COOLDOWN_EXTENDED_TOPIC
            ) {
                continue;
            }
            ++matches;
            assertEq(uint256(entry.topics[1]), positionId);
            assertEq(uint256(entry.topics[2]), nextAllocationAt);
            assertEq(entry.data.length, 0);
        }
        assertEq(matches, 1);
    }

    function _incentiveActionSelectors() private pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](8);
        selectors[0] = GaugeIncentiveFacet.fundGaugeReserve.selector;
        selectors[1] = GaugeIncentiveFacet.activateGaugeSchedule.selector;
        selectors[2] = GaugeIncentiveFacet.setGaugeAllocations.selector;
        selectors[3] = GaugeIncentiveFacet.checkpointGaugeSchedule.selector;
        selectors[4] = GaugeIncentiveFacet.scheduleGaugeReleaseBps.selector;
        selectors[5] = GaugeIncentiveFacet.setGaugeAllocationCooldown.selector;
        selectors[6] = GaugeIncentiveFacet.claimGaugeAllocatorRewards.selector;
        selectors[7] = GaugeIncentiveFacet.forfeitGaugeAllocatorReward.selector;
    }

    function _incentiveViewSelectors() private pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](13);
        selectors[0] = GaugeIncentiveViewFacet.currentGaugePeriod.selector;
        selectors[1] = GaugeIncentiveViewFacet.gaugePeriodAt.selector;
        selectors[2] = GaugeIncentiveViewFacet.gaugeReserve.selector;
        selectors[3] = GaugeIncentiveViewFacet.gaugePoolWeight.selector;
        selectors[4] = GaugeIncentiveViewFacet.gaugePositionAllocations.selector;
        selectors[5] = GaugeIncentiveViewFacet.previewGaugePoolReward.selector;
        selectors[6] = GaugeIncentiveViewFacet.maxGaugeAllocationsPerPosition.selector;
        selectors[7] = GaugeIncentiveViewFacet.maxWeeklyGaugeReleaseBps.selector;
        selectors[8] = GaugeIncentiveViewFacet.maxGaugeCatchupPeriods.selector;
        selectors[9] = GaugeIncentiveViewFacet.gaugeAllocationCooldown.selector;
        selectors[10] = GaugeIncentiveViewFacet.gaugeAllocatorReward.selector;
        selectors[11] = GaugeIncentiveViewFacet.previewGaugeAllocatorRewards.selector;
        selectors[12] = GaugeIncentiveViewFacet.positionGaugeAllocatorPools.selector;
    }
}
