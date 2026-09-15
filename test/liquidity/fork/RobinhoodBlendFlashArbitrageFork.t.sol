// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {IStaticsBasket} from "../../../src/interfaces/IStaticsBasket.sol";
import {IStaticsBasketLiquidity} from "../../../src/interfaces/IStaticsBasketLiquidity.sol";
import {StaticsFlashArbitrageReceiver} from "../../../src/periphery/StaticsFlashArbitrageReceiver.sol";
import {IBlendBasket, RobinhoodBlendBasketForkBase} from "../../basket/fork/RobinhoodBlendBasketFork.t.sol";
import {CanonicalV4Router} from "../../helpers/CanonicalPoolTestBase.sol";

interface IBlendFlashBasket is IBlendBasket {
    function previewMint(uint256 shares)
        external
        view
        returns (address[] memory tokens, uint256[] memory required, uint256[] memory fees);
    function redeem(uint256 shares, address to) external;
    function flashMint(uint256 shares, bytes calldata data) external;
    function stateChangeActive() external view returns (bool);
}

interface IBlendFlashMintCallback {
    function onFlashMint(
        uint256 shares,
        address[] calldata tokens,
        uint256[] calldata required,
        uint256[] calldata fees,
        bytes calldata data
    ) external;
}

/// @notice Test-only executor proving that Blend's live flash-mint callback can cross a Statics pool.
/// @dev Blend issues the AI shares before collecting their exact NVDA/GOOGL/MSFT vector. During that
///      callback the shares buy discounted sBAI, which is redeemed through normal Statics custody.
///      No Blend accounting view is consulted by Statics while Blend reports transient state.
contract BlendStaticsFlashMintReceiver is IBlendFlashMintCallback {
    using SafeERC20 for IERC20;

    error InvalidCallback();
    error MinimumProfitNotMet(uint256 minimum, uint256 actual);
    error NoOuterBasketReceived();

    IBlendFlashBasket public immutable blendBasket;
    IStaticsBasket public immutable staticsBasket;
    CanonicalV4Router public immutable router;
    uint256 public immutable basketId;
    address public immutable outerBasketToken;

    PoolKey private _pool;
    uint256 private _activeShares;
    uint256 private _minimumProfit;
    bool private _active;

    bool public observedTransientBlendState;
    uint256 public redeemedOuterShares;

    constructor(
        IBlendFlashBasket blendBasket_,
        IStaticsBasket staticsBasket_,
        CanonicalV4Router router_,
        uint256 basketId_,
        address outerBasketToken_,
        PoolKey memory pool_
    ) {
        blendBasket = blendBasket_;
        staticsBasket = staticsBasket_;
        router = router_;
        basketId = basketId_;
        outerBasketToken = outerBasketToken_;
        _pool = pool_;
    }

    function executeFlashMintArbitrage(uint256 shares, uint256 minimumProfit)
        external
        returns (uint256 payout, uint256 profit)
    {
        uint256 startingBlendBalance = blendBasket.balanceOf(address(this));
        _activeShares = shares;
        _minimumProfit = minimumProfit;
        _active = true;
        blendBasket.flashMint(shares, "");
        _active = false;

        address[] memory tokens = blendBasket.constituents();
        for (uint256 i; i < tokens.length; ++i) {
            IERC20(tokens[i]).forceApprove(address(blendBasket), 0);
        }

        uint256 endingBlendBalance = blendBasket.balanceOf(address(this));
        payout = endingBlendBalance - startingBlendBalance;
        if (payout < shares + minimumProfit) revert MinimumProfitNotMet(minimumProfit, payout - shares);
        profit = payout - shares;
        IERC20(address(blendBasket)).safeTransfer(msg.sender, payout);
    }

    function onFlashMint(
        uint256 shares,
        address[] calldata tokens,
        uint256[] calldata required,
        uint256[] calldata fees,
        bytes calldata data
    ) external {
        if (
            msg.sender != address(blendBasket) || !_active || shares != _activeShares || data.length != 0
                || tokens.length != required.length || tokens.length != fees.length
        ) revert InvalidCallback();
        if (!blendBasket.stateChangeActive()) revert InvalidCallback();
        observedTransientBlendState = true;

        uint256 outerShares = _buyOuterBasket(shares);
        if (outerShares == 0) revert NoOuterBasketReceived();
        redeemedOuterShares = outerShares;
        uint256[] memory minimums = staticsBasket.quoteRedeem(basketId, outerShares);
        staticsBasket.redeem(basketId, outerShares, address(this), minimums);

        uint256 blendBalance = blendBasket.balanceOf(address(this));
        if (blendBalance < shares + _minimumProfit) {
            revert MinimumProfitNotMet(_minimumProfit, blendBalance > shares ? blendBalance - shares : 0);
        }
        for (uint256 i; i < tokens.length; ++i) {
            IERC20(tokens[i]).forceApprove(address(blendBasket), required[i] + fees[i]);
        }
    }

    function _buyOuterBasket(uint256 amountIn) private returns (uint256 amountOut) {
        IERC20 blend = IERC20(address(blendBasket));
        IERC20 outer = IERC20(outerBasketToken);
        uint256 outputBefore = outer.balanceOf(address(this));
        blend.forceApprove(address(router), amountIn);
        bool zeroForOne = Currency.unwrap(_pool.currency0) == address(blendBasket);
        router.swap(
            _pool,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            })
        );
        blend.forceApprove(address(router), 0);
        amountOut = outer.balanceOf(address(this)) - outputBefore;
    }
}

