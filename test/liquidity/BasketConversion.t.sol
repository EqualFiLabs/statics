// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IStaticsBasketMarkets} from "../../src/interfaces/IStaticsBasketMarkets.sol";
import {IStaticsProtocolPools} from "../../src/interfaces/IStaticsProtocolPools.sol";
import {IStaticsBasketImpairment} from "../../src/interfaces/IStaticsBasketImpairment.sol";
import {BasketConversionRoute, BasketConversionRequest} from "../../src/interfaces/IStaticsBasketConversionRoutes.sol";
import {BasketConversionStep, BasketConversionBounds} from "../../src/liquidity/StaticsBasketConversionRouter.sol";
import {LibBasketConversion} from "../../src/libraries/LibBasketConversion.sol";
import {BasketConversionTestBase} from "../helpers/BasketConversionTestBase.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

contract BasketConversionTest is BasketConversionTestBase {
    using PoolIdLibrary for PoolKey;

    function testRealHookBuyPrefundedSellAndBacking() public {
        Fixture memory f = _fixture(false);
        int256 paid = _trade(f, true, 10 ether, false, false);
        assertLt(paid, 0);
        assertEq(IERC20(f.token).balanceOf(alice), 10 ether);
        _assertBacking(f);
        assertGt(_trade(f, false, 5 ether, true, false), 0);
        assertEq(IERC20(f.token).balanceOf(alice), 5 ether);
        _assertBacking(f);
    }

    function testSharedHookSeparatesBasketsAndQuotes() public {
        Fixture memory a = _fixture(false);
        Fixture memory b = _fixture(true);
        address otherQuote = address(new MockERC20("Other", "O", 18));
        _seedUnderlying(address(assetA), otherQuote);
        _seedUnderlying(address(assetB), otherQuote);
        _approveQuote(otherQuote);
        Fixture memory c = abi.decode(abi.encode(a), (Fixture));
        c.poolId = conversion.createBasketConversionMarket{value: 1}(a.basketId, otherQuote, 1, block.timestamp);
        c.key = conversion.basketConversionMarket(c.poolId).key;
        c.routes = new BasketConversionRoute[](2);
        c.routes[0] = _route(otherQuote, address(assetA));
        c.routes[1] = _route(otherQuote, address(assetB));
        conversionHook.setPreset(a.poolId, true, a.routes);
        _trade(a, true, 10 ether, false, true);
        _trade(b, true, 7 ether, false, false);
        _trade(c, true, 3 ether, false, false);
        assertEq(IERC20(a.token).balanceOf(alice), 13 ether);
        assertEq(IERC20(b.token).balanceOf(alice), 7 ether);
        assertEq(conversionHook.preset(c.poolId, true).length, 0);
        _trade(b, false, 2 ether, true, false);
        _trade(c, false, 1 ether, true, false);
        _assertBacking(a);
        _assertBacking(b);
    }

    function testZapAndHookHaveIdenticalCostAndBacking() public {
        Fixture memory f = _fixture(true);
        uint256 snapshot = vm.snapshotState();
        uint256 hookCost = uint256(-_trade(f, true, 10 ether, false, false));
        uint256 backing = baskets.vaultBalance(f.basketId, address(assetA));
        assertTrue(vm.revertToState(snapshot));
        vm.prank(alice);
        uint256 zapCost = conversionZap.buy(f.poolId, 10 ether, alice, _request(f, true, false));
        assertEq(zapCost, hookCost);
        assertEq(baskets.vaultBalance(f.basketId, address(assetA)), backing);
        vm.prank(alice);
        assertGt(conversionZap.sell(f.poolId, 10 ether, alice, _request(f, false, false)), 0);
        _assertBacking(f);
    }

    function testZapBuyResolvesMarketOnce() public {
        Fixture memory f = _fixture(false);
        vm.expectCall(address(diamond), abi.encodeCall(conversion.basketConversionMarket, (f.poolId)), uint64(1));
        vm.prank(alice);
        conversionZap.buy(f.poolId, 1 ether, alice, _request(f, true, false));
        _assertBacking(f);
    }

    function testHookAndZapUseSameDirectionalPresetAndCallerBounds() public {
        Fixture memory f = _fixture(false);
        conversionHook.setPreset(f.poolId, true, f.routes);
        conversionHook.setPreset(f.poolId, false, f.routes);
        uint256 snapshot = vm.snapshotState();
        int256 callerCost = _trade(f, true, 10 ether, false, false);
        assertTrue(vm.revertToState(snapshot));
        assertEq(_trade(f, true, 10 ether, false, true), callerCost);
        BasketConversionRequest memory r = _request(f, false, true);
        vm.prank(alice);
        assertGt(conversionZap.sell(f.poolId, 1 ether, alice, r), 0);
        r = _request(f, true, true);
        r.routeLimits[0] = 0;
        vm.prank(alice);
        vm.expectRevert(LibBasketConversion.ConversionBound.selector);
        conversionZap.buy(f.poolId, 1 ether, alice, r);
    }

    function testSellNeedsPhysicalInventoryAndDiamondAllowance() public {
        Fixture memory f = _fixture(false);
        _trade(f, true, 10 ether, false, false);
        uint256 beforeSupply = IERC20(f.token).totalSupply();
        vm.expectRevert();
        _trade(f, false, 1 ether, false, false);
        assertEq(IERC20(f.token).totalSupply(), beforeSupply);
        vm.prank(alice);
        IERC20(f.token).approve(address(diamond), 0);
        vm.expectRevert();
        _trade(f, false, 1 ether, true, false);
        assertEq(IERC20(f.token).totalSupply(), beforeSupply);
    }

    function testZapDistributorRevocationAndAllowancesAreEnforced() public {
        Fixture memory f = _fixture(false);
        _trade(f, true, 10 ether, false, false);
        basketAdmin.setBasketDistributor(address(conversionZap), false);
        vm.prank(alice);
        vm.expectRevert();
        conversionZap.sell(f.poolId, 1 ether, alice, _request(f, false, false));
        basketAdmin.setBasketDistributor(address(conversionZap), true);
        vm.prank(alice);
        IERC20(f.token).approve(address(conversionZap), 0);
        vm.prank(alice);
        vm.expectRevert();
        conversionZap.sell(f.poolId, 1 ether, alice, _request(f, false, false));
    }

    function testCannotInitializeEarlyAddLiquidityOrReplayCallbacks() public {
        Fixture memory f = _fixture(false);
        PoolKey memory key = _key(f.token, address(assetA), address(conversionHook), 0, 1);
        vm.expectRevert();
        pm.initialize(key, uint160(1 << 96));
        vm.expectRevert();
        liquidityRouter.modifyLiquidity(f.key, ModifyLiquidityParams(-100, 100, 1 ether, bytes32(0)));
        vm.expectRevert(LibBasketConversion.UnauthorizedConversionCallback.selector);
        conversionZap.unlockCallback("");
        vm.expectRevert(LibBasketConversion.UnauthorizedConversionCallback.selector);
        conversionRouter.unlockCallback("");
        vm.expectRevert(LibBasketConversion.UnauthorizedConversionCallback.selector);
        conversionHook.deliverBasketConversion(f.poolId, f.basketId, 1 ether, alice, new uint256[](2));
        vm.prank(address(diamond));
        vm.expectRevert(LibBasketConversion.UnauthorizedConversionCallback.selector);
        conversionZap.deliverBasketConversion(f.poolId, f.basketId, 1 ether, alice, new uint256[](2));
    }

    function testDeadlinesBoundsAndDustRollback() public {
        Fixture memory f = _fixture(false);
        deal(address(assetA), address(conversionHook), 1 ether);
        deal(address(assetA), address(conversionZap), 1 ether);
        deal(address(assetA), address(diamond), IERC20(address(assetA)).balanceOf(address(diamond)) + 1 ether);
        BasketConversionRequest memory r = _request(f, true, false);
        r.limit = 1;
        vm.prank(alice);
        vm.expectRevert(LibBasketConversion.ConversionBound.selector);
        conversionZap.buy(f.poolId, 10 ether, alice, r);
        assertEq(IERC20(f.token).totalSupply(), 0);
        r = _request(f, true, false);
        vm.warp(block.timestamp + 1);
        vm.prank(alice);
        vm.expectRevert(LibBasketConversion.ConversionExpired.selector);
        conversionZap.buy(f.poolId, 10 ether, alice, r);
        _trade(f, true, 10 ether, false, false);
        assertEq(IERC20(address(assetA)).balanceOf(address(conversionHook)), 1 ether);
        vm.prank(alice);
        conversionZap.sell(f.poolId, 1 ether, alice, _request(f, false, false));
        assertEq(IERC20(address(assetA)).balanceOf(address(conversionZap)), 1 ether);
        _assertBacking(f);
    }

    function testRejectRecursiveRoutesAndUnauthorizedPresetChanges() public {
        Fixture memory f = _fixture(false);
        vm.prank(alice);
        vm.expectRevert();
        conversionHook.setPreset(f.poolId, true, f.routes);
        BasketConversionRequest memory r = _request(f, true, false);
        r.routes[0].pools[0].hooks = IHooks(address(conversionHook));
        vm.prank(alice);
        vm.expectRevert(LibBasketConversion.InvalidConversionRoute.selector);
        conversionZap.buy(f.poolId, 1 ether, alice, r);
        assertEq(IERC20(f.token).totalSupply(), 0);
    }

    function testImpairmentPauseAndMarketRetirementRejectConversion() public {
        Fixture memory f = _fixture(false);
        _trade(f, true, 10 ether, false, false);
        governance.pauseProtocolSwaps();
        vm.expectRevert();
        _trade(f, false, 1 ether, true, false);
        governance.unpauseProtocolSwaps();
        uint256 snapshot = vm.snapshotState();
        conversion.decommissionBasketConversionMarket(f.poolId);
        vm.expectRevert();
        _trade(f, true, 1 ether, false, false);
        assertTrue(vm.revertToState(snapshot));
        IStaticsBasketImpairment(address(diamond)).markBasketAssetImpaired(f.basketId, address(assetA));
        vm.expectRevert();
        _trade(f, false, 1 ether, true, false);
        vm.prank(alice);
        IStaticsBasketImpairment(address(diamond)).redeemImpaired(f.basketId, 1 ether, alice, new uint256[](2));
        assertEq(IERC20(f.token).balanceOf(alice), 9 ether);
    }

    function testConversionIsNotAnAmmAndQuarantineIsPoolLocal() public {
        Fixture memory a = _fixture(false);
        Fixture memory b = _fixture(true);
        assertFalse(IStaticsProtocolPools(address(diamond)).isProtocolPool(a.poolId));
        vm.expectRevert();
        IStaticsProtocolPools(address(diamond)).activateProtocolPoolPol(a.poolId);
        governance.quarantineProtocolPool(a.poolId);
        vm.prank(alice);
        vm.expectRevert(LibBasketConversion.ConversionUnavailable.selector);
        conversionZap.buy(a.poolId, 1 ether, alice, _request(a, true, false));
        assertEq(IERC20(a.token).totalSupply(), 0);
        vm.expectRevert();
        _trade(a, true, 1 ether, false, false);
        _trade(b, true, 1 ether, false, false);
        governance.releaseProtocolPoolQuarantine(a.poolId);
        _trade(a, true, 1 ether, false, false);
    }

    function _arbitrage(bool premium) private {
        Fixture memory f = _fixture(false);
        vm.prank(alice);
        uint256 cost = conversionZap.buy(f.poolId, 1000 ether, alice, _request(f, true, false));
        uint256 price = premium ? cost / 500 : cost / 2000;
        IStaticsBasketMarkets.MarketParams memory p = IStaticsBasketMarkets.MarketParams(
            f.token,
            quoteToken,
            500,
            10,
            uint160(Math.sqrt(Math.mulDiv(price, 1 << 192, 1 ether))),
            1,
            block.timestamp,
            false
        );
        IStaticsBasketMarkets(address(diamond)).createBasketMarket{value: 1}(p);
        PoolKey memory secondary = _key(f.token, quoteToken, address(_localBasketHook), 500, 10);
        vm.prank(alice);
        liquidityRouter.modifyLiquidity(secondary, ModifyLiquidityParams(-887270, 887270, 1 ether, bytes32(0)));
        BasketConversionStep[] memory steps = new BasketConversionStep[](2);
        BasketConversionStep memory convert = _step(
            f.key,
            premium ? quoteToken : f.token,
            premium ? int256(1 ether) : -int256(1 ether),
            abi.encode(_request(f, premium, false))
        );
        BasketConversionStep memory market =
            _step(secondary, premium ? f.token : quoteToken, premium ? -int256(1 ether) : int256(1 ether), "");
        steps[0] = premium ? convert : market;
        steps[1] = premium ? market : convert;
        uint256 beforeQuote = IERC20(quoteToken).balanceOf(alice);
        uint256 beforeBasket = IERC20(f.token).balanceOf(alice);
        vm.prank(alice);
        IERC20(quoteToken).approve(address(conversionRouter), 0);
        vm.prank(alice);
        int256 profit = conversionRouter.execute(f.poolId, steps, 0, BasketConversionBounds(0, 1, 0, block.timestamp));
        assertGt(profit, 0);
        assertEq(IERC20(quoteToken).balanceOf(alice) - beforeQuote, uint256(profit));
        assertEq(IERC20(f.token).balanceOf(alice), beforeBasket);
        _assertBacking(f);
    }

    function testMintSellArbitrageWithNoQuoteAllowance() public {
        _arbitrage(true);
    }

    function testBuyRedeemArbitrageWithNoQuoteAllowance() public {
        _arbitrage(false);
    }

    function testFuzzRoundTripMaintainsBacking(uint256 shares) public {
        Fixture memory f = _fixture(false);
        shares = bound(shares, 0.01 ether, 1000 ether);
        _trade(f, true, shares, false, false);
        _assertBacking(f);
        _trade(f, false, shares, true, false);
        assertEq(IERC20(f.token).totalSupply(), 0);
        _assertBacking(f);
    }
}
