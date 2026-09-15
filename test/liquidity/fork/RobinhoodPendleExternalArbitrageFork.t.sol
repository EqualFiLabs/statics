// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {IStaticsBasket} from "../../../src/interfaces/IStaticsBasket.sol";
import {IStaticsFlashAssetBorrower} from "../../../src/interfaces/IStaticsFlashAssetBorrower.sol";
import {IStaticsFlashLoan} from "../../../src/interfaces/IStaticsFlashLoan.sol";
import {CanonicalV4Router} from "../../helpers/CanonicalPoolTestBase.sol";
import {
    IPendleMarket,
    IPendleMarketSwapCallback,
    IPendleRouterStatic,
    IPendleSY,
    IRobinhoodV3Quoter,
    IRobinhoodV3Router,
    RobinhoodPendleForkBase
} from "../../helpers/RobinhoodPendleForkBase.sol";

struct PendleExternalRouteConfig {
    address staticsDiamond;
    address canonicalRouter;
    uint256 termBasketId;
    address termBasketToken;
    address routerStatic;
    address v3Router;
    address v3Quoter;
    address usdg;
    PoolKey[] pools;
    address[] markets;
    address[] syTokens;
    address[] ptTokens;
    address[] underlyings;
    uint24[] v3Fees;
}

/// @notice Test-only executor crossing Statics, three Pendle markets, three SY adapters, and V3.
/// @dev The second entrypoint uses Pendle's production flash-settled market callback. It is not a
///      generic or free flash loan: the originating NVDA market receives its exact SY debt before
///      the callback returns.
contract PendleStaticsExternalArbitrageReceiver is IStaticsFlashAssetBorrower, IPendleMarketSwapCallback {
    using SafeERC20 for IERC20;

    bytes32 private constant STATICS_CALLBACK_SUCCESS = keccak256("IStaticsFlashAssetBorrower.onStaticsFlashLoanAsset");
    uint256 private constant BPS = 10_000;
    uint256 private constant SLIPPAGE_BPS = 100;
    uint8 private constant PENDLE_BUY = 1;
    uint8 private constant PENDLE_EXTERNAL_FUNDING = 2;

    error ActiveRoute();
    error DirtyBalance(address token);
    error InvalidCallback();
    error InvalidConfiguration();
    error InsufficientRepayment(uint256 required, uint256 available);
    error MinimumProfitNotMet(uint256 minimum, uint256 actual);
    error SlippageExceeded(uint256 limit, uint256 actual);

    IStaticsFlashLoan public immutable flashLoans;
    IStaticsBasket public immutable baskets;
    CanonicalV4Router public immutable canonicalRouter;
    uint256 public immutable termBasketId;
    address public immutable termBasketToken;
    IPendleRouterStatic public immutable routerStatic;
    IRobinhoodV3Router public immutable v3Router;
    IRobinhoodV3Quoter public immutable v3Quoter;
    address public immutable usdg;

    PoolKey[] private _pools;
    address[] private _markets;
    address[] private _syTokens;
    address[] private _ptTokens;
    address[] private _underlyings;
    uint24[] private _v3Fees;

    bool private _staticsActive;
    uint8 private _pendleCallbackKind;
    address private _activePendleMarket;
    address private _activeSy;
    uint256 private _expectedPtOut;
    uint256 private _maximumSyIn;
    uint256 private _minimumProfit;

    uint256 public observedStaticsPrincipal;
    uint256 public observedStaticsFee;
    uint256 public observedPendleSyDebt;
    uint256 public observedPendleSyFee;
    uint256 public discountedTermShares;

    constructor(PendleExternalRouteConfig memory config) {
        uint256 length = config.pools.length;
        if (
            length != 3 || config.markets.length != length || config.syTokens.length != length
                || config.ptTokens.length != length || config.underlyings.length != length
                || config.v3Fees.length != length
        ) revert InvalidConfiguration();
        flashLoans = IStaticsFlashLoan(config.staticsDiamond);
        baskets = IStaticsBasket(config.staticsDiamond);
        canonicalRouter = CanonicalV4Router(config.canonicalRouter);
        termBasketId = config.termBasketId;
        termBasketToken = config.termBasketToken;
        routerStatic = IPendleRouterStatic(config.routerStatic);
        v3Router = IRobinhoodV3Router(config.v3Router);
        v3Quoter = IRobinhoodV3Quoter(config.v3Quoter);
        usdg = config.usdg;
        for (uint256 i; i < length; ++i) {
            _pools.push(config.pools[i]);
            _markets.push(config.markets[i]);
            _syTokens.push(config.syTokens[i]);
            _ptTokens.push(config.ptTokens[i]);
            _underlyings.push(config.underlyings[i]);
            _v3Fees.push(config.v3Fees[i]);
        }
    }

    function executeStaticsFunded(uint256 flashAmount, uint256 termShares, uint256 minimumProfit)
        external
        returns (uint256 profit)
    {
        _beginRoute(minimumProfit);
        _staticsActive = true;
        flashLoans.flashLoanAsset(usdg, flashAmount, address(this), abi.encode(termShares));
        _staticsActive = false;
        profit = IERC20(usdg).balanceOf(address(this));
        if (profit < minimumProfit) revert MinimumProfitNotMet(minimumProfit, profit);
        IERC20(usdg).safeTransfer(msg.sender, profit);
        _assertCleanBalances();
    }

    function executePendleFunded(uint256 exactPtOut, uint256 minimumProfit) external returns (uint256 profit) {
        _beginRoute(minimumProfit);
        _pendleCallbackKind = PENDLE_EXTERNAL_FUNDING;
        _activePendleMarket = _markets[0];
        _activeSy = _syTokens[0];
        _expectedPtOut = exactPtOut;
        (uint256 netSyIn, uint256 netSyFee) =
            IPendleMarket(_markets[0]).swapSyForExactPt(address(this), exactPtOut, hex"02");
        if (netSyIn != observedPendleSyDebt) revert InvalidCallback();
        observedPendleSyFee = netSyFee;
        _clearPendleCallback();

        _redeemSurplusSyToUsdg(0);
        _liquidatePtToUsdg(0, IERC20(_ptTokens[0]).balanceOf(address(this)));
        profit = IERC20(usdg).balanceOf(address(this));
        if (profit < minimumProfit) revert MinimumProfitNotMet(minimumProfit, profit);
        IERC20(usdg).safeTransfer(msg.sender, profit);
        _assertCleanBalances();
    }

    function onStaticsFlashLoanAsset(address initiator, address asset, uint256 amount, uint256 fee, bytes calldata data)
        external
        returns (bytes32)
    {
        if (
            msg.sender != address(flashLoans) || initiator != address(this) || !_staticsActive || asset != usdg
                || data.length == 0
        ) revert InvalidCallback();
        observedStaticsPrincipal = amount;
        observedStaticsFee = fee;
        uint256 termShares = abi.decode(data, (uint256));

        uint256[] memory mintQuote = baskets.quoteMint(termBasketId, termShares);
        for (uint256 i; i < 3; ++i) {
            _acquireExactPt(i, mintQuote[i]);
        }
        for (uint256 i; i < 3; ++i) {
            IERC20(_ptTokens[i]).forceApprove(address(baskets), mintQuote[i]);
        }
        baskets.mint(termBasketId, termShares, address(this), mintQuote);
        for (uint256 i; i < 3; ++i) {
            IERC20(_ptTokens[i]).forceApprove(address(baskets), 0);
        }

        uint256 perPool = termShares / 3;
        for (uint256 i; i < 3; ++i) {
            uint256 saleAmount = i == 2 ? termShares - perPool * 2 : perPool;
            _swapCanonical(i, termBasketToken, _ptTokens[i], saleAmount);
        }
        for (uint256 i; i < 3; ++i) {
            _liquidatePtToUsdg(i, IERC20(_ptTokens[i]).balanceOf(address(this)));
        }

        uint256 repayment = amount + fee;
        uint256 available = IERC20(usdg).balanceOf(address(this));
        if (available < repayment) revert InsufficientRepayment(repayment, available);
        uint256 profit = available - repayment;
        if (profit < _minimumProfit) revert MinimumProfitNotMet(_minimumProfit, profit);
        IERC20(usdg).forceApprove(address(flashLoans), repayment);
        return STATICS_CALLBACK_SUCCESS;
    }

    function swapCallback(int256 ptToAccount, int256 syToAccount, bytes calldata data) external {
        if (
            msg.sender != _activePendleMarket || ptToAccount <= 0 || syToAccount >= 0
                || uint256(ptToAccount) != _expectedPtOut
        ) revert InvalidCallback();
        uint256 syOwed = uint256(-syToAccount);
        if (_pendleCallbackKind == PENDLE_BUY) {
            if (data.length != 1 || data[0] != 0x01 || syOwed > _maximumSyIn) revert InvalidCallback();
            IERC20(_activeSy).safeTransfer(msg.sender, syOwed);
            return;
        }
        if (_pendleCallbackKind != PENDLE_EXTERNAL_FUNDING || data.length != 1 || data[0] != 0x02) {
            revert InvalidCallback();
        }

        observedPendleSyDebt = syOwed;
        discountedTermShares = _swapCanonical(0, _ptTokens[0], termBasketToken, uint256(ptToAccount));
        uint256[] memory minimums = baskets.quoteRedeem(termBasketId, discountedTermShares);
        baskets.redeem(termBasketId, discountedTermShares, address(this), minimums);

        _liquidatePtToUsdg(1, IERC20(_ptTokens[1]).balanceOf(address(this)));
        _liquidatePtToUsdg(2, IERC20(_ptTokens[2]).balanceOf(address(this)));
        _acquireSyDebtWithUsdg(0, syOwed);
        IERC20(_activeSy).safeTransfer(msg.sender, syOwed);
    }

    function _beginRoute(uint256 minimumProfit) private {
        if (_staticsActive || _pendleCallbackKind != 0) revert ActiveRoute();
        _assertCleanBalances();
        _minimumProfit = minimumProfit;
        observedStaticsPrincipal = 0;
        observedStaticsFee = 0;
        observedPendleSyDebt = 0;
        observedPendleSyFee = 0;
        discountedTermShares = 0;
    }

    function _acquireExactPt(uint256 index, uint256 exactPtOut) private {
        (uint256 syIn,,,) = routerStatic.swapSyForExactPtStatic(_markets[index], exactPtOut);
        uint256 syBefore = IERC20(_syTokens[index]).balanceOf(address(this));
        uint256 underlyingNeeded = _underlyingForSy(index, syIn);
        _v3ExactOutput(index, usdg, _underlyings[index], underlyingNeeded);

        IERC20(_underlyings[index]).forceApprove(_syTokens[index], underlyingNeeded);
        uint256 syOut = IPendleSY(_syTokens[index]).deposit(address(this), _underlyings[index], underlyingNeeded, syIn);
        IERC20(_underlyings[index]).forceApprove(_syTokens[index], 0);

        _pendleCallbackKind = PENDLE_BUY;
        _activePendleMarket = _markets[index];
        _activeSy = _syTokens[index];
        _expectedPtOut = exactPtOut;
        _maximumSyIn = syOut;
        (uint256 netSyIn,) = IPendleMarket(_markets[index]).swapSyForExactPt(address(this), exactPtOut, hex"01");
        if (netSyIn > syOut) revert SlippageExceeded(syOut, netSyIn);
        _clearPendleCallback();

        uint256 remainingSy = IERC20(_syTokens[index]).balanceOf(address(this)) - syBefore;
        if (remainingSy != 0) {
            uint256 recovered =
                IPendleSY(_syTokens[index]).redeem(address(this), remainingSy, _underlyings[index], 1, false);
            _v3ExactInput(index, _underlyings[index], usdg, recovered);
        }
    }

    function _acquireSyDebtWithUsdg(uint256 index, uint256 syDebt) private {
        uint256 underlyingNeeded = _underlyingForSy(index, syDebt);
        _v3ExactOutput(index, usdg, _underlyings[index], underlyingNeeded);
        IERC20(_underlyings[index]).forceApprove(_syTokens[index], underlyingNeeded);
        IPendleSY(_syTokens[index]).deposit(address(this), _underlyings[index], underlyingNeeded, syDebt);
        IERC20(_underlyings[index]).forceApprove(_syTokens[index], 0);
    }

    function _liquidatePtToUsdg(uint256 index, uint256 exactPtIn) private returns (uint256 usdgOut) {
        if (exactPtIn == 0) return 0;
        uint256 syBefore = IERC20(_syTokens[index]).balanceOf(address(this));
        IERC20(_ptTokens[index]).safeTransfer(_markets[index], exactPtIn);
        IPendleMarket(_markets[index]).swapExactPtForSy(address(this), exactPtIn, "");
        uint256 syOut = IERC20(_syTokens[index]).balanceOf(address(this)) - syBefore;
        uint256 underlyingOut = IPendleSY(_syTokens[index]).redeem(address(this), syOut, _underlyings[index], 1, false);
        usdgOut = _v3ExactInput(index, _underlyings[index], usdg, underlyingOut);
    }

    function _redeemSurplusSyToUsdg(uint256 index) private {
        uint256 syBalance = IERC20(_syTokens[index]).balanceOf(address(this));
        if (syBalance == 0) return;
        uint256 underlyingOut =
            IPendleSY(_syTokens[index]).redeem(address(this), syBalance, _underlyings[index], 1, false);
        _v3ExactInput(index, _underlyings[index], usdg, underlyingOut);
    }

    function _swapCanonical(uint256 index, address input, address output, uint256 amountIn)
        private
        returns (uint256 amountOut)
    {
        PoolKey memory pool = _pools[index];
        bool zeroForOne;
        if (Currency.unwrap(pool.currency0) == input && Currency.unwrap(pool.currency1) == output) {
            zeroForOne = true;
        } else if (Currency.unwrap(pool.currency1) == input && Currency.unwrap(pool.currency0) == output) {
            zeroForOne = false;
        } else {
            revert InvalidConfiguration();
        }
        uint256 outputBefore = IERC20(output).balanceOf(address(this));
        IERC20(input).forceApprove(address(canonicalRouter), amountIn);
        canonicalRouter.swap(
            pool,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            })
        );
        IERC20(input).forceApprove(address(canonicalRouter), 0);
        amountOut = IERC20(output).balanceOf(address(this)) - outputBefore;
    }

    function _v3ExactInput(uint256 index, address input, address output, uint256 amountIn)
        private
        returns (uint256 amountOut)
    {
        (uint256 quote,,,) = v3Quoter.quoteExactInputSingle(
            IRobinhoodV3Quoter.QuoteExactInputSingleParams({
                tokenIn: input, tokenOut: output, amountIn: amountIn, fee: _v3Fees[index], sqrtPriceLimitX96: 0
            })
        );
        IERC20(input).forceApprove(address(v3Router), amountIn);
        amountOut = v3Router.exactInputSingle(
            IRobinhoodV3Router.ExactInputSingleParams({
                tokenIn: input,
                tokenOut: output,
                fee: _v3Fees[index],
                recipient: address(this),
                amountIn: amountIn,
                amountOutMinimum: Math.mulDiv(quote, BPS - SLIPPAGE_BPS, BPS),
                sqrtPriceLimitX96: 0
            })
        );
        IERC20(input).forceApprove(address(v3Router), 0);
    }

    function _v3ExactOutput(uint256 index, address input, address output, uint256 amountOut)
        private
        returns (uint256 amountIn)
    {
        (uint256 quote,,,) = v3Quoter.quoteExactOutputSingle(
            IRobinhoodV3Quoter.QuoteExactOutputSingleParams({
                tokenIn: input, tokenOut: output, amount: amountOut, fee: _v3Fees[index], sqrtPriceLimitX96: 0
            })
        );
        uint256 maximum = Math.mulDiv(quote, BPS + SLIPPAGE_BPS, BPS, Math.Rounding.Ceil);
        IERC20(input).forceApprove(address(v3Router), maximum);
        amountIn = v3Router.exactOutputSingle(
            IRobinhoodV3Router.ExactOutputSingleParams({
                tokenIn: input,
                tokenOut: output,
                fee: _v3Fees[index],
                recipient: address(this),
                amountOut: amountOut,
                amountInMaximum: maximum,
                sqrtPriceLimitX96: 0
            })
        );
        IERC20(input).forceApprove(address(v3Router), 0);
    }

    function _underlyingForSy(uint256 index, uint256 syAmount) private view returns (uint256 underlyingAmount) {
        uint256 preview = IPendleSY(_syTokens[index]).previewRedeem(_underlyings[index], syAmount);
        underlyingAmount = Math.mulDiv(preview, BPS + SLIPPAGE_BPS, BPS, Math.Rounding.Ceil) + 1;
        if (IPendleSY(_syTokens[index]).previewDeposit(_underlyings[index], underlyingAmount) < syAmount) {
            revert SlippageExceeded(syAmount, underlyingAmount);
        }
    }

    function _clearPendleCallback() private {
        _pendleCallbackKind = 0;
        _activePendleMarket = address(0);
        _activeSy = address(0);
        _expectedPtOut = 0;
        _maximumSyIn = 0;
    }

    function _assertCleanBalances() private view {
        if (IERC20(usdg).balanceOf(address(this)) != 0) revert DirtyBalance(usdg);
        if (IERC20(termBasketToken).balanceOf(address(this)) != 0) revert DirtyBalance(termBasketToken);
        for (uint256 i; i < 3; ++i) {
            if (IERC20(_ptTokens[i]).balanceOf(address(this)) != 0) revert DirtyBalance(_ptTokens[i]);
            if (IERC20(_syTokens[i]).balanceOf(address(this)) != 0) revert DirtyBalance(_syTokens[i]);
            if (IERC20(_underlyings[i]).balanceOf(address(this)) != 0) revert DirtyBalance(_underlyings[i]);
        }
    }
}

