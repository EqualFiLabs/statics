// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {IStaticsBasketCollateral} from "../../../src/interfaces/IStaticsBasketCollateral.sol";
import {IStaticsLending} from "../../../src/interfaces/IStaticsLending.sol";
import {CanonicalV4Router} from "../../helpers/CanonicalPoolTestBase.sol";
import {IBlendBasket, IBlendHook, RobinhoodBlendBasketForkBase} from "./RobinhoodBlendBasketFork.t.sol";

interface IBlendLendingBasket is IBlendBasket {
    function protocolFees(address token) external view returns (uint256);
}

/// @notice Proves a Statics position can borrow and repay a live Blend share constituent.
contract RobinhoodBlendLendingForkTest is RobinhoodBlendBasketForkBase {
    uint256 private constant POSITION_SHARES = 10 ether;
    uint256 private constant BORROW_SHARES = 5 ether;
    uint256 private constant MARKET_BORROW_SHARES = 0.01 ether;
    uint256 private constant MARKET_BUFFER_USDG = 1_000_000;

    error InvalidBlendMarket();

    CanonicalV4Router private marketRouter;

    struct BooksSnapshot {
        uint256 vault;
        uint256 basketReserve;
        uint256 globalReserve;
        uint256 treasury;
        uint256 diamondBlend;
        uint256 outerSupply;
        uint256 outerReserve;
        uint256 aliceOuter;
        uint256 bobBlend;
    }

    struct LendingMetrics {
        uint256 positionId;
        uint256 withdrawnShares;
        uint256 mintGas;
        uint256 borrowGas;
        uint256 repayGas;
        uint256 withdrawGas;
    }

    struct MarketLendingMetrics {
        uint256 positionId;
        uint256 withdrawnShares;
        uint256 principal;
        uint256 soldForUsdg;
        uint256 spentToBuyBack;
        uint256 mintGas;
        uint256 borrowGas;
        uint256 sellGas;
        uint256 buyBackGas;
        uint256 repayGas;
        uint256 withdrawGas;
    }

    struct BlendBookSnapshot {
        address token;
        uint256 units;
        uint256 backing;
        uint256 protocolFees;
    }

    function setUp() public override {
        super.setUp();
        marketRouter = new CanonicalV4Router(poolManager);
    }

    function testStaticsLendsAndRecoversLiveBlendConstituent() public {
        IBlendBasket blend = IBlendBasket(BLEND_AI);
        bytes32 blendBackingBefore = _blendBackingHash(blend);
        BooksSnapshot memory beforePosition = _snapshot();
        LendingMetrics memory metrics = _exerciseLending();

        _assertExited(metrics.positionId, metrics.withdrawnShares, beforePosition);
        assertEq(_blendBackingHash(blend), blendBackingBefore);

        emit log("Statics collateral: sBAI; borrowed and repaid asset: live Blend AI shares");
        emit log_named_uint("Blend-backed collateral mint gas", metrics.mintGas);
        emit log_named_uint("Blend constituent borrow gas", metrics.borrowGas);
        emit log_named_uint("Blend constituent repay gas", metrics.repayGas);
        emit log_named_uint("Unlocked sBAI withdrawal gas", metrics.withdrawGas);
    }

    function testBorrowedBlendShareTradesThroughLiveMarketAndRepays() public {
        IBlendLendingBasket blend = IBlendLendingBasket(BLEND_AI);
        (uint256 blendSupplyBefore, BlendBookSnapshot[] memory blendBooksBefore) = _snapshotBlendBooks(blend);
        BooksSnapshot memory beforePosition = _snapshot();
        MarketLendingMetrics memory metrics = _exerciseMarketLending();

        _assertExited(metrics.positionId, metrics.withdrawnShares, beforePosition);
        _assertBlendBooksAfterMarket(blend, blendSupplyBefore, blendBooksBefore);

        emit log("Statics loan route: borrow Blend AI -> live BlendHook USDG -> buy back AI -> repay");
        emit log_named_uint("Borrowed Blend AI shares", metrics.principal);
        emit log_named_uint("USDG received from live market", metrics.soldForUsdg);
        emit log_named_uint("USDG spent to buy exact repayment", metrics.spentToBuyBack);
        emit log_named_uint("Blend-backed collateral mint gas", metrics.mintGas);
        emit log_named_uint("Blend constituent borrow gas", metrics.borrowGas);
        emit log_named_uint("Live Blend AI sale gas", metrics.sellGas);
        emit log_named_uint("Live Blend AI buyback gas", metrics.buyBackGas);
        emit log_named_uint("Blend constituent repay gas", metrics.repayGas);
        emit log_named_uint("Unlocked sBAI withdrawal gas", metrics.withdrawGas);
    }

    function _exerciseLending() private returns (LendingMetrics memory metrics) {
        (metrics.positionId, metrics.mintGas) = _mintPosition();
        (metrics.withdrawnShares, metrics.borrowGas, metrics.repayGas) = _borrowAndRepay(metrics.positionId);
        uint256 gasBefore = gasleft();
        vm.prank(alice);
        basketCollateral.withdrawBasketCollateral(metrics.positionId, staticsBasketId, metrics.withdrawnShares, alice);
        metrics.withdrawGas = gasBefore - gasleft();
    }

    function _exerciseMarketLending() private returns (MarketLendingMetrics memory metrics) {
        (metrics.positionId, metrics.mintGas) = _mintPosition();
        address trader = makeAddr("Blend lending market trader");
        IStaticsLending.BorrowQuote memory quoted = lending.quoteBorrow(staticsBasketId, MARKET_BORROW_SHARES);
        BooksSnapshot memory beforeBorrow = _snapshot();
        uint256 traderBlendBefore = IERC20(BLEND_AI).balanceOf(trader);

        uint256 gasBefore = gasleft();
        vm.prank(alice);
        (uint256 loanId, uint256[] memory principals) =
            lending.borrow(metrics.positionId, staticsBasketId, MARKET_BORROW_SHARES, trader);
        metrics.borrowGas = gasBefore - gasleft();
        assertEq(principals, quoted.principals);
        metrics.principal = principals[0];
        _assertBorrow(metrics.positionId, loanId, quoted, beforeBorrow, trader, traderBlendBefore);

        _fundMarketTrader(trader);
        (metrics.soldForUsdg, metrics.sellGas) = _sellBlendForUsdg(trader, metrics.principal);
        (metrics.spentToBuyBack, metrics.buyBackGas) = _buyExactBlendWithUsdg(trader, metrics.principal);

        gasBefore = gasleft();
        vm.startPrank(trader);
        assertTrue(IERC20(BLEND_AI).approve(address(diamond), metrics.principal));
        lending.repay(loanId);
        vm.stopPrank();
        metrics.repayGas = gasBefore - gasleft();
        _assertRepaid(metrics.positionId, quoted, beforeBorrow, trader, traderBlendBefore);

        IStaticsBasketCollateral.BasketCollateralPosition memory position =
            basketCollateral.basketCollateralPosition(metrics.positionId, staticsBasketId);
        metrics.withdrawnShares = position.depositedShares;
        gasBefore = gasleft();
        vm.prank(alice);
        basketCollateral.withdrawBasketCollateral(metrics.positionId, staticsBasketId, metrics.withdrawnShares, alice);
        metrics.withdrawGas = gasBefore - gasleft();

        assertEq(IERC20(USDG).balanceOf(trader), MARKET_BUFFER_USDG + metrics.soldForUsdg - metrics.spentToBuyBack);
        assertEq(IERC20(BLEND_AI).balanceOf(address(marketRouter)), 0);
        assertEq(IERC20(USDG).balanceOf(address(marketRouter)), 0);
        assertEq(IERC20(BLEND_AI).allowance(trader, address(marketRouter)), 0);
        assertEq(IERC20(USDG).allowance(trader, address(marketRouter)), 0);
    }

    function _fundMarketTrader(address trader) private {
        uint256 holderBefore = IERC20(USDG).balanceOf(BLEND_AI_HOLDER);
        uint256 traderBefore = IERC20(USDG).balanceOf(trader);
        assertGe(holderBefore, MARKET_BUFFER_USDG);
        vm.prank(BLEND_AI_HOLDER);
        assertTrue(IERC20(USDG).transfer(trader, MARKET_BUFFER_USDG));
        assertEq(IERC20(USDG).balanceOf(BLEND_AI_HOLDER), holderBefore - MARKET_BUFFER_USDG);
        assertEq(IERC20(USDG).balanceOf(trader), traderBefore + MARKET_BUFFER_USDG);
    }

    function _sellBlendForUsdg(address trader, uint256 principal)
        private
        returns (uint256 receivedUsdg, uint256 executionGas)
    {
        assertLe(principal, uint256(type(int256).max));
        PoolKey memory pool = _blendMarketPool();
        uint256 blendBefore = IERC20(BLEND_AI).balanceOf(trader);
        uint256 usdgBefore = IERC20(USDG).balanceOf(trader);

        vm.prank(trader);
        assertTrue(IERC20(BLEND_AI).approve(address(marketRouter), principal));
        vm.prank(trader);
        marketRouter.swap(
            pool,
            SwapParams({
                zeroForOne: _direction(pool, BLEND_AI, USDG),
                amountSpecified: -int256(principal),
                sqrtPriceLimitX96: _priceLimit(pool, BLEND_AI, USDG)
            })
        );
        executionGas = vm.lastFrameGas().gasTotalUsed;
        vm.prank(trader);
        assertTrue(IERC20(BLEND_AI).approve(address(marketRouter), 0));

        assertEq(blendBefore - IERC20(BLEND_AI).balanceOf(trader), principal);
        receivedUsdg = IERC20(USDG).balanceOf(trader) - usdgBefore;
        assertGt(receivedUsdg, 0);
    }

    function _buyExactBlendWithUsdg(address trader, uint256 principal)
        private
        returns (uint256 spentUsdg, uint256 executionGas)
    {
        assertLe(principal, uint256(type(int256).max));
        PoolKey memory pool = _blendMarketPool();
        uint256 blendBefore = IERC20(BLEND_AI).balanceOf(trader);
        uint256 usdgBefore = IERC20(USDG).balanceOf(trader);

        vm.prank(trader);
        assertTrue(IERC20(USDG).approve(address(marketRouter), usdgBefore));
        vm.prank(trader);
        marketRouter.swap(
            pool,
            SwapParams({
                zeroForOne: _direction(pool, USDG, BLEND_AI),
                amountSpecified: int256(principal),
                sqrtPriceLimitX96: _priceLimit(pool, USDG, BLEND_AI)
            })
        );
        executionGas = vm.lastFrameGas().gasTotalUsed;
        vm.prank(trader);
        assertTrue(IERC20(USDG).approve(address(marketRouter), 0));

        spentUsdg = usdgBefore - IERC20(USDG).balanceOf(trader);
        assertGt(spentUsdg, 0);
        assertEq(IERC20(BLEND_AI).balanceOf(trader) - blendBefore, principal);
    }

    function _blendMarketPool() private view returns (PoolKey memory) {
        return IBlendHook(BLEND_HOOK).poolKeyFor(BLEND_AI, USDG);
    }

    function _priceLimit(PoolKey memory pool, address input, address output) private pure returns (uint160) {
        return _direction(pool, input, output) ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
    }

    function _direction(PoolKey memory pool, address input, address output) private pure returns (bool zeroForOne) {
        if (Currency.unwrap(pool.currency0) == input && Currency.unwrap(pool.currency1) == output) return true;
        if (Currency.unwrap(pool.currency1) == input && Currency.unwrap(pool.currency0) == output) return false;
        revert InvalidBlendMarket();
    }

    function _mintPosition() private returns (uint256 positionId, uint256 executionGas) {
        uint256[] memory mintQuote = baskets.quoteMint(staticsBasketId, POSITION_SHARES);
        uint256 gasBefore = gasleft();
        vm.prank(alice);
        uint256[] memory actualInputs;
        (positionId, actualInputs) =
            basketCollateral.createAndMintBasketCollateral(staticsBasketId, POSITION_SHARES, alice, mintQuote);
        executionGas = gasBefore - gasleft();
        assertEq(actualInputs, mintQuote);
        assertEq(IERC721(address(diamond)).ownerOf(positionId), alice);
    }

    function _borrowAndRepay(uint256 positionId)
        private
        returns (uint256 withdrawnShares, uint256 borrowGas, uint256 repayGas)
    {
        IStaticsLending.BorrowQuote memory quoted = lending.quoteBorrow(staticsBasketId, BORROW_SHARES);
        assertEq(quoted.assets.length, 1);
        assertEq(quoted.assets[0], BLEND_AI);
        assertEq(quoted.principals.length, 1);
        assertGt(quoted.principals[0], 0);

        BooksSnapshot memory beforeBorrow = _snapshot();
        uint256 gasBefore = gasleft();
        vm.prank(alice);
        (uint256 loanId, uint256[] memory principals) = lending.borrow(positionId, staticsBasketId, BORROW_SHARES, bob);
        borrowGas = gasBefore - gasleft();
        assertEq(principals, quoted.principals);
        _assertBorrow(positionId, loanId, quoted, beforeBorrow, bob, beforeBorrow.bobBlend);

        gasBefore = gasleft();
        vm.startPrank(bob);
        assertTrue(IERC20(BLEND_AI).approve(address(diamond), principals[0]));
        lending.repay(loanId);
        vm.stopPrank();
        repayGas = gasBefore - gasleft();
        _assertRepaid(positionId, quoted, beforeBorrow, bob, beforeBorrow.bobBlend);

        IStaticsBasketCollateral.BasketCollateralPosition memory position =
            basketCollateral.basketCollateralPosition(positionId, staticsBasketId);
        withdrawnShares = position.depositedShares;
    }

    function _assertExited(uint256 positionId, uint256 withdrawnShares, BooksSnapshot memory beforePosition)
        private
        view
    {
        IStaticsBasketCollateral.BasketCollateralPosition memory exited =
            basketCollateral.basketCollateralPosition(positionId, staticsBasketId);
        assertEq(exited.depositedShares, 0);
        assertEq(exited.lockedShares, 0);
        assertEq(custody.globalReservedByToken(staticsBasketToken), beforePosition.outerReserve);
        assertEq(IERC20(staticsBasketToken).balanceOf(alice), beforePosition.aliceOuter + withdrawnShares);
    }

    function _assertBorrow(
        uint256 positionId,
        uint256 loanId,
        IStaticsLending.BorrowQuote memory quoted,
        BooksSnapshot memory beforeBorrow,
        address receiver,
        uint256 receiverBlendBefore
    ) private view {
        uint256 principal = quoted.principals[0];
        uint256 feeUnderlying = quoted.feeShares;
        IStaticsLending.LoanView memory current = lending.loan(loanId);
        assertEq(current.positionId, positionId);
        assertEq(current.basketId, staticsBasketId);
        assertEq(current.collateralShares, quoted.collateralShares);
        assertEq(current.feeShares, quoted.feeShares);
        assertEq(current.debtShares, quoted.debtShares);
        assertEq(current.penaltyShares, quoted.penaltyShares);
        assertEq(current.assets[0], BLEND_AI);
        assertEq(current.principals[0], principal);
        assertEq(lending.outstandingPrincipal(staticsBasketId, BLEND_AI), principal);
        assertEq(IERC20(BLEND_AI).balanceOf(receiver), receiverBlendBefore + principal);
        assertEq(baskets.vaultBalance(staticsBasketId, BLEND_AI), beforeBorrow.vault - principal - feeUnderlying);
        assertEq(custody.globalReservedByToken(BLEND_AI), beforeBorrow.globalReserve - principal);
        assertEq(IERC20(BLEND_AI).balanceOf(address(diamond)), beforeBorrow.diamondBlend - principal);
        assertEq(globalRewards.treasuryAccrued(BLEND_AI), beforeBorrow.treasury + feeUnderlying);

        IStaticsBasketCollateral.BasketCollateralPosition memory position =
            basketCollateral.basketCollateralPosition(positionId, staticsBasketId);
        assertEq(position.depositedShares, POSITION_SHARES - quoted.feeShares);
        assertEq(position.lockedShares, quoted.collateralShares);
        assertEq(IERC20(staticsBasketToken).totalSupply(), beforeBorrow.outerSupply - quoted.feeShares);
    }

    function _assertRepaid(
        uint256 positionId,
        IStaticsLending.BorrowQuote memory quoted,
        BooksSnapshot memory beforeBorrow,
        address borrower,
        uint256 borrowerBlendBefore
    ) private view {
        uint256 feeUnderlying = quoted.feeShares;
        assertEq(lending.outstandingPrincipal(staticsBasketId, BLEND_AI), 0);
        assertEq(IERC20(BLEND_AI).balanceOf(borrower), borrowerBlendBefore);
        assertEq(baskets.vaultBalance(staticsBasketId, BLEND_AI), beforeBorrow.vault - feeUnderlying);
        assertEq(custody.globalReservedByToken(BLEND_AI), beforeBorrow.globalReserve);
        assertEq(IERC20(BLEND_AI).balanceOf(address(diamond)), beforeBorrow.diamondBlend);
        assertEq(globalRewards.treasuryAccrued(BLEND_AI), beforeBorrow.treasury + feeUnderlying);
        assertEq(
            custody.reservedByAccount(custody.basketCustodyAccount(staticsBasketId), BLEND_AI),
            beforeBorrow.basketReserve - feeUnderlying
        );

        IStaticsBasketCollateral.BasketCollateralPosition memory position =
            basketCollateral.basketCollateralPosition(positionId, staticsBasketId);
        assertEq(position.depositedShares, POSITION_SHARES - quoted.feeShares);
        assertEq(position.lockedShares, 0);
    }

    function _snapshot() private view returns (BooksSnapshot memory snapshot) {
        snapshot.vault = baskets.vaultBalance(staticsBasketId, BLEND_AI);
        snapshot.basketReserve = custody.reservedByAccount(custody.basketCustodyAccount(staticsBasketId), BLEND_AI);
        snapshot.globalReserve = custody.globalReservedByToken(BLEND_AI);
        snapshot.treasury = globalRewards.treasuryAccrued(BLEND_AI);
        snapshot.diamondBlend = IERC20(BLEND_AI).balanceOf(address(diamond));
        snapshot.outerSupply = IERC20(staticsBasketToken).totalSupply();
        snapshot.outerReserve = custody.globalReservedByToken(staticsBasketToken);
        snapshot.aliceOuter = IERC20(staticsBasketToken).balanceOf(alice);
        snapshot.bobBlend = IERC20(BLEND_AI).balanceOf(bob);
    }

    function _snapshotBlendBooks(IBlendLendingBasket blend)
        private
        view
        returns (uint256 supply, BlendBookSnapshot[] memory snapshots)
    {
        supply = blend.totalSupply();
        address[] memory assets = blend.constituents();
        snapshots = new BlendBookSnapshot[](assets.length);
        for (uint256 i; i < assets.length; ++i) {
            address token = assets[i];
            uint256 backing = blend.backing(token);
            uint256 protocolFees = blend.protocolFees(token);
            assertEq(IERC20(token).balanceOf(BLEND_AI), backing + protocolFees);
            snapshots[i] = BlendBookSnapshot({
                token: token, units: blend.units(token), backing: backing, protocolFees: protocolFees
            });
        }
    }

    function _assertBlendBooksAfterMarket(
        IBlendLendingBasket blend,
        uint256 supplyBefore,
        BlendBookSnapshot[] memory beforeAction
    ) private {
        assertEq(blend.totalSupply(), supplyBefore);
        address[] memory assets = blend.constituents();
        assertEq(assets.length, beforeAction.length);
        for (uint256 i; i < assets.length; ++i) {
            BlendBookSnapshot memory previous = beforeAction[i];
            address token = assets[i];
            uint256 backing = blend.backing(token);
            uint256 protocolFees = blend.protocolFees(token);
            assertEq(token, previous.token);
            assertEq(blend.units(token), previous.units);
            assertGe(backing, previous.backing);
            assertGe(protocolFees, previous.protocolFees);
            assertEq(IERC20(token).balanceOf(BLEND_AI), backing + protocolFees);

            emit log_named_address("Blend backing constituent", token);
            emit log_named_uint("Backing increase after AI market round trip", backing - previous.backing);
            emit log_named_uint(
                "Protocol fee increase after AI market round trip", protocolFees - previous.protocolFees
            );
        }
    }

    function _blendBackingHash(IBlendBasket blend) private view returns (bytes32 result) {
        address[] memory assets = blend.constituents();
        for (uint256 i; i < assets.length; ++i) {
            result = keccak256(abi.encode(result, assets[i], blend.units(assets[i]), blend.backing(assets[i])));
        }
    }
}
