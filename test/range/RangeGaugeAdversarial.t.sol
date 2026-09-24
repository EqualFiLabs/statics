// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IStaticsProtocolPools} from "../../src/interfaces/IStaticsProtocolPools.sol";
import {IStaticsRangeGauge} from "../../src/interfaces/IStaticsRangeGauge.sol";
import {StaticsLiquidityManager} from "../../src/liquidity/StaticsLiquidityManager.sol";
import {LibRangeGauge} from "../../src/libraries/LibRangeGauge.sol";
import {
    RangeGaugeCallbackHarness,
    RangeGaugeHookCaller,
    RangeGaugePoolManagerMock
} from "../helpers/RangeGaugeCallbackHarness.sol";
import {RangeGaugeLifecycleTestBase} from "../helpers/RangeGaugeLifecycleTestBase.sol";
import {MockERC20, MockFalseReturnERC20} from "../mocks/MockERC20.sol";

contract RangeGaugeAdversarialTest is RangeGaugeLifecycleTestBase {
    uint256 private constant START = 1_000_000;

    function testDenseSparseAndSharedBoundarySpamKeepsBitmapAndNetCoherent() public {
        PoolId poolId = _createRangeGaugePool(alice);
        rangeGaugeState.addGaugeRange(poolId, -800_000, -799_990, 10, 0, 1 ether);
        rangeGaugeState.addGaugeRange(poolId, 799_980, 799_990, 10, 0, 1 ether);
        for (uint256 i; i < 64; ++i) {
            int256 lower = -640 + int256(i * 20);
            rangeGaugeState.addGaugeRange(poolId, lower, lower + 20, 10, 0, 1 ether);
        }

        IStaticsRangeGauge.GaugeBoundaryView memory shared = rangeGauge.gaugeBoundary(poolId, 0);
        assertEq(shared.grossLiquidity, 2 ether);
        assertEq(shared.netLiquidity, 0);

        int24 cursor = -887_270;
        uint256 count;
        while (count < 100) {
            (int24 next, bool initialized) = rangeGaugeState.nextGaugeBoundary(poolId, cursor, 10, false);
            if (!initialized) break;
            assertGt(next, cursor);
            assertGt(rangeGauge.gaugeBoundary(poolId, next).grossLiquidity, 0);
            cursor = next;
            ++count;
        }
        assertEq(count, 69);
    }

    function testProtectedContributionRejectsDustCompressionAndExpiryTopUpKeepsFinish() public {
        PoolId poolId = _createRangeGaugePool(alice);
        uint256 positionId = _createPosition(alice);
        _provide(positionId, poolId, alice);
        vm.warp(START);
        _fundReward(poolId, stakingAsset, 700 ether);
        uint8 staticsSlot = _ordinaryRewardSlot(poolId, address(stakingAsset));
        uint40 finish = rangeGauge.poolRewardStream(poolId, staticsSlot).periodFinish;

        vm.warp(finish - 1 hours);
        stakingAsset.mint(bob, 100 ether);
        vm.startPrank(bob);
        stakingAsset.approve(address(diamond), type(uint256).max);
        vm.expectRevert(
            abi.encodeWithSelector(
                IStaticsRangeGauge.MinimumRemainingDurationNotMet.selector, uint40(1 hours), uint40(1 days)
            )
        );
        rangeGauge.fundPoolReward(poolId, staticsSlot, 100 ether, uint40(1 days));
        rangeGauge.fundPoolReward(poolId, staticsSlot, 1, 0);
        vm.stopPrank();

        IStaticsRangeGauge.GaugeRewardStreamView memory stream = rangeGauge.poolRewardStream(poolId, staticsSlot);
        assertEq(stream.periodFinish, finish);
        uint256 expectedRemaining = 700 ether - Math.mulDiv(700 ether, 7 days - 1 hours, 7 days);
        assertEq(stream.periodBudget - stream.periodEmitted, expectedRemaining + 1);
    }

    function testManagerReplacementAcrossEmptyActiveAndClaimOnlyStates() public {
        PoolId poolId = _createRangeGaugePool(alice);
        StaticsLiquidityManager first = _replacement();
        IStaticsProtocolPools(address(diamond)).replaceLiquidityManager(address(first));

        uint256 positionId = _createPosition(alice);
        _provide(positionId, poolId, alice);
        assertEq(rangeGauge.lpLeg(positionId, poolId).manager, address(first));
        _fundReward(poolId, stakingAsset, 700 ether);
        uint8 staticsSlot = _ordinaryRewardSlot(poolId, address(stakingAsset));
        vm.warp(block.timestamp + 1 days);

        StaticsLiquidityManager second = _replacement();
        IStaticsProtocolPools(address(diamond)).replaceLiquidityManager(address(second));
        _exit(positionId, poolId, alice);
        IStaticsRangeGauge.LpLegView memory stub = rangeGauge.lpLeg(positionId, poolId);
        assertEq(stub.manager, address(0));
        assertEq(stub.claimable[staticsSlot], 100 ether);

        StaticsLiquidityManager third = _replacement();
        IStaticsProtocolPools(address(diamond)).replaceLiquidityManager(address(third));
        assertEq(_claim(positionId, poolId, address(stakingAsset), 100 ether, bob, alice), 100 ether);
        assertEq(rangeGauge.gaugePool(poolId).unresolvedLegCount, 0);
    }

    function testFalseReturnRewardCannotCreateUnbackedLiability() public {
        PoolId poolId = _createRangeGaugePool(alice);
        MockFalseReturnERC20 malformed = new MockFalseReturnERC20();
        uint8 malformedSlot = _assignReward(poolId, address(malformed));
        malformed.mint(alice, 100 ether);
        vm.startPrank(alice);
        malformed.approve(address(diamond), type(uint256).max);
        malformed.setTransfersReturnFalse(true);
        vm.expectRevert();
        rangeGauge.fundPoolReward(poolId, malformedSlot, 100 ether, 0);
        vm.stopPrank();

        IStaticsRangeGauge.GaugeRewardStreamView memory stream = rangeGauge.poolRewardStream(poolId, malformedSlot);
        (bytes32 account,) = rangeGauge.poolRewardCustodyAccount(poolId, malformedSlot);
        assertEq(stream.periodBudget, 0);
        assertEq(stream.indexedLiability, 0);
        assertEq(stream.claimLiability, 0);
        assertEq(custody.reservedByAccount(account, address(malformed)), 0);
        assertEq(malformed.balanceOf(address(diamond)), 0);
    }

    function testDecommissionWithOnlyScheduledLiabilityMovesItWithoutTokenCall() public {
        PoolId poolId = _createRangeGaugePool(alice);
        _fundReward(poolId, stakingAsset, 700 ether);
        uint8 staticsSlot = _ordinaryRewardSlot(poolId, address(stakingAsset));
        uint256 treasuryBefore = globalRewards.treasuryAccrued(address(stakingAsset));
        IStaticsProtocolPools(address(diamond)).decommissionGeneralPool(poolId);

        IStaticsRangeGauge.GaugeRewardStreamView memory stream = rangeGauge.poolRewardStream(poolId, staticsSlot);
        assertEq(stream.periodBudget, stream.periodEmitted);
        assertEq(stream.indexedLiability, 0);
        assertEq(stream.claimLiability, 0);
        assertEq(globalRewards.treasuryAccrued(address(stakingAsset)) - treasuryBefore, 700 ether);
        vm.prank(bob);
        assertEq(rangeGauge.reconcilePoolRewardSurplus(poolId, staticsSlot), 0);
    }

    function testSameTimestampSwapCrossingAndRealRebalancePreserveAccounting() public {
        PoolId poolId = _createRangeGaugePool(alice);
        PoolKey memory key = _poolKey(poolId);
        uint256 positionId = _createPosition(alice);
        _fundAndApprovePoolAssets(key, alice, TOKEN_MAXIMUM);
        vm.prank(alice);
        rangeGauge.provideLiquidity(
            positionId,
            IStaticsRangeGauge.ProvideLiquidityParams({
                poolId: poolId,
                tickLower: -100,
                tickUpper: 100,
                liquidity: INITIAL_LIQUIDITY,
                amount0Maximum: TOKEN_MAXIMUM,
                amount1Maximum: TOKEN_MAXIMUM,
                deadline: block.timestamp + 1 hours
            })
        );
        _fundReward(poolId, stakingAsset, 700 ether);
        uint8 staticsSlot = _ordinaryRewardSlot(poolId, address(stakingAsset));
        vm.warp(block.timestamp + 1 days);

        _mintUnmanagedPosition(key, bob);
        _fundAndApprovePoolAssets(key, bob, TOKEN_MAXIMUM);
        _approveV4Router(bob, Currency.unwrap(key.currency0));
        _approveV4Router(bob, Currency.unwrap(key.currency1));
        vm.prank(bob);
        v4Router.swap(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: -int256(1 ether), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            })
        );

        IStaticsRangeGauge.GaugePoolView memory afterSwap = rangeGauge.gaugePool(poolId);
        IStaticsRangeGauge.GaugeRewardStreamView memory streamAfterSwap =
            rangeGauge.poolRewardStream(poolId, staticsSlot);
        assertEq(afterSwap.activeGaugeLiquidity, 0);

        _fundAndApprovePoolAssets(key, alice, TOKEN_MAXIMUM);
        vm.prank(alice);
        rangeGauge.rebalanceLiquidity(
            positionId,
            poolId,
            IStaticsRangeGauge.RebalanceLiquidityParams({
                tickLower: TickMath.minUsableTick(key.tickSpacing),
                tickUpper: TickMath.maxUsableTick(key.tickSpacing),
                liquidity: INITIAL_LIQUIDITY,
                amount0Maximum: TOKEN_MAXIMUM,
                amount1Maximum: TOKEN_MAXIMUM,
                amount0Minimum: 0,
                amount1Minimum: 0,
                deadline: block.timestamp + 1 hours
            })
        );

        IStaticsRangeGauge.GaugePoolView memory afterRebalance = rangeGauge.gaugePool(poolId);
        IStaticsRangeGauge.GaugeRewardStreamView memory streamAfterRebalance =
            rangeGauge.poolRewardStream(poolId, staticsSlot);
        assertEq(afterRebalance.referenceTick, afterSwap.referenceTick);
        assertEq(afterRebalance.activeGaugeLiquidity, INITIAL_LIQUIDITY);
        assertEq(streamAfterRebalance.periodEmitted, streamAfterSwap.periodEmitted);
        assertEq(streamAfterRebalance.globalIndexRay, streamAfterSwap.globalIndexRay);
        assertGt(rangeGauge.lpLeg(positionId, poolId).claimable[staticsSlot], 0);
    }

    function _replacement() private returns (StaticsLiquidityManager manager) {
        manager = new StaticsLiquidityManager(
            address(diamond), address(rangePositionManager), address(poolManager), address(rangePermit2)
        );
    }
}

