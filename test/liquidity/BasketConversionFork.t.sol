// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {FlashConversionProbe} from "./FlashConversionProbe.sol";
import {BasketConversionForkBase} from "../helpers/BasketConversionForkBase.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IStaticsBorrowLiquidity} from "../../src/interfaces/IStaticsBorrowLiquidity.sol";
import {IStaticsLending} from "../../src/interfaces/IStaticsLending.sol";
import {IStaticsBasketImpairment} from "../../src/interfaces/IStaticsBasketImpairment.sol";
import {IStaticsProtocolPools} from "../../src/interfaces/IStaticsProtocolPools.sol";
import {IStaticsRangeGauge} from "../../src/interfaces/IStaticsRangeGauge.sol";
import {IStaticsPosition} from "../../src/interfaces/IStaticsPosition.sol";
import {StaticsLiquidityManager} from "../../src/liquidity/StaticsLiquidityManager.sol";
import {StaticsFlashArbitrageReceiver} from "../../src/periphery/StaticsFlashArbitrageReceiver.sol";
import {BasketConversionRequest} from "../../src/interfaces/IStaticsBasketConversionRoutes.sol";
import {LibBasketConversion} from "../../src/libraries/LibBasketConversion.sol";
import {BasketConversionStep, BasketConversionBounds} from "../../src/liquidity/StaticsBasketConversionRouter.sol";

