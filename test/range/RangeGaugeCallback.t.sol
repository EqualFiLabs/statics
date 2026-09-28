// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {RangeGaugeCallbackFacet} from "../../src/facets/RangeGaugeCallbackFacet.sol";
import {IStaticsMarketTape} from "../../src/interfaces/IStaticsMarketTape.sol";
import {IStaticsProtocolPools} from "../../src/interfaces/IStaticsProtocolPools.sol";
import {LibMarketTape} from "../../src/libraries/LibMarketTape.sol";
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
    bytes32 private constant MARKET_SWAP_RECORDED_TOPIC =
        keccak256("MarketSwapRecorded(bytes32,uint256,int256,uint256,int24,uint24,uint8)");

    struct RecordedMarketSwap {
        bytes32 poolId;
        uint256 sequence;
        int256 poolDelta;
        uint256 staticsFeesPacked;
        int24 finalTick;
        uint24 nativeLpFee;
        uint8 flags;
    }

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
        vm.expectRevert(
            abi.encodeWithSelector(RangeGaugeCallbackFacet.LiquidityIntegrationNotInstalled.selector, false)
        );
        hook.notify(address(callback), PoolId.wrap(bytes32(uint256(1))));
    }

    function testRejectsCallerOtherThanInstalledPublicHook() public {
        callback.installPublicIntegration(makeAddr("poolManager"), address(hook));

        vm.expectRevert(
            abi.encodeWithSelector(RangeGaugeCallbackFacet.OnlyInstalledSwapHook.selector, address(this), address(hook))
        );
        callback.afterStaticsPoolSwap(PoolId.wrap(bytes32(uint256(1))), toBalanceDelta(0, 0), 0, 0, 0);
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
                RangeGaugeCallbackFacet.InvalidSwapPoolKind.selector,
                poolId,
                IStaticsProtocolPools.ProtocolPoolKind.PermissionedGeneral,
                false
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
                RangeGaugeCallbackFacet.SwapPoolHookMismatch.selector, poolId, address(hook), otherHook
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

    function testSwapWithoutManagedBoundaryDoesNotCheckpointGaugeSchedule() public {
        (PoolId poolId,) = _readyGeneral(0, 10);
        uint64 periodBefore = callback.currentGaugePeriod();
        vm.warp(block.timestamp + 7 days);

        hook.notify(address(callback), poolId);

        assertEq(callback.currentGaugePeriod(), periodBefore);
        assertEq(callback.stream(poolId, 0).periodBudget, 0);
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

    function testCanonicalMarketStateRecordsRawDeltaFeesAndTickTime() public {
        (PoolId poolId,) = _readyGeneral(0, 5);
        poolManager.setTickAndLpFee(poolId, 5, 3_000);
        vm.warp(START);
        hook.notify(address(callback), poolId, toBalanceDelta(-100, 90), 7 | uint256(3) << 128, 1);

        IStaticsMarketTape.CanonicalMarketState memory first = callback.canonicalMarketState(poolId);
        assertEq(first.externalVolume0, 100);
        assertEq(first.externalVolume1, 90);
        assertEq(first.staticsFees0, 7);
        assertEq(first.staticsFees1, 3);
        assertEq(first.externalSwapCount, 1);
        assertEq(first.internalSwapCount, 0);
        assertEq(first.sequence, 1);
        assertEq(first.lastTick, 5);
        assertEq(first.lastTimestamp, START);
        assertEq(first.lastFlags, 1);
        assertEq(first.lastNativeLpFee, 3_000);

        vm.warp(START + 60);
        poolManager.setTickAndLpFee(poolId, 7, 3_000);
        hook.notify(address(callback), poolId, toBalanceDelta(-50, 45), 2 | uint256(1) << 128, 1);
        IStaticsMarketTape.CanonicalMarketState memory second = callback.canonicalMarketState(poolId);
        assertEq(second.externalVolume0, 150);
        assertEq(second.externalVolume1, 135);
        assertEq(second.staticsFees0, 9);
        assertEq(second.staticsFees1, 4);
        assertEq(second.externalSwapCount, 2);
        assertEq(second.sequence, 2);
        assertEq(second.tickCumulative, 300);
        assertEq(second.lastTick, 7);
    }

    function testMarketSwapEventPreservesCanonicalPublicExecutionFacts() public {
        (PoolId poolId,) = _readyGeneral(0, 5);
        poolManager.setTickAndLpFee(poolId, 5, 3_000);
        BalanceDelta delta = toBalanceDelta(-100, 90);
        uint256 packedFees = 7 | uint256(3) << 128;
        uint8 flags = LibMarketTape.FLAG_ZERO_FOR_ONE | LibMarketTape.FLAG_EXACT_OUTPUT;

        vm.recordLogs();
        hook.notify(address(callback), poolId, delta, packedFees, flags);

        Vm.Log[] memory events = _marketSwapLogs(vm.getRecordedLogs(), address(callback));
        assertEq(events.length, 1);
        RecordedMarketSwap memory recorded = _decodeMarketSwap(events[0]);
        assertEq(recorded.poolId, PoolId.unwrap(poolId));
        assertEq(recorded.sequence, 1);
        assertEq(recorded.poolDelta, BalanceDelta.unwrap(delta));
        assertEq(recorded.staticsFeesPacked, packedFees);
        assertEq(recorded.finalTick, 5);
        assertEq(recorded.nativeLpFee, 3_000);
        assertEq(recorded.flags, flags);

        IStaticsMarketTape.CanonicalMarketState memory state = callback.canonicalMarketState(poolId);
        assertEq(recorded.sequence, state.sequence);
        assertEq(uint128(recorded.staticsFeesPacked), state.staticsFees0);
        assertEq(uint128(recorded.staticsFeesPacked >> 128), state.staticsFees1);
    }

    function testSequentialMarketSwapEventsUseCanonicalMonotonicSequences() public {
        (PoolId poolId,) = _readyGeneral(0, 0);

        vm.recordLogs();
        hook.notify(address(callback), poolId, toBalanceDelta(-100, 90), 0, 1);
        hook.notify(address(callback), poolId, toBalanceDelta(50, -45), 0, 0);

        Vm.Log[] memory events = _marketSwapLogs(vm.getRecordedLogs(), address(callback));
        assertEq(events.length, 2);
        assertEq(_decodeMarketSwap(events[0]).sequence, 1);
        assertEq(_decodeMarketSwap(events[1]).sequence, 2);
        assertEq(callback.canonicalMarketState(poolId).sequence, 2);
    }

    function testPermissionedNormalizationIsSeparatedFromHeadlineVolume() public {
        PoolKey memory key = _key(address(hook));
        PoolId poolId = callback.registerPermissionedPool(key, makeAddr("creator"));
        callback.installPermissionedIntegration(address(poolManager), address(hook));
        poolManager.setTick(poolId, 3);

        uint8 externalFlags =
            LibMarketTape.FLAG_PERMISSIONED | LibMarketTape.FLAG_ZERO_FOR_ONE | LibMarketTape.FLAG_PARTIAL;
        uint8 internalFlags = LibMarketTape.FLAG_PERMISSIONED | LibMarketTape.FLAG_INTERNAL;
        vm.recordLogs();
        hook.notify(address(callback), poolId, toBalanceDelta(2, -3), 0, internalFlags);
        hook.notify(address(callback), poolId, toBalanceDelta(-100, 90), uint256(4) << 128, externalFlags);

        Vm.Log[] memory events = _marketSwapLogs(vm.getRecordedLogs(), address(callback));
        assertEq(events.length, 2);
        RecordedMarketSwap memory internalSwap = _decodeMarketSwap(events[0]);
        RecordedMarketSwap memory externalSwap = _decodeMarketSwap(events[1]);
        assertEq(internalSwap.sequence, 1);
        assertEq(internalSwap.flags, internalFlags);
        assertEq(internalSwap.flags & LibMarketTape.FLAG_INTERNAL, LibMarketTape.FLAG_INTERNAL);
        assertEq(externalSwap.sequence, 2);
        assertEq(externalSwap.flags, externalFlags);
        assertEq(externalSwap.flags & LibMarketTape.FLAG_PARTIAL, LibMarketTape.FLAG_PARTIAL);

        IStaticsMarketTape.CanonicalMarketState memory state = callback.canonicalMarketState(poolId);
        assertEq(state.externalVolume0, 100);
        assertEq(state.externalVolume1, 90);
        assertEq(state.internalVolume0, 2);
        assertEq(state.internalVolume1, 3);
        assertEq(state.staticsFees0, 0);
        assertEq(state.staticsFees1, 4);
        assertEq(state.externalSwapCount, 1);
        assertEq(state.internalSwapCount, 1);
        assertEq(state.sequence, 2);
    }

    function testCanonicalMarketCountersSaturateWithoutStoppingSwaps() public {
        PoolKey memory key = _key(address(hook));
        PoolId poolId = callback.registerPermissionedPool(key, makeAddr("creator"));
        callback.installPermissionedIntegration(address(poolManager), address(hook));
        callback.primeCanonicalMarketStateForSaturation(poolId);

        hook.notify(address(callback), poolId, toBalanceDelta(-2, 2), 2 | uint256(2) << 128, 5);
        hook.notify(address(callback), poolId, toBalanceDelta(2, -2), 0, 12);

        IStaticsMarketTape.CanonicalMarketState memory state = callback.canonicalMarketState(poolId);
        assertEq(state.externalVolume0, type(uint256).max);
        assertEq(state.externalVolume1, type(uint256).max);
        assertEq(state.internalVolume0, type(uint256).max);
        assertEq(state.internalVolume1, type(uint256).max);
        assertEq(state.staticsFees0, type(uint256).max);
        assertEq(state.staticsFees1, type(uint256).max);
        assertEq(state.externalSwapCount, type(uint256).max);
        assertEq(state.internalSwapCount, type(uint256).max);
        assertEq(state.sequence, type(uint256).max);
        assertEq(state.saturatedFields, type(uint8).max);
    }

    function testMissingObservationFacetDoesNotRollbackCanonicalAccounting() public {
        (PoolId poolId,) = _readyGeneral(0, 0);
        vm.recordLogs();
        hook.notify(address(callback), poolId, toBalanceDelta(-100, 90), 0, 1);

        assertEq(callback.canonicalMarketState(poolId).sequence, 1);
        Vm.Log[] memory events = _marketSwapLogs(vm.getRecordedLogs(), address(callback));
        assertEq(events.length, 1);
        assertEq(_decodeMarketSwap(events[0]).sequence, 1);
        (uint256 failures, uint256 lastSequence) = callback.observationFailures(poolId);
        assertEq(failures, 1);
        assertEq(lastSequence, 1);
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
        uint8 slot = callback.appendRewardAsset(poolId, address(new MockERC20("Reward", "RWD", 18)));
        callback.fundStream(poolId, slot, 700 ether, START, DURATION);
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
        LibRangeGauge.GaugeRewardStream memory stream = callback.stream(poolId, slot);
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
        uint8 slot = callback.appendRewardAsset(poolId, address(new MockERC20("Reward", "RWD", 18)));
        callback.fundStream(poolId, slot, 700 ether, START, DURATION);
        vm.warp(START + 1 days);

        hook.notify(address(callback), poolId);
        LibRangeGauge.GaugeRewardStream memory afterRight = callback.stream(poolId, slot);
        poolManager.setTick(poolId, 9);
        hook.notify(address(callback), poolId);

        (,, int24 referenceTick, uint128 activeLiquidity) = callback.gaugeState(poolId);
        LibRangeGauge.GaugeRewardStream memory afterLeft = callback.stream(poolId, slot);
        (,, uint256[5] memory upperOutside) = callback.boundary(poolId, 10);
        assertEq(referenceTick, 9);
        assertEq(activeLiquidity, 100);
        assertEq(afterRight.periodEmitted, 100 ether);
        assertEq(afterLeft.periodEmitted, afterRight.periodEmitted);
        assertEq(afterLeft.globalIndexRay, afterRight.globalIndexRay);
        assertEq(upperOutside[slot], 0);
    }

    function testCrossingCheckpointsEveryAssignedStreamOnce() public {
        (PoolId poolId,) = _readyGeneral(0, 10);
        callback.addRange(poolId, -10, 10, 10, 0, 100);
        callback.setActiveLiquidity(poolId, 100);
        for (uint256 slot; slot < 4; ++slot) {
            callback.appendRewardAsset(poolId, address(new MockERC20("Extra", "EXT", 18)));
        }
        for (uint256 slot = 1; slot < 5; ++slot) {
            callback.fundStream(poolId, slot, 700 ether, START, DURATION);
        }
        vm.warp(START + 1 days);

        hook.notify(address(callback), poolId);

        LibRangeGauge.GaugeRewardStream memory protocolStream = callback.stream(poolId, 0);
        assertEq(protocolStream.lastUpdate, 0);
        assertEq(protocolStream.periodEmitted, 0);
        for (uint256 slot = 1; slot < 5; ++slot) {
            LibRangeGauge.GaugeRewardStream memory stream = callback.stream(poolId, slot);
            assertEq(stream.lastUpdate, START + 1 days);
            assertEq(stream.periodEmitted, 100 ether);
        }
    }

    function testProtocolRewardsUseOldLiquidityBeforeEachBoundaryCrossing() public {
        (PoolId poolId,) = _readyGeneral(0, 0);
        callback.addRange(poolId, 10, 20, 10, 0, 100);
        callback.setActiveLiquidity(poolId, 100);

        PoolId[] memory pools = new PoolId[](1);
        pools[0] = poolId;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100 ether;
        callback.setGaugeAllocations(1, pools, amounts);
        statics.mint(address(callback), 1_000 ether);
        vm.warp(START);
        assertEq(callback.activateFundedGaugeSchedule(1_000 ether), 40 ether);

        vm.warp(START + 1 days);
        poolManager.setTick(poolId, 10);
        hook.notify(address(callback), poolId);

        uint256 firstReward = Math.mulDiv(40 ether, 1 days, 7 days);
        LibRangeGauge.GaugeRewardStream memory first = callback.stream(poolId, 0);
        assertApproxEqAbs(first.periodBudget, firstReward, 1);
        uint256 firstGrowth = Math.mulDiv(first.periodBudget, uint256(1) << 160, 100);
        assertEq(first.globalIndexRay, firstGrowth);
        (,, uint256[5] memory lowerOutside) = callback.boundary(poolId, 10);
        assertEq(lowerOutside[0], firstGrowth);
        (,,, uint128 firstLiquidity) = callback.gaugeState(poolId);
        assertEq(firstLiquidity, 200);

        vm.warp(START + 2 days);
        poolManager.setTick(poolId, 20);
        hook.notify(address(callback), poolId);

        uint256 totalReward = Math.mulDiv(40 ether, 2 days, 7 days);
        LibRangeGauge.GaugeRewardStream memory second = callback.stream(poolId, 0);
        assertApproxEqAbs(second.periodBudget, totalReward, 2);
        uint256 secondReward = second.periodBudget - first.periodBudget;
        uint256 secondGrowth = Math.mulDiv(secondReward, uint256(1) << 160, 200);
        assertEq(second.globalIndexRay, firstGrowth + secondGrowth);
        (,, uint256[5] memory upperOutside) = callback.boundary(poolId, 20);
        assertEq(upperOutside[0], firstGrowth + secondGrowth);
        (,,, uint128 secondLiquidity) = callback.gaugeState(poolId);
        assertEq(secondLiquidity, 100);
    }

    function testRepeatedBoundaryCrossingCannotEraseLowDecimalEmission() public {
        (PoolId poolId, PoolKey memory key) = _readyGeneral(0, 0);
        uint128 baseLiquidity = 1e33;
        callback.addRange(poolId, -100, 100, key.tickSpacing, 0, baseLiquidity);
        callback.addRange(poolId, -10, 10, key.tickSpacing, 0, 1);
        callback.setActiveLiquidity(poolId, baseLiquidity + 1);
        uint8 slot = callback.appendRewardAsset(poolId, address(new MockERC20("Reward", "RWD", 6)));
        callback.fundStream(poolId, slot, 100e6, START, DURATION);

        for (uint256 hour = 1; hour <= 168; ++hour) {
            vm.warp(START + hour * 1 hours);
            poolManager.setTick(poolId, hour % 2 == 1 ? int256(10) : int256(9));
            hook.notify(address(callback), poolId);
        }
        callback.synchronizeTopology(poolId, key.tickSpacing);

        LibRangeGauge.GaugeRewardStream memory stream = callback.stream(poolId, slot);
        assertEq(stream.periodEmitted, 100e6);
        assertEq(stream.indexedLiability, 100e6);
        assertLt(stream.indexRemainder, 1 << 160);
    }

    function testStoppedGaugeStillRecordsMarketStateWithoutGaugeMutation() public {
        (PoolId poolId,) = _readyGeneral(0, 0);
        callback.addRange(poolId, -10, 10, 10, 0, 100);
        callback.setActiveLiquidity(poolId, 100);
        callback.fundStream(poolId, 0, 700 ether, START, DURATION);
        callback.setStopped(poolId, true);
        vm.warp(START + 1 days);

        vm.recordLogs();
        hook.notify(address(callback), poolId, toBalanceDelta(-100, 90), 0, 1);

        (, bool stopped, int24 referenceTick, uint128 activeLiquidity) = callback.gaugeState(poolId);
        LibRangeGauge.GaugeRewardStream memory stream = callback.stream(poolId, 0);
        assertTrue(stopped);
        assertEq(referenceTick, 0);
        assertEq(activeLiquidity, 100);
        assertEq(stream.lastUpdate, START);
        assertEq(stream.periodEmitted, 0);
        assertEq(callback.canonicalMarketState(poolId).externalSwapCount, 1);
        Vm.Log[] memory events = _marketSwapLogs(vm.getRecordedLogs(), address(callback));
        assertEq(events.length, 1);
        assertEq(_decodeMarketSwap(events[0]).sequence, 1);
    }

    function testMarketSwapEventIsIndependentOfManagedBoundaryCrossing() public {
        (PoolId poolId,) = _readyGeneral(0, 0);
        callback.addRange(poolId, -10, 10, 10, 0, 100);
        callback.setActiveLiquidity(poolId, 100);

        vm.recordLogs();
        hook.notify(address(callback), poolId, toBalanceDelta(-100, 90), 0, 1);
        poolManager.setTick(poolId, 10);
        hook.notify(address(callback), poolId, toBalanceDelta(-50, 45), 0, 1);

        Vm.Log[] memory events = _marketSwapLogs(vm.getRecordedLogs(), address(callback));
        assertEq(events.length, 2);
        assertEq(_decodeMarketSwap(events[0]).sequence, 1);
        assertEq(_decodeMarketSwap(events[1]).sequence, 2);
        (,, int24 referenceTick, uint128 activeLiquidity) = callback.gaugeState(poolId);
        assertEq(referenceTick, 10);
        assertEq(activeLiquidity, 0);
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

    function _marketSwapLogs(Vm.Log[] memory logs, address emitter) private pure returns (Vm.Log[] memory events) {
        uint256 count;
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == emitter && logs[i].topics.length == 3
                    && logs[i].topics[0] == MARKET_SWAP_RECORDED_TOPIC
            ) {
                ++count;
            }
        }
        events = new Vm.Log[](count);
        uint256 cursor;
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == emitter && logs[i].topics.length == 3
                    && logs[i].topics[0] == MARKET_SWAP_RECORDED_TOPIC
            ) {
                events[cursor++] = logs[i];
            }
        }
    }

    function _decodeMarketSwap(Vm.Log memory entry) private pure returns (RecordedMarketSwap memory recorded) {
        recorded.poolId = entry.topics[1];
        recorded.sequence = uint256(entry.topics[2]);
        (recorded.poolDelta, recorded.staticsFeesPacked, recorded.finalTick, recorded.nativeLpFee, recorded.flags) =
            abi.decode(entry.data, (int256, uint256, int24, uint24, uint8));
    }
}
