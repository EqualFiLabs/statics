// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {StaticsFlashArbitrageReceiver} from "../../../src/periphery/StaticsFlashArbitrageReceiver.sol";
import {RobinhoodPendleForkBase} from "../../helpers/RobinhoodPendleForkBase.sol";

/// @notice Bidirectional parity arbitrage for a 1:1 PT-NVDA Statics wrapper.
///
/// Expensive sPT-NVDA:
///   Statics PT flash -> mint sPT-NVDA -> sell wrapper -> repay PT
///
/// Cheap sPT-NVDA:
///   Statics PT flash -> buy wrapper -> redeem PT -> repay PT
///
/// Both routes use the production StaticsFlashArbitrageReceiver and the canonical Statics hook.
contract RobinhoodPendleParityArbitrageForkTest is RobinhoodPendleForkBase {
    using PoolIdLibrary for PoolKey;

    uint256 private constant DISTORTION_INPUT = 0.4 ether;
    uint256 private constant DISTORTION_MINT_SHARES = 1 ether;
    uint256 private constant FLASH_SHARES = 0.25 ether;
    uint256 private constant PRICE_PROBE = 0.05 ether;
    uint256 private constant MINIMUM_PT_PROFIT = 0.001 ether;

    struct ParityContext {
        PoolKey pool;
        uint256 baselineQuote;
        uint256 distortedQuote;
        uint256 principal;
        uint256 fee;
        uint256 topUp;
        uint256 treasuryBefore;
        uint256 holderBefore;
        uint128 lockedBefore;
    }

    struct ParityExecution {
        address receiver;
        address asset;
        uint256 profit;
        uint256 gasUsed;
    }

    function setUp() public override {
        super.setUp();
        _fundAliceWithPts();
        _launchPtWrapper(2 ether);
    }

    function testProductionReceiverMintsAndSellsOverpricedPtWrapper() public {
        ParityContext memory context = _prepareOverpricedWrapper();
        ParityExecution memory execution = _executeMintAndSell(context);
        uint256 quoteAfter = _quoteCanonicalExactInput(context.pool, wrapperBasketToken, PT_NVDA, uint128(PRICE_PROBE));
        _assertOverpricedResult(context, execution, quoteAfter);

        emit log("Overpriced sPT-NVDA: Statics flash -> mint -> canonical sale -> PT repayment");
        emit log_named_uint("PT parity mint-and-sell gas", execution.gasUsed);
        emit log_named_uint("PT net profit", execution.profit);
    }

    function testProductionReceiverBuysAndRedeemsUnderpricedPtWrapper() public {
        ParityContext memory context = _prepareUnderpricedWrapper();
        ParityExecution memory execution = _executeBuyAndRedeem(context);
        uint256 quoteAfter = _quoteCanonicalExactInput(context.pool, PT_NVDA, wrapperBasketToken, uint128(PRICE_PROBE));
        _assertUnderpricedResult(context, execution, quoteAfter);

        emit log("Underpriced sPT-NVDA: Statics flash -> canonical buy -> redeem -> PT repayment");
        emit log_named_uint("PT parity buy-and-redeem gas", execution.gasUsed);
        emit log_named_uint("PT net profit", execution.profit);
    }

    function _prepareOverpricedWrapper() private returns (ParityContext memory context) {
        context.pool = _canonicalPool(wrapperBasketId, PT_NVDA);
        context.baselineQuote =
            _quoteCanonicalExactInput(context.pool, wrapperBasketToken, PT_NVDA, uint128(PRICE_PROBE));
        _swapCanonicalExactInput(alice, context.pool, PT_NVDA, wrapperBasketToken, DISTORTION_INPUT);
        context.distortedQuote =
            _quoteCanonicalExactInput(context.pool, wrapperBasketToken, PT_NVDA, uint128(PRICE_PROBE));
        assertGt(context.distortedQuote, context.baselineQuote, "buying wrapper must make it expensive");
        (, uint256[] memory principals, uint256[] memory fees) =
            flashLoans.quoteFlashLoan(wrapperBasketId, FLASH_SHARES);
        context.principal = principals[0];
        context.fee = fees[0];
        context.topUp = baskets.quoteMint(wrapperBasketId, FLASH_SHARES)[0] - context.principal;
        context.treasuryBefore = globalRewards.treasuryAccrued(PT_NVDA);
        context.lockedBefore = staticsHook.lockedLiquidity(context.pool.toId());
        context.holderBefore = IERC20(PT_NVDA).balanceOf(alice);
    }

    function _prepareUnderpricedWrapper() private returns (ParityContext memory context) {
        context.pool = _canonicalPool(wrapperBasketId, PT_NVDA);
        context.baselineQuote =
            _quoteCanonicalExactInput(context.pool, PT_NVDA, wrapperBasketToken, uint128(PRICE_PROBE));
        uint256[] memory mintQuote = baskets.quoteMint(wrapperBasketId, DISTORTION_MINT_SHARES);
        vm.prank(alice);
        baskets.mint(wrapperBasketId, DISTORTION_MINT_SHARES, alice, mintQuote);
        _swapCanonicalExactInput(alice, context.pool, wrapperBasketToken, PT_NVDA, DISTORTION_INPUT);
        context.distortedQuote =
            _quoteCanonicalExactInput(context.pool, PT_NVDA, wrapperBasketToken, uint128(PRICE_PROBE));
        assertGt(context.distortedQuote, context.baselineQuote, "selling wrapper must make it cheap");
        (, uint256[] memory principals, uint256[] memory fees) =
            flashLoans.quoteFlashLoan(wrapperBasketId, FLASH_SHARES);
        context.principal = principals[0];
        context.fee = fees[0];
        context.treasuryBefore = globalRewards.treasuryAccrued(PT_NVDA);
        context.lockedBefore = staticsHook.lockedLiquidity(context.pool.toId());
        context.holderBefore = IERC20(PT_NVDA).balanceOf(address(this));
    }

    function _executeMintAndSell(ParityContext memory context) private returns (ParityExecution memory execution) {
        StaticsFlashArbitrageReceiver receiver = new StaticsFlashArbitrageReceiver(address(diamond));
        execution.receiver = address(receiver);
        vm.prank(alice);
        IERC20(PT_NVDA).approve(address(receiver), context.topUp);
        PoolKey[] memory pools = _singlePool(context.pool);
        uint256[] memory amounts = _singleAmount(FLASH_SHARES);
        uint256[] memory minimums = _singleAmount(MINIMUM_PT_PROFIT);
        uint256 gasBefore = gasleft();
        vm.prank(alice);
        (address[] memory assets, uint256[] memory profits) = receiver.executeMintAndSell(
            wrapperBasketId, FLASH_SHARES, pools, amounts, minimums, block.timestamp + 1 minutes
        );
        execution.gasUsed = gasBefore - gasleft();
        execution.asset = assets[0];
        execution.profit = profits[0];
    }

    function _executeBuyAndRedeem(ParityContext memory context) private returns (ParityExecution memory execution) {
        StaticsFlashArbitrageReceiver receiver = new StaticsFlashArbitrageReceiver(address(diamond));
        execution.receiver = address(receiver);
        PoolKey[] memory pools = _singlePool(context.pool);
        uint256[] memory amounts = _singleAmount(FLASH_SHARES);
        uint256[] memory minimums = _singleAmount(MINIMUM_PT_PROFIT);
        uint256 gasBefore = gasleft();
        (address[] memory assets, uint256[] memory profits) = receiver.executeBuyAndRedeem(
            wrapperBasketId, FLASH_SHARES, pools, amounts, minimums, block.timestamp + 1 minutes
        );
        execution.gasUsed = gasBefore - gasleft();
        execution.asset = assets[0];
        execution.profit = profits[0];
    }

    function _assertOverpricedResult(ParityContext memory context, ParityExecution memory execution, uint256 quoteAfter)
        private
        view
    {
        assertEq(execution.asset, PT_NVDA);
        assertEq(context.principal, FLASH_SHARES);
        assertGt(context.fee, 0);
        assertGe(execution.profit, MINIMUM_PT_PROFIT);
        assertEq(IERC20(PT_NVDA).balanceOf(alice), context.holderBefore + execution.profit);
        _assertPriceAndFees(context, execution, quoteAfter, context.fee + MINT_FEE_SHARES);
    }

    function _assertUnderpricedResult(
        ParityContext memory context,
        ParityExecution memory execution,
        uint256 quoteAfter
    ) private view {
        assertEq(execution.asset, PT_NVDA);
        assertEq(context.principal, FLASH_SHARES);
        assertGt(context.fee, 0);
        assertGe(execution.profit, MINIMUM_PT_PROFIT);
        assertEq(IERC20(PT_NVDA).balanceOf(address(this)), context.holderBefore + execution.profit);
        _assertPriceAndFees(context, execution, quoteAfter, context.fee);
    }

    function _assertPriceAndFees(
        ParityContext memory context,
        ParityExecution memory execution,
        uint256 quoteAfter,
        uint256 minimumFeeAccrual
    ) private view {
        assertLt(quoteAfter, context.distortedQuote);
        assertLt(
            _difference(quoteAfter, context.baselineQuote), _difference(context.distortedQuote, context.baselineQuote)
        );
        assertGe(globalRewards.treasuryAccrued(PT_NVDA) - context.treasuryBefore, minimumFeeAccrual);
        assertGt(staticsHook.lockedLiquidity(context.pool.toId()), context.lockedBefore);
        _assertReceiverClean(StaticsFlashArbitrageReceiver(execution.receiver));
    }

    function _assertReceiverClean(StaticsFlashArbitrageReceiver receiver) private view {
        assertEq(IERC20(PT_NVDA).balanceOf(address(receiver)), 0);
        assertEq(IERC20(wrapperBasketToken).balanceOf(address(receiver)), 0);
        assertEq(IERC20(PT_NVDA).allowance(address(receiver), address(diamond)), 0);
        assertEq(IERC20(wrapperBasketToken).allowance(address(receiver), address(diamond)), 0);
    }

    function _singlePool(PoolKey memory pool) private pure returns (PoolKey[] memory pools) {
        pools = new PoolKey[](1);
        pools[0] = pool;
    }

    function _singleAmount(uint256 value) private pure returns (uint256[] memory values) {
        values = new uint256[](1);
        values[0] = value;
    }

    function _difference(uint256 first, uint256 second) private pure returns (uint256) {
        return first > second ? first - second : second - first;
    }
}
