// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IStaticsCustody} from "../../src/interfaces/IStaticsCustody.sol";
import {IStaticsLiquidityManager} from "../../src/interfaces/IStaticsLiquidityManager.sol";
import {IStaticsPosition} from "../../src/interfaces/IStaticsPosition.sol";
import {IStaticsProtocolPools} from "../../src/interfaces/IStaticsProtocolPools.sol";
import {IStaticsRangeGauge} from "../../src/interfaces/IStaticsRangeGauge.sol";
import {IStaticsSwapFeeHook} from "../../src/interfaces/IStaticsSwapFeeHook.sol";
import {StaticsLiquidityManager} from "../../src/liquidity/StaticsLiquidityManager.sol";
import {LibRangeGauge} from "../../src/libraries/LibRangeGauge.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {CanonicalV4Router} from "../helpers/CanonicalPoolTestBase.sol";
import {RangeGaugeLifecycleTestBase} from "../helpers/RangeGaugeLifecycleTestBase.sol";

contract RangeGaugeInvariantHandler is Test {
    IStaticsRangeGauge private immutable gauge;
    IStaticsProtocolPools private immutable pools;
    CanonicalV4Router private immutable router;
    PoolId private immutable poolId;
    PoolKey private key;
    address private immutable owner;
    address private immutable poolManager;
    address private immutable reward0;
    address private immutable reward1;
    uint256[] private positions;
    uint256 private unmanagedPosm;
    uint256 private managerReplacements;

    bool public accountingViolation;
    uint256 public successfulCalls;

    constructor(
        address diamond,
        CanonicalV4Router router_,
        PoolId poolId_,
        PoolKey memory key_,
        address owner_,
        address poolManager_,
        address reward0_,
        address reward1_
    ) {
        gauge = IStaticsRangeGauge(diamond);
        pools = IStaticsProtocolPools(diamond);
        router = router_;
        poolId = poolId_;
        key = key_;
        owner = owner_;
        poolManager = poolManager_;
        reward0 = reward0_;
        reward1 = reward1_;
        IERC20(Currency.unwrap(key_.currency0)).approve(address(diamond), type(uint256).max);
        IERC20(Currency.unwrap(key_.currency1)).approve(address(diamond), type(uint256).max);
        IERC20(Currency.unwrap(key_.currency0)).approve(address(router_), type(uint256).max);
        IERC20(Currency.unwrap(key_.currency1)).approve(address(router_), type(uint256).max);
        IERC20(reward0_).approve(address(diamond), type(uint256).max);
        IERC20(reward1_).approve(address(diamond), type(uint256).max);
        for (uint256 i; i < 4; ++i) {
            positions.push(IStaticsPosition(diamond).createPosition(address(this)));
        }
    }

    function setUnmanagedPosm(uint256 posmTokenId) external {
        if (unmanagedPosm == 0) unmanagedPosm = posmTokenId;
    }

    function provide(uint256 rawPosition, uint256 rawLiquidity) external {
        uint256 id = _position(rawPosition);
        if (_hasPool(id)) return;
        uint128 liquidity = uint128(bound(rawLiquidity, 1 ether, 5 ether));
        try gauge.provideLiquidity(
            id,
            IStaticsRangeGauge.ProvideLiquidityParams({
                poolId: poolId,
                tickLower: TickMath.minUsableTick(key.tickSpacing),
                tickUpper: TickMath.maxUsableTick(key.tickSpacing),
                liquidity: liquidity,
                amount0Maximum: 10 ether,
                amount1Maximum: 10 ether,
                deadline: block.timestamp + 1 hours
            })
        ) returns (
            IStaticsRangeGauge.LiquidityMovement memory
        ) {
            ++successfulCalls;
        } catch {}
    }

    function attach(uint256 rawPosition) external {
        uint256 id = _position(rawPosition);
        uint256 tokenId = unmanagedPosm;
        if (tokenId == 0 || _hasPool(id)) return;
        (address manager, bool installed) = gauge.liquidityManager();
        if (!installed) return;
        address posm = IStaticsLiquidityManager(manager).positionManager();
        try IERC721(posm).approve(manager, tokenId) {
            try gauge.attachLiquidity(id, poolId, tokenId) returns (IStaticsRangeGauge.LiquidityMovement memory) {
                unmanagedPosm = 0;
                ++successfulCalls;
            } catch {}
        } catch {}
    }

    function increase(uint256 rawPosition, uint256 rawLiquidity) external {
        uint256 id = _position(rawPosition);
        IStaticsRangeGauge.LpLegView memory leg = gauge.lpLeg(id, poolId);
        if (leg.manager == address(0)) return;
        uint128 liquidity = uint128(bound(rawLiquidity, 1, 1 ether));
        try gauge.increaseLiquidity(
            id,
            poolId,
            IStaticsRangeGauge.IncreaseLiquidityParams({
                liquidity: liquidity,
                amount0Maximum: 10 ether,
                amount1Maximum: 10 ether,
                deadline: block.timestamp + 1 hours
            })
        ) returns (
            IStaticsRangeGauge.LiquidityMovement memory
        ) {
            ++successfulCalls;
        } catch {}
    }

    function decrease(uint256 rawPosition, uint256 rawLiquidity) external {
        uint256 id = _position(rawPosition);
        IStaticsRangeGauge.LpLegView memory leg = gauge.lpLeg(id, poolId);
        if (leg.liquidity <= 1) return;
        uint128 liquidity = uint128(bound(rawLiquidity, 1, leg.liquidity - 1));
        try gauge.decreaseLiquidity(
            id,
            poolId,
            IStaticsRangeGauge.DecreaseLiquidityParams({
                liquidity: liquidity, amount0Minimum: 0, amount1Minimum: 0, deadline: block.timestamp + 1 hours
            })
        ) returns (
            IStaticsRangeGauge.LiquidityMovement memory
        ) {
            ++successfulCalls;
        } catch {}
    }

    function rebalance(uint256 rawPosition, uint256 rawRange, uint256 rawLiquidity) external {
        uint256 id = _position(rawPosition);
        if (gauge.lpLeg(id, poolId).manager == address(0)) return;
        int24 halfWidth = rawRange % 2 == 0 ? int24(100) : int24(200);
        uint128 liquidity = uint128(bound(rawLiquidity, 1 ether, 5 ether));
        try gauge.rebalanceLiquidity(
            id,
            poolId,
            IStaticsRangeGauge.RebalanceLiquidityParams({
                tickLower: -halfWidth,
                tickUpper: halfWidth,
                liquidity: liquidity,
                amount0Maximum: 10 ether,
                amount1Maximum: 10 ether,
                amount0Minimum: 0,
                amount1Minimum: 0,
                deadline: block.timestamp + 1 hours
            })
        ) returns (
            IStaticsRangeGauge.LiquidityMovement memory
        ) {
            ++successfulCalls;
        } catch {}
    }

    function fund(uint256 rawAsset, uint256 rawAmount, uint256 rawMinimum) external {
        address asset = rawAsset % 2 == 0 ? reward0 : reward1;
        uint256 amount = bound(rawAmount, 1, 100 ether);
        uint40 minimum = rawMinimum % 2 == 0 ? uint40(0) : uint40(1 days);
        try gauge.fundPoolReward(poolId, asset, amount, minimum) returns (uint256) {
            ++successfulCalls;
        } catch {}
    }

    function claim(uint256 rawPosition, uint256 rawAsset) external {
        address[] memory assets = new address[](1);
        assets[0] = rawAsset % 2 == 0 ? reward0 : reward1;
        uint256[] memory minimums = new uint256[](1);
        try gauge.claimLpRewards(_position(rawPosition), poolId, assets, minimums, address(this)) returns (
            uint256[] memory
        ) {
            ++successfulCalls;
        } catch {}
    }

    function forfeit(uint256 rawPosition, uint256 rawAsset) external {
        address asset = rawAsset % 2 == 0 ? reward0 : reward1;
        try gauge.forfeitLpReward(_position(rawPosition), poolId, asset) returns (uint256) {
            ++successfulCalls;
        } catch {}
    }

    function exit(uint256 rawPosition) external {
        try gauge.exitLiquidity(_position(rawPosition), poolId, 0, 0, block.timestamp + 1 hours) returns (
            IStaticsRangeGauge.LiquidityMovement memory
        ) {
            ++successfulCalls;
        } catch {}
    }

    function swap(uint256 rawDirection, uint256 rawAmount) external {
        bool zeroForOne = rawDirection % 2 == 0;
        uint256 amount = bound(rawAmount, 1e12, 0.01 ether);
        try router.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amount),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            })
        ) returns (
            BalanceDelta
        ) {
            ++successfulCalls;
        } catch {}
    }

    function advanceTime(uint256 rawSeconds) external {
        vm.warp(block.timestamp + bound(rawSeconds, 1, 2 days));
    }

    function changeDuration(uint256 rawDuration) external {
        IStaticsRangeGauge.GaugeRewardStreamView memory before0 = gauge.poolRewardStream(poolId, reward0);
        IStaticsRangeGauge.GaugeRewardStreamView memory before1 = gauge.poolRewardStream(poolId, reward1);
        vm.prank(owner);
        gauge.setGaugeRewardDuration(uint40(bound(rawDuration, 1 days, 30 days)));
        IStaticsRangeGauge.GaugeRewardStreamView memory after0 = gauge.poolRewardStream(poolId, reward0);
        IStaticsRangeGauge.GaugeRewardStreamView memory after1 = gauge.poolRewardStream(poolId, reward1);
        if (before0.periodFinish != after0.periodFinish || before1.periodFinish != after1.periodFinish) {
            accountingViolation = true;
        }
        ++successfulCalls;
    }

    function replaceManager() external {
        if (managerReplacements == 3) return;
        (address current, bool installed) = gauge.liquidityManager();
        if (!installed) return;
        IStaticsLiquidityManager binding = IStaticsLiquidityManager(current);
        StaticsLiquidityManager replacement =
            new StaticsLiquidityManager(address(gauge), binding.positionManager(), poolManager, binding.permit2());
        vm.prank(owner);
        try pools.replaceLiquidityManager(address(replacement)) {
            ++managerReplacements;
            ++successfulCalls;
        } catch {}
    }

    function decommission() external {
        if (pools.protocolPool(poolId).decommissioned) return;
        vm.prank(owner);
        try pools.decommissionGeneralPool(poolId) returns (uint256, uint256) {
            ++successfulCalls;
        } catch {}
    }

    function reconcile(uint256 rawAsset) external {
        address asset = rawAsset % 2 == 0 ? reward0 : reward1;
        IStaticsRangeGauge.GaugePoolView memory poolBefore = gauge.gaugePool(poolId);
        IStaticsRangeGauge.GaugeRewardStreamView memory streamBefore = gauge.poolRewardStream(poolId, asset);
        try gauge.reconcilePoolRewardSurplus(poolId, asset) returns (uint256) {
            if (
                !poolBefore.stopped || poolBefore.unresolvedLegCount != 0
                    || streamBefore.periodBudget != streamBefore.periodEmitted || streamBefore.claimLiability != 0
                    || gauge.poolRewardStream(poolId, asset).indexedLiability != 0
            ) accountingViolation = true;
            ++successfulCalls;
        } catch {}
    }

    function positionAt(uint256 index) external view returns (uint256) {
        return positions[index];
    }

    function positionCount() external view returns (uint256) {
        return positions.length;
    }

    function _position(uint256 rawPosition) private view returns (uint256) {
        return positions[rawPosition % positions.length];
    }

    function _hasPool(uint256 id) private view returns (bool) {
        (PoolId[] memory poolIds,) = gauge.positionGaugePools(id, 0, 1);
        return poolIds.length != 0;
    }
}

