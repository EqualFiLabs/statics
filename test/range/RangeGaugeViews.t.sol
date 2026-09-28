// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IStaticsRangeGauge} from "../../src/interfaces/IStaticsRangeGauge.sol";
import {LibRangeGauge} from "../../src/libraries/LibRangeGauge.sol";
import {RangeGaugeFeatureTestBase} from "../helpers/RangeGaugeFeatureTestBase.sol";

contract RangeGaugeViewsTest is RangeGaugeFeatureTestBase {
    uint256 private constant START = 1_000_000;
    uint256 private constant POSITION_ID = 11;
    uint256 private constant POSM_TOKEN_ID = 77;

    function testViewsExposePoolStreamBoundaryLegManagerAndPaginationState() public {
        PoolId poolId = _createRangeGaugePool(alice);
        address legacyManager = makeAddr("legacyManager");
        rangeGaugeState.addGaugeRange(poolId, -10, 10, 10, 0, 100);
        rangeGaugeState.setActiveGaugeLiquidity(poolId, 100);
        rangeGaugeState.seedLpLeg(POSITION_ID, poolId, legacyManager, POSM_TOKEN_ID, -10, 10, 100);
        vm.prank(alice);
        uint8 staticsSlot = rangeGauge.appendPoolRewardAsset(poolId, address(stakingAsset));

        stakingAsset.mint(bob, 700 ether);
        vm.prank(bob);
        stakingAsset.approve(address(diamond), type(uint256).max);
        vm.warp(START);
        vm.prank(bob);
        rangeGauge.fundPoolReward(poolId, staticsSlot, 700 ether, uint40(7 days), 0);
        vm.warp(START + 1 days);

        IStaticsRangeGauge.PoolRewardConfigView memory config = rangeGauge.poolRewardConfig(poolId);
        assertTrue(config.initialized);
        assertEq(config.slotCount, 2);
        assertEq(config.assets[0], address(stakingAsset));

        IStaticsRangeGauge.GaugePoolView memory pool = rangeGauge.gaugePool(poolId);
        assertTrue(pool.initialized);
        assertFalse(pool.stopped);
        assertEq(pool.referenceTick, 0);
        assertEq(pool.activeGaugeLiquidity, 100);
        assertEq(pool.managedLegCount, 1);
        assertEq(pool.unresolvedLegCount, 1);

        IStaticsRangeGauge.GaugeRewardStreamView memory stream = rangeGauge.poolRewardStream(poolId, staticsSlot);
        assertTrue(stream.assigned);
        assertEq(stream.slot, staticsSlot);
        assertEq(stream.periodBudget, 700 ether);
        assertEq(stream.periodEmitted, 0);

        IStaticsRangeGauge.GaugeBoundaryView memory lower = rangeGauge.gaugeBoundary(poolId, -10);
        IStaticsRangeGauge.GaugeBoundaryView memory upper = rangeGauge.gaugeBoundary(poolId, 10);
        assertEq(lower.grossLiquidity, 100);
        assertEq(lower.netLiquidity, 100);
        assertEq(upper.grossLiquidity, 100);
        assertEq(upper.netLiquidity, -100);

        IStaticsRangeGauge.LpLegView memory leg = rangeGauge.lpLeg(POSITION_ID, poolId);
        assertEq(leg.manager, legacyManager);
        assertEq(leg.posmTokenId, POSM_TOKEN_ID);
        assertEq(leg.tickLower, -10);
        assertEq(leg.tickUpper, 10);
        assertEq(leg.liquidity, 100);
        assertEq(rangeGauge.recordedLiquidityManager(POSITION_ID, poolId), legacyManager);
        assertEq(rangeGauge.posmBinding(POSM_TOKEN_ID), LibRangeGauge.bindingFor(POSITION_ID, poolId));

        (PoolId[] memory poolIds, uint256 nextCursor) = rangeGauge.positionGaugePools(POSITION_ID, 0, 10);
        assertEq(poolIds.length, 1);
        assertEq(PoolId.unwrap(poolIds[0]), PoolId.unwrap(poolId));
        assertEq(nextCursor, 1);
        (poolIds, nextCursor) = rangeGauge.positionGaugePools(POSITION_ID, 1, 10);
        assertEq(poolIds.length, 0);
        assertEq(nextCursor, 1);

        (address activeManager, bool installed) = rangeGauge.liquidityManager();
        assertTrue(installed);
        assertTrue(activeManager != address(0));

        _assertRewardCustody(poolId, staticsSlot, 700 ether);
    }

    function testPendingPreviewIncludesUncheckpointedEmissionWithoutMutatingStream() public {
        PoolId poolId = _createRangeGaugePool(alice);
        rangeGaugeState.addGaugeRange(poolId, -10, 10, 10, 0, 100);
        rangeGaugeState.setActiveGaugeLiquidity(poolId, 100);
        rangeGaugeState.seedLpLeg(POSITION_ID, poolId, makeAddr("manager"), POSM_TOKEN_ID, -10, 10, 100);
        vm.prank(alice);
        uint8 staticsSlot = rangeGauge.appendPoolRewardAsset(poolId, address(stakingAsset));
        stakingAsset.mint(bob, 700 ether);
        vm.prank(bob);
        stakingAsset.approve(address(diamond), type(uint256).max);
        vm.warp(START);
        vm.prank(bob);
        rangeGauge.fundPoolReward(poolId, staticsSlot, 700 ether, uint40(7 days), 0);
        vm.warp(START + 1 days);

        IStaticsRangeGauge.PendingRewardsView memory pending = rangeGauge.previewLpRewards(POSITION_ID, poolId);
        assertEq(pending.slotCount, 2);
        assertEq(pending.assets[0], address(stakingAsset));
        assertEq(pending.assets[staticsSlot], address(stakingAsset));
        assertEq(pending.amounts[staticsSlot], 100 ether);

        IStaticsRangeGauge.GaugeRewardStreamView memory unchanged = rangeGauge.poolRewardStream(poolId, staticsSlot);
        assertEq(unchanged.lastUpdate, START);
        assertEq(unchanged.periodEmitted, 0);
        assertEq(unchanged.globalIndexRay, 0);
    }

    function testUnknownRewardAssetViewsAreExplicitlyUnassigned() public {
        PoolId poolId = _createRangeGaugePool(alice);
        IStaticsRangeGauge.GaugeRewardStreamView memory stream = rangeGauge.poolRewardStream(poolId, 4);
        assertFalse(stream.assigned);
        assertEq(stream.asset, address(0));
        assertEq(stream.slot, 4);
        assertEq(stream.periodBudget, 0);
        (bytes32 account, bool assigned) = rangeGauge.poolRewardCustodyAccount(poolId, 4);
        assertEq(account, bytes32(0));
        assertFalse(assigned);
    }

    function _assertRewardCustody(PoolId poolId, uint8 slot, uint256 expected) private view {
        (bytes32 account, bool assigned) = rangeGauge.poolRewardCustodyAccount(poolId, slot);
        assertTrue(assigned);
        assertEq(custody.reservedByAccount(account, address(stakingAsset)), expected);
    }
}
