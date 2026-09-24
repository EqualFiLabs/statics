// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IStaticsBasketLiquidity} from "../../src/interfaces/IStaticsBasketLiquidity.sol";
import {IStaticsRangeGauge} from "../../src/interfaces/IStaticsRangeGauge.sol";
import {IStaticsRewardPolicy} from "../../src/interfaces/IStaticsRewardPolicy.sol";
import {LibDiamond} from "../../src/libraries/LibDiamond.sol";
import {LibRangeGauge} from "../../src/libraries/LibRangeGauge.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {RangeGaugeFeatureTestBase} from "../helpers/RangeGaugeFeatureTestBase.sol";

contract RangeGaugeRegistryTest is RangeGaugeFeatureTestBase {
    uint256 private constant PAUSE_LIQUIDITY = 1 << 5;

    function testDefaultsAndPublicPoolInitializationAssignStaticsSlotZero() public {
        assertEq(rangeGauge.gaugeRewardDuration(), 7 days);
        assertTrue(rangeGauge.gaugeRewardAssetAllowed(address(stakingAsset)));

        PoolId poolId = _createRangeGaugePool(alice);
        IStaticsRangeGauge.PoolRewardConfigView memory config = rangeGauge.poolRewardConfig(poolId);
        IStaticsRangeGauge.GaugePoolView memory pool = rangeGauge.gaugePool(poolId);
        assertTrue(config.initialized);
        assertEq(config.slotCount, 1);
        assertEq(config.assets[0], address(stakingAsset));
        assertTrue(pool.initialized);
        assertFalse(pool.stopped);
    }

    function testOwnerControlsAllowlistAndBoundedDuration() public {
        MockERC20 reward = new MockERC20("Reward", "RWD", 18);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LibDiamond.NotContractOwner.selector, alice, address(this)));
        rangeGauge.setGaugeRewardAssetAllowed(address(reward), true);

        rangeGauge.setGaugeRewardAssetAllowed(address(reward), true);
        assertTrue(rangeGauge.gaugeRewardAssetAllowed(address(reward)));
        rangeGauge.setGaugeRewardAssetAllowed(address(reward), false);
        assertFalse(rangeGauge.gaugeRewardAssetAllowed(address(reward)));

        rangeGauge.setGaugeRewardDuration(1 days);
        assertEq(rangeGauge.gaugeRewardDuration(), 1 days);
        rangeGauge.setGaugeRewardDuration(30 days);
        assertEq(rangeGauge.gaugeRewardDuration(), 30 days);
        vm.expectRevert(abi.encodeWithSelector(LibRangeGauge.InvalidRewardDuration.selector, uint40(1 days - 1)));
        rangeGauge.setGaugeRewardDuration(uint40(1 days - 1));
        vm.expectRevert(abi.encodeWithSelector(LibRangeGauge.InvalidRewardDuration.selector, uint40(30 days + 1)));
        rangeGauge.setGaugeRewardDuration(uint40(30 days + 1));
    }

    function testOnlyCreatorAppendsGloballyAllowedAssetsIntoLifetimeSlots() public {
        PoolId poolId = _createRangeGaugePool(alice);
        MockERC20[4] memory rewards = [
            new MockERC20("Reward One", "R1", 18),
            new MockERC20("Reward Two", "R2", 18),
            new MockERC20("Reward Three", "R3", 18),
            new MockERC20("Reward Four", "R4", 18)
        ];
        for (uint256 i; i < rewards.length; ++i) {
            rangeGauge.setGaugeRewardAssetAllowed(address(rewards[i]), true);
        }

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IStaticsRangeGauge.NotPoolCreator.selector, poolId, bob, alice));
        rangeGauge.appendPoolRewardAsset(poolId, address(rewards[0]));

        vm.startPrank(alice);
        assertEq(rangeGauge.appendPoolRewardAsset(poolId, address(rewards[0])), 1);
        assertEq(rangeGauge.appendPoolRewardAsset(poolId, address(rewards[1])), 2);
        assertEq(rangeGauge.appendPoolRewardAsset(poolId, address(rewards[2])), 3);
        vm.expectRevert(abi.encodeWithSelector(LibRangeGauge.RewardSlotLimitReached.selector, poolId));
        rangeGauge.appendPoolRewardAsset(poolId, address(rewards[3]));
        vm.stopPrank();

        IStaticsRangeGauge.PoolRewardConfigView memory config = rangeGauge.poolRewardConfig(poolId);
        assertEq(config.slotCount, 4);
        assertEq(config.assets[1], address(rewards[0]));
        assertEq(config.assets[2], address(rewards[1]));
        assertEq(config.assets[3], address(rewards[2]));
    }

    function testRewardAllowlistRemainsSeparateFromRestrictionPolicy() public {
        PoolId poolId = _createRangeGaugePool(alice);
        MockERC20 reward = new MockERC20("Reward", "RWD", 18);
        rangeGauge.setGaugeRewardAssetAllowed(address(reward), true);

        vm.prank(guardian);
        IStaticsRewardPolicy(address(diamond)).addRewardRestriction(address(reward));
        assertTrue(rangeGauge.gaugeRewardAssetAllowed(address(reward)));
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IStaticsRangeGauge.GaugeRewardAssetRestricted.selector, address(reward)));
        rangeGauge.appendPoolRewardAsset(poolId, address(reward));

        IStaticsRewardPolicy(address(diamond)).removeRewardRestriction(address(reward));
        vm.prank(alice);
        assertEq(rangeGauge.appendPoolRewardAsset(poolId, address(reward)), 1);
    }

    function testLiquidityPauseBlocksCreatorConfiguration() public {
        PoolId poolId = _createRangeGaugePool(alice);
        MockERC20 reward = new MockERC20("Reward", "RWD", 18);
        rangeGauge.setGaugeRewardAssetAllowed(address(reward), true);
        vm.prank(guardian);
        governance.pause(PAUSE_LIQUIDITY);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IStaticsRangeGauge.ActionPaused.selector, PAUSE_LIQUIDITY));
        rangeGauge.appendPoolRewardAsset(poolId, address(reward));
    }

    function testBasketCreatorControlsCanonicalPoolRewardSlots() public {
        (uint256 basketId,) = _createDefaultBasket(0, 0);
        IStaticsBasketLiquidity.CanonicalPoolView memory pool = basketLiquidity.canonicalPool(basketId, address(assetA));
        MockERC20 reward = new MockERC20("Basket Reward", "BRWD", 18);
        rangeGauge.setGaugeRewardAssetAllowed(address(reward), true);

        vm.prank(alice);
        assertEq(rangeGauge.appendPoolRewardAsset(pool.poolId, address(reward)), 1);
        assertEq(rangeGauge.poolRewardConfig(pool.poolId).assets[1], address(reward));
    }
}