/// @notice Cross-venue NAV arbitrage using each protocol's native atomic funding system.
contract RobinhoodPendleExternalArbitrageForkTest is RobinhoodPendleForkBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint256 private constant USDG_FUNDING = 70_000_000;
    uint256 private constant USDG_POOL_SEED = 5_000_000;
    uint256 private constant USDG_RESERVE_SHARES = 40 ether;
    uint256 private constant STATICS_FLASH_USDG = 10_000_000;
    uint256 private constant STATICS_ARB_SHARES = 2 ether;
    uint256 private constant PENDLE_FLASH_PT = 0.005 ether;
    uint256 private constant MINIMUM_USDG_PROFIT = 1_000;
    uint256 private constant TERM_DISTORTION_SHARES = 0.25 ether;
    uint256 private constant MAX_DISTORTION_STEPS = 8;
    uint256 private constant ROUTE_MARGIN_BPS = 200;

    function setUp() public override {
        super.setUp();
        _fundAliceWithPts();
        _fundAliceWithLiveUsdg(USDG_FUNDING);
        _launchTermBasket(2 ether);
        _launchUsdgReserve(USDG_POOL_SEED, USDG_RESERVE_SHARES);
        assertGe(flashLoans.maxFlashLoan(USDG), STATICS_FLASH_USDG);
    }

    function testStaticsUsdGFlashArbitragesOverpricedTermAcrossExternalVenues() public {
        uint256[3] memory baseline = _termSaleQuotes();
        _makeTermExpensive();
        uint256[3] memory distorted = _termSaleQuotes();
        for (uint256 i; i < 3; ++i) {
            assertGt(distorted[i], baseline[i]);
        }

        PendleStaticsExternalArbitrageReceiver receiver = _receiver();
        uint256 quotedFee = flashLoans.quoteFlashLoanAsset(USDG, STATICS_FLASH_USDG);
        uint256 diamondBefore = IERC20(USDG).balanceOf(address(diamond));
        uint256 reserveBefore = custody.globalReservedByToken(USDG);
        uint256 treasuryBefore = globalRewards.treasuryAccrued(USDG);
        uint128[3] memory lockedBefore = _lockedLiquidity();
        uint256 callerBefore = IERC20(USDG).balanceOf(address(this));

        uint256 gasBefore = gasleft();
        uint256 profit = receiver.executeStaticsFunded(STATICS_FLASH_USDG, STATICS_ARB_SHARES, MINIMUM_USDG_PROFIT);
        uint256 executionGas = gasBefore - gasleft();

        assertEq(receiver.observedStaticsPrincipal(), STATICS_FLASH_USDG);
        assertEq(receiver.observedStaticsFee(), quotedFee);
        assertGe(profit, MINIMUM_USDG_PROFIT);
        assertEq(IERC20(USDG).balanceOf(address(this)), callerBefore + profit);
        assertEq(IERC20(USDG).balanceOf(address(diamond)), diamondBefore + quotedFee);
        assertEq(custody.globalReservedByToken(USDG), reserveBefore + quotedFee);
        assertEq(globalRewards.treasuryAccrued(USDG), treasuryBefore + quotedFee);
        _assertPricesImproved(baseline, distorted);
        _assertHookAndReceiverClean(receiver, lockedBefore);

        emit log("Statics-funded NAV route: USDG flash -> stock/SY/PT -> sTERM -> PT/SY/stock -> USDG");
        emit log_named_uint("Cross-venue Statics-funded gas", executionGas);
        emit log_named_uint("USDG net profit", profit);
    }

    function testPendleCallbackFundsUnderpricedTermArbitrage() public {
        PoolKey memory nvdaPool = _canonicalPool(termBasketId, PT_NVDA);
        uint256 baseline = _quoteCanonicalExactInput(nvdaPool, PT_NVDA, termBasketToken, uint128(PENDLE_FLASH_PT));
        uint256 steps = _distortUntilPendleRouteIsFundable(nvdaPool);
        uint256 distorted = _quoteCanonicalExactInput(nvdaPool, PT_NVDA, termBasketToken, uint128(PENDLE_FLASH_PT));
        assertGt(distorted, baseline);

        PendleStaticsExternalArbitrageReceiver receiver = _receiver();
        uint128 lockedBefore = staticsHook.lockedLiquidity(nvdaPool.toId());
        uint256 callerBefore = IERC20(USDG).balanceOf(address(this));
        uint256 gasBefore = gasleft();
        uint256 profit = receiver.executePendleFunded(PENDLE_FLASH_PT, MINIMUM_USDG_PROFIT);
        uint256 executionGas = gasBefore - gasleft();

        uint256 quoteAfter = _quoteCanonicalExactInput(nvdaPool, PT_NVDA, termBasketToken, uint128(PENDLE_FLASH_PT));
        assertGt(receiver.observedPendleSyDebt(), 0);
        assertGt(receiver.observedPendleSyFee(), 0);
        assertGt(receiver.discountedTermShares(), 0);
        assertGe(profit, MINIMUM_USDG_PROFIT);
        assertEq(IERC20(USDG).balanceOf(address(this)), callerBefore + profit);
        assertLt(quoteAfter, distorted);
        assertLt(_difference(quoteAfter, baseline), _difference(distorted, baseline));
        assertGt(staticsHook.lockedLiquidity(nvdaPool.toId()), lockedBefore);
        _assertReceiverBalances(receiver);

        emit log("Pendle-funded NAV route: exact PT callback -> cheap sTERM -> vector unwind -> exact SY settlement");
        emit log("The Pendle leg is a flash-settled swap callback, not a generic flash loan");
        emit log_named_uint("Bounded distortion steps", steps);
        emit log_named_uint("Cross-venue Pendle-funded gas", executionGas);
        emit log_named_uint("USDG net profit", profit);
    }

    function testCrossVenueMinimumProfitFailureRollsBackAtomically() public {
        _makeTermExpensive();
        PendleStaticsExternalArbitrageReceiver receiver = _receiver();
        uint256 diamondBefore = IERC20(USDG).balanceOf(address(diamond));
        uint256 reserveBefore = custody.globalReservedByToken(USDG);
        uint256 supplyBefore = IERC20(termBasketToken).totalSupply();
        uint160[3] memory staticsPricesBefore = _staticsSqrtPrices();
        uint256[3] memory marketPtBefore;
        uint256[3] memory marketSyBefore;
        uint256[3] memory v3UsdgBefore;
        for (uint256 i; i < 3; ++i) {
            TermMarket memory configured = _termMarket(i);
            marketPtBefore[i] = IERC20(configured.pt).balanceOf(configured.market);
            marketSyBefore[i] = IERC20(configured.sy).balanceOf(configured.market);
            v3UsdgBefore[i] = IERC20(USDG).balanceOf(configured.v3Pool);
        }

        vm.expectPartialRevert(PendleStaticsExternalArbitrageReceiver.MinimumProfitNotMet.selector);
        receiver.executeStaticsFunded(STATICS_FLASH_USDG, STATICS_ARB_SHARES, type(uint256).max);

        assertEq(IERC20(USDG).balanceOf(address(diamond)), diamondBefore);
        assertEq(custody.globalReservedByToken(USDG), reserveBefore);
        assertEq(IERC20(termBasketToken).totalSupply(), supplyBefore);
        uint160[3] memory staticsPricesAfter = _staticsSqrtPrices();
        for (uint256 i; i < 3; ++i) {
            TermMarket memory configured = _termMarket(i);
            assertEq(staticsPricesAfter[i], staticsPricesBefore[i]);
            assertEq(IERC20(configured.pt).balanceOf(configured.market), marketPtBefore[i]);
            assertEq(IERC20(configured.sy).balanceOf(configured.market), marketSyBefore[i]);
            assertEq(IERC20(USDG).balanceOf(configured.v3Pool), v3UsdgBefore[i]);
        }
        _assertReceiverBalances(receiver);
    }

    function _makeTermExpensive() private {
        for (uint256 i; i < 3; ++i) {
            TermMarket memory configured = _termMarket(i);
            uint256 amountIn = Math.mulDiv(termBundles[i], 2 ether, SHARE_SCALE);
            _swapCanonicalExactInput(
                alice, _canonicalPool(termBasketId, configured.pt), configured.pt, termBasketToken, amountIn
            );
        }
    }

    function _distortUntilPendleRouteIsFundable(PoolKey memory nvdaPool) private returns (uint256 steps) {
        uint256 totalShares = TERM_DISTORTION_SHARES * MAX_DISTORTION_STEPS;
        uint256[] memory mintQuote = baskets.quoteMint(termBasketId, totalShares);
        vm.prank(alice);
        baskets.mint(termBasketId, totalShares, alice, mintQuote);

        for (steps = 1; steps <= MAX_DISTORTION_STEPS; ++steps) {
            _swapCanonicalExactInput(alice, nvdaPool, termBasketToken, PT_NVDA, TERM_DISTORTION_SHARES);
            uint256 discountedShares =
                _quoteCanonicalExactInput(nvdaPool, PT_NVDA, termBasketToken, uint128(PENDLE_FLASH_PT));
            if (discountedShares <= REDEMPTION_FEE_SHARES) continue;
            uint256[] memory redemption = baskets.quoteRedeem(termBasketId, discountedShares);
            uint256 otherLegProceeds = _quotePtUsdg(1, redemption[1]) + _quotePtUsdg(2, redemption[2]);
            uint256 nvdaDebtCost = _quoteUsdgForExactPt(0, PENDLE_FLASH_PT);
            uint256 required = Math.mulDiv(nvdaDebtCost, BPS + ROUTE_MARGIN_BPS, BPS) + MINIMUM_USDG_PROFIT;
            if (otherLegProceeds >= required) return steps;
        }
        fail("bounded sTERM distortion did not fund Pendle callback debt");
    }

    function _receiver() private returns (PendleStaticsExternalArbitrageReceiver receiver) {
        PoolKey[] memory pools = new PoolKey[](3);
        address[] memory markets = new address[](3);
        address[] memory syTokens = new address[](3);
        address[] memory ptTokens = new address[](3);
        address[] memory underlyings = new address[](3);
        uint24[] memory v3Fees = new uint24[](3);
        for (uint256 i; i < 3; ++i) {
            TermMarket memory configured = _termMarket(i);
            pools[i] = _canonicalPool(termBasketId, configured.pt);
            markets[i] = configured.market;
            syTokens[i] = configured.sy;
            ptTokens[i] = configured.pt;
            underlyings[i] = configured.underlying;
            v3Fees[i] = configured.v3Fee;
        }
        receiver = new PendleStaticsExternalArbitrageReceiver(
            PendleExternalRouteConfig({
                staticsDiamond: address(diamond),
                canonicalRouter: address(canonicalRouter),
                termBasketId: termBasketId,
                termBasketToken: termBasketToken,
                routerStatic: PENDLE_ROUTER_STATIC,
                v3Router: V3_ROUTER,
                v3Quoter: V3_QUOTER,
                usdg: USDG,
                pools: pools,
                markets: markets,
                syTokens: syTokens,
                ptTokens: ptTokens,
                underlyings: underlyings,
                v3Fees: v3Fees
            })
        );
    }

    function _termSaleQuotes() private returns (uint256[3] memory quotes) {
        for (uint256 i; i < 3; ++i) {
            TermMarket memory configured = _termMarket(i);
            quotes[i] = _quoteCanonicalExactInput(
                _canonicalPool(termBasketId, configured.pt), termBasketToken, configured.pt, uint128(0.1 ether)
            );
        }
    }

    function _assertPricesImproved(uint256[3] memory baseline, uint256[3] memory distorted) private {
        uint256[3] memory afterQuotes = _termSaleQuotes();
        for (uint256 i; i < 3; ++i) {
            assertLt(afterQuotes[i], distorted[i]);
            assertLt(_difference(afterQuotes[i], baseline[i]), _difference(distorted[i], baseline[i]));
        }
    }

    function _lockedLiquidity() private view returns (uint128[3] memory locked) {
        for (uint256 i; i < 3; ++i) {
            locked[i] = staticsHook.lockedLiquidity(_canonicalPool(termBasketId, _termMarket(i).pt).toId());
        }
    }

    function _assertHookAndReceiverClean(
        PendleStaticsExternalArbitrageReceiver receiver,
        uint128[3] memory lockedBefore
    ) private view {
        for (uint256 i; i < 3; ++i) {
            PoolKey memory pool = _canonicalPool(termBasketId, _termMarket(i).pt);
            assertGt(staticsHook.lockedLiquidity(pool.toId()), lockedBefore[i]);
        }
        _assertReceiverBalances(receiver);
    }

    function _assertReceiverBalances(PendleStaticsExternalArbitrageReceiver receiver) private view {
        assertEq(IERC20(USDG).balanceOf(address(receiver)), 0);
        assertEq(IERC20(termBasketToken).balanceOf(address(receiver)), 0);
        assertEq(IERC20(USDG).allowance(address(receiver), address(diamond)), 0);
        for (uint256 i; i < 3; ++i) {
            TermMarket memory configured = _termMarket(i);
            assertEq(IERC20(configured.pt).balanceOf(address(receiver)), 0);
            assertEq(IERC20(configured.sy).balanceOf(address(receiver)), 0);
            assertEq(IERC20(configured.underlying).balanceOf(address(receiver)), 0);
            assertEq(IERC20(configured.pt).allowance(address(receiver), address(diamond)), 0);
            assertEq(IERC20(configured.pt).allowance(address(receiver), address(canonicalRouter)), 0);
            assertEq(IERC20(configured.underlying).allowance(address(receiver), V3_ROUTER), 0);
        }
    }

    function _staticsSqrtPrices() private view returns (uint160[3] memory prices) {
        for (uint256 i; i < 3; ++i) {
            (prices[i],,,) = poolManager.getSlot0(_canonicalPool(termBasketId, _termMarket(i).pt).toId());
        }
    }

    function _difference(uint256 first, uint256 second) private pure returns (uint256) {
        return first > second ? first - second : second - first;
    }
}
