// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IStaticsRangeGauge} from "../../src/interfaces/IStaticsRangeGauge.sol";
import {IStaticsRewardPolicy} from "../../src/interfaces/IStaticsRewardPolicy.sol";
import {MockERC20, MockFeeOnTransferERC20, MockReentrantERC20, MockSenderExtraFeeERC20} from "../mocks/MockERC20.sol";
import {RangeGaugeFeatureTestBase} from "../helpers/RangeGaugeFeatureTestBase.sol";

contract RangeGaugeFundingTest is RangeGaugeFeatureTestBase {
    uint256 private constant RAY = 1e27;
    uint256 private constant START = 1_000_000;
    uint256 private constant DURATION = 7 days;
    uint256 private constant PAUSE_LIQUIDITY = 1 << 5;

    function testFundingUsesActualReceivedAndReservesExactlyThatAmount() public {
        PoolId poolId = _createRangeGaugePool(alice);
        rangeGaugeState.setActiveGaugeLiquidity(poolId, 100);
        MockFeeOnTransferERC20 reward = new MockFeeOnTransferERC20();
        _appendReward(poolId, address(reward));
        reward.mint(bob, 100 ether);
        vm.prank(bob);
        reward.approve(address(diamond), type(uint256).max);
        vm.warp(START);

        vm.prank(bob);
        uint256 received = rangeGauge.fundPoolReward(poolId, address(reward), 100 ether, uint40(DURATION));

        assertEq(received, 99 ether);
        IStaticsRangeGauge.GaugeRewardStreamView memory stream = rangeGauge.poolRewardStream(poolId, address(reward));
        assertEq(stream.periodBudget, 99 ether);
        assertEq(stream.periodStart, START);
        assertEq(stream.periodFinish, START + DURATION);
        (bytes32 account, bool assigned) = rangeGauge.poolRewardCustodyAccount(poolId, address(reward));
        assertTrue(assigned);
        assertEq(custody.reservedByAccount(account, address(reward)), 99 ether);
        assertEq(custody.globalReservedByToken(address(reward)), 99 ether);
        assertEq(reward.balanceOf(address(diamond)), 99 ether);
    }

    function testFundingRejectsSenderExtraFeeAboveRequestedMaximum() public {
        PoolId poolId = _createRangeGaugePool(alice);
        MockSenderExtraFeeERC20 reward = new MockSenderExtraFeeERC20();
        _appendReward(poolId, address(reward));
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
        rangeGauge.fundPoolReward(poolId, address(reward), 100 ether, 0);

        assertEq(reward.balanceOf(bob), 101 ether);
        assertEq(reward.balanceOf(address(diamond)), 0);
        assertEq(rangeGauge.poolRewardStream(poolId, address(reward)).periodBudget, 0);
        (bytes32 account,) = rangeGauge.poolRewardCustodyAccount(poolId, address(reward));
        assertEq(custody.reservedByAccount(account, address(reward)), 0);
        assertEq(custody.globalReservedByToken(address(reward)), 0);
    }

    function testFundingCapacityRejectionRollsBackTransferAndReservation() public {
        PoolId poolId = _createRangeGaugePool(alice);
        MockERC20 reward = new MockERC20("Capacity Reward", "CAP", 18);
        _appendReward(poolId, address(reward));
        uint256 maximumBudget = type(uint256).max / RAY;
        reward.mint(bob, maximumBudget + 1);
        vm.prank(bob);
        reward.approve(address(diamond), type(uint256).max);
        vm.warp(START);

        vm.prank(bob);
        rangeGauge.fundPoolReward(poolId, address(reward), maximumBudget, 0);
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(
                IStaticsRangeGauge.RewardBudgetExceedsIndexCapacity.selector, maximumBudget, uint256(1), maximumBudget
            )
        );
        rangeGauge.fundPoolReward(poolId, address(reward), 1, 0);

        (bytes32 account,) = rangeGauge.poolRewardCustodyAccount(poolId, address(reward));
        assertEq(reward.balanceOf(bob), 1);
        assertEq(reward.balanceOf(address(diamond)), maximumBudget);
        assertEq(custody.reservedByAccount(account, address(reward)), maximumBudget);
        assertEq(custody.globalReservedByToken(address(reward)), maximumBudget);
        IStaticsRangeGauge.GaugeRewardStreamView memory stream = rangeGauge.poolRewardStream(poolId, address(reward));
        assertEq(stream.periodBudget, maximumBudget);
        assertEq(stream.indexCapacityUsed, maximumBudget);
    }

    function testMinimumRemainingDurationRejectsNearExpiryDustCompression() public {
        PoolId poolId = _createRangeGaugePool(alice);
        rangeGaugeState.setActiveGaugeLiquidity(poolId, 100);
        stakingAsset.mint(alice, 1);
        vm.prank(alice);
        stakingAsset.approve(address(diamond), type(uint256).max);
        vm.warp(START);
        vm.prank(alice);
        rangeGauge.fundPoolReward(poolId, address(stakingAsset), 1, uint40(DURATION));

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
        rangeGauge.fundPoolReward(poolId, address(stakingAsset), 700 ether, uint40(1 days));

        assertEq(stakingAsset.balanceOf(bob), bobBefore);
        IStaticsRangeGauge.GaugeRewardStreamView memory unchanged =
            rangeGauge.poolRewardStream(poolId, address(stakingAsset));
        assertEq(unchanged.lastUpdate, START);
        assertEq(unchanged.periodBudget, 1);

        vm.prank(bob);
        assertEq(rangeGauge.fundPoolReward(poolId, address(stakingAsset), 700 ether, 0), 700 ether);
        IStaticsRangeGauge.GaugeRewardStreamView memory compressed =
            rangeGauge.poolRewardStream(poolId, address(stakingAsset));
        assertEq(compressed.periodFinish, START + DURATION);
        assertEq(compressed.periodBudget, 700 ether + 1);
    }

    function testTopUpSynchronizesFirstAndPreservesFinish() public {
        PoolId poolId = _createRangeGaugePool(alice);
        rangeGaugeState.setActiveGaugeLiquidity(poolId, 100);
        stakingAsset.mint(bob, 1_000 ether);
        vm.prank(bob);
        stakingAsset.approve(address(diamond), type(uint256).max);
        vm.warp(START);
        vm.prank(bob);
        rangeGauge.fundPoolReward(poolId, address(stakingAsset), 700 ether, uint40(DURATION));

        vm.warp(START + DURATION / 2);
        vm.prank(bob);
        rangeGauge.fundPoolReward(poolId, address(stakingAsset), 300 ether, uint40(DURATION / 2));

        IStaticsRangeGauge.GaugeRewardStreamView memory stream =
            rangeGauge.poolRewardStream(poolId, address(stakingAsset));
        assertEq(stream.periodStart, START + DURATION / 2);
        assertEq(stream.periodFinish, START + DURATION);
        assertEq(stream.periodBudget, 650 ether);
        assertEq(stream.periodEmitted, 0);
        assertEq(stream.indexedLiability, 350 ether);
        (bytes32 account,) = rangeGauge.poolRewardCustodyAccount(poolId, address(stakingAsset));
        assertEq(custody.reservedByAccount(account, address(stakingAsset)), 1_000 ether);
    }

    function testDisabledRestrictedAndUnassignedAssetsCannotCreateFundingLiability() public {
        PoolId poolId = _createRangeGaugePool(alice);
        MockERC20 assigned = new MockERC20("Assigned", "ASG", 18);
        MockERC20 unassigned = new MockERC20("Unassigned", "UNA", 18);
        _appendReward(poolId, address(assigned));
        rangeGauge.setGaugeRewardAssetAllowed(address(unassigned), true);
        assigned.mint(bob, 10 ether);
        unassigned.mint(bob, 10 ether);
        vm.startPrank(bob);
        assigned.approve(address(diamond), type(uint256).max);
        unassigned.approve(address(diamond), type(uint256).max);
        vm.expectRevert(
            abi.encodeWithSelector(IStaticsRangeGauge.GaugeRewardAssetNotAssigned.selector, poolId, address(unassigned))
        );
        rangeGauge.fundPoolReward(poolId, address(unassigned), 1 ether, 0);
        vm.stopPrank();

        rangeGauge.setGaugeRewardAssetAllowed(address(assigned), false);
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(IStaticsRangeGauge.GaugeRewardAssetNotAllowed.selector, address(assigned))
        );
        rangeGauge.fundPoolReward(poolId, address(assigned), 1 ether, 0);

        rangeGauge.setGaugeRewardAssetAllowed(address(assigned), true);
        vm.prank(guardian);
        IStaticsRewardPolicy(address(diamond)).addRewardRestriction(address(assigned));
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(IStaticsRangeGauge.GaugeRewardAssetRestricted.selector, address(assigned))
        );
        rangeGauge.fundPoolReward(poolId, address(assigned), 1 ether, 0);
    }

    function testLiquidityPauseBlocksFundingWithoutBlockingViews() public {
        PoolId poolId = _createRangeGaugePool(alice);
        stakingAsset.mint(bob, 10 ether);
        vm.prank(bob);
        stakingAsset.approve(address(diamond), type(uint256).max);
        vm.prank(guardian);
        governance.pause(PAUSE_LIQUIDITY);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IStaticsRangeGauge.ActionPaused.selector, PAUSE_LIQUIDITY));
        rangeGauge.fundPoolReward(poolId, address(stakingAsset), 1 ether, 0);
        assertTrue(rangeGauge.poolRewardStream(poolId, address(stakingAsset)).assigned);
    }

    function testFundingRejectsTokenDrivenReentrancyButKeepsOuterContribution() public {
        PoolId poolId = _createRangeGaugePool(alice);
        MockReentrantERC20 reward = new MockReentrantERC20();
        _appendReward(poolId, address(reward));
        reward.mint(bob, 10 ether);
        vm.prank(bob);
        reward.approve(address(diamond), type(uint256).max);
        reward.setCallback(
            bob,
            address(diamond),
            abi.encodeCall(IStaticsRangeGauge.fundPoolReward, (poolId, address(reward), 1 ether, uint40(0)))
        );

        vm.prank(bob);
        assertEq(rangeGauge.fundPoolReward(poolId, address(reward), 10 ether, 0), 10 ether);
        assertFalse(reward.reentrySucceeded());
        assertEq(rangeGauge.poolRewardStream(poolId, address(reward)).periodBudget, 10 ether);
    }

    function _appendReward(PoolId poolId, address reward) private {
        rangeGauge.setGaugeRewardAssetAllowed(reward, true);
        vm.prank(alice);
        rangeGauge.appendPoolRewardAsset(poolId, reward);
    }
}