/// @notice Cross-protocol arbitrage proofs using both protocols' production flash entrypoints.
///
/// Statics path:
///   flash-borrow live Blend AI -> mint sBAI -> sell overpriced sBAI -> repay AI + 5 bps
///
/// Blend path:
///   flash-mint live Blend AI -> buy discounted sBAI -> redeem sBAI
///   -> settle exact NVDA + GOOGL + MSFT vector after the callback
contract RobinhoodBlendFlashArbitrageForkTest is RobinhoodBlendBasketForkBase {
    uint256 private constant DISTORTION_MINT_SHARES = 1 ether;
    uint256 private constant DISTORTION_SALE = 0.3 ether;
    uint256 private constant FLASH_SHARES = 0.25 ether;
    uint256 private constant MINIMUM_BLEND_PROFIT = 0.02 ether;

    CanonicalV4Router private router;

    struct StaticsFlashResult {
        address[] assets;
        address[] returnedAssets;
        uint256[] principals;
        uint256[] fees;
        uint256[] profits;
        uint256 aliceBlendBefore;
        uint256 treasuryBefore;
        uint256 executionGas;
    }

    function setUp() public override {
        super.setUp();
        router = new CanonicalV4Router(IPoolManager(address(poolManager)));
    }

    function testStaticsFlashLoanArbitragesOuterBasketAgainstLiveBlendShare() public {
        PoolKey memory pool = _makeOuterBasketExpensive();
        StaticsFlashArbitrageReceiver receiver = new StaticsFlashArbitrageReceiver(address(diamond));
        StaticsFlashResult memory result = _executeStaticsFlash(receiver, pool);

        assertEq(result.assets.length, 1);
        assertEq(result.assets[0], BLEND_AI);
        assertEq(result.returnedAssets[0], BLEND_AI);
        assertEq(result.principals[0], FLASH_SHARES);
        assertGt(result.fees[0], 0);
        assertGe(result.profits[0], MINIMUM_BLEND_PROFIT);
        assertEq(IERC20(BLEND_AI).balanceOf(alice), result.aliceBlendBefore + result.profits[0]);
        assertEq(IERC20(BLEND_AI).balanceOf(address(receiver)), 0);
        assertEq(IERC20(staticsBasketToken).balanceOf(address(receiver)), 0);
        assertEq(IERC20(BLEND_AI).balanceOf(address(diamond)), custody.globalReservedByToken(BLEND_AI));
        assertEq(custody.unreservedBalance(BLEND_AI), 0);
        assertGe(globalRewards.treasuryAccrued(BLEND_AI) - result.treasuryBefore, result.fees[0] + MINT_FEE_SHARES);

        emit log("Statics flash route: Blend AI -> mint sBAI -> sell overpriced sBAI -> Blend AI");
        emit log_named_uint("Statics flash arbitrage execution gas", result.executionGas);
        emit log_named_uint("Live Blend AI profit", result.profits[0]);
    }

    function _executeStaticsFlash(StaticsFlashArbitrageReceiver receiver, PoolKey memory pool)
        private
        returns (StaticsFlashResult memory result)
    {
        PoolKey[] memory pools = new PoolKey[](1);
        pools[0] = pool;
        uint256[] memory basketAmountsIn = new uint256[](1);
        basketAmountsIn[0] = FLASH_SHARES;
        uint256[] memory minimumProfits = new uint256[](1);
        minimumProfits[0] = MINIMUM_BLEND_PROFIT;

        (result.assets, result.principals, result.fees) = flashLoans.quoteFlashLoan(staticsBasketId, FLASH_SHARES);
        uint256[] memory mintQuote = baskets.quoteMint(staticsBasketId, FLASH_SHARES);
        uint256 topUp = mintQuote[0] - result.principals[0];
        vm.prank(alice);
        assertTrue(IERC20(BLEND_AI).approve(address(receiver), topUp));
        result.aliceBlendBefore = IERC20(BLEND_AI).balanceOf(alice);
        result.treasuryBefore = globalRewards.treasuryAccrued(BLEND_AI);
        uint256 gasBefore = gasleft();
        vm.prank(alice);
        (result.returnedAssets, result.profits) = receiver.executeMintAndSell(
            staticsBasketId, FLASH_SHARES, pools, basketAmountsIn, minimumProfits, block.timestamp + 1 minutes
        );
        result.executionGas = gasBefore - gasleft();
    }

    function testBlendFlashMintArbitragesLiveShareAgainstStaticsPool() public {
        PoolKey memory pool = _makeOuterBasketCheap();
        IBlendFlashBasket blend = IBlendFlashBasket(BLEND_AI);
        BlendStaticsFlashMintReceiver receiver =
            new BlendStaticsFlashMintReceiver(blend, baskets, router, staticsBasketId, staticsBasketToken, pool);
        address[] memory repaymentTokens = _fundBlendFlashMintReceiver(blend, receiver);

        uint256 blendSupplyBefore = blend.totalSupply();
        uint256 outerSupplyBefore = IERC20(staticsBasketToken).totalSupply();
        uint256 callerBlendBefore = blend.balanceOf(address(this));
        uint256 gasBefore = gasleft();
        (uint256 payout, uint256 profit) = receiver.executeFlashMintArbitrage(FLASH_SHARES, MINIMUM_BLEND_PROFIT);
        uint256 executionGas = gasBefore - gasleft();

        assertTrue(receiver.observedTransientBlendState());
        assertFalse(blend.stateChangeActive());
        assertEq(blend.totalSupply(), blendSupplyBefore + FLASH_SHARES);
        assertEq(payout, FLASH_SHARES + profit);
        assertGe(profit, MINIMUM_BLEND_PROFIT);
        assertEq(blend.balanceOf(address(this)), callerBlendBefore + payout);
        assertEq(blend.balanceOf(address(receiver)), 0);
        assertEq(IERC20(staticsBasketToken).balanceOf(address(receiver)), 0);
        assertEq(IERC20(staticsBasketToken).totalSupply(), outerSupplyBefore - receiver.redeemedOuterShares());
        for (uint256 i; i < repaymentTokens.length; ++i) {
            assertEq(IERC20(repaymentTokens[i]).balanceOf(address(receiver)), 0);
        }

        emit log("Blend flash route: flash-mint AI -> discounted sBAI -> redeem to AI -> settle stock vector");
        emit log_named_uint("Blend flash-mint arbitrage execution gas", executionGas);
        emit log_named_uint("Live Blend AI profit", profit);
    }

    function _makeOuterBasketCheap() private returns (PoolKey memory pool) {
        uint256[] memory mintQuote = baskets.quoteMint(staticsBasketId, DISTORTION_MINT_SHARES);
        vm.prank(alice);
        baskets.mint(staticsBasketId, DISTORTION_MINT_SHARES, alice, mintQuote);
        vm.prank(alice);
        assertTrue(IERC20(staticsBasketToken).approve(address(router), type(uint256).max));

        pool = _outerBasketPool();
        bool zeroForOne = Currency.unwrap(pool.currency0) == staticsBasketToken;
        uint256 blendBefore = IERC20(BLEND_AI).balanceOf(alice);
        vm.prank(alice);
        router.swap(
            pool,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(DISTORTION_SALE),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            })
        );
        assertGt(IERC20(BLEND_AI).balanceOf(alice), blendBefore);
    }

    function _makeOuterBasketExpensive() private returns (PoolKey memory pool) {
        pool = _outerBasketPool();
        vm.prank(alice);
        assertTrue(IERC20(BLEND_AI).approve(address(router), type(uint256).max));
        bool zeroForOne = Currency.unwrap(pool.currency0) == BLEND_AI;
        uint256 outerBefore = IERC20(staticsBasketToken).balanceOf(alice);
        vm.prank(alice);
        router.swap(
            pool,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(DISTORTION_SALE),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            })
        );
        assertGt(IERC20(staticsBasketToken).balanceOf(alice), outerBefore);
    }

    function _fundBlendFlashMintReceiver(IBlendFlashBasket blend, BlendStaticsFlashMintReceiver receiver)
        private
        returns (address[] memory tokens)
    {
        vm.prank(alice);
        blend.redeem(1 ether, alice);

        uint256[] memory required;
        uint256[] memory fees;
        (tokens, required, fees) = blend.previewMint(FLASH_SHARES);
        assertEq(tokens.length, 3);
        for (uint256 i; i < tokens.length; ++i) {
            uint256 repayment = required[i] + fees[i];
            assertGe(IERC20(tokens[i]).balanceOf(alice), repayment);
            vm.prank(alice);
            assertTrue(IERC20(tokens[i]).transfer(address(receiver), repayment));
        }
    }

    function _outerBasketPool() private view returns (PoolKey memory pool) {
        IStaticsBasketLiquidity.CanonicalPoolView memory canonical =
            basketLiquidity.canonicalPool(staticsBasketId, BLEND_AI);
        pool = PoolKey({
            currency0: Currency.wrap(canonical.currency0),
            currency1: Currency.wrap(canonical.currency1),
            fee: canonical.lpFee,
            tickSpacing: canonical.tickSpacing,
            hooks: staticsHook
        });
    }
}
