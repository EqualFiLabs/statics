// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IStaticsPosition} from "../../src/interfaces/IStaticsPosition.sol";
import {IStaticsRangeGauge} from "../../src/interfaces/IStaticsRangeGauge.sol";
import {MockERC20, MockFeeOnTransferERC20, MockReentrantERC20, MockRevertingERC20} from "../mocks/MockERC20.sol";
import {RangeGaugeLifecycleTestBase} from "../helpers/RangeGaugeLifecycleTestBase.sol";

contract RangeGaugeClaimsTest is RangeGaugeLifecycleTestBase {
    function testSubsetClaimSettlesEverySlotAndTransfersOnlyRequestedAsset() public {
        PoolId poolId = _createRangeGaugePool(alice);
        uint256 positionId = _createPosition(alice);
        _provide(positionId, poolId, alice);
        MockERC20 secondReward = new MockERC20("Second Reward", "SECOND", 18);
        _assignReward(poolId, address(secondReward));
        _fundReward(poolId, stakingAsset, 700 ether);
        _fundReward(poolId, secondReward, 350 ether);

        vm.warp(block.timestamp + 1 days);
        uint256 claimed = _claim(positionId, poolId, address(stakingAsset), 100 ether, alice, alice);
        assertEq(claimed, 100 ether);
        assertEq(stakingAsset.balanceOf(alice), 100 ether);
        assertEq(secondReward.balanceOf(alice), 0);
        IStaticsRangeGauge.LpLegView memory settled = rangeGauge.lpLeg(positionId, poolId);
        assertEq(settled.claimable[0], 0);
        assertEq(settled.claimable[1], 50 ether);
        assertEq(rangeGauge.poolRewardStream(poolId, address(stakingAsset)).claimLiability, 0);
        assertEq(rangeGauge.poolRewardStream(poolId, address(secondReward)).claimLiability, 50 ether);

        assertEq(_claim(positionId, poolId, address(secondReward), 50 ether, bob, alice), 50 ether);
        assertEq(secondReward.balanceOf(bob), 50 ether);
    }

    function testFeeOnTransferClaimUsesCallerMinimumAndActualReceived() public {
        PoolId poolId = _createRangeGaugePool(alice);
        uint256 positionId = _createPosition(alice);
        _provide(positionId, poolId, alice);
        MockFeeOnTransferERC20 taxed = new MockFeeOnTransferERC20();
        _assignReward(poolId, address(taxed));
        assertEq(_fundReward(poolId, taxed, 700 ether), 693 ether);
        vm.warp(block.timestamp + 1 days);

        address[] memory assets = new address[](1);
        assets[0] = address(taxed);
        uint256[] memory minimums = new uint256[](1);
        minimums[0] = 99 ether;
        vm.expectPartialRevert(IStaticsRangeGauge.RewardAmountBelowMinimum.selector);
        vm.prank(alice);
        rangeGauge.claimLpRewards(positionId, poolId, assets, minimums, bob);
        uint256 received = _claim(positionId, poolId, address(taxed), 98 ether, bob, alice);
        assertEq(received, 98.01 ether);
        assertEq(taxed.balanceOf(bob), received);
        assertEq(rangeGauge.poolRewardStream(poolId, address(taxed)).claimLiability, 0);
    }

    function testRewardTransferReentrancyCannotDoubleClaim() public {
        PoolId poolId = _createRangeGaugePool(alice);
        uint256 positionId = _createPosition(alice);
        _provide(positionId, poolId, alice);
        MockReentrantERC20 reward = new MockReentrantERC20();
        _assignReward(poolId, address(reward));
        _fundReward(poolId, reward, 700 ether);
        vm.warp(block.timestamp + 1 days);

        address[] memory assets = new address[](1);
        assets[0] = address(reward);
        uint256[] memory minimums = new uint256[](1);
        reward.setCallback(
            address(diamond),
            address(diamond),
            abi.encodeCall(IStaticsRangeGauge.claimLpRewards, (positionId, poolId, assets, minimums, alice))
        );
        assertEq(_claim(positionId, poolId, address(reward), 100 ether, alice, alice), 100 ether);
        assertFalse(reward.reentrySucceeded());
        assertEq(bytes4(reward.reentryResult()), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(reward.balanceOf(alice), 100 ether);
    }

    function testBrokenRewardAffectsOnlyItsClaimAndForfeitureNeedsNoTransfer() public {
        PoolId poolId = _createRangeGaugePool(alice);
        uint256 positionId = _createPosition(alice);
        _provide(positionId, poolId, alice);
        MockERC20 working = new MockERC20("Working", "WORK", 18);
        MockRevertingERC20 broken = new MockRevertingERC20();
        _assignReward(poolId, address(working));
        _assignReward(poolId, address(broken));
        _fundReward(poolId, working, 700 ether);
        _fundReward(poolId, broken, 700 ether);
        vm.warp(block.timestamp + 1 days);
        broken.setTransfersRevert(true);

        assertEq(_claim(positionId, poolId, address(working), 100 ether, alice, alice), 100 ether);
        address[] memory assets = new address[](1);
        assets[0] = address(broken);
        uint256[] memory minimums = new uint256[](1);
        vm.expectRevert(MockRevertingERC20.TransferBlocked.selector);
        vm.prank(alice);
        rangeGauge.claimLpRewards(positionId, poolId, assets, minimums, alice);
        uint256 treasuryBefore = globalRewards.treasuryAccrued(address(broken));
        vm.prank(alice);
        assertEq(rangeGauge.forfeitLpReward(positionId, poolId, address(broken)), 100 ether);
        assertEq(globalRewards.treasuryAccrued(address(broken)) - treasuryBefore, 100 ether);
        assertEq(rangeGauge.poolRewardStream(poolId, address(broken)).claimLiability, 0);
    }

    function testExitAvoidsRewardTransferAndRetainsClaimStubUntilResolution() public {
        PoolId poolId = _createRangeGaugePool(alice);
        uint256 positionId = _createPosition(alice);
        IStaticsRangeGauge.LiquidityMovement memory provided = _provide(positionId, poolId, alice);
        MockRevertingERC20 broken = new MockRevertingERC20();
        _assignReward(poolId, address(broken));
        _fundReward(poolId, broken, 700 ether);
        vm.warp(block.timestamp + 1 days);
        broken.setTransfersRevert(true);

        IStaticsRangeGauge.LiquidityMovement memory exited = _exit(positionId, poolId, alice);
        assertGt(exited.received0 + exited.received1, 0);
        _assertPosmBurned(provided.posmTokenId);
        IStaticsRangeGauge.LpLegView memory stub = rangeGauge.lpLeg(positionId, poolId);
        assertEq(stub.manager, address(0));
        assertEq(stub.posmTokenId, 0);
        assertEq(stub.liquidity, 0);
        assertEq(stub.claimable[1], 100 ether);
        (PoolId[] memory pools,) = rangeGauge.positionGaugePools(positionId, 0, 1);
        assertEq(pools.length, 1);
        assertEq(IStaticsPosition(address(diamond)).activeLegCount(positionId), 1);

        vm.prank(alice);
        rangeGauge.forfeitLpReward(positionId, poolId, address(broken));
        (pools,) = rangeGauge.positionGaugePools(positionId, 0, 1);
        assertEq(pools.length, 0);
        assertEq(IStaticsPosition(address(diamond)).activeLegCount(positionId), 0);
        assertEq(rangeGauge.gaugePool(poolId).unresolvedLegCount, 0);
        assertEq(rangeGauge.posmBinding(provided.posmTokenId), bytes32(0));
    }

    function testClaimAfterExitFinalizesClaimOnlyStub() public {
        PoolId poolId = _createRangeGaugePool(alice);
        uint256 positionId = _createPosition(alice);
        _provide(positionId, poolId, alice);
        _fundReward(poolId, stakingAsset, 700 ether);
        vm.warp(block.timestamp + 1 days);
        _exit(positionId, poolId, alice);

        assertEq(_claim(positionId, poolId, address(stakingAsset), 100 ether, bob, alice), 100 ether);
        assertEq(stakingAsset.balanceOf(bob), 100 ether);
        assertEq(rangeGauge.lpLeg(positionId, poolId).manager, address(0));
        (PoolId[] memory pools,) = rangeGauge.positionGaugePools(positionId, 0, 1);
        assertEq(pools.length, 0);
        assertEq(IStaticsPosition(address(diamond)).activeLegCount(positionId), 0);
    }
}
