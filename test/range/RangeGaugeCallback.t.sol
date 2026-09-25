// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {RangeGaugeCallbackFacet} from "../../src/facets/RangeGaugeCallbackFacet.sol";
import {IStaticsProtocolPools} from "../../src/interfaces/IStaticsProtocolPools.sol";
import {LibProtocolPools} from "../../src/libraries/LibProtocolPools.sol";
import {LibRangeGauge} from "../../src/libraries/LibRangeGauge.sol";
import {
    RangeGaugeCallbackHarness,
    RangeGaugeHookCaller,
    RangeGaugePoolManagerMock
} from "../helpers/RangeGaugeCallbackHarness.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

contract RangeGaugeCallbackTest is Test {
    using PoolIdLibrary for PoolKey;

    RangeGaugeCallbackHarness private callback;
    RangeGaugeHookCaller private hook;
    RangeGaugePoolManagerMock private poolManager;
    MockERC20 private statics;
    address private otherHook;

    uint256 private constant START = 1_000_000;
    uint256 private constant DURATION = 7 days;

    function setUp() public {
        callback = new RangeGaugeCallbackHarness();
        hook = new RangeGaugeHookCaller();
        poolManager = new RangeGaugePoolManagerMock();
        statics = new MockERC20("Statics", "STATICS", 18);
        otherHook = makeAddr("otherHook");
    }

    function testAcceptsInstalledHookForRegisteredGeneralPool() public {
        PoolKey memory key = _key(address(hook));
        PoolId poolId = callback.registerGeneralPool(key, makeAddr("creator"));
        _initialize(poolId, 0, 0);

        hook.notify(address(callback), poolId);
    }

    function testAcceptsInstalledHookForRegisteredBasketPool() public {
        PoolKey memory key = _key(address(hook));
        PoolId poolId = callback.registerBasketPool(key, 7, address(0xBEEF));
        _initialize(poolId, 0, 0);

        hook.notify(address(callback), poolId);
    }

    function testRejectsCallbackBeforePublicIntegrationIsInstalled() public {
        vm.expectRevert(RangeGaugeCallbackFacet.PublicLiquidityIntegrationNotInstalled.selector);
        hook.notify(address(callback), PoolId.wrap(bytes32(uint256(1))));
    }

    function testRejectsCallerOtherThanInstalledPublicHook() public {
        callback.installPublicIntegration(makeAddr("poolManager"), address(hook));

        vm.expectRevert(
            abi.encodeWithSelector(
                RangeGaugeCallbackFacet.OnlyInstalledPublicHook.selector, address(this), address(hook)
            )
        );
        callback.afterProtocolPoolSwap(PoolId.wrap(bytes32(uint256(1))));
    }

    function testRejectsUnregisteredPool() public {
        PoolId poolId = PoolId.wrap(bytes32(uint256(1)));
        callback.installPublicIntegration(makeAddr("poolManager"), address(hook));

        vm.expectRevert(abi.encodeWithSelector(LibProtocolPools.ProtocolPoolNotRegistered.selector, poolId));
        hook.notify(address(callback), poolId);
    }

    function testRejectsPermissionedPool() public {
        PoolKey memory key = _key(address(hook));
        PoolId poolId = callback.registerPermissionedPool(key, makeAddr("creator"));
        callback.installPublicIntegration(makeAddr("poolManager"), address(hook));

        vm.expectRevert(
            abi.encodeWithSelector(
                RangeGaugeCallbackFacet.InvalidPublicPoolKind.selector,
                poolId,
                IStaticsProtocolPools.ProtocolPoolKind.PermissionedGeneral
            )
        );
        hook.notify(address(callback), poolId);
    }

    function testRejectsPublicPoolBoundToDifferentHook() public {
        PoolKey memory key = _key(otherHook);
        PoolId poolId = callback.registerGeneralPool(key, makeAddr("creator"));
        callback.installPublicIntegration(makeAddr("poolManager"), address(hook));

        vm.expectRevert(
            abi.encodeWithSelector(
                RangeGaugeCallbackFacet.PublicPoolHookMismatch.selector, poolId, address(hook), otherHook
            )
        );
        hook.notify(address(callback), poolId);
    }

    function testNoTickMovementDoesNotCheckpointOrWriteGauge() public {
        (PoolId poolId,) = _readyGeneral(0, 0);
        callback.setActiveLiquidity(poolId, 100);
        callback.fundStream(poolId, 0, 700 ether, START, DURATION);
        vm.warp(START + 1 days);

        hook.notify(address(callback), poolId);

        (, bool stopped, int24 referenceTick, uint128 activeLiquidity) = callback.gaugeState(poolId);
        LibRangeGauge.GaugeRewardStream memory stream = callback.stream(poolId, 0);
        assertFalse(stopped);
        assertEq(referenceTick, 0);
        assertEq(activeLiquidity, 100);
        assertEq(stream.lastUpdate, START);
        assertEq(stream.periodEmitted, 0);
    }

    function testMovementWithoutBoundaryLeavesReferenceAndStreamUnchanged() public {
        (PoolId poolId,) = _readyGeneral(0, 5);
        callback.setActiveLiquidity(poolId, 100);
        callback.fundStream(poolId, 0, 700 ether, START, DURATION);
        vm.warp(START + 1 days);

        hook.notify(address(callback), poolId);

        (,, int24 referenceTick, uint128 activeLiquidity) = callback.gaugeState(poolId);
        LibRangeGauge.GaugeRewardStream memory stream = callback.stream(poolId, 0);
        assertEq(referenceTick, 0);
        assertEq(activeLiquidity, 100);
        assertEq(stream.lastUpdate, START);
        assertEq(stream.periodEmitted, 0);
    }

    function testOneAndManyRightwardCrossingsUseFinalTick() public {
        (PoolId onePool,) = _readyGeneral(0, 10);
        callback.addRange(onePool, -10, 10, 10, 0, 100);
        callback.setActiveLiquidity(onePool, 100);
        hook.notify(address(callback), onePool);
        (,, int24 oneReference, uint128 oneActive) = callback.gaugeState(onePool);
        assertEq(oneReference, 10);
        assertEq(oneActive, 0);

        RangeGaugeCallbackHarness many = new RangeGaugeCallbackHarness();
        RangeGaugeHookCaller manyHook = new RangeGaugeHookCaller();
        RangeGaugePoolManagerMock manyManager = new RangeGaugePoolManagerMock();
        MockERC20 manyStatics = new MockERC20("Many Statics", "MSTAT", 18);
        PoolKey memory manyKey = _key(address(manyHook));
        PoolId manyPool = many.registerGeneralPool(manyKey, makeAddr("manyCreator"));
        many.initialize(address(manyStatics));
        many.initializeGauge(manyPool, 0);
        many.installPublicIntegration(address(manyManager), address(manyHook));
        manyManager.setTick(manyPool, 20);
        many.addRange(manyPool, -30, 10, 10, 0, 100);
        many.addRange(manyPool, -30, 20, 10, 0, 200);
        many.setActiveLiquidity(manyPool, 300);

        manyHook.notify(address(many), manyPool);

        (,, int24 manyReference, uint128 manyActive) = many.gaugeState(manyPool);
        assertEq(manyReference, 20);
        assertEq(manyActive, 0);
    }

    function testOneAndManyLeftwardCrossingsUseFinalTick() public {
        (PoolId onePool,) = _readyGeneral(0, -11);
        callback.addRange(onePool, -10, 10, 10, 0, 100);
        callback.setActiveLiquidity(onePool, 100);
        hook.notify(address(callback), onePool);
        (,, int24 oneReference, uint128 oneActive) = callback.gaugeState(onePool);
        assertEq(oneReference, -11);
        assertEq(oneActive, 0);

        RangeGaugeCallbackHarness many = new RangeGaugeCallbackHarness();
        RangeGaugeHookCaller manyHook = new RangeGaugeHookCaller();
        RangeGaugePoolManagerMock manyManager = new RangeGaugePoolManagerMock();
        MockERC20 manyStatics = new MockERC20("Many Statics", "MSTAT", 18);
        PoolKey memory manyKey = _key(address(manyHook));
        PoolId manyPool = many.registerGeneralPool(manyKey, makeAddr("manyCreator"));
        many.initialize(address(manyStatics));
        many.initializeGauge(manyPool, 0);
        many.installPublicIntegration(address(manyManager), address(manyHook));
        manyManager.setTick(manyPool, -21);
        many.addRange(manyPool, -20, 30, 10, 0, 100);
        many.addRange(manyPool, -10, 30, 10, 0, 200);
        many.setActiveLiquidity(manyPool, 300);

        manyHook.notify(address(many), manyPool);

        (,, int24 manyReference, uint128 manyActive) = many.gaugeState(manyPool);
        assertEq(manyReference, -21);
        assertEq(manyActive, 0);
    }

    function testStaleReferenceLaterCrossesOnlyRegisteredBoundary() public {
        (PoolId poolId,) = _readyGeneral(0, 5);
        callback.addRange(poolId, -10, 10, 10, 0, 100);
        callback.setActiveLiquidity(poolId, 100);

        hook.notify(address(callback), poolId);
        (,, int24 staleReference, uint128 beforeCrossing) = callback.gaugeState(poolId);
        assertEq(staleReference, 0);
        assertEq(beforeCrossing, 100);

        poolManager.setTick(poolId, 10);
        hook.notify(address(callback), poolId);
        (,, int24 synchronizedReference, uint128 afterCrossing) = callback.gaugeState(poolId);
        assertEq(synchronizedReference, 10);
        assertEq(afterCrossing, 0);
    }

    function testTopologySynchronizationResetsStaleReferenceAndCheckpoints() public {
        (PoolId poolId, PoolKey memory key) = _readyGeneral(0, 2);
        callback.addRange(poolId, -10, 10, key.tickSpacing, 0, 100);
        callback.setActiveLiquidity(poolId, 100);
        callback.fundStream(poolId, 0, 700 ether, START, DURATION);
        vm.warp(START + 1 days);

        hook.notify(address(callback), poolId);
        poolManager.setTick(poolId, 5);
        hook.notify(address(callback), poolId);
        poolManager.setTick(poolId, 7);
        hook.notify(address(callback), poolId);
        (,, int24 staleReference,) = callback.gaugeState(poolId);
        assertEq(staleReference, 0);

        assertFalse(callback.synchronizeTopology(poolId, key.tickSpacing));
        callback.addRange(poolId, 20, 30, key.tickSpacing, 7, 50);

        (,, int24 synchronizedReference, uint128 activeLiquidity) = callback.gaugeState(poolId);
        LibRangeGauge.GaugeRewardStream memory stream = callback.stream(poolId, 0);
        (uint128 gross,,) = callback.boundary(poolId, 20);
        assertEq(synchronizedReference, 7);
        assertEq(activeLiquidity, 100);
        assertEq(stream.lastUpdate, START + 1 days);
        assertEq(stream.periodEmitted, 100 ether);
        assertEq(gross, 50);
    }

    function testSameTimestampOutAndBackDoesNotDoubleEmit() public {
        (PoolId poolId,) = _readyGeneral(0, 10);
        callback.addRange(poolId, -10, 10, 10, 0, 100);
        callback.setActiveLiquidity(poolId, 100);
        callback.fundStream(poolId, 0, 700 ether, START, DURATION);
        vm.warp(START + 1 days);

        hook.notify(address(callback), poolId);
        LibRangeGauge.GaugeRewardStream memory afterRight = callback.stream(poolId, 0);
        poolManager.setTick(poolId, 9);
        hook.notify(address(callback), poolId);

        (,, int24 referenceTick, uint128 activeLiquidity) = callback.gaugeState(poolId);
        LibRangeGauge.GaugeRewardStream memory afterLeft = callback.stream(poolId, 0);
        (,, uint256[5] memory upperOutside) = callback.boundary(poolId, 10);
        assertEq(referenceTick, 9);
        assertEq(activeLiquidity, 100);
        assertEq(afterRight.periodEmitted, 100 ether);
        assertEq(afterLeft.periodEmitted, afterRight.periodEmitted);
        assertEq(afterLeft.globalIndexRay, afterRight.globalIndexRay);
        assertEq(upperOutside[0], 0);
    }

    function testCrossingCheckpointsEveryAssignedStreamOnce() public {
        (PoolId poolId,) = _readyGeneral(0, 10);
        callback.addRange(poolId, -10, 10, 10, 0, 100);
        callback.setActiveLiquidity(poolId, 100);
        for (uint256 slot; slot < 4; ++slot) {
            callback.appendRewardAsset(poolId, address(new MockERC20("Extra", "EXT", 18)));
        }
        for (uint256 slot; slot < 5; ++slot) {
            callback.fundStream(poolId, slot, 700 ether, START, DURATION);
        }
        vm.warp(START + 1 days);

        hook.notify(address(callback), poolId);

        for (uint256 slot; slot < 5; ++slot) {
            LibRangeGauge.GaugeRewardStream memory stream = callback.stream(poolId, slot);
            assertEq(stream.lastUpdate, START + 1 days);
            assertEq(stream.periodEmitted, 100 ether);
        }
    }

    function testRepeatedBoundaryCrossingCannotEraseLowDecimalEmission() public {
        (PoolId poolId, PoolKey memory key) = _readyGeneral(0, 0);
        uint128 baseLiquidity = 1e33;
        callback.addRange(poolId, -100, 100, key.tickSpacing, 0, baseLiquidity);
        callback.addRange(poolId, -10, 10, key.tickSpacing, 0, 1);
        callback.setActiveLiquidity(poolId, baseLiquidity + 1);
        callback.fundStream(poolId, 0, 100e6, START, DURATION);

        for (uint256 hour = 1; hour <= 168; ++hour) {
            vm.warp(START + hour * 1 hours);
            poolManager.setTick(poolId, hour % 2 == 1 ? int256(10) : int256(9));
            hook.notify(address(callback), poolId);
        }
        callback.synchronizeTopology(poolId, key.tickSpacing);

        LibRangeGauge.GaugeRewardStream memory stream = callback.stream(poolId, 0);
        assertEq(stream.periodEmitted, 100e6);
        assertEq(stream.indexedLiability, 100e6);
        assertLt(stream.indexRemainder, 1 << 160);
    }

    function testStoppedGaugeReturnsWithoutPoolReadOrMutation() public {
        (PoolId poolId,) = _readyGeneral(0, 0);
        callback.addRange(poolId, -10, 10, 10, 0, 100);
        callback.setActiveLiquidity(poolId, 100);
        callback.fundStream(poolId, 0, 700 ether, START, DURATION);
        callback.setStopped(poolId, true);
        vm.warp(START + 1 days);

        callback.installPublicIntegration(address(0xDEAD), address(hook));
        hook.notify(address(callback), poolId);

        (, bool stopped, int24 referenceTick, uint128 activeLiquidity) = callback.gaugeState(poolId);
        LibRangeGauge.GaugeRewardStream memory stream = callback.stream(poolId, 0);
        assertTrue(stopped);
        assertEq(referenceTick, 0);
        assertEq(activeLiquidity, 100);
        assertEq(stream.lastUpdate, START);
        assertEq(stream.periodEmitted, 0);
    }

    function testCrossingFailureRollsBackCheckpointAndEarlierBoundary() public {
        (PoolId poolId,) = _readyGeneral(0, 20);
        callback.addRange(poolId, -30, 10, 10, 0, 100);
        callback.addRange(poolId, -30, 20, 10, 0, 200);
        callback.setActiveLiquidity(poolId, 100);
        callback.fundStream(poolId, 0, 700 ether, START, DURATION);
        vm.warp(START + 1 days);

        vm.expectRevert(
            abi.encodeWithSelector(LibRangeGauge.ActiveLiquidityOverflow.selector, uint128(0), int128(-200), true)
        );
        hook.notify(address(callback), poolId);

        (,, int24 referenceTick, uint128 activeLiquidity) = callback.gaugeState(poolId);
        LibRangeGauge.GaugeRewardStream memory stream = callback.stream(poolId, 0);
        (,, uint256[5] memory firstOutside) = callback.boundary(poolId, 10);
        assertEq(referenceTick, 0);
        assertEq(activeLiquidity, 100);
        assertEq(stream.lastUpdate, START);
        assertEq(stream.periodEmitted, 0);
        assertEq(firstOutside[0], 0);
    }

    function _readyGeneral(int256 referenceTick, int256 liveTick) private returns (PoolId poolId, PoolKey memory key) {
        key = _key(address(hook));
        poolId = callback.registerGeneralPool(key, makeAddr("creator"));
        _initialize(poolId, referenceTick, liveTick);
    }

    function _initialize(PoolId poolId, int256 referenceTick, int256 liveTick) private {
        callback.initialize(address(statics));
        callback.initializeGauge(poolId, referenceTick);
        callback.installPublicIntegration(address(poolManager), address(hook));
        poolManager.setTick(poolId, liveTick);
    }

    function _key(address hookAddress) private pure returns (PoolKey memory key) {
        key = PoolKey({
            currency0: Currency.wrap(address(0x1000)),
            currency1: Currency.wrap(address(0x2000)),
            fee: 3_000,
            tickSpacing: 10,
            hooks: IHooks(hookAddress)
        });
    }
}