contract BasketConversionForkTest is BasketConversionForkBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    address internal posm;
    address internal manager;

    struct Strategy {
        Fixture f;
        uint256 position;
        uint256 loanId;
        uint256[] nfts;
        PoolId[] pools;
    }

    function setUp() public override {
        super.setUp();
        (manager,) = basketLiquidity.liquidityManager();
        posm = StaticsLiquidityManager(payable(manager)).positionManager();
    }

    function _marketKey(PoolId id) internal view returns (PoolKey memory) {
        return IStaticsProtocolPools(address(diamond)).protocolPool(id).key;
    }

    function _strategy() internal returns (Strategy memory s) {
        s.f = _fixture(2);
        _trade(s.f, true, 1000 ether, false, false);
        vm.prank(alice);
        s.position = basketCollateral.createAndDepositBasketCollateral(s.f.basketId, 100 ether, alice);
        vm.warp(block.timestamp + 25 hours);
        address[] memory aa = baskets.basket(s.f.basketId).assets;
        IStaticsBorrowLiquidity.LiquidityParams[] memory p = new IStaticsBorrowLiquidity.LiquidityParams[](2);
        s.pools = new PoolId[](2);
        for (uint256 i; i < 2; ++i) {
            s.pools[i] = basketLiquidity.canonicalPool(s.f.basketId, aa[i]).poolId;
            p[i] = IStaticsBorrowLiquidity.LiquidityParams(
                aa[i],
                TickMath.minUsableTick(10),
                TickMath.maxUsableTick(10),
                1e14,
                100 ether,
                100 ether,
                block.timestamp + 1 hours
            );
        }
        vm.prank(alice);
        (s.loanId, s.nfts) = IStaticsBorrowLiquidity(address(diamond))
            .borrowAndProvideLiquidity(s.position, s.f.basketId, 20 ether, p, alice);
        for (uint256 i; i < 2; ++i) {
            vm.startPrank(alice);
            IERC721(posm).approve(manager, s.nfts[i]);
            gauge.attachLiquidity(s.position, s.pools[i], s.nfts[i]);
            vm.stopPrank();
            assertEq(IERC721(posm).ownerOf(s.nfts[i]), manager);
            _fundGauge(s.pools[i]);
        }
        _creditBooks(s.f);
    }

    function _creditBooks(Fixture memory f) internal view {
        address[] memory aa = baskets.basket(f.basketId).assets;
        uint256 supply = IERC20(f.token).totalSupply();
        for (uint256 i; i < aa.length; ++i) {
            assertEq(
                baskets.vaultBalance(f.basketId, aa[i]) + lending.outstandingPrincipal(f.basketId, aa[i]),
                Math.mulDiv(0.001 ether, supply, 1 ether, Math.Rounding.Ceil),
                "backing plus receivables"
            );
            assertLe(
                custody.globalReservedByToken(aa[i]), IERC20(aa[i]).balanceOf(address(diamond)), "custody solvency"
            );
            assertEq(IERC20(aa[i]).balanceOf(address(conversionHook)), 0);
            assertEq(IERC20(aa[i]).balanceOf(address(conversionZap)), 0);
        }
    }

    function _tradeMarket(Strategy memory s) internal {
        vm.startPrank(alice);
        IERC20(s.f.token).approve(address(marketRouter), type(uint256).max);
        marketRouter.swap(_marketKey(s.pools[0]), _step(_marketKey(s.pools[0]), s.f.token, -int256(1e12), "").params);
        vm.stopPrank();
        IStaticsProtocolPools(address(diamond)).settleProtocolPoolRevenue(s.pools[0], s.f.token);
        IStaticsProtocolPools(address(diamond)).settleProtocolPoolRevenue(s.pools[0], AAPL);
    }

    function _assertClaimAuthority(Strategy memory s) internal {
        (address[] memory rewardAssets, uint256[] memory earned) =
            basketRewards.getBasketRewards(s.position, s.f.basketId);
        uint256[] memory balances = new uint256[](rewardAssets.length);
        for (uint256 i; i < balances.length; ++i) {
            balances[i] = IERC20(rewardAssets[i]).balanceOf(bob);
        }
        assertGt(earned[0] + earned[1] + earned[2], 0);
        uint256 beforeQuote = IERC20(USDG).balanceOf(bob);
        vm.prank(alice);
        vm.expectRevert();
        basketRewards.claimBasketRewards(s.position, s.f.basketId, alice);
        vm.prank(bob);
        basketRewards.claimBasketRewards(s.position, s.f.basketId, bob);
        for (uint256 i; i < balances.length; ++i) {
            assertEq(IERC20(rewardAssets[i]).balanceOf(bob), balances[i] + earned[i]);
        }
        uint8[] memory slots = new uint8[](1);
        slots[0] = 1;
        vm.prank(alice);
        vm.expectRevert();
        gauge.claimLpRewards(s.position, s.pools[0], slots, new uint256[](1), alice);
        vm.prank(bob);
        uint256[] memory paid = gauge.claimLpRewards(s.position, s.pools[0], slots, new uint256[](1), bob);
        assertGt(paid[0], 0);
        assertEq(IERC20(USDG).balanceOf(bob), beforeQuote + paid[0]);
        _checkNativeFees(s);
    }

    function _checkNativeFees(Strategy memory s) private {
        PoolKey memory k = _marketKey(s.pools[0]);
        uint256 before0 = IERC20(Currency.unwrap(k.currency0)).balanceOf(bob);
        uint256 before1 = IERC20(Currency.unwrap(k.currency1)).balanceOf(bob);
        vm.prank(alice);
        vm.expectRevert();
        gauge.collectNativeFees(s.position, s.pools[0], 0, 0, block.timestamp);
        vm.prank(bob);
        IStaticsRangeGauge.LiquidityMovement memory fee =
            gauge.collectNativeFees(s.position, s.pools[0], 0, 0, block.timestamp);
        assertGt(fee.received0 + fee.received1, 0);
        assertEq(IERC20(Currency.unwrap(k.currency0)).balanceOf(bob), before0 + fee.received0);
        assertEq(IERC20(Currency.unwrap(k.currency1)).balanceOf(bob), before1 + fee.received1);
    }

    function _fundRepayFromExistingWallet(Strategy memory s, address payer) internal {
        IStaticsLending.LoanView memory loan = lending.loan(s.loanId);
        // Tokens are acquired via real conversion/redemption; no constituent deal for debt settlement.
        vm.prank(alice);
        baskets.redeem(s.f.basketId, 30 ether, payer, new uint256[](2));
        vm.startPrank(payer);
        for (uint256 i; i < loan.assets.length; ++i) {
            IERC20(loan.assets[i]).approve(address(diamond), loan.principals[i]);
        }
        lending.repay(s.loanId);
        vm.stopPrank();
        _creditBooks(s.f);
    }

    function testEvalStrategyTransferCollectUnwindRepay() public {
        Strategy memory s = _strategy();
        vm.warp(block.timestamp + 2 hours);
        _tradeMarket(s);
        uint256 q = gauge.previewLpRewards(s.position, s.pools[0]).amounts[1];
        assertGt(q, 0);
        uint256 looseBacking = IERC20(AAPL).balanceOf(alice);
        uint256 looseShares = IERC20(s.f.token).balanceOf(alice);
        vm.prank(alice);
        IERC721(address(diamond)).transferFrom(alice, bob, s.position);
        assertEq(IERC20(AAPL).balanceOf(alice), looseBacking);
        assertEq(IERC20(s.f.token).balanceOf(alice), looseShares);
        assertEq(gauge.previewLpRewards(s.position, s.pools[0]).amounts[1], q);
        assertEq(lending.loan(s.loanId).positionId, s.position);
        _assertClaimAuthority(s);
        for (uint256 i; i < 2; ++i) {
            vm.prank(alice);
            vm.expectRevert();
            gauge.exitLiquidity(s.position, s.pools[i], 0, 0, block.timestamp);
            vm.prank(bob);
            gauge.exitLiquidity(s.position, s.pools[i], 0, 0, block.timestamp);
            assertEq(gauge.lpLeg(s.position, s.pools[i]).liquidity, 0);
        }
        _fundRepayFromExistingWallet(s, bob);
        assertEq(basketCollateral.basketCollateralPosition(s.position, s.f.basketId).lockedShares, 0);
        uint256 deposited = basketCollateral.basketCollateralPosition(s.position, s.f.basketId).depositedShares;
        vm.prank(bob);
        basketCollateral.withdrawBasketCollateral(s.position, s.f.basketId, deposited, bob);
        _creditBooks(s.f);
    }

    function testEvalExtensionRecoveryKeepsGaugeActiveAfterTransfer() public {
        Strategy memory s = _strategy();
        vm.prank(alice);
        IERC721(address(diamond)).transferFrom(alice, bob, s.position);
        vm.prank(alice);
        baskets.redeem(s.f.basketId, 1 ether, bob, new uint256[](2));
        (address[] memory aa, uint256[] memory fees) = lending.quoteExtension(s.loanId);
        uint256 oldMaturity = lending.loan(s.loanId).maturity;
        vm.startPrank(bob);
        for (uint256 i; i < aa.length; ++i) {
            IERC20(aa[i]).approve(address(diamond), fees[i]);
        }
        lending.extend(s.loanId, fees);
        vm.stopPrank();
        assertGt(lending.loan(s.loanId).maturity, oldMaturity);
        vm.warp(lending.quoteRecovery(s.loanId).recoverableAt + 1);
        uint256 earned = gauge.previewLpRewards(s.position, s.pools[0]).amounts[1];
        assertGt(earned, 0);
        lending.recover(s.loanId);
        assertEq(gauge.lpLeg(s.position, s.pools[0]).liquidity, 1e14);
        assertEq(IERC721(posm).ownerOf(s.nfts[0]), manager);
        assertEq(gauge.previewLpRewards(s.position, s.pools[0]).amounts[1], earned);
        assertEq(basketCollateral.basketCollateralPosition(s.position, s.f.basketId).lockedShares, 0);
        _creditBooks(s.f);
        vm.prank(bob);
        gauge.exitLiquidity(s.position, s.pools[0], 0, 0, block.timestamp);
    }

    function testEvalConversionWithOutstandingCreditAndBackingRollback() public {
        Strategy memory s = _strategy();
        uint256 debt = lending.outstandingPrincipal(s.f.basketId, AAPL);
        _trade(s.f, true, 10 ether, false, false);
        _trade(s.f, false, 10 ether, true, false);
        assertEq(lending.outstandingPrincipal(s.f.basketId, AAPL), debt);
        _creditBooks(s.f);
        uint256 total = IERC20(s.f.token).totalSupply();
        vm.expectPartialRevert(bytes4(keccak256("InsufficientVaultBalance(address,uint256,uint256)")));
        baskets.quoteRedeem(s.f.basketId, total);
        uint256 shares = IERC20(s.f.token).balanceOf(alice);
        // The locked collateral cannot be sold; freely held supply remains redeemable.
        vm.prank(alice);
        basketCollateral.withdrawBasketCollateral(s.position, s.f.basketId, 79 ether, alice);
        shares = IERC20(s.f.token).balanceOf(alice);
        bytes32 beforeState = _rollbackHash(s.f);
        BasketConversionRequest memory r = _request(s.f, false, false);
        r.limit = type(uint128).max;
        vm.prank(alice);
        vm.expectRevert();
        conversionZap.sell(s.f.poolId, 1 ether, alice, r);
        assertEq(_rollbackHash(s.f), beforeState);
        // Free shares remain fully redeemable despite receivables: locked collateral covers the outstanding debt.
        vm.prank(alice);
        conversionZap.sell(s.f.poolId, shares, alice, _request(s.f, false, false));
        assertEq(lending.outstandingPrincipal(s.f.basketId, AAPL), debt);
        _creditBooks(s.f);
    }

    function _rollbackHash(Fixture memory f) internal view returns (bytes32 h) {
        h = keccak256(
            abi.encode(IERC20(f.token).totalSupply(), IERC20(f.token).balanceOf(alice), IERC20(USDG).balanceOf(alice))
        );
        address[] memory aa = baskets.basket(f.basketId).assets;
        for (uint256 i; i < aa.length; ++i) {
            (uint160 price, int24 tick,,) = PM.getSlot0(f.routes[i].pools[0].toId());
            h = keccak256(
                abi.encode(
                    h,
                    IERC20(aa[i]).balanceOf(address(diamond)),
                    baskets.vaultBalance(f.basketId, aa[i]),
                    lending.outstandingPrincipal(f.basketId, aa[i]),
                    custody.globalReservedByToken(aa[i]),
                    globalRewards.rewardAsset(aa[i]).indexRay,
                    price,
                    tick
                )
            );
        }
    }

    function testEvalImpairmentExplicitExitAndConversionRollback() public {
        Fixture memory f = _fixture(2);
        _trade(f, true, 100 ether, false, false);
        IStaticsBasketImpairment impaired = IStaticsBasketImpairment(address(diamond));
        impaired.markBasketAssetImpaired(f.basketId, AAPL);
        bytes32 beforeState = _rollbackHash(f);
        vm.prank(alice);
        vm.expectRevert();
        conversionZap.buy(f.poolId, 1 ether, alice, _request(f, true, false));
        assertEq(_rollbackHash(f), beforeState);
        vm.prank(alice);
        vm.expectRevert();
        conversionZap.sell(f.poolId, 1 ether, alice, _request(f, false, false));
        assertEq(_rollbackHash(f), beforeState);
        uint256 apple = IERC20(AAPL).balanceOf(alice);
        uint256 meta = IERC20(META).balanceOf(alice);
        vm.prank(alice);
        uint256[] memory paid = impaired.redeemImpaired(f.basketId, 1 ether, alice, new uint256[](2));
        assertEq(paid[0], 0);
        assertGt(paid[1], 0);
        assertEq(IERC20(AAPL).balanceOf(alice), apple);
        assertEq(IERC20(META).balanceOf(alice), meta + paid[1]);
    }

    function testEvalThinLiveRouteRevertsAllMintAndSwaps() public {
        Fixture memory f = _fixture(2);
        _trade(f, true, 100 ether, false, false);
        bytes32 beforeState = _rollbackHash(f);
        BasketConversionRequest memory r = _request(f, true, false);
        // Existing live pools are unchanged: exceed executable depth without a restrictive spend cap.
        r.limit = type(uint128).max;
        vm.prank(alice);
        vm.expectPartialRevert(LibBasketConversion.ConversionBound.selector);
        conversionZap.buy(f.poolId, 1_000_000_000 ether, alice, r);
        assertEq(_rollbackHash(f), beforeState);
    }

    function _cycle(Fixture memory f, PoolKey memory secondary, bool premium, uint256 shares)
        internal
        returns (int256)
    {
        BasketConversionStep[] memory steps = new BasketConversionStep[](2);
        BasketConversionStep memory conversion = _step(
            f.key,
            premium ? USDG : f.token,
            premium ? int256(shares) : -int256(shares),
            abi.encode(_request(f, premium, false))
        );
        BasketConversionStep memory market =
            _step(secondary, premium ? f.token : USDG, premium ? -int256(shares) : int256(shares), "");
        steps[0] = premium ? conversion : market;
        steps[1] = premium ? market : conversion;
        vm.prank(alice);
        return conversionRouter.execute(f.poolId, steps, 0, BasketConversionBounds(0, 1, 0, block.timestamp));
    }

    function testEvalBothArbitrageDirectionsWithOutstandingCredit() public {
        Strategy memory s = _strategy();
        uint256 snap = vm.snapshotState();
        PoolKey memory market = _secondaryMarket(s.f, true);
        uint256 debt = lending.outstandingPrincipal(s.f.basketId, AAPL);
        assertGt(_cycle(s.f, market, true, 1 ether), 0);
        assertEq(lending.outstandingPrincipal(s.f.basketId, AAPL), debt);
        _creditBooks(s.f);
        assertTrue(vm.revertToState(snap));
        market = _secondaryMarket(s.f, false);
        assertGt(_cycle(s.f, market, false, 1 ether), 0);
        assertEq(lending.outstandingPrincipal(s.f.basketId, AAPL), debt);
        _creditBooks(s.f);
    }

    function _provideTemporary(Strategy memory s) internal returns (uint256 position) {
        vm.prank(alice);
        conversionZap.buy(s.f.poolId, 0.001 ether, bob, _request(s.f, true, false));
        vm.prank(alice);
        IERC20(AAPL).transfer(bob, 0.001 ether);
        vm.startPrank(bob);
        position = IStaticsPosition(address(diamond)).createPosition(bob);
        IERC20(s.f.token).approve(address(diamond), 0.001 ether);
        IERC20(AAPL).approve(address(diamond), 0.001 ether);
        gauge.provideLiquidity(
            position,
            IStaticsRangeGauge.ProvideLiquidityParams(
                s.pools[0],
                TickMath.minUsableTick(10),
                TickMath.maxUsableTick(10),
                1e13,
                0.0005 ether,
                0.0005 ether,
                block.timestamp
            )
        );
        vm.stopPrank();
    }

    function _attachTemporary(Strategy memory s) internal returns (uint256 position) {
        IStaticsBorrowLiquidity.LiquidityParams[] memory p = new IStaticsBorrowLiquidity.LiquidityParams[](2);
        address[] memory aa = baskets.basket(s.f.basketId).assets;
        for (uint256 i; i < 2; ++i) {
            p[i] = IStaticsBorrowLiquidity.LiquidityParams(
                aa[i], TickMath.minUsableTick(10), TickMath.maxUsableTick(10), 1e13, 1 ether, 1 ether, block.timestamp
            );
        }
        vm.prank(alice);
        (, uint256[] memory nfts) = IStaticsBorrowLiquidity(address(diamond))
            .borrowAndProvideLiquidity(s.position, s.f.basketId, 20 ether, p, alice);
        vm.prank(alice);
        IERC721(posm).transferFrom(alice, bob, nfts[0]);
        vm.prank(alice);
        conversionZap.buy(s.f.poolId, 0.001 ether, bob, _request(s.f, true, false));
        vm.prank(alice);
        IERC20(AAPL).transfer(bob, 0.001 ether);
        vm.startPrank(bob);
        position = IStaticsPosition(address(diamond)).createPosition(bob);
        IERC20(s.f.token).approve(address(diamond), 0.001 ether);
        IERC20(AAPL).approve(address(diamond), 0.001 ether);
        IERC721(posm).approve(manager, nfts[0]);
        gauge.attachLiquidity(position, s.pools[0], nfts[0]);
        vm.stopPrank();
    }

    function testEvalAtomicTemporaryGaugeLegCannotCaptureHistoryOrManufactureEmission() public {
        _temporaryGaugeScenario(false);
    }

    function testEvalLateAttachmentCannotCaptureHistoryDuringAtomicConversion() public {
        _temporaryGaugeScenario(true);
    }

    function testEvalTemporaryGaugeDuringBuyRedeemArbitrage() public {
        _temporaryGaugeScenario(false, false);
    }

    function testEvalLateAttachmentDuringBuyRedeemArbitrage() public {
        _temporaryGaugeScenario(true, false);
    }

    function _temporaryGaugeScenario(bool attach) internal {
        _temporaryGaugeScenario(attach, true);
    }

    function _temporaryGaugeScenario(bool attach, bool premium) internal {
        Strategy memory s = _strategy();
        PoolKey memory market = _secondaryMarket(s.f, premium);
        vm.deal(bob, 10 ether);
        vm.warp(block.timestamp + 1 hours);
        uint256 oldRewards = gauge.previewLpRewards(s.position, s.pools[0]).amounts[1];
        uint256 newcomer = attach ? _attachTemporary(s) : _provideTemporary(s);
        assertEq(gauge.previewLpRewards(newcomer, s.pools[0]).amounts[1], 0);
        assertEq(gauge.previewLpRewards(s.position, s.pools[0]).amounts[1], oldRewards);
        uint256 emitted = gauge.poolRewardStream(s.pools[0], 1).periodEmitted;
        _cycle(s.f, market, premium, 1 ether);
        vm.prank(bob);
        gauge.increaseLiquidity(
            newcomer,
            s.pools[0],
            IStaticsRangeGauge.IncreaseLiquidityParams(1e12, 0.0001 ether, 0.0001 ether, block.timestamp)
        );
        vm.prank(bob);
        gauge.decreaseLiquidity(
            newcomer, s.pools[0], IStaticsRangeGauge.DecreaseLiquidityParams(1e12, 0, 0, block.timestamp)
        );
        vm.prank(bob);
        gauge.exitLiquidity(newcomer, s.pools[0], 0, 0, block.timestamp);
        assertEq(gauge.previewLpRewards(newcomer, s.pools[0]).amounts[1], 0);
        assertEq(gauge.poolRewardStream(s.pools[0], 1).periodEmitted, emitted);
        assertEq(gauge.previewLpRewards(s.position, s.pools[0]).amounts[1], oldRewards);
        _creditBooks(s.f);
    }

    function testEvalBoundaryCrossingArbitrageCannotPayNewLiquidityHistory() public {
        Fixture memory f = _fixture(2);
        _trade(f, true, 1000 ether, false, false);
        uint256 baseline = vm.snapshotState();
        for (uint256 direction; direction < 2; ++direction) {
            if (direction != 0) assertTrue(vm.revertToState(baseline));
            _crossingScenario(f, direction == 0);
        }
    }

    function _crossingScenario(Fixture memory f, bool premium) private {
        PoolKey memory market = _secondaryMarket(f, premium);
        PoolId pool = market.toId();
        (, int24 tick,,) = PM.getSlot0(pool);
        int24 aligned = tick / 10 * 10;
        int24 lower = aligned - 10;
        int24 upper = aligned + 10;
        uint256 oldPosition = _provideNarrow(f, pool, alice, lower, upper);
        _fundGauge(pool);
        vm.prank(alice);
        conversionZap.buy(f.poolId, 1 ether, bob, _request(f, true, false));
        vm.prank(alice);
        IERC20(USDG).transfer(bob, 100e6);
        vm.warp(block.timestamp + 1 hours);
        uint256 historical = gauge.previewLpRewards(oldPosition, pool).amounts[1];
        assertGt(historical, 0);
        uint256 newPosition = _provideNarrow(f, pool, bob, lower, upper);
        assertEq(gauge.previewLpRewards(newPosition, pool).amounts[1], 0);
        uint256 emitted = gauge.poolRewardStream(pool, 1).periodEmitted;
        _cycle(f, market, premium, 10 ether);
        IStaticsRangeGauge.GaugePoolView memory state = gauge.gaugePool(pool);
        assertTrue(state.referenceTick < lower || state.referenceTick >= upper, "arbitrage crosses managed boundary");
        assertEq(state.activeGaugeLiquidity, 0);
        assertEq(gauge.previewLpRewards(newPosition, pool).amounts[1], 0);
        assertEq(gauge.previewLpRewards(oldPosition, pool).amounts[1], historical);
        assertEq(gauge.poolRewardStream(pool, 1).periodEmitted, emitted);
        vm.prank(bob);
        gauge.exitLiquidity(newPosition, pool, 0, 0, block.timestamp);
        assertEq(gauge.previewLpRewards(newPosition, pool).amounts[1], 0);
        _creditBooks(f);
    }

    function _provideNarrow(Fixture memory f, PoolId pool, address owner, int24 lower, int24 upper)
        private
        returns (uint256 position)
    {
        vm.startPrank(owner);
        position = IStaticsPosition(address(diamond)).createPosition(owner);
        IERC20(f.token).approve(address(diamond), type(uint256).max);
        IERC20(USDG).approve(address(diamond), type(uint256).max);
        PoolKey memory k = _marketKey(pool);
        gauge.provideLiquidity(
            position,
            IStaticsRangeGauge.ProvideLiquidityParams(
                pool,
                lower,
                upper,
                1e13,
                Currency.unwrap(k.currency0) == USDG ? 100e6 : 1 ether,
                Currency.unwrap(k.currency1) == USDG ? 100e6 : 1 ether,
                block.timestamp
            )
        );
        vm.stopPrank();
    }

    function testEvalConversionMintRevenueIsIndexedOnce() public {
        Fixture memory f = _fixture(2);
        uint256[] memory positions = _activateStakers(baskets.basket(f.basketId).assets);
        uint256[] memory required = baskets.quoteMint(f.basketId, 10 ether);
        address[] memory aa = baskets.basket(f.basketId).assets;
        uint256[] memory treasuryBefore = new uint256[](2);
        uint256[] memory pendingBefore = globalRewards.pendingRewards(positions[0], aa);
        for (uint256 i; i < 2; ++i) {
            treasuryBefore[i] = globalRewards.treasuryAccrued(aa[i]);
        }
        _trade(f, true, 10 ether, false, false);
        uint256[] memory afterPending = globalRewards.pendingRewards(positions[0], aa);
        for (uint256 i; i < 2; ++i) {
            uint256 fee = required[i] - 0.01 ether;
            assertApproxEqAbs(
                afterPending[i] - pendingBefore[i] + globalRewards.treasuryAccrued(aa[i]) - treasuryBefore[i], fee, 1
            );
        }
        globalRewards.checkpointRewardAssets(aa);
        assertEq(globalRewards.pendingRewards(positions[0], aa), afterPending);
        _creditBooks(f);
    }

    function testEvalExistingArbitrageHelperRejectsConversionPoolAtomically() public {
        Fixture memory f = _fixture(2);
        _trade(f, true, 100 ether, false, false);
        StaticsFlashArbitrageReceiver receiver = new StaticsFlashArbitrageReceiver(address(diamond));
        PoolKey[] memory pools = new PoolKey[](2);
        pools[0] = f.key;
        pools[1] = f.key;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 0.5 ether;
        amounts[1] = 0.5 ether;
        vm.prank(alice);
        baskets.redeem(f.basketId, 1 ether, alice, new uint256[](2));
        vm.startPrank(alice);
        IERC20(AAPL).approve(address(receiver), type(uint256).max);
        IERC20(META).approve(address(receiver), type(uint256).max);
        vm.stopPrank();
        bytes32 beforeState = _rollbackHash(f);
        vm.prank(alice);
        vm.expectPartialRevert(StaticsFlashArbitrageReceiver.InvalidPool.selector);
        receiver.executeMintAndSell(f.basketId, 1 ether, pools, amounts, new uint256[](2), block.timestamp);
        assertEq(_rollbackHash(f), beforeState);
        amounts[0] = 0.0005 ether;
        amounts[1] = 0.0005 ether;
        vm.prank(alice);
        vm.expectPartialRevert(StaticsFlashArbitrageReceiver.InvalidPool.selector);
        receiver.executeBuyAndRedeem(f.basketId, 1 ether, pools, amounts, new uint256[](2), block.timestamp);
        assertEq(_rollbackHash(f), beforeState);
    }

    function testEvalCreditPlusFlashShortageRevertsConversionAndFlashAtomically() public {
        Strategy memory s = _strategy();
        FlashConversionProbe probe =
            new FlashConversionProbe(address(diamond), conversionZap, s.f.poolId, s.f.basketId, s.f.token);
        vm.prank(alice);
        conversionZap.buy(s.f.poolId, 1 ether, address(probe), _request(s.f, true, false));
        vm.prank(alice);
        baskets.redeem(s.f.basketId, 10 ether, address(probe), new uint256[](2));
        uint256 minimum = IERC20(AAPL).balanceOf(address(diamond));
        uint256 other = IERC20(META).balanceOf(address(diamond));
        if (other < minimum) minimum = other;
        uint256 shares = minimum * 1000;
        bytes32 beforeState = _rollbackHash(s.f);
        uint256 probeApple = IERC20(AAPL).balanceOf(address(probe));
        uint256 probeMeta = IERC20(META).balanceOf(address(probe));
        vm.expectPartialRevert(bytes4(keccak256("ERC20InsufficientBalance(address,uint256,uint256)")));
        probe.execute(shares, _request(s.f, false, false));
        assertEq(IERC20(AAPL).balanceOf(address(probe)), probeApple);
        assertEq(IERC20(META).balanceOf(address(probe)), probeMeta);
        assertEq(_rollbackHash(s.f), beforeState);
        assertEq(IERC20(s.f.token).balanceOf(address(probe)), 1 ether);
        _creditBooks(s.f);
    }

    function testEvalConversionArbitrageRevenueConservationBothDirections(uint256 shares, uint256 idle) public {
        shares = bound(shares, 1 ether, 10 ether);
        idle = bound(idle, 0, 48 hours);
        Fixture memory f = _fixture(2);
        uint256[] memory positions = _activateStakers(baskets.basket(f.basketId).assets);
        _trade(f, true, 1000 ether, false, false);
        vm.warp(block.timestamp + idle);
        uint256 baseline = vm.snapshotState();
        for (uint256 direction; direction < 2; ++direction) {
            if (direction != 0) assertTrue(vm.revertToState(baseline));
            bool premium = direction == 0;
            PoolKey memory market = _secondaryMarket(f, premium);
            _assertConversionRevenue(f, market, premium, shares, positions[0]);
        }
    }

    function _assertConversionRevenue(
        Fixture memory f,
        PoolKey memory market,
        bool premium,
        uint256 shares,
        uint256 position
    ) private {
        address[] memory aa = baskets.basket(f.basketId).assets;
        uint256[] memory quote =
            premium ? baskets.quoteMint(f.basketId, shares) : baskets.quoteRedeem(f.basketId, shares);
        uint256[] memory pending = globalRewards.pendingRewards(position, aa);
        uint256[2] memory treasuryBefore;
        for (uint256 i; i < 2; ++i) {
            treasuryBefore[i] = globalRewards.treasuryAccrued(aa[i]);
        }
        uint256 backingBefore = baskets.vaultBalance(f.basketId, aa[0]);
        _cycle(f, market, premium, shares);
        uint256[] memory next = globalRewards.pendingRewards(position, aa);
        uint256 backingAfter = baskets.vaultBalance(f.basketId, aa[0]);
        uint256 base = premium ? backingAfter - backingBefore : backingBefore - backingAfter;
        for (uint256 i; i < 2; ++i) {
            uint256 fee = premium ? quote[i] - base : base - quote[i];
            assertApproxEqAbs(
                next[i] - pending[i] + globalRewards.treasuryAccrued(aa[i]) - treasuryBefore[i],
                fee,
                1,
                "one conversion fee per constituent"
            );
        }
        _creditBooks(f);
    }
}
