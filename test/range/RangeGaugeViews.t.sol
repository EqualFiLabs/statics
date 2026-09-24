// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IStaticsRangeGauge} from "../../src/interfaces/IStaticsRangeGauge.sol";
import {LibRangeGauge} from "../../src/libraries/LibRangeGauge.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
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

        stakingAsset.mint(bob, 700 ether);
        vm.prank(bob);
        stakingAsset.approve(address(diamond), type(uint256).max);
        vm.warp(START);
        vm.prank(bob);
        rangeGauge.fundPoolReward(poolId, address(stakingAsset), 700 ether, uint40(7 days));
        vm.warp(START + 1 days);

        IStaticsRangeGauge.PoolRewardConfigView memory config = rangeGauge.poolRewardConfig(poolId);
        assertTrue(config.initialized);
        assertEq(config.slotCount, 1);
        assertEq(config.assets[0], address(stakingAsset));

        IStaticsRangeGauge.GaugePoolView memory pool = rangeGauge.gaugePool(poolId);
        assertTrue(pool.initialized);
        assertFalse(pool.stopped);
        assertEq(pool.referenceTick, 0);
        assertEq(pool.activeGaugeLiquidity, 100);
        assertEq(pool.managedLegCount, 1);
        assertEq(pool.unresolvedLegCount, 1);

        IStaticsRangeGauge.GaugeRewardStreamView memory stream =
            rangeGauge.poolRewardStream(poolId, address(stakingAsset));
        assertTrue(stream.assigned);
        assertEq(stream.slot, 0);
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

        (bytes32 account, bool assigned) = rangeGauge.poolRewardCustodyAccount(poolId, address(stakingAsset));
        assertTrue(assigned);
        assertEq(custody.reservedByAccount(account, address(stakingAsset)), 700 ether);
    }

    function testPendingPreviewIncludesUncheckpointedEmissionWithoutMutatingStream() public {
        PoolId poolId = _createRangeGaugePool(alice);
        rangeGaugeState.addGaugeRange(poolId, -10, 10, 10, 0, 100);
        rangeGaugeState.setActiveGaugeLiquidity(poolId, 100);
        rangeGaugeState.seedLpLeg(POSITION_ID, poolId, makeAddr("manager"), POSM_TOKEN_ID, -10, 10, 100);
        stakingAsset.mint(bob, 700 ether);
        vm.prank(bob);
        stakingAsset.approve(address(diamond), type(uint256).max);
        vm.warp(START);
        vm.prank(bob);
        rangeGauge.fundPoolReward(poolId, address(stakingAsset), 700 ether, uint40(7 days));
        vm.warp(START + 1 days);

        IStaticsRangeGauge.PendingRewardsView memory pending = rangeGauge.previewLpRewards(POSITION_ID, poolId);
        assertEq(pending.slotCount, 1);
        assertEq(pending.assets[0], address(stakingAsset));
        assertEq(pending.amounts[0], 100 ether);

        IStaticsRangeGauge.GaugeRewardStreamView memory unchanged =
            rangeGauge.poolRewardStream(poolId, address(stakingAsset));
        assertEq(unchanged.lastUpdate, START);
        assertEq(unchanged.periodEmitted, 0);
        assertEq(unchanged.globalIndexRay, 0);
    }

    function testUnknownRewardAssetViewsAreExplicitlyUnassigned() public {
        PoolId poolId = _createRangeGaugePool(alice);
        MockERC20 unknown = new MockERC20("Unknown", "UNK", 18);
        IStaticsRangeGauge.GaugeRewardStreamView memory stream = rangeGauge.poolRewardStream(poolId, address(unknown));
        assertFalse(stream.assigned);
        assertEq(stream.asset, address(unknown));
        assertEq(stream.periodBudget, 0);
        (bytes32 account, bool assigned) = rangeGauge.poolRewardCustodyAccount(poolId, address(unknown));
        assertEq(account, bytes32(0));
        assertFalse(assigned);
    }
}
