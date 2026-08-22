// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IStaticsLiquidityRewards} from "../../src/interfaces/IStaticsLiquidityRewards.sol";
import {IStaticsGlobalRewards} from "../../src/interfaces/IStaticsGlobalRewards.sol";
import {IStaticsProtocolPools} from "../../src/interfaces/IStaticsProtocolPools.sol";
import {IStaticsProtocolRevenue} from "../../src/interfaces/IStaticsProtocolRevenue.sol";
import {IModularPositionNFT} from "../../src/interfaces/IModularPositionNFT.sol";
import {IStaticsPositionFees} from "../../src/interfaces/IStaticsPosition.sol";
import {LibPosition} from "../../src/position/LibPosition.sol";
import {LiquidityRewardsFacet} from "../../src/facets/LiquidityRewardsFacet.sol";
import {ProtocolPoolAdminFacet} from "../../src/facets/ProtocolPoolAdminFacet.sol";
import {StaticsSwapFeeHook} from "../../src/liquidity/StaticsSwapFeeHook.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {GeneralPoolLifecycleTestBase} from "../helpers/GeneralPoolLifecycleTestBase.sol";

/// @notice End-to-end permissionless general-pool lifecycle against real local v4 contracts:
/// create-at-zero-liquidity, add full-range liquidity, stake, activate, swap both directions,
/// accrue PoolId-local LP rewards / creator credit / global staker rewards / POL, form the first POL
/// position from fees, compound, claim, decommission, and prove blocked new exposure while unstake,
/// claim, and external principal exit remain available.
contract GeneralPoolLifecycleTest is GeneralPoolLifecycleTestBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    IStaticsLiquidityRewards private lpRewards;
    IStaticsProtocolRevenue private revenue;
    IStaticsGlobalRewards private staticsStakers;

    address private creator = makeAddr("general-creator");
    address private lp = makeAddr("general-lp");
    address private trader = makeAddr("general-trader");

    function setUp() public override {
        super.setUp();
        lpRewards = IStaticsLiquidityRewards(address(diamond));
        revenue = IStaticsProtocolRevenue(address(diamond));
        staticsStakers = IStaticsGlobalRewards(address(diamond));
    }

    struct Lifecycle {
        address tokenA;
        address tokenB;
        PoolId poolId;
        PoolKey key;
        uint256 lpPositionId;
        uint256 tokenId;
    }

    function testFullGeneralPoolLifecycleAgainstRealV4() public {
        Lifecycle memory ctx;
        ctx.tokenA = _newToken("Alpha");
        ctx.tokenB = _newToken("Beta");
        (ctx.poolId, ctx.key) = _createGeneralPool(ctx.tokenA, ctx.tokenB, 10, creator);

        _assertCreatedWithZeroLiquidity(ctx);
        _stakeAndActivateLp(ctx);
        _swapAccrueAndAssertFees(ctx);
        _assertPolCompoundAndClaims(ctx);
        _decommissionAndProveBlockedNewExposure(ctx);
        _provePreservedExits(ctx);
    }

    function _assertCreatedWithZeroLiquidity(Lifecycle memory ctx) private view {
        assertTrue(pools.isProtocolPool(ctx.poolId));
        assertEq(pools.protocolPoolCreator(ctx.poolId), creator);
        assertEq(swapFeeHook.lockedLiquidity(ctx.poolId), 0);
        (uint160 initializedPrice,,,) = poolManager.getSlot0(ctx.poolId);
        assertEq(initializedPrice, SQRT_PRICE_1_1_LOCAL);
        IStaticsProtocolPools.ProtocolPoolView memory poolView = pools.protocolPool(ctx.poolId);
        assertEq(uint256(poolView.kind), uint256(IStaticsProtocolPools.ProtocolPoolKind.General));
        assertEq(poolView.basketId, 0);
        assertEq(poolView.basketAsset, address(0));
    }

    function _stakeAndActivateLp(Lifecycle memory ctx) private {
        ctx.lpPositionId = _createUserPosition(lp);
        ctx.tokenId = _mintFullRangeGeneralPosition(ctx.key, lp, 5 ether);
        vm.startPrank(lp);
        IERC721(address(positionManagerContract)).approve(address(diamond), ctx.tokenId);
        lpRewards.stakeLiquidityPosition(ctx.lpPositionId, ctx.tokenId);
        vm.stopPrank();
        assertEq(IERC721(address(positionManagerContract)).ownerOf(ctx.tokenId), address(diamond));
        assertTrue(
            IModularPositionNFT(address(diamond))
                .isLegActive(ctx.lpPositionId, LibPosition.liquidityLegKey(address(diamond)))
        );
        // Not yet eligible: next-block activation gate.
        assertFalse(lpRewards.canAccrueLiquidityRewards(ctx.poolId));

        vm.roll(block.number + 1);
        lpRewards.activateLiquidityPosition(ctx.tokenId);
        assertTrue(lpRewards.canAccrueLiquidityRewards(ctx.poolId));
        assertEq(lpRewards.poolLiquidityRewards(ctx.poolId).totalEligibleLiquidity, 5 ether);
    }

    function _swapAccrueAndAssertFees(Lifecycle memory ctx) private {
        // A Statics staker opts into both pool currencies so global staker fees can accrue.
        uint256 traderStakePositionId = _stakeStaticsFor(trader, ctx.tokenA, ctx.tokenB);
        // Advance past the 24h staker eligibility delay so swaps credit the staker directly rather
        // than falling through to treasury.
        vm.warp(block.timestamp + 25 hours);
        vm.roll(block.number + 1);

        // Swap both directions: fees accrue.
        _swapGeneralPool(ctx.key, trader, true, 0.01 ether);
        _swapGeneralPool(ctx.key, trader, false, 0.01 ether);

        // LP rewards accrued PoolId-local.
        vm.prank(lp);
        (, uint256 pending0,, uint256 pending1) = lpRewards.pendingLiquidityRewards(ctx.lpPositionId, ctx.tokenId);
        assertGt(pending0 + pending1, 0, "LP fees not accrued");

        // Creator credit accrued in both currencies (5% of each swap fee).
        assertGt(revenue.creatorRevenue(creator, ctx.tokenA), 0, "creator A not accrued");
        assertGt(revenue.creatorRevenue(creator, ctx.tokenB), 0, "creator B not accrued");

        // Global Statics-staker rewards route to opted-in stakers when eligible, otherwise to the
        // documented treasury fallback. Either way the global-staker leg is accounted for.
        address[] memory rewardQuery = new address[](2);
        rewardQuery[0] = ctx.tokenA;
        rewardQuery[1] = ctx.tokenB;
        uint256[] memory stakerPending = new uint256[](2);
        vm.prank(trader);
        stakerPending = staticsStakers.pendingRewards(traderStakePositionId, rewardQuery);
        uint256 stakerLeg = stakerPending[0] + stakerPending[1] + staticsStakers.treasuryAccrued(ctx.tokenA)
            + staticsStakers.treasuryAccrued(ctx.tokenB);
        assertGt(stakerLeg, 0, "global staker/treasury leg not accrued");
    }

    function _assertPolCompoundAndClaims(Lifecycle memory ctx) private {
        // POL formed from fees: the general pool bootstrapped its first permanent-liquidity position.
        assertGt(swapFeeHook.lockedLiquidity(ctx.poolId), 0, "POL not formed from fees");
        uint128 polAfterFirstSwaps = swapFeeHook.lockedLiquidity(ctx.poolId);

        // Compounding: further swaps grow POL.
        _swapGeneralPool(ctx.key, trader, true, 0.02 ether);
        _swapGeneralPool(ctx.key, trader, false, 0.02 ether);
        assertGe(swapFeeHook.lockedLiquidity(ctx.poolId), polAfterFirstSwaps, "POL did not compound");

        // Claims: LP claim and creator claim pay measured amounts.
        vm.prank(lp);
        (uint256 claimed0, uint256 claimed1) = lpRewards.claimLiquidityRewards(ctx.lpPositionId, ctx.tokenId, lp, 0, 0);
        assertGt(claimed0 + claimed1, 0);

        uint256 creatorABefore = IERC20(ctx.tokenA).balanceOf(creator);
        uint256 owedCreatorA = revenue.creatorRevenue(creator, ctx.tokenA);
        vm.prank(creator);
        (uint256 amount,) = revenue.claimCreatorRevenue(ctx.tokenA, creator, 0);
        assertEq(amount, owedCreatorA);
        assertEq(IERC20(ctx.tokenA).balanceOf(creator) - creatorABefore, owedCreatorA);
        assertEq(revenue.creatorRevenue(creator, ctx.tokenA), 0);
    }

    function _decommissionAndProveBlockedNewExposure(Lifecycle memory ctx) private {
        // Decommission: owner-only terminal transition releasing POL to treasury.
        assertGt(swapFeeHook.lockedLiquidity(ctx.poolId), 0);
        pools.decommissionGeneralPool(ctx.poolId);
        assertTrue(pools.protocolPool(ctx.poolId).decommissioned);

        // Blocked new exposure: swaps and new staking revert on the decommissioned pool.
        MockERC20(Currency.unwrap(ctx.key.currency0)).mint(trader, 0.01 ether);
        _approveV4Router(trader, Currency.unwrap(ctx.key.currency0));
        vm.prank(trader);
        vm.expectRevert();
        v4Router.swap(
            ctx.key,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(uint256(0.01 ether)),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            })
        );

        address lp2 = makeAddr("lp2");
        uint256 lp2PositionId = _createUserPosition(lp2);
        uint256 tokenId2 = _mintFullRangeGeneralPosition(ctx.key, lp2, 1 ether);
        vm.startPrank(lp2);
        IERC721(address(positionManagerContract)).approve(address(diamond), tokenId2);
        vm.expectRevert(abi.encodeWithSelector(LiquidityRewardsFacet.PoolDecommissioned.selector, ctx.poolId));
        lpRewards.stakeLiquidityPosition(lp2PositionId, tokenId2);
        vm.stopPrank();
    }

    function _provePreservedExits(Lifecycle memory ctx) private {
        // Preserved exits: existing staker can still unstake and reclaim principal after decommission.
        vm.prank(lp);
        lpRewards.unstakeLiquidityPosition(ctx.lpPositionId, ctx.tokenId, lp);
        assertEq(IERC721(address(positionManagerContract)).ownerOf(ctx.tokenId), lp);

        // Preserved creator claim of the other currency after decommission.
        uint256 owedCreatorB = revenue.creatorRevenue(creator, ctx.tokenB);
        assertGt(owedCreatorB, 0);
        vm.prank(creator);
        revenue.claimCreatorRevenue(ctx.tokenB, creator, 0);
        assertEq(revenue.creatorRevenue(creator, ctx.tokenB), 0);
    }

    function testSamePairDifferentTickSpacingHasIsolatedPolAndLpAccounting() public {
        address tokenA = _newToken("Gamma");
        address tokenB = _newToken("Delta");
        (PoolId poolLow, PoolKey memory keyLow) = _createGeneralPool(tokenA, tokenB, 10, creator);
        (PoolId poolHigh, PoolKey memory keyHigh) = _createGeneralPool(tokenA, tokenB, 60, creator);
        assertTrue(PoolId.unwrap(poolLow) != PoolId.unwrap(poolHigh));

        // Stake full-range liquidity into only the low-spacing pool.
        uint256 lpPositionId = _createUserPosition(lp);
        uint256 tokenId = _mintFullRangeGeneralPosition(keyLow, lp, 5 ether);
        vm.startPrank(lp);
        IERC721(address(positionManagerContract)).approve(address(diamond), tokenId);
        lpRewards.stakeLiquidityPosition(lpPositionId, tokenId);
        vm.stopPrank();
        vm.roll(block.number + 1);
        lpRewards.activateLiquidityPosition(tokenId);

        // Provide raw external liquidity to the high-spacing pool so it can be swapped.
        _mintFullRangeGeneralPosition(keyHigh, makeAddr("ext-lp"), 5 ether);

        // Swap only the high-spacing pool.
        _swapGeneralPool(keyHigh, trader, true, 0.05 ether);
        _swapGeneralPool(keyHigh, trader, false, 0.05 ether);

        // The low-spacing pool accrued no LP rewards; POL is isolated per PoolId.
        vm.prank(lp);
        (, uint256 low0,, uint256 low1) = lpRewards.pendingLiquidityRewards(lpPositionId, tokenId);
        assertEq(low0 + low1, 0, "low-spacing pool wrongly accrued LP rewards from sibling pool");
        assertEq(swapFeeHook.lockedLiquidity(poolLow), 0, "low-spacing POL not isolated");
        assertGt(swapFeeHook.lockedLiquidity(poolHigh), 0, "high-spacing POL not formed");

        // Now swap the low pool; only its own accounting moves.
        _swapGeneralPool(keyLow, trader, true, 0.05 ether);
        _swapGeneralPool(keyLow, trader, false, 0.05 ether);
        vm.prank(lp);
        (, uint256 lowAfter0,, uint256 lowAfter1) = lpRewards.pendingLiquidityRewards(lpPositionId, tokenId);
        assertGt(lowAfter0 + lowAfter1, 0, "low-spacing pool did not accrue its own LP rewards");
        assertGt(swapFeeHook.lockedLiquidity(poolLow), 0, "low-spacing POL not formed from own swaps");
    }

    function testGeneralPoolHasNoBasketRewardsLendingOrBacking() public {
        address tokenA = _newToken("Epsilon");
        address tokenB = _newToken("Zeta");
        (PoolId poolId,) = _createGeneralPool(tokenA, tokenB, 10, creator);

        // General pools never accrue basket rewards.
        assertFalse(lpRewards.canAccrueBasketRewards(poolId));

        // Routing a basket-staker share to a general pool reverts.
        _fundHook(tokenA, 100);
        vm.prank(address(swapFeeHook));
        vm.expectRevert();
        revenue.routeProtocolSwapFees(
            poolId,
            tokenA,
            IStaticsProtocolRevenue.ProtocolFeeDistribution({
                liquidityProvider: 0, basketStaker: 100, staticsStaker: 0, creator: 0, treasury: 0
            })
        );

        // The view reports no basket association at all.
        IStaticsProtocolPools.ProtocolPoolView memory poolView = pools.protocolPool(poolId);
        assertEq(poolView.basketId, 0);
        assertEq(poolView.basketAsset, address(0));
    }

    function testGeneralPoolDecommissionOnlyByOwner() public {
        address tokenA = _newToken("Eta");
        address tokenB = _newToken("Theta");
        (PoolId poolId,) = _createGeneralPool(tokenA, tokenB, 10, creator);
        // The immutable creator cannot decommission.
        vm.prank(creator);
        vm.expectRevert();
        pools.decommissionGeneralPool(poolId);
        // Owner can.
        pools.decommissionGeneralPool(poolId);
        assertTrue(pools.protocolPool(poolId).decommissioned);
    }

    function _stakeStaticsFor(address user, address rewardA, address rewardB) private returns (uint256 positionId) {
        uint256 fee = IStaticsPositionFees(address(diamond)).positionCreationFee();
        uint256 stakeAmount = 10 ether;
        stakingAsset.mint(user, stakeAmount);
        address[] memory rewards = new address[](2);
        rewards[0] = rewardA;
        rewards[1] = rewardB;
        vm.deal(user, user.balance + fee);
        vm.startPrank(user);
        IERC20(address(stakingAsset)).approve(address(diamond), stakeAmount);
        positionId = staticsStakers.createAndStake{value: fee}(stakeAmount, user, rewards);
        vm.stopPrank();
    }

    function _fundHook(address token, uint256 amount) private {
        _newTokenMint(token, address(swapFeeHook), amount);
        vm.prank(address(swapFeeHook));
        IERC20(token).approve(address(diamond), amount);
    }

    function _newTokenMint(address token, address to, uint256 amount) private {
        // token is a MockERC20 created by _newToken.
        (bool ok,) = token.call(abi.encodeWithSignature("mint(address,uint256)", to, amount));
        require(ok, "mint failed");
    }
}
