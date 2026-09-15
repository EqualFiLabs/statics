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

    function setUp() public override {
        super.setUp();
        _fundAliceWithPts();
        _launchPtWrapper(2 ether);
    }

    function testProductionReceiverMintsAndSellsOverpricedPtWrapper() public {
        PoolKey memory pool = _canonicalPool(wrapperBasketId, PT_NVDA);
        uint256 baselineQuote = _quoteCanonicalExactInput(pool, wrapperBasketToken, PT_NVDA, uint128(PRICE_PROBE));
        _swapCanonicalExactInput(alice, pool, PT_NVDA, wrapperBasketToken, DISTORTION_INPUT);
        uint256 distortedQuote = _quoteCanonicalExactInput(pool, wrapperBasketToken, PT_NVDA, uint128(PRICE_PROBE));
        assertGt(distortedQuote, baselineQuote, "buying wrapper must make it expensive");

        StaticsFlashArbitrageReceiver receiver = new StaticsFlashArbitrageReceiver(address(diamond));
        (, uint256[] memory principals, uint256[] memory fees) =
            flashLoans.quoteFlashLoan(wrapperBasketId, FLASH_SHARES);
        uint256[] memory mintQuote = baskets.quoteMint(wrapperBasketId, FLASH_SHARES);
        uint256 topUp = mintQuote[0] - principals[0];
        uint256 treasuryBefore = globalRewards.treasuryAccrued(PT_NVDA);
        uint128 lockedBefore = staticsHook.lockedLiquidity(pool.toId());
        uint256 aliceBefore = IERC20(PT_NVDA).balanceOf(alice);

        vm.prank(alice);
        IERC20(PT_NVDA).approve(address(receiver), topUp);
        uint256 gasBefore = gasleft();
        vm.prank(alice);
        (address[] memory assets, uint256[] memory profits) = receiver.executeMintAndSell(
            wrapperBasketId,
            FLASH_SHARES,
            _singlePool(pool),
            _singleAmount(FLASH_SHARES),
            _singleAmount(MINIMUM_PT_PROFIT),
            block.timestamp + 1 minutes
        );
        uint256 executionGas = gasBefore - gasleft();

        uint256 quoteAfter = _quoteCanonicalExactInput(pool, wrapperBasketToken, PT_NVDA, uint128(PRICE_PROBE));
        assertEq(assets[0], PT_NVDA);
        assertEq(principals[0], FLASH_SHARES);
        assertGt(fees[0], 0);
        assertGe(profits[0], MINIMUM_PT_PROFIT);
        assertEq(IERC20(PT_NVDA).balanceOf(alice), aliceBefore + profits[0]);
        assertLt(quoteAfter, distortedQuote);
        assertLt(_difference(quoteAfter, baselineQuote), _difference(distortedQuote, baselineQuote));
        assertGe(globalRewards.treasuryAccrued(PT_NVDA) - treasuryBefore, fees[0] + MINT_FEE_SHARES);
        assertGt(staticsHook.lockedLiquidity(pool.toId()), lockedBefore);
        _assertReceiverClean(receiver);

        emit log("Overpriced sPT-NVDA: Statics flash -> mint -> canonical sale -> PT repayment");
        emit log_named_uint("PT parity mint-and-sell gas", executionGas);
        emit log_named_uint("PT net profit", profits[0]);
    }

    function testProductionReceiverBuysAndRedeemsUnderpricedPtWrapper() public {
        PoolKey memory pool = _canonicalPool(wrapperBasketId, PT_NVDA);
        uint256 baselineQuote = _quoteCanonicalExactInput(pool, PT_NVDA, wrapperBasketToken, uint128(PRICE_PROBE));
        uint256[] memory mintQuote = baskets.quoteMint(wrapperBasketId, DISTORTION_MINT_SHARES);
        vm.prank(alice);
        baskets.mint(wrapperBasketId, DISTORTION_MINT_SHARES, alice, mintQuote);
        _swapCanonicalExactInput(alice, pool, wrapperBasketToken, PT_NVDA, DISTORTION_INPUT);
        uint256 distortedQuote = _quoteCanonicalExactInput(pool, PT_NVDA, wrapperBasketToken, uint128(PRICE_PROBE));
        assertGt(distortedQuote, baselineQuote, "selling wrapper must make it cheap");

        StaticsFlashArbitrageReceiver receiver = new StaticsFlashArbitrageReceiver(address(diamond));
        (, uint256[] memory principals, uint256[] memory fees) =
            flashLoans.quoteFlashLoan(wrapperBasketId, FLASH_SHARES);
        uint256 treasuryBefore = globalRewards.treasuryAccrued(PT_NVDA);
        uint128 lockedBefore = staticsHook.lockedLiquidity(pool.toId());
        uint256 callerBefore = IERC20(PT_NVDA).balanceOf(address(this));

        uint256 gasBefore = gasleft();
        (address[] memory assets, uint256[] memory profits) = receiver.executeBuyAndRedeem(
            wrapperBasketId,
            FLASH_SHARES,
            _singlePool(pool),
            _singleAmount(FLASH_SHARES),
            _singleAmount(MINIMUM_PT_PROFIT),
            block.timestamp + 1 minutes
        );
        uint256 executionGas = gasBefore - gasleft();

        uint256 quoteAfter = _quoteCanonicalExactInput(pool, PT_NVDA, wrapperBasketToken, uint128(PRICE_PROBE));
        assertEq(assets[0], PT_NVDA);
        assertEq(principals[0], FLASH_SHARES);
        assertGt(fees[0], 0);
        assertGe(profits[0], MINIMUM_PT_PROFIT);
        assertEq(IERC20(PT_NVDA).balanceOf(address(this)), callerBefore + profits[0]);
        assertLt(quoteAfter, distortedQuote);
        assertLt(_difference(quoteAfter, baselineQuote), _difference(distortedQuote, baselineQuote));
        assertGe(globalRewards.treasuryAccrued(PT_NVDA) - treasuryBefore, fees[0]);
        assertGt(staticsHook.lockedLiquidity(pool.toId()), lockedBefore);
        _assertReceiverClean(receiver);

        emit log("Underpriced sPT-NVDA: Statics flash -> canonical buy -> redeem -> PT repayment");
        emit log_named_uint("PT parity buy-and-redeem gas", executionGas);
        emit log_named_uint("PT net profit", profits[0]);
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
