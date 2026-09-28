// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IStaticsRangeGauge} from "../../src/interfaces/IStaticsRangeGauge.sol";
import {IStaticsRewardPolicy} from "../../src/interfaces/IStaticsRewardPolicy.sol";
import {LibGaugeBribes} from "../../src/libraries/LibGaugeBribes.sol";
import {LibGaugeEpoch} from "../../src/libraries/LibGaugeEpoch.sol";
import {MockERC20, MockFeeOnTransferERC20, MockReentrantERC20, MockSenderExtraFeeERC20} from "../mocks/MockERC20.sol";
import {RangeGaugeFeatureTestBase} from "../helpers/RangeGaugeFeatureTestBase.sol";

contract RangeGaugeFundingTest is RangeGaugeFeatureTestBase {
    uint256 private constant INDEX_SCALE = 1 << 160;
    uint256 private constant START = 1_000_000;
    uint256 private constant DURATION = 7 days;
    uint256 private constant PAUSE_LIQUIDITY = 1 << 5;

    function testFundingUsesActualReceivedAndReservesExactlyThatAmount() public {
        PoolId poolId = _createRangeGaugePool(alice);
        rangeGaugeState.setActiveGaugeLiquidity(poolId, 100);
        MockFeeOnTransferERC20 reward = new MockFeeOnTransferERC20();
        uint8 slot = _appendReward(poolId, address(reward));
        reward.mint(bob, 100 ether);
        vm.prank(bob);
        reward.approve(address(diamond), type(uint256).max);
        vm.warp(START);

        vm.prank(bob);
        uint256 received = rangeGauge.fundPoolReward(poolId, slot, 100 ether, uint40(DURATION), 0, 0);

        assertEq(received, 99 ether);
        IStaticsRangeGauge.GaugeRewardStreamView memory stream = rangeGauge.poolRewardStream(poolId, slot);
        assertEq(stream.periodBudget, 99 ether);
        assertEq(stream.periodStart, START);
        assertEq(stream.periodFinish, START + DURATION);
        (bytes32 account, bool assigned) = rangeGauge.poolRewardCustodyAccount(poolId, slot);
        assertTrue(assigned);
        assertEq(custody.reservedByAccount(account, address(reward)), 99 ether);
        assertEq(custody.globalReservedByToken(address(reward)), 99 ether);
        assertEq(reward.balanceOf(address(diamond)), 99 ether);
    }

    function testCreatorSetsAllocatorShareAndFundingSplitsActualReceived() public {
        PoolId poolId = _createRangeGaugePool(alice);
        rangeGaugeState.setActiveGaugeLiquidity(poolId, 100);
        MockFeeOnTransferERC20 reward = new MockFeeOnTransferERC20();
        uint8 slot = _appendReward(poolId, address(reward));
        vm.prank(alice);
        rangeGauge.setPoolRewardAllocatorShare(poolId, slot, 2_500);
        assertEq(rangeGauge.poolRewardConfig(poolId).allocatorShareBps[slot], 2_500);

        reward.mint(bob, 100 ether);
        vm.prank(bob);
        reward.approve(address(diamond), type(uint256).max);
        vm.warp(START);
        uint64 targetEpoch = LibGaugeEpoch.epochAt(START) + 1;
        vm.prank(bob);
        uint256 received = rangeGauge.fundPoolReward(poolId, slot, 100 ether, uint40(DURATION), 2_500, targetEpoch);

        assertEq(received, 99 ether);
        assertEq(rangeGauge.poolRewardStream(poolId, slot).periodBudget, 74.25 ether);
        (bytes32 lpAccount,) = rangeGauge.poolRewardCustodyAccount(poolId, slot);
        assertEq(custody.reservedByAccount(lpAccount, address(reward)), 74.25 ether);
        assertEq(
            custody.reservedByAccount(LibGaugeBribes.account(poolId, slot, targetEpoch), address(reward)), 24.75 ether
        );
        assertEq(custody.globalReservedByToken(address(reward)), 99 ether);
    }

    function testFundingPinsAllocatorShareAndFullAllocationSkipsLpStream() public {
        PoolId poolId = _createRangeGaugePool(alice);
        uint8 slot = _appendReward(poolId, address(stakingAsset));
        vm.prank(alice);
        rangeGauge.setPoolRewardAllocatorShare(poolId, slot, 10_000);
        stakingAsset.mint(bob, 10 ether);
        vm.prank(bob);
        stakingAsset.approve(address(diamond), type(uint256).max);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IStaticsRangeGauge.AllocatorShareChanged.selector, 0, 10_000));
        rangeGauge.fundPoolReward(poolId, slot, 10 ether, uint40(30 days), 0, 0);

        vm.prank(bob);
        assertEq(
            rangeGauge.fundPoolReward(
                poolId, slot, 10 ether, uint40(30 days), 10_000, LibGaugeEpoch.epochAt(block.timestamp) + 1
            ),
            10 ether
        );
        assertEq(rangeGauge.poolRewardStream(poolId, slot).periodBudget, 0);
    }

    function testAllocatorFundingPinsTargetEpochAcrossBoundary() public {
        PoolId poolId = _createRangeGaugePool(alice);
        uint8 slot = _appendReward(poolId, address(stakingAsset));
        vm.prank(alice);
        rangeGauge.setPoolRewardAllocatorShare(poolId, slot, 5_000);
        stakingAsset.mint(bob, 10 ether);
        vm.prank(bob);
        stakingAsset.approve(address(diamond), 10 ether);
        uint64 expectedEpoch = LibGaugeEpoch.epochAt(block.timestamp) + 1;

        vm.warp(LibGaugeEpoch.epochStart(expectedEpoch));
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(IStaticsRangeGauge.AllocatorEpochChanged.selector, expectedEpoch, expectedEpoch + 1)
        );
        rangeGauge.fundPoolReward(poolId, slot, 10 ether, 0, 5_000, expectedEpoch);

        assertEq(stakingAsset.balanceOf(bob), 10 ether);
    }

    function testOnlyCreatorCanConfigureDirectSlotAllocatorShare() public {
        PoolId poolId = _createRangeGaugePool(alice);
        uint8 slot = _appendReward(poolId, address(stakingAsset));

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IStaticsRangeGauge.NotPoolCreator.selector, poolId, bob, alice));
        rangeGauge.setPoolRewardAllocatorShare(poolId, slot, 1);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IStaticsRangeGauge.InvalidAllocatorShareBps.selector, 10_001));
        rangeGauge.setPoolRewardAllocatorShare(poolId, slot, 10_001);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IStaticsRangeGauge.ProtocolRewardSlotReserved.selector, poolId));
        rangeGauge.setPoolRewardAllocatorShare(poolId, 0, 1);
    }

    function testDirectFundingCannotEnterProtocolSlotZero() public {
        PoolId poolId = _createRangeGaugePool(alice);
        stakingAsset.mint(bob, 1 ether);
        vm.prank(bob);
        stakingAsset.approve(address(diamond), 1 ether);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IStaticsRangeGauge.ProtocolRewardSlotReserved.selector, poolId));
        rangeGauge.fundPoolReward(poolId, 0, 1 ether, 0, 0, 0);

        assertEq(stakingAsset.balanceOf(bob), 1 ether);
        assertEq(rangeGauge.poolRewardStream(poolId, 0).periodBudget, 0);
    }

    function testFundingRejectsSenderExtraFeeAboveRequestedMaximum() public {
        PoolId poolId = _createRangeGaugePool(alice);
        MockSenderExtraFeeERC20 reward = new MockSenderExtraFeeERC20();
        uint8 slot = _appendReward(poolId, address(reward));
        reward.mint(bob, 101 ether);
        reward.setTaxedSender(bob);
        vm.prank(bob);
        reward.approve(address(diamond), type(uint256).max);

        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(
                IStaticsRangeGauge.InputDebitExceedsMaximum.selector, address(reward), 101 ether, 100 ether
            )
        );
        rangeGauge.fundPoolReward(poolId, slot, 100 ether, 0, 0, 0);

        assertEq(reward.balanceOf(bob), 101 ether);
        assertEq(reward.balanceOf(address(diamond)), 0);
        assertEq(rangeGauge.poolRewardStream(poolId, slot).periodBudget, 0);
        (bytes32 account,) = rangeGauge.poolRewardCustodyAccount(poolId, slot);
        assertEq(custody.reservedByAccount(account, address(reward)), 0);
        assertEq(custody.globalReservedByToken(address(reward)), 0);
    }

    function testFundingCapacityRejectionRollsBackTransferAndReservation() public {
        PoolId poolId = _createRangeGaugePool(alice);
        MockERC20 reward = new MockERC20("Capacity Reward", "CAP", 18);
        uint8 slot = _appendReward(poolId, address(reward));
        uint256 maximumBudget = type(uint256).max / INDEX_SCALE;
        reward.mint(bob, maximumBudget + 1);
        vm.prank(bob);
        reward.approve(address(diamond), type(uint256).max);
        vm.warp(START);

        vm.prank(bob);
        rangeGauge.fundPoolReward(poolId, slot, maximumBudget, 0, 0, 0);
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(
                IStaticsRangeGauge.RewardBudgetExceedsIndexCapacity.selector, maximumBudget, uint256(1), maximumBudget
            )
        );
        rangeGauge.fundPoolReward(poolId, slot, 1, 0, 0, 0);

        (bytes32 account,) = rangeGauge.poolRewardCustodyAccount(poolId, slot);
        assertEq(reward.balanceOf(bob), 1);
        assertEq(reward.balanceOf(address(diamond)), maximumBudget);
        assertEq(custody.reservedByAccount(account, address(reward)), maximumBudget);
        assertEq(custody.globalReservedByToken(address(reward)), maximumBudget);
        IStaticsRangeGauge.GaugeRewardStreamView memory stream = rangeGauge.poolRewardStream(poolId, slot);
        assertEq(stream.periodBudget, maximumBudget);
        assertEq(stream.indexCapacityUsed, maximumBudget);
    }

    function testMinimumRemainingDurationRejectsNearExpiryDustCompression() public {
        PoolId poolId = _createRangeGaugePool(alice);
        rangeGaugeState.setActiveGaugeLiquidity(poolId, 100);
        uint8 slot = _appendReward(poolId, address(stakingAsset));
        stakingAsset.mint(alice, 1);
        vm.prank(alice);
        stakingAsset.approve(address(diamond), type(uint256).max);
        vm.warp(START);
        vm.prank(alice);
        rangeGauge.fundPoolReward(poolId, slot, 1, uint40(DURATION), 0, 0);

        stakingAsset.mint(bob, 700 ether);
        vm.prank(bob);
        stakingAsset.approve(address(diamond), type(uint256).max);
        vm.warp(START + DURATION - 1 hours);
        uint256 bobBefore = stakingAsset.balanceOf(bob);
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(
                IStaticsRangeGauge.MinimumRemainingDurationNotMet.selector, uint40(1 hours), uint40(1 days)
            )
        );
        rangeGauge.fundPoolReward(poolId, slot, 700 ether, uint40(1 days), 0, 0);

        assertEq(stakingAsset.balanceOf(bob), bobBefore);
        IStaticsRangeGauge.GaugeRewardStreamView memory unchanged = rangeGauge.poolRewardStream(poolId, slot);
        assertEq(unchanged.lastUpdate, START);
        assertEq(unchanged.periodBudget, 1);

        vm.prank(bob);
        assertEq(rangeGauge.fundPoolReward(poolId, slot, 700 ether, 0, 0, 0), 700 ether);
        IStaticsRangeGauge.GaugeRewardStreamView memory compressed = rangeGauge.poolRewardStream(poolId, slot);
        assertEq(compressed.periodFinish, START + DURATION);
        assertEq(compressed.periodBudget, 700 ether + 1);
    }

    function testTopUpSynchronizesFirstAndPreservesFinish() public {
        PoolId poolId = _createRangeGaugePool(alice);
        rangeGaugeState.setActiveGaugeLiquidity(poolId, 100);
        uint8 slot = _appendReward(poolId, address(stakingAsset));
        stakingAsset.mint(bob, 1_000 ether);
        vm.prank(bob);
        stakingAsset.approve(address(diamond), type(uint256).max);
        vm.warp(START);
        vm.prank(bob);
        rangeGauge.fundPoolReward(poolId, slot, 700 ether, uint40(DURATION), 0, 0);

        vm.warp(START + DURATION / 2);
        vm.prank(bob);
        rangeGauge.fundPoolReward(poolId, slot, 300 ether, uint40(DURATION / 2), 0, 0);

        IStaticsRangeGauge.GaugeRewardStreamView memory stream = rangeGauge.poolRewardStream(poolId, slot);
        assertEq(stream.periodStart, START + DURATION / 2);
        assertEq(stream.periodFinish, START + DURATION);
        assertEq(stream.periodBudget, 650 ether);
        assertEq(stream.periodEmitted, 0);
        assertEq(stream.indexedLiability, 350 ether);
        (bytes32 account,) = rangeGauge.poolRewardCustodyAccount(poolId, slot);
        assertEq(custody.reservedByAccount(account, address(stakingAsset)), 1_000 ether);
    }

    function testDisabledRestrictedAndUnassignedAssetsCannotCreateFundingLiability() public {
        PoolId poolId = _createRangeGaugePool(alice);
        MockERC20 assigned = new MockERC20("Assigned", "ASG", 18);
        MockERC20 unassigned = new MockERC20("Unassigned", "UNA", 18);
        uint8 slot = _appendReward(poolId, address(assigned));
        rangeGauge.setGaugeRewardAssetAllowed(address(unassigned), true);
        assigned.mint(bob, 10 ether);
        unassigned.mint(bob, 10 ether);
        vm.startPrank(bob);
        assigned.approve(address(diamond), type(uint256).max);
        unassigned.approve(address(diamond), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(IStaticsRangeGauge.GaugeRewardSlotNotAssigned.selector, poolId, 2));
        rangeGauge.fundPoolReward(poolId, 2, 1 ether, 0, 0, 0);
        vm.stopPrank();

        rangeGauge.setGaugeRewardAssetAllowed(address(assigned), false);
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(IStaticsRangeGauge.GaugeRewardAssetNotAllowed.selector, address(assigned))
        );
        rangeGauge.fundPoolReward(poolId, slot, 1 ether, 0, 0, 0);

        rangeGauge.setGaugeRewardAssetAllowed(address(assigned), true);
        vm.prank(guardian);
        IStaticsRewardPolicy(address(diamond)).addRewardRestriction(address(assigned));
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(IStaticsRangeGauge.GaugeRewardAssetRestricted.selector, address(assigned))
        );
        rangeGauge.fundPoolReward(poolId, slot, 1 ether, 0, 0, 0);
    }

    function testLiquidityPauseBlocksFundingWithoutBlockingViews() public {
        PoolId poolId = _createRangeGaugePool(alice);
        uint8 slot = _appendReward(poolId, address(stakingAsset));
        stakingAsset.mint(bob, 10 ether);
        vm.prank(bob);
        stakingAsset.approve(address(diamond), type(uint256).max);
        vm.prank(guardian);
        governance.pause(PAUSE_LIQUIDITY);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IStaticsRangeGauge.ActionPaused.selector, PAUSE_LIQUIDITY));
        rangeGauge.fundPoolReward(poolId, slot, 1 ether, 0, 0, 0);
        assertTrue(rangeGauge.poolRewardStream(poolId, slot).assigned);
    }

    function testFundingRejectsTokenDrivenReentrancyButKeepsOuterContribution() public {
        PoolId poolId = _createRangeGaugePool(alice);
        MockReentrantERC20 reward = new MockReentrantERC20();
        uint8 slot = _appendReward(poolId, address(reward));
        reward.mint(bob, 10 ether);
        vm.prank(bob);
        reward.approve(address(diamond), type(uint256).max);
        reward.setCallback(
            bob,
            address(diamond),
            abi.encodeCall(IStaticsRangeGauge.fundPoolReward, (poolId, slot, 1 ether, uint40(0), uint16(0), uint64(0)))
        );

        vm.prank(bob);
        assertEq(rangeGauge.fundPoolReward(poolId, slot, 10 ether, 0, 0, 0), 10 ether);
        assertFalse(reward.reentrySucceeded());
        assertEq(rangeGauge.poolRewardStream(poolId, slot).periodBudget, 10 ether);
    }

    function _appendReward(PoolId poolId, address reward) private returns (uint8 slot) {
        rangeGauge.setGaugeRewardAssetAllowed(reward, true);
        vm.prank(alice);
        slot = rangeGauge.appendPoolRewardAsset(poolId, reward);
    }
}