contract RangeGaugeInvariantTest is StdInvariant, RangeGaugeLifecycleTestBase {
    RangeGaugeInvariantHandler private handler;
    PoolId private poolId;
    MockERC20 private secondReward;

    function setUp() public override {
        super.setUp();
        poolId = _createRangeGaugePool(alice);
        secondReward = new MockERC20("Invariant Reward", "INV", 18);
        _assignReward(poolId, address(secondReward));
        PoolKey memory key = _poolKey(poolId);
        handler = new RangeGaugeInvariantHandler(
            address(diamond),
            v4Router,
            poolId,
            key,
            address(this),
            address(poolManager),
            address(stakingAsset),
            address(secondReward)
        );
        MockERC20(Currency.unwrap(key.currency0)).mint(address(handler), 1_000_000 ether);
        MockERC20(Currency.unwrap(key.currency1)).mint(address(handler), 1_000_000 ether);
        stakingAsset.mint(address(handler), 1_000_000 ether);
        secondReward.mint(address(handler), 1_000_000 ether);
        uint256 unmanaged = _mintUnmanagedPosition(key, address(handler));
        handler.setUnmanagedPosm(unmanaged);

        bytes4[] memory selectors = new bytes4[](15);
        selectors[0] = handler.provide.selector;
        selectors[1] = handler.attach.selector;
        selectors[2] = handler.increase.selector;
        selectors[3] = handler.decrease.selector;
        selectors[4] = handler.rebalance.selector;
        selectors[5] = handler.fund.selector;
        selectors[6] = handler.claim.selector;
        selectors[7] = handler.forfeit.selector;
        selectors[8] = handler.exit.selector;
        selectors[9] = handler.swap.selector;
        selectors[10] = handler.advanceTime.selector;
        selectors[11] = handler.changeDuration.selector;
        selectors[12] = handler.replaceManager.selector;
        selectors[13] = handler.decommission.selector;
        selectors[14] = handler.reconcile.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariantManagedLiquidityMatchesRangesAndBoundaries() public view {
        IStaticsRangeGauge.GaugePoolView memory gaugePool = rangeGauge.gaugePool(poolId);
        uint128 expectedActive;
        uint64 expectedManaged;
        uint64 expectedUnresolved;
        int24[6] memory boundaries =
            [TickMath.minUsableTick(10), int24(-200), int24(-100), int24(100), int24(200), TickMath.maxUsableTick(10)];
        uint256[6] memory expectedGross;

        for (uint256 i; i < handler.positionCount(); ++i) {
            uint256 positionId = handler.positionAt(i);
            IStaticsRangeGauge.LpLegView memory leg = rangeGauge.lpLeg(positionId, poolId);
            (PoolId[] memory indexedPools,) = rangeGauge.positionGaugePools(positionId, 0, 1);
            if (indexedPools.length != 0) ++expectedUnresolved;
            if (leg.manager == address(0)) continue;
            ++expectedManaged;
            if (leg.tickLower <= gaugePool.referenceTick && gaugePool.referenceTick < leg.tickUpper) {
                expectedActive += leg.liquidity;
            }
            for (uint256 j; j < boundaries.length; ++j) {
                if (boundaries[j] == leg.tickLower || boundaries[j] == leg.tickUpper) {
                    expectedGross[j] += leg.liquidity;
                }
            }
            assertEq(rangeGauge.posmBinding(leg.posmTokenId), LibRangeGauge.bindingFor(positionId, poolId));
            IPositionManager posm = IPositionManager(IStaticsLiquidityManager(leg.manager).positionManager());
            assertEq(IERC721(address(posm)).ownerOf(leg.posmTokenId), leg.manager);
            assertEq(posm.getPositionLiquidity(leg.posmTokenId), leg.liquidity);
            assertEq(address(posm.subscriber(leg.posmTokenId)), address(0));
        }

        assertEq(gaugePool.activeGaugeLiquidity, expectedActive);
        assertEq(gaugePool.managedLegCount, expectedManaged);
        assertEq(gaugePool.unresolvedLegCount, expectedUnresolved);
        for (uint256 i; i < boundaries.length; ++i) {
            uint256 gross = rangeGauge.gaugeBoundary(poolId, boundaries[i]).grossLiquidity;
            assertEq(gross, expectedGross[i]);
            (int24 discovered, bool initialized) = rangeGaugeState.nextGaugeBoundary(poolId, boundaries[i], 10, true);
            assertEq(initialized && discovered == boundaries[i], gross != 0);
        }
    }

    function invariantRewardSlotsAndCustodyRemainConserved() public view {
        IStaticsRangeGauge.PoolRewardConfigView memory config = rangeGauge.poolRewardConfig(poolId);
        assertEq(config.slotCount, 2);
        assertEq(config.assets[0], address(stakingAsset));
        assertEq(config.assets[1], address(secondReward));
        for (uint256 i; i < config.slotCount; ++i) {
            address asset = config.assets[i];
            IStaticsRangeGauge.GaugeRewardStreamView memory stream = rangeGauge.poolRewardStream(poolId, asset);
            (bytes32 account, bool assigned) = rangeGauge.poolRewardCustodyAccount(poolId, asset);
            assertTrue(assigned);
            uint256 scheduled = stream.periodBudget - stream.periodEmitted;
            assertEq(
                custody.reservedByAccount(account, asset), scheduled + stream.indexedLiability + stream.claimLiability
            );
            assertGe(IERC20(asset).balanceOf(address(diamond)), custody.globalReservedByToken(asset));
        }
        assertFalse(handler.accountingViolation());
    }

    function afterInvariant() public view {
        assertGt(handler.successfulCalls(), 0);
    }
}

contract RangeGaugeInvariantPropertiesTest is RangeGaugeLifecycleTestBase {
    function testZeroActiveLiquidityPausesScheduleInRealLifecycle() public {
        PoolId poolId = _createRangeGaugePool(alice);
        uint256 positionId = _createPosition(alice);
        _fundAndApprovePoolAssets(_poolKey(poolId), alice, TOKEN_MAXIMUM);
        vm.prank(alice);
        rangeGauge.provideLiquidity(
            positionId,
            IStaticsRangeGauge.ProvideLiquidityParams({
                poolId: poolId,
                tickLower: 10,
                tickUpper: 20,
                liquidity: INITIAL_LIQUIDITY,
                amount0Maximum: TOKEN_MAXIMUM,
                amount1Maximum: TOKEN_MAXIMUM,
                deadline: block.timestamp + 1 hours
            })
        );
        assertEq(rangeGauge.gaugePool(poolId).activeGaugeLiquidity, 0);
        _fundReward(poolId, stakingAsset, 700 ether);
        IStaticsRangeGauge.GaugeRewardStreamView memory before =
            rangeGauge.poolRewardStream(poolId, address(stakingAsset));
        vm.warp(block.timestamp + 1 days);
        vm.prank(alice);
        rangeGauge.claimLpRewards(positionId, poolId, new address[](0), new uint256[](0), alice);
        IStaticsRangeGauge.GaugeRewardStreamView memory afterPause =
            rangeGauge.poolRewardStream(poolId, address(stakingAsset));
        assertEq(afterPause.periodEmitted, before.periodEmitted);
        assertEq(afterPause.periodBudget, before.periodBudget);
        assertEq(afterPause.periodFinish, before.periodFinish + 1 days);
    }

    function testDurationChangeCannotRewriteLiveStreamFinish() public {
        PoolId poolId = _createRangeGaugePool(alice);
        uint256 positionId = _createPosition(alice);
        _provide(positionId, poolId, alice);
        _fundReward(poolId, stakingAsset, 700 ether);
        uint40 finish = rangeGauge.poolRewardStream(poolId, address(stakingAsset)).periodFinish;
        rangeGauge.setGaugeRewardDuration(1 days);
        assertEq(rangeGauge.poolRewardStream(poolId, address(stakingAsset)).periodFinish, finish);
        stakingAsset.mint(alice, 1 ether);
        vm.startPrank(alice);
        stakingAsset.approve(address(diamond), 1 ether);
        rangeGauge.fundPoolReward(poolId, address(stakingAsset), 1 ether, 0);
        vm.stopPrank();
        assertEq(rangeGauge.poolRewardStream(poolId, address(stakingAsset)).periodFinish, finish);
    }

    function testUnmanagedV4LiquidityNeverChangesGaugeWeight() public {
        PoolId poolId = _createRangeGaugePool(alice);
        _mintUnmanagedPosition(_poolKey(poolId), alice);
        assertEq(rangeGauge.gaugePool(poolId).activeGaugeLiquidity, 0);
        assertEq(rangeGauge.gaugePool(poolId).managedLegCount, 0);
    }

    function testPermanentProtocolLiquidityNeverChangesGaugeWeight() public {
        PoolId poolId = _createRangeGaugePool(alice);
        PoolKey memory key = _poolKey(poolId);
        uint128 liquidity = 1 ether;
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(TickMath.minUsableTick(key.tickSpacing));
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(TickMath.maxUsableTick(key.tickSpacing));
        uint256 amount0 = SqrtPriceMath.getAmount0Delta(1 << 96, sqrtUpper, liquidity, true);
        uint256 amount1 = SqrtPriceMath.getAmount1Delta(sqrtLower, 1 << 96, liquidity, true);
        MockERC20 token0 = MockERC20(Currency.unwrap(key.currency0));
        MockERC20 token1 = MockERC20(Currency.unwrap(key.currency1));
        token0.mint(address(diamond), amount0);
        token1.mint(address(diamond), amount1);
        vm.startPrank(address(diamond));
        token0.approve(address(swapFeeHook), amount0);
        token1.approve(address(swapFeeHook), amount1);
        IStaticsSwapFeeHook.PermanentLiquiditySeed[] memory seeds = new IStaticsSwapFeeHook.PermanentLiquiditySeed[](1);
        seeds[0] = IStaticsSwapFeeHook.PermanentLiquiditySeed({key: key, liquidity: liquidity});
        swapFeeHook.seedPermanentLiquidity(seeds);
        vm.stopPrank();

        assertEq(swapFeeHook.lockedLiquidity(poolId), liquidity);
        assertEq(rangeGauge.gaugePool(poolId).activeGaugeLiquidity, 0);
        assertEq(rangeGauge.gaugePool(poolId).managedLegCount, 0);
    }
}
