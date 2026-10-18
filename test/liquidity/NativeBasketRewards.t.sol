// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IStaticsBasket} from "../../src/interfaces/IStaticsBasket.sol";
import {IStaticsBasketImpairment} from "../../src/interfaces/IStaticsBasketImpairment.sol";
import {IStaticsBasketMarkets} from "../../src/interfaces/IStaticsBasketMarkets.sol";
import {IStaticsBasketSettlement} from "../../src/interfaces/IStaticsBasketSettlement.sol";
import {IStaticsProtocolPools} from "../../src/interfaces/IStaticsProtocolPools.sol";
import {IStaticsProtocolRevenue} from "../../src/interfaces/IStaticsProtocolRevenue.sol";
import {IStaticsSwapFeeHook} from "../../src/interfaces/IStaticsSwapFeeHook.sol";
import {LibCustody} from "../../src/libraries/LibCustody.sol";
import {CanonicalPoolTestBase} from "../helpers/CanonicalPoolTestBase.sol";

contract NativeBasketRewardsTest is CanonicalPoolTestBase {
    using PoolIdLibrary for PoolKey;

    struct NativeMarket {
        uint256 basketId;
        uint256 positionId;
        PoolKey key;
    }

    function testImpairedCollateralExitForfeitsFrozenRewardsAndPaysHealthyRewards() public {
        NativeMarket memory market = _createNativeMarket(true, true);
        _swapNative(market.key);
        vm.prank(alice);
        v4Router.swap(market.key, SwapParams(false, -int256(0.001 ether), TickMath.MAX_SQRT_PRICE - 1));
        IStaticsProtocolPools pools = IStaticsProtocolPools(address(diamond));
        pools.settleProtocolPoolRevenue(market.key.toId(), address(0));
        address basketToken = baskets.basket(market.basketId).token;
        pools.settleProtocolPoolRevenue(market.key.toId(), basketToken);
        (, uint256[] memory earned) = basketRewards.getBasketRewards(market.positionId, market.basketId);
        assertGt(earned[0], 0);
        assertGt(earned[2], 0);
        uint256 reserved = custody.reservedByAccount(LibCustody.feeAccount(), address(wrappedNative));
        IStaticsBasketImpairment impairment = IStaticsBasketImpairment(address(diamond));
        impairment.markBasketAssetImpaired(market.basketId, address(wrappedNative));
        vm.mockCallRevert(address(wrappedNative), abi.encodeWithSelector(IERC20.balanceOf.selector), "frozen");
        vm.mockCallRevert(address(wrappedNative), abi.encodeWithSelector(IERC20.transfer.selector), "frozen");
        vm.prank(alice);
        impairment.redeemImpairedBasketCollateral(
            market.positionId, market.basketId, 0.5 ether, alice, new uint256[](2)
        );
        (, uint256[] memory visible) = basketRewards.getBasketRewards(market.positionId, market.basketId);
        assertEq(visible[0], earned[0]);
        assertEq(visible[2], 0);
        uint256 beforeBalance = IERC20(basketToken).balanceOf(alice);
        vm.prank(alice);
        (, uint256[] memory paid) = basketRewards.claimBasketRewards(market.positionId, market.basketId, alice);
        assertEq(paid[0], earned[0]);
        assertEq(paid[2], 0);
        assertEq(IERC20(basketToken).balanceOf(alice) - beforeBalance, earned[0]);
        assertEq(custody.reservedByAccount(LibCustody.feeAccount(), address(wrappedNative)), reserved);
        assertEq(basketRewards.basketRewardState(market.basketId, address(wrappedNative)).totalClaimable, 0);
    }

    function testCurrencyEligibilityUsesBasketRewardAssetsAndMatureStake() public {
        NativeMarket memory market = _createNativeMarket(true, false);
        IStaticsBasketSettlement settlement = IStaticsBasketSettlement(address(diamond));
        PoolId id = market.key.toId();
        IStaticsBasket.BasketView memory basket = baskets.basket(market.basketId);
        assertFalse(settlement.canAccrueBasketCurrencyRewards(id, basket.token));
        assertFalse(settlement.canAccrueBasketCurrencyRewards(id, address(wrappedNative)));

        vm.warp(block.timestamp + 25 hours);
        assertTrue(settlement.canAccrueBasketCurrencyRewards(id, basket.token));
        for (uint256 i; i < basket.assets.length; ++i) {
            assertTrue(settlement.canAccrueBasketCurrencyRewards(id, basket.assets[i]));
        }
        assertFalse(settlement.canAccrueBasketCurrencyRewards(id, address(stakingAsset)));
        assertFalse(settlement.canAccrueBasketCurrencyRewards(id, address(0)));
        assertFalse(settlement.canAccrueBasketCurrencyRewards(PoolId.wrap(keccak256("unknown")), basket.token));
    }

    function testEligibleSwapAndSettlementDoNotReadFullPoolOrBasketViews() public {
        NativeMarket memory market = _createNativeMarket(true, true);
        vm.mockCallRevert(address(diamond), abi.encodeWithSelector(IStaticsProtocolPools.protocolPool.selector), "");
        vm.mockCallRevert(address(diamond), abi.encodeWithSelector(IStaticsBasket.basket.selector), "");

        uint256 charged = _swapNative(market.key);
        PoolId id = market.key.toId();
        IStaticsSwapFeeHook hook = IStaticsSwapFeeHook(address(market.key.hooks));
        uint256 expectedBasket = charged * 3_000 / 10_000;
        assertEq(hook.pendingFeeDistribution(id, Currency.wrap(address(0))).basketStaker, expectedBasket);
        IStaticsProtocolPools(address(diamond)).settleProtocolPoolRevenue(id, address(0));
        assertEq(hook.pendingFeeDistribution(id, Currency.wrap(address(0))).basketStaker, 0);
        vm.clearMockedCalls();
        _claimWethBasketRewards(market, expectedBasket);
    }

    function testRestrictedStakerRewardsFundAndPayThroughOriginatingPool() public {
        NativeMarket memory market = _createNativeMarket(true, true);
        address token = baskets.basket(market.basketId).token;
        address[] memory rewards = new address[](1);
        rewards[0] = token;
        stakingAsset.mint(bob, 10 ether);
        vm.startPrank(bob);
        stakingAsset.approve(address(diamond), 10 ether);
        uint256 staker = globalRewards.createAndStake(10 ether, bob, rewards);
        vm.stopPrank();
        vm.warp(block.timestamp + 25 hours);

        _swapNative(market.key);
        IStaticsSwapFeeHook hook = IStaticsSwapFeeHook(address(market.key.hooks));
        uint256 pending = hook.pendingStakerRewards(Currency.wrap(token));
        assertGt(pending, 0);
        assertEq(globalRewards.unfundedSwapRewards(token), pending);
        uint256 beforeFunding = IERC20(token).balanceOf(address(diamond));
        assertEq(globalRewards.settlePublicSwapRewards(token, type(uint256).max), pending);
        assertEq(IERC20(token).balanceOf(address(diamond)) - beforeFunding, pending);
        assertEq(hook.pendingStakerRewards(Currency.wrap(token)), 0);
        assertEq(globalRewards.unfundedSwapRewards(token), 0);

        uint256 beforeClaim = IERC20(token).balanceOf(bob);
        vm.prank(bob);
        uint256[] memory claimed = globalRewards.claimRewards(staker, rewards, bob, new uint256[](1));
        assertGt(claimed[0], 0);
        assertLe(claimed[0], pending);
        assertEq(IERC20(token).balanceOf(bob) - beforeClaim, claimed[0]);
    }

    function testNativeFeesPayEligibleWethBasketRewards() public {
        NativeMarket memory market = _createNativeMarket(true, true);
        uint256 charged = _swapNative(market.key);
        PoolId id = market.key.toId();
        IStaticsSwapFeeHook hook = IStaticsSwapFeeHook(address(market.key.hooks));
        IStaticsSwapFeeHook.FeeDistribution memory pending = hook.pendingFeeDistribution(id, Currency.wrap(address(0)));
        uint256 expectedBasket = charged * 3_000 / 10_000;
        assertEq(pending.basketStaker, expectedBasket);
        assertEq(hook.pendingProtocolPol(id, Currency.wrap(address(0))), charged * 1_500 / 10_000);

        IStaticsProtocolPools pools = IStaticsProtocolPools(address(diamond));
        (uint256 gross, uint256 tip) = pools.settleProtocolPoolRevenue(id, address(0));
        assertEq(gross, pending.basketStaker + pending.creator + pending.treasury);
        assertEq(tip, 0);
        assertEq(hook.pendingFeeDistribution(id, Currency.wrap(address(0))).basketStaker, 0);
        _claimWethBasketRewards(market, expectedBasket);
        assertGe(wrappedNative.balanceOf(address(diamond)), custody.globalReservedByToken(address(wrappedNative)));
        assertEq(address(diamond).balance, custody.globalReservedByToken(address(0)));
    }

    function testNativeBasketShareDoesNotInflateZeroPolMaintenanceTip() public {
        NativeMarket memory market = _createNativeMarket(true, true);
        PoolId id = market.key.toId();
        IStaticsProtocolPools pools = IStaticsProtocolPools(address(diamond));
        pools.setProtocolPoolPolShare(id, 0);
        pools.setProtocolPoolMaintenanceConfig(IStaticsProtocolPools.ProtocolPoolMaintenanceConfig(2_000));
        uint256 charged = _swapNative(market.key);
        uint256 expectedBasket = charged * 3_000 / 10_000;
        uint256 expectedTreasury = charged - expectedBasket - charged * 3_000 / 10_000 - charged * 500 / 10_000;
        IStaticsSwapFeeHook hook = IStaticsSwapFeeHook(address(market.key.hooks));
        assertEq(hook.pendingFeeDistribution(id, Currency.wrap(address(0))).basketStaker, expectedBasket);
        assertEq(hook.pendingFeeDistribution(id, Currency.wrap(address(0))).treasury, expectedTreasury);
        assertEq(hook.pendingProtocolPol(id, Currency.wrap(address(0))), 0);

        uint256 callerBefore = wrappedNative.balanceOf(bob);
        uint256 treasuryBefore = globalRewards.treasuryAccrued(address(wrappedNative));
        vm.prank(bob);
        (, uint256 tip) = pools.settleProtocolPoolRevenue(id, address(0));
        assertEq(tip, expectedTreasury * 2_000 / 10_000);
        assertEq(wrappedNative.balanceOf(bob) - callerBefore, tip);
        assertEq(globalRewards.treasuryAccrued(address(wrappedNative)) - treasuryBefore, expectedTreasury - tip);
        _claimWethBasketRewards(market, expectedBasket);
    }

    function testNativeFeesStillFallBackWhenBasketHasNoWeth() public {
        NativeMarket memory market = _createNativeMarket(false, true);
        assertTrue(IStaticsProtocolRevenue(address(diamond)).canAccrueBasketRewards(market.key.toId()));
        _assertNativeBasketFallback(market.key);
    }

    function testNativeFeesStillFallBackBeforeCollateralEligibility() public {
        NativeMarket memory market = _createNativeMarket(true, false);
        assertFalse(IStaticsProtocolRevenue(address(diamond)).canAccrueBasketRewards(market.key.toId()));
        _assertNativeBasketFallback(market.key);
    }

    function testInactivePolPreservesEligibleBasketAndStaticsRewards() public {
        NativeMarket memory market = _createNativeMarket(true, true, false);
        uint256 charged = _swapNative(market.key);
        PoolId id = market.key.toId();
        IStaticsSwapFeeHook hook = IStaticsSwapFeeHook(address(market.key.hooks));
        IStaticsSwapFeeHook.FeeDistribution memory pending = hook.pendingFeeDistribution(id, Currency.wrap(address(0)));
        assertEq(pending.basketStaker, charged * 3000 / 10_000);
        assertEq(hook.pendingStakerRewards(Currency.wrap(address(0))), charged * 3000 / 10_000);
        assertEq(globalRewards.unfundedSwapRewards(address(wrappedNative)), charged * 3000 / 10_000);
        assertEq(hook.pendingProtocolPol(id, Currency.wrap(address(0))), 0);
        assertEq(pending.treasury, charged - pending.basketStaker - charged * 3000 / 10_000 - pending.creator);
        IStaticsProtocolPools(address(diamond)).settleProtocolPoolRevenue(id, address(0));
        _claimWethBasketRewards(market, pending.basketStaker);
    }

    function testInactivePolSendsLostPendingBasketEligibilityToTreasury() public {
        NativeMarket memory market = _createNativeMarket(true, true, false);
        _swapNative(market.key);
        PoolId id = market.key.toId();
        IStaticsSwapFeeHook hook = IStaticsSwapFeeHook(address(market.key.hooks));
        IStaticsSwapFeeHook.FeeDistribution memory before_ = hook.pendingFeeDistribution(id, Currency.wrap(address(0)));
        assertGt(before_.basketStaker, 0);
        vm.prank(guardian);
        governance.quarantineBasket(market.basketId);
        (uint256 gross,) = IStaticsProtocolPools(address(diamond)).settleProtocolPoolRevenue(id, address(0));
        assertEq(gross, before_.basketStaker + before_.creator + before_.treasury);
        assertEq(hook.pendingProtocolPol(id, Currency.wrap(address(0))), 0);
        assertEq(hook.pendingFeeDistribution(id, Currency.wrap(address(0))).basketStaker, 0);
    }

    function _createNativeMarket(bool includesWeth, bool mature) private returns (NativeMarket memory market) {
        return _createNativeMarket(includesWeth, mature, true);
    }

    function _createNativeMarket(bool includesWeth, bool mature, bool activate)
        private
        returns (NativeMarket memory market)
    {
        address token;
        (market.basketId, token, market.positionId) = _createRewardBasket(includesWeth);
        stakingAsset.mint(alice, 10 ether);
        address[] memory rewardAssets = new address[](1);
        rewardAssets[0] = address(wrappedNative);
        vm.startPrank(alice);
        stakingAsset.approve(address(diamond), 10 ether);
        globalRewards.createAndStake(10 ether, alice, rewardAssets);
        vm.stopPrank();
        if (mature) vm.warp(block.timestamp + 25 hours);

        market.key = _createAdditionalNativeMarket(token, activate);
        _approveV4Router(alice, token);
        vm.prank(alice);
        v4Router.modifyLiquidity{value: 0.2 ether}(
            market.key,
            ModifyLiquidityParams(TickMath.minUsableTick(10), TickMath.maxUsableTick(10), int256(0.2 ether), bytes32(0))
        );
    }

    function _createRewardBasket(bool includesWeth)
        private
        returns (uint256 basketId, address token, uint256 positionId)
    {
        IStaticsBasket.CreateBasketParams memory params = _defaultParams(0, 0);
        if (includesWeth) params.assets[1] = address(wrappedNative);
        (IStaticsBasket.PoolLaunchParams[] memory launch, uint256[] memory maximums) =
            _fundDefaultLaunch(params.assets, alice);
        uint256 creationFee = basketAdmin.creationFee();
        vm.prank(alice);
        (basketId, token) = baskets.createBasket{value: creationFee}(params, launch, maximums, type(uint256).max);
        uint256[] memory quote = baskets.quoteMint(basketId, 1 ether);
        vm.startPrank(alice);
        baskets.mint(basketId, 1 ether, alice, quote);
        IERC20(token).approve(address(diamond), 0.5 ether);
        positionId = basketCollateral.createAndDepositBasketCollateral(basketId, 0.5 ether, alice);
        vm.stopPrank();
    }

    function _createAdditionalNativeMarket(address token, bool activate) private returns (PoolKey memory key) {
        IStaticsProtocolPools pools = IStaticsProtocolPools(address(diamond));
        pools.setPoolCreationFee(1 ether);
        IStaticsBasketMarkets markets = IStaticsBasketMarkets(address(diamond));
        IStaticsBasketMarkets.MarketParams memory extra = IStaticsBasketMarkets.MarketParams(
            address(0), token, 3_000, 10, 1 << 96, 1 ether, type(uint256).max, activate
        );
        vm.prank(alice);
        PoolId id = markets.createBasketMarket{value: 1 ether}(extra);
        key = pools.protocolPool(id).key;
    }

    function _swapNative(PoolKey memory key) private returns (uint256 charged) {
        vm.prank(alice);
        v4Router.swap{value: 0.01 ether}(key, SwapParams(true, -int256(0.01 ether), TickMath.MIN_SQRT_PRICE + 1));
        charged = IStaticsSwapFeeHook(address(key.hooks)).claimLiability(Currency.wrap(address(0)));
        assertGt(charged, 0);
    }

    function _assertNativeBasketFallback(PoolKey memory key) private {
        uint256 charged = _swapNative(key);
        IStaticsSwapFeeHook hook = IStaticsSwapFeeHook(address(key.hooks));
        assertEq(hook.pendingFeeDistribution(key.toId(), Currency.wrap(address(0))).basketStaker, 0);
        assertEq(
            hook.pendingProtocolPol(key.toId(), Currency.wrap(address(0))),
            charged * 1_500 / 10_000 + charged * 3_000 / 10_000
        );
    }

    function _claimWethBasketRewards(NativeMarket memory market, uint256 expected) private {
        uint256 beforeBalance = wrappedNative.balanceOf(alice);
        vm.prank(alice);
        (address[] memory assets, uint256[] memory amounts) =
            basketRewards.claimBasketRewards(market.positionId, market.basketId, alice);
        uint256 paid;
        for (uint256 i; i < assets.length; ++i) {
            if (assets[i] == address(wrappedNative)) paid = amounts[i];
        }
        assertEq(paid, expected);
        assertEq(wrappedNative.balanceOf(alice) - beforeBalance, expected);
    }
}
