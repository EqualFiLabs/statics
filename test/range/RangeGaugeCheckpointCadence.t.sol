// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IStaticsRangeGauge} from "../../src/interfaces/IStaticsRangeGauge.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {RangeGaugeLifecycleTestBase} from "../helpers/RangeGaugeLifecycleTestBase.sol";

contract RangeGaugeCheckpointCadenceTest is RangeGaugeLifecycleTestBase {
    uint128 private constant HIGH_LIQUIDITY = 1e33;
    uint256 private constant HIGH_TOKEN_MAXIMUM = 2e33;
    uint256 private constant LOW_DECIMAL_BUDGET = 100e6;

    function testCheckpointCadenceCannotRedirectLowDecimalRewards() public {
        MockERC20 sparseReward = new MockERC20("Sparse Reward", "SPARSE", 6);
        MockERC20 frequentReward = new MockERC20("Frequent Reward", "FREQ", 6);
        MockERC20 frequentPairAsset = new MockERC20("Frequent Pair", "FPAIR", 18);
        PoolId sparsePool = _createRangeGaugePool(alice);
        PoolId frequentPool = _createRangeGaugePool(alice, address(assetA), address(frequentPairAsset));
        uint256 sparsePosition = _createPosition(alice);
        uint256 frequentPosition = _createPosition(alice);
        _provideHighLiquidity(sparsePosition, sparsePool, alice);
        _provideHighLiquidity(frequentPosition, frequentPool, alice);
        uint8 sparseSlot = _fundRewardAmount(sparsePool, sparseReward, LOW_DECIMAL_BUDGET);
        uint8 frequentSlot = _fundRewardAmount(frequentPool, frequentReward, LOW_DECIMAL_BUDGET);
        uint256 finish = block.timestamp + 7 days;
        uint256 frequentClaim;

        while (block.timestamp < finish) {
            vm.warp(block.timestamp + 1 hours);
            frequentClaim += _claimSlot(frequentPosition, frequentPool, frequentSlot, alice);
        }

        uint256 sparseClaim = _claimSlot(sparsePosition, sparsePool, sparseSlot, alice);

        assertApproxEqAbs(sparseClaim, LOW_DECIMAL_BUDGET, 1);
        assertApproxEqAbs(frequentClaim, sparseClaim, 1);
        assertLe(globalRewards.treasuryAccrued(address(frequentReward)), 1);
        _assertFinishedConservation(sparsePool, sparseSlot, sparseReward);
        _assertFinishedConservation(frequentPool, frequentSlot, frequentReward);
    }

    function testEmptyClaimsCannotEraseLowDecimalRewards() public {
        MockERC20 reward = new MockERC20("Empty Claim Reward", "EMPTY", 6);
        PoolId poolId = _createRangeGaugePool(alice);
        uint256 positionId = _createPosition(alice);
        _provideHighLiquidity(positionId, poolId, alice);
        uint8 slot = _fundRewardAmount(poolId, reward, LOW_DECIMAL_BUDGET);
        uint256 finish = block.timestamp + 7 days;
        uint8[] memory noSlots = new uint8[](0);
        uint256[] memory noMinimums = new uint256[](0);

        while (block.timestamp < finish) {
            vm.warp(block.timestamp + 1 hours);
            vm.prank(alice);
            rangeGauge.claimLpRewards(positionId, poolId, noSlots, noMinimums, alice);
        }

        assertApproxEqAbs(_claimSlot(positionId, poolId, slot, alice), LOW_DECIMAL_BUDGET, 1);
        assertEq(globalRewards.treasuryAccrued(address(reward)), 0);
        _assertFinishedConservation(poolId, slot, reward);
    }

    function testFrequentClaimsPreserveEighteenDecimalRewards() public {
        MockERC20 reward = new MockERC20("Eighteen Decimal Reward", "R18", 18);
        PoolId poolId = _createRangeGaugePool(alice);
        uint256 positionId = _createPosition(alice);
        _provideHighLiquidity(positionId, poolId, alice);
        uint256 budget = 100 ether;
        uint8 slot = _fundRewardAmount(poolId, reward, budget);
        uint256 finish = block.timestamp + 7 days;
        uint256 claimed;

        while (block.timestamp < finish) {
            vm.warp(block.timestamp + 1 hours);
            claimed += _claimSlot(positionId, poolId, slot, alice);
        }

        assertApproxEqAbs(claimed, budget, 1);
        assertEq(globalRewards.treasuryAccrued(address(reward)), 0);
        _assertFinishedConservation(poolId, slot, reward);
    }

    function testFrequentClaimsPreserveAggregateEntitlementForMultipleLps() public {
        MockERC20 reward = new MockERC20("Shared Reward", "SHARED", 6);
        PoolId poolId = _createRangeGaugePool(alice);
        uint256 alicePosition = _createPosition(alice);
        uint256 bobPosition = _createPosition(bob);
        _provideLiquidity(alicePosition, poolId, alice, HIGH_LIQUIDITY / 2, HIGH_TOKEN_MAXIMUM / 2);
        _provideLiquidity(bobPosition, poolId, bob, HIGH_LIQUIDITY / 2, HIGH_TOKEN_MAXIMUM / 2);
        uint8 slot = _fundRewardAmount(poolId, reward, LOW_DECIMAL_BUDGET);
        uint256 finish = block.timestamp + 7 days;
        uint256 claimed;

        while (block.timestamp < finish) {
            vm.warp(block.timestamp + 1 days);
            claimed += _claimSlot(alicePosition, poolId, slot, alice);
            claimed += _claimSlot(bobPosition, poolId, slot, bob);
        }

        assertApproxEqAbs(claimed, LOW_DECIMAL_BUDGET, 2);
        assertEq(globalRewards.treasuryAccrued(address(reward)), 0);
        _assertFinishedConservation(poolId, slot, reward);
    }

    function testTinyLiquidityChurnCannotRedirectLowDecimalRewards() public {
        MockERC20 reward = new MockERC20("Churn Reward", "CHURN", 6);
        PoolId poolId = _createRangeGaugePool(alice);
        uint256 victimPosition = _createPosition(alice);
        uint256 churnPosition = _createPosition(bob);
        _provideHighLiquidity(victimPosition, poolId, alice);
        _provideLiquidity(churnPosition, poolId, bob, 1_000_000, 2_000_000);
        _fundAndApprovePoolAssets(_poolKey(poolId), bob, 1_000);
        uint8 slot = _fundRewardAmount(poolId, reward, LOW_DECIMAL_BUDGET);
        uint256 finish = block.timestamp + 7 days;

        while (block.timestamp < finish) {
            vm.warp(block.timestamp + 1 hours);
            vm.prank(bob);
            rangeGauge.increaseLiquidity(
                churnPosition,
                poolId,
                IStaticsRangeGauge.IncreaseLiquidityParams({
                    liquidity: 1, amount0Maximum: 10, amount1Maximum: 10, deadline: block.timestamp + 1 hours
                })
            );
            vm.prank(bob);
            rangeGauge.decreaseLiquidity(
                churnPosition,
                poolId,
                IStaticsRangeGauge.DecreaseLiquidityParams({
                    liquidity: 1, amount0Minimum: 0, amount1Minimum: 0, deadline: block.timestamp + 1 hours
                })
            );
        }

        uint256 claimed = _claimSlot(victimPosition, poolId, slot, alice);
        claimed += _claimSlot(churnPosition, poolId, slot, bob);
        assertApproxEqAbs(claimed, LOW_DECIMAL_BUDGET, 2);
        assertEq(globalRewards.treasuryAccrued(address(reward)), 0);
        _assertFinishedConservation(poolId, slot, reward);
    }

    function testSameWeightRebalanceCannotRedirectLowDecimalRewards() public {
        MockERC20 reward = new MockERC20("Rebalance Reward", "REBAL", 6);
        PoolId poolId = _createRangeGaugePool(alice);
        PoolKey memory key = _poolKey(poolId);
        uint256 victimPosition = _createPosition(alice);
        uint256 churnPosition = _createPosition(bob);
        _provideHighLiquidity(victimPosition, poolId, alice);
        _provideLiquidity(churnPosition, poolId, bob, 1_000_000, 2_000_000);
        _fundAndApprovePoolAssets(key, bob, 1_000);
        uint8 slot = _fundRewardAmount(poolId, reward, LOW_DECIMAL_BUDGET);
        uint256 finish = block.timestamp + 7 days;

        for (uint256 hour = 1; hour <= 24; ++hour) {
            vm.warp(block.timestamp + 1 hours);
            vm.prank(bob);
            rangeGauge.rebalanceLiquidity(
                churnPosition,
                poolId,
                IStaticsRangeGauge.RebalanceLiquidityParams({
                    tickLower: TickMath.minUsableTick(key.tickSpacing),
                    tickUpper: TickMath.maxUsableTick(key.tickSpacing),
                    liquidity: 1_000_000,
                    amount0Maximum: 1_000,
                    amount1Maximum: 1_000,
                    amount0Minimum: 0,
                    amount1Minimum: 0,
                    deadline: block.timestamp + 1 hours
                })
            );
        }
        vm.warp(finish);
        assertEq(block.timestamp, finish);

        uint256 claimed = _claimSlot(victimPosition, poolId, slot, alice);
        claimed += _claimSlot(churnPosition, poolId, slot, bob);
        assertApproxEqAbs(claimed, LOW_DECIMAL_BUDGET, 2);
        assertEq(globalRewards.treasuryAccrued(address(reward)), 0);
        _assertFinishedConservation(poolId, slot, reward);
    }

    function _provideHighLiquidity(uint256 positionId, PoolId poolId, address payer) private {
        _provideLiquidity(positionId, poolId, payer, HIGH_LIQUIDITY, HIGH_TOKEN_MAXIMUM);
    }

    function _provideLiquidity(uint256 positionId, PoolId poolId, address payer, uint128 liquidity, uint256 maximum)
        private
    {
        _fundAndApprovePoolAssets(_poolKey(poolId), payer, maximum);
        vm.prank(payer);
        rangeGauge.provideLiquidity(
            positionId,
            IStaticsRangeGauge.ProvideLiquidityParams({
                poolId: poolId,
                tickLower: TickMath.minUsableTick(10),
                tickUpper: TickMath.maxUsableTick(10),
                liquidity: liquidity,
                amount0Maximum: maximum,
                amount1Maximum: maximum,
                deadline: block.timestamp + 1 hours
            })
        );
    }

    function _fundRewardAmount(PoolId poolId, MockERC20 reward, uint256 amount) private returns (uint8 slot) {
        slot = _assignReward(poolId, address(reward));
        reward.mint(alice, amount);
        vm.startPrank(alice);
        reward.approve(address(diamond), amount);
        rangeGauge.fundPoolReward(poolId, slot, amount, 0, 0, 0);
        vm.stopPrank();
    }

    function _claimSlot(uint256 positionId, PoolId poolId, uint8 slot, address owner)
        private
        returns (uint256 claimed)
    {
        uint8[] memory slots = new uint8[](1);
        slots[0] = slot;
        uint256[] memory minimums = new uint256[](1);
        vm.prank(owner);
        uint256[] memory amounts = rangeGauge.claimLpRewards(positionId, poolId, slots, minimums, owner);
        claimed = amounts[0];
    }

    function _assertFinishedConservation(PoolId poolId, uint8 slot, MockERC20 reward) private view {
        IStaticsRangeGauge.GaugeRewardStreamView memory stream = rangeGauge.poolRewardStream(poolId, slot);
        (bytes32 account,) = rangeGauge.poolRewardCustodyAccount(poolId, slot);
        uint256 reserved = custody.reservedByAccount(account, address(reward));
        assertEq(stream.periodEmitted, stream.periodBudget);
        assertEq(reserved, stream.indexedLiability + stream.claimLiability);
        assertEq(reward.balanceOf(address(diamond)), reserved);
    }
}