contract RangeGaugeAdversarialCallbackTest is Test {
    using PoolIdLibrary for PoolKey;

    uint256 private constant START = 1_000_000;
    uint256 private constant DURATION = 7 days;

    function testSameTimestampLargeJumpAcrossOneHundredTwentyEightBoundaries() public {
        (
            RangeGaugeCallbackHarness callback,
            RangeGaugeHookCaller hook,
            RangeGaugePoolManagerMock manager,
            PoolId poolId
        ) = _ready(0, 1_280);
        for (uint256 i; i < 128; ++i) {
            callback.addRange(poolId, -1_000, int256((i + 1) * 10), 10, 0, 1);
        }
        callback.setActiveLiquidity(poolId, 128);
        callback.fundStream(poolId, 0, 700 ether, START, DURATION);
        vm.warp(START + 1 days);
        hook.notify(address(callback), poolId);
        LibRangeGauge.GaugeRewardStream memory afterJump = callback.stream(poolId, 0);

        manager.setTick(poolId, 1_279);
        hook.notify(address(callback), poolId);
        callback.synchronizeTopology(poolId, 10);
        LibRangeGauge.GaugeRewardStream memory sameTimestamp = callback.stream(poolId, 0);
        (,, int24 referenceTick, uint128 activeLiquidity) = callback.gaugeState(poolId);
        assertEq(referenceTick, 1_279);
        assertEq(activeLiquidity, 1);
        assertEq(sameTimestamp.periodEmitted, afterJump.periodEmitted);
        assertEq(sameTimestamp.globalIndexRay, afterJump.globalIndexRay);
    }

    function testCallbackFailureRollsBackCheckpointAndEarlierCrossing() public {
        (RangeGaugeCallbackHarness callback, RangeGaugeHookCaller hook,, PoolId poolId) = _ready(0, 20);
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
        (,, uint256[5] memory outside) = callback.boundary(poolId, 10);
        assertEq(referenceTick, 0);
        assertEq(activeLiquidity, 100);
        assertEq(stream.periodEmitted, 0);
        assertEq(outside[0], 0);
    }

    function _ready(int256 referenceTick, int256 liveTick)
        private
        returns (
            RangeGaugeCallbackHarness callback,
            RangeGaugeHookCaller hook,
            RangeGaugePoolManagerMock manager,
            PoolId poolId
        )
    {
        callback = new RangeGaugeCallbackHarness();
        hook = new RangeGaugeHookCaller();
        manager = new RangeGaugePoolManagerMock();
        MockERC20 statics = new MockERC20("Statics", "STATICS", 18);
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0x1000)),
            currency1: Currency.wrap(address(0x2000)),
            fee: 3_000,
            tickSpacing: 10,
            hooks: IHooks(address(hook))
        });
        poolId = callback.registerGeneralPool(key, address(this));
        callback.initialize(address(statics));
        callback.initializeGauge(poolId, referenceTick);
        callback.installPublicIntegration(address(manager), address(hook));
        manager.setTick(poolId, liveTick);
    }
}
