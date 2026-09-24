// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IStaticsCustody} from "../../src/interfaces/IStaticsCustody.sol";
import {IStaticsProtocolPools} from "../../src/interfaces/IStaticsProtocolPools.sol";
import {IStaticsRangeGauge} from "../../src/interfaces/IStaticsRangeGauge.sol";
import {StaticsLiquidityManager} from "../../src/liquidity/StaticsLiquidityManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {RangeGaugeLifecycleTestBase} from "../helpers/RangeGaugeLifecycleTestBase.sol";

contract RangeGaugeDecommissionTest is RangeGaugeLifecycleTestBase {
    function testDecommissionPreservesIndexedAndClaimLiabilitiesWhileStoppingSchedule() public {
        PoolId poolId = _createRangeGaugePool(alice);
        uint256 positionId = _createPosition(alice);
        _provide(positionId, poolId, alice);
        _fundReward(poolId, stakingAsset, 700 ether);
        uint8 staticsSlot = _ordinaryRewardSlot(poolId, address(stakingAsset));
        vm.warp(block.timestamp + 1 days);

        uint8[] memory noSlots = new uint8[](0);
        uint256[] memory noMinimums = new uint256[](0);
        vm.prank(alice);
        rangeGauge.claimLpRewards(positionId, poolId, noSlots, noMinimums, alice);
        assertEq(rangeGauge.poolRewardStream(poolId, staticsSlot).claimLiability, 100 ether);

        _fundReward(poolId, stakingAsset, 700 ether);
        vm.warp(block.timestamp + 1 days);
        uint256 treasuryBefore = globalRewards.treasuryAccrued(address(stakingAsset));
        IStaticsProtocolPools(address(diamond)).decommissionGeneralPool(poolId);

        IStaticsRangeGauge.GaugePoolView memory gauge = rangeGauge.gaugePool(poolId);
        IStaticsRangeGauge.GaugeRewardStreamView memory stream = rangeGauge.poolRewardStream(poolId, staticsSlot);
        assertTrue(gauge.stopped);
        assertEq(stream.periodEmitted, stream.periodBudget);
        assertGt(stream.indexedLiability, 0);
        assertEq(stream.claimLiability, 100 ether);
        assertGt(globalRewards.treasuryAccrued(address(stakingAsset)), treasuryBefore);

        assertGt(_claim(positionId, poolId, address(stakingAsset), 100 ether, bob, alice), 100 ether);
        _exit(positionId, poolId, alice);
        assertEq(rangeGauge.gaugePool(poolId).unresolvedLegCount, 0);
    }

    function testStoppedGaugeRejectsIngressAndPreservesLifecycleOperations() public {
        PoolId poolId = _createRangeGaugePool(alice);
        uint256 positionId = _createPosition(alice);
        _provide(positionId, poolId, alice);
        MockERC20 extraReward = new MockERC20("Extra Reward", "EXTRA", 18);
        rangeGauge.setGaugeRewardAssetAllowed(address(extraReward), true);
        IStaticsProtocolPools(address(diamond)).decommissionGeneralPool(poolId);

        uint256 emptyPosition = _createPosition(alice);
        vm.prank(alice);
        vm.expectPartialRevert(IStaticsRangeGauge.GaugeStopped.selector);
        rangeGauge.provideLiquidity(
            emptyPosition,
            IStaticsRangeGauge.ProvideLiquidityParams({
                poolId: poolId,
                tickLower: TickMath.minUsableTick(10),
                tickUpper: TickMath.maxUsableTick(10),
                liquidity: INITIAL_LIQUIDITY,
                amount0Maximum: TOKEN_MAXIMUM,
                amount1Maximum: TOKEN_MAXIMUM,
                deadline: block.timestamp + 1 hours
            })
        );

        vm.prank(alice);
        vm.expectPartialRevert(IStaticsRangeGauge.GaugeStopped.selector);
        rangeGauge.attachLiquidity(emptyPosition, poolId, type(uint256).max);

        vm.prank(alice);
        vm.expectPartialRevert(IStaticsRangeGauge.GaugeStopped.selector);
        rangeGauge.increaseLiquidity(
            positionId,
            poolId,
            IStaticsRangeGauge.IncreaseLiquidityParams({
                liquidity: 1 ether,
                amount0Maximum: TOKEN_MAXIMUM,
                amount1Maximum: TOKEN_MAXIMUM,
                deadline: block.timestamp + 1 hours
            })
        );

        vm.prank(alice);
        vm.expectPartialRevert(IStaticsRangeGauge.GaugeStopped.selector);
        rangeGauge.rebalanceLiquidity(
            positionId,
            poolId,
            IStaticsRangeGauge.RebalanceLiquidityParams({
                tickLower: -100,
                tickUpper: 100,
                liquidity: INITIAL_LIQUIDITY,
                amount0Maximum: TOKEN_MAXIMUM,
                amount1Maximum: TOKEN_MAXIMUM,
                amount0Minimum: 0,
                amount1Minimum: 0,
                deadline: block.timestamp + 1 hours
            })
        );

        vm.prank(alice);
        vm.expectPartialRevert(IStaticsRangeGauge.GaugeStopped.selector);
        rangeGauge.appendPoolRewardAsset(poolId, address(extraReward));
        vm.prank(alice);
        vm.expectPartialRevert(IStaticsRangeGauge.GaugeStopped.selector);
        rangeGauge.fundPoolReward(poolId, 0, 1 ether, 0, 0);

        vm.prank(alice);
        IStaticsRangeGauge.LiquidityMovement memory decreased = rangeGauge.decreaseLiquidity(
            positionId,
            poolId,
            IStaticsRangeGauge.DecreaseLiquidityParams({
                liquidity: INITIAL_LIQUIDITY / 2,
                amount0Minimum: 0,
                amount1Minimum: 0,
                deadline: block.timestamp + 1 hours
            })
        );
        assertEq(decreased.liquidity, INITIAL_LIQUIDITY / 2);
        vm.prank(alice);
        rangeGauge.collectNativeFees(positionId, poolId, 0, 0, block.timestamp + 1 hours);
        _exit(positionId, poolId, alice);

        vm.prank(bob);
        assertEq(rangeGauge.reconcilePoolRewardSurplus(poolId, 0), 0);
    }

    function testFinalReconciliationWaitsForEveryLegAndRoutesOnlyResidual() public {
        PoolId poolId = _createRangeGaugePool(alice);
        uint256 firstPosition = _createPosition(alice);
        uint256 secondPosition = _createPosition(bob);
        _provide(firstPosition, poolId, alice);
        _provide(secondPosition, poolId, bob);
        _fundReward(poolId, stakingAsset, 1);
        uint8 staticsSlot = _ordinaryRewardSlot(poolId, address(stakingAsset));
        vm.warp(block.timestamp + 7 days);
        IStaticsProtocolPools(address(diamond)).decommissionGeneralPool(poolId);

        IStaticsRangeGauge.GaugeRewardStreamView memory beforeExit = rangeGauge.poolRewardStream(poolId, staticsSlot);
        assertEq(beforeExit.indexedLiability, 1);
        assertEq(beforeExit.claimLiability, 0);
        vm.expectPartialRevert(IStaticsRangeGauge.PoolRewardReconciliationUnavailable.selector);
        rangeGauge.reconcilePoolRewardSurplus(poolId, staticsSlot);

        _exit(firstPosition, poolId, alice);
        vm.expectPartialRevert(IStaticsRangeGauge.PoolRewardReconciliationUnavailable.selector);
        rangeGauge.reconcilePoolRewardSurplus(poolId, staticsSlot);
        _exit(secondPosition, poolId, bob);
        assertEq(rangeGauge.gaugePool(poolId).unresolvedLegCount, 0);

        (bytes32 rewardAccount,) = rangeGauge.poolRewardCustodyAccount(poolId, staticsSlot);
        IStaticsCustody custodyView = IStaticsCustody(address(diamond));
        assertEq(custodyView.reservedByAccount(rewardAccount, address(stakingAsset)), 1);
        uint256 treasuryBefore = globalRewards.treasuryAccrued(address(stakingAsset));
        vm.prank(bob);
        assertEq(rangeGauge.reconcilePoolRewardSurplus(poolId, staticsSlot), 1);
        assertEq(custodyView.reservedByAccount(rewardAccount, address(stakingAsset)), 0);
        assertEq(rangeGauge.poolRewardStream(poolId, staticsSlot).indexedLiability, 0);
        assertEq(globalRewards.treasuryAccrued(address(stakingAsset)) - treasuryBefore, 1);
    }

    function testOwnerCanRecoverOnlyUnboundPosmFromMatchingManager() public {
        PoolId poolId = _createRangeGaugePool(alice);
        uint256 posmTokenId = _mintUnmanagedPosition(_poolKey(poolId), alice);
        vm.prank(alice);
        IERC721(address(rangePositionManager)).transferFrom(alice, address(rangeLiquidityManager), posmTokenId);

        vm.prank(alice);
        vm.expectRevert();
        rangeGauge.recoverUnboundPosm(address(rangeLiquidityManager), posmTokenId, bob);

        address otherDiamond = makeAddr("other-diamond");
        StaticsLiquidityManager wrongManager = new StaticsLiquidityManager(
            otherDiamond, address(rangePositionManager), address(poolManager), address(rangePermit2)
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                IStaticsRangeGauge.LiquidityManagerBindingMismatch.selector,
                address(wrongManager),
                address(diamond),
                otherDiamond
            )
        );
        rangeGauge.recoverUnboundPosm(address(wrongManager), posmTokenId, bob);

        rangeGauge.recoverUnboundPosm(address(rangeLiquidityManager), posmTokenId, bob);
        assertEq(IERC721(address(rangePositionManager)).ownerOf(posmTokenId), bob);
    }
}
