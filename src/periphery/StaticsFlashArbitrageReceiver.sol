// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IStaticsBasket} from "../interfaces/IStaticsBasket.sol";
import {IStaticsBasketLiquidity} from "../interfaces/IStaticsBasketLiquidity.sol";
import {IStaticsFlashBorrower} from "../interfaces/IStaticsFlashBorrower.sol";
import {IStaticsFlashLoan} from "../interfaces/IStaticsFlashLoan.sol";

/// @notice Permissionless typed receiver for flash-minting a basket and selling it across its canonical pools.
/// @dev The caller supplies only canonical pool keys, a complete BasketToken allocation, and per-asset net profit
///      floors. There is no arbitrary-call surface or privileged fee path.
contract StaticsFlashArbitrageReceiver is IStaticsFlashBorrower, IUnlockCallback, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 private constant CALLBACK_SUCCESS = keccak256("IStaticsFlashBorrower.onStaticsFlashLoan");

    struct CallbackRoute {
        uint256 basketId;
        uint256 shares;
        PoolKey[] pools;
        uint256[] basketAmountsIn;
    }

    struct SwapCall {
        PoolKey pool;
        bool zeroForOne;
        uint256 amountIn;
    }

    address public immutable staticsDiamond;
    IPoolManager public immutable poolManager;

    error InvalidIntegration();
    error InvalidRoute();
    error InvalidPool(address basketToken, address asset);
    error DeadlineExpired(uint256 deadline, uint256 timestamp);
    error OnlyStaticsDiamond(address caller);
    error OnlyPoolManager(address caller);
    error InvalidInitiator(address initiator);
    error InsufficientRepayment(address asset, uint256 required, uint256 available);
    error MinimumProfitNotMet(address asset, uint256 required, uint256 available);
    error BasketBalanceNotRestored(address basketToken, uint256 expected, uint256 actual);
    error UnexpectedTokenMovement(address token, uint256 expected, uint256 spent, uint256 received);
    error UnexpectedSwapDelta(address input, uint256 expectedInput, int128 inputDelta, int128 outputDelta);
    error UnexpectedSettlement(address token, uint256 expected, uint256 actual);

    event MintAndSellArbitrageExecuted(
        address indexed executor, uint256 indexed basketId, uint256 shares, address[] assets, uint256[] profits
    );

    constructor(address staticsDiamond_) {
        (address manager,, bool installed) = IStaticsBasketLiquidity(staticsDiamond_).liquidityIntegration();
        if (!installed || manager.code.length == 0) revert InvalidIntegration();
        staticsDiamond = staticsDiamond_;
        poolManager = IPoolManager(manager);
    }

    /// @notice Flash-borrows the basket vector, mints BasketTokens, sells the complete mint across canonical pools,
    ///         repays every constituent, and transfers the net per-asset profit to the caller.
    function executeMintAndSell(
        uint256 basketId,
        uint256 shares,
        PoolKey[] calldata pools,
        uint256[] calldata basketAmountsIn,
        uint256[] calldata minimumProfits,
        uint256 deadline
    ) external nonReentrant returns (address[] memory assets, uint256[] memory profits) {
        if (block.timestamp > deadline) revert DeadlineExpired(deadline, block.timestamp);

        uint256[] memory flashAmounts;
        (assets, flashAmounts,) = IStaticsFlashLoan(staticsDiamond).quoteFlashLoan(basketId, shares);
        uint256 length = assets.length;
        if (pools.length != length || basketAmountsIn.length != length || minimumProfits.length != length) {
            revert InvalidRoute();
        }

        uint256[] memory mintMaximums = IStaticsBasket(staticsDiamond).quoteMint(basketId, shares);
        if (mintMaximums.length != length || flashAmounts.length != length) revert InvalidRoute();
        uint256[] memory startingBalances = new uint256[](length);
        uint256[] memory topUps = new uint256[](length);
        for (uint256 i; i < length; ++i) {
            IERC20 asset = IERC20(assets[i]);
            startingBalances[i] = asset.balanceOf(address(this));
            uint256 topUp = mintMaximums[i] > flashAmounts[i] ? mintMaximums[i] - flashAmounts[i] : 0;
            topUps[i] = topUp;
            if (topUp != 0) _pullExact(asset, msg.sender, topUp);
        }

        CallbackRoute memory route =
            CallbackRoute({basketId: basketId, shares: shares, pools: pools, basketAmountsIn: basketAmountsIn});
        IStaticsFlashLoan(staticsDiamond).flashLoan(basketId, shares, address(this), abi.encode(route));

        profits = new uint256[](length);
        for (uint256 i; i < length; ++i) {
            IERC20 asset = IERC20(assets[i]);
            asset.forceApprove(staticsDiamond, 0);
            uint256 endingBalance = asset.balanceOf(address(this));
            uint256 requiredBalance = startingBalances[i] + topUps[i] + minimumProfits[i];
            if (endingBalance < requiredBalance) {
                revert MinimumProfitNotMet(assets[i], requiredBalance, endingBalance);
            }
            uint256 payout = endingBalance - startingBalances[i];
            profits[i] = payout - topUps[i];
            _pushExact(asset, msg.sender, payout);
        }
        emit MintAndSellArbitrageExecuted(msg.sender, basketId, shares, assets, profits);
    }

    function onStaticsFlashLoan(
        address initiator,
        uint256 basketId,
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata fees,
        bytes calldata data
    ) external returns (bytes32) {
        if (msg.sender != staticsDiamond) revert OnlyStaticsDiamond(msg.sender);
        if (initiator != address(this)) revert InvalidInitiator(initiator);
        CallbackRoute memory route = abi.decode(data, (CallbackRoute));
        uint256 length = assets.length;
        if (
            route.basketId != basketId || route.pools.length != length || route.basketAmountsIn.length != length
                || amounts.length != length || fees.length != length
        ) revert InvalidRoute();

        IStaticsBasket basket = IStaticsBasket(staticsDiamond);
        address basketToken = basket.basket(basketId).token;
        uint256 basketBalanceBefore = IERC20(basketToken).balanceOf(address(this));
        uint256[] memory maximums = basket.quoteMint(basketId, route.shares);
        if (maximums.length != length) revert InvalidRoute();

        uint256 totalBasketAmountIn;
        for (uint256 i; i < length; ++i) {
            IERC20(assets[i]).forceApprove(staticsDiamond, maximums[i]);
            totalBasketAmountIn += route.basketAmountsIn[i];
        }
        if (totalBasketAmountIn != route.shares) revert InvalidRoute();
        basket.mint(basketId, route.shares, address(this), maximums);
        for (uint256 i; i < length; ++i) {
            IERC20(assets[i]).forceApprove(staticsDiamond, 0);
        }

        for (uint256 i; i < length; ++i) {
            _validatePool(basketId, route.pools[i], basketToken, assets[i]);
            uint256 amountIn = route.basketAmountsIn[i];
            if (amountIn != 0) _swapExactInput(route.pools[i], basketToken, assets[i], amountIn);
        }
        uint256 basketBalanceAfter = IERC20(basketToken).balanceOf(address(this));
        if (basketBalanceAfter != basketBalanceBefore) {
            revert BasketBalanceNotRestored(basketToken, basketBalanceBefore, basketBalanceAfter);
        }

        for (uint256 i; i < length; ++i) {
            uint256 repayment = amounts[i] + fees[i];
            uint256 available = IERC20(assets[i]).balanceOf(address(this));
            if (available < repayment) revert InsufficientRepayment(assets[i], repayment, available);
            IERC20(assets[i]).forceApprove(staticsDiamond, repayment);
        }
        return CALLBACK_SUCCESS;
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager(msg.sender);
        SwapCall memory call = abi.decode(data, (SwapCall));
        BalanceDelta delta = poolManager.swap(
            call.pool,
            SwapParams({
                zeroForOne: call.zeroForOne,
                amountSpecified: -int256(call.amountIn),
                sqrtPriceLimitX96: call.zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );

        int128 inputDelta = call.zeroForOne ? delta.amount0() : delta.amount1();
        int128 outputDelta = call.zeroForOne ? delta.amount1() : delta.amount0();
        address input = Currency.unwrap(call.zeroForOne ? call.pool.currency0 : call.pool.currency1);
        if (inputDelta >= 0 || outputDelta <= 0 || uint256(-int256(inputDelta)) != call.amountIn) {
            revert UnexpectedSwapDelta(input, call.amountIn, inputDelta, outputDelta);
        }

        _settle(call.pool.currency0, delta.amount0());
        _settle(call.pool.currency1, delta.amount1());
        return abi.encode(uint256(uint128(outputDelta)));
    }

    function _swapExactInput(PoolKey memory pool, address input, address output, uint256 amountIn)
        private
        returns (uint256 amountOut)
    {
        bool zeroForOne = Currency.unwrap(pool.currency0) == input;
        IERC20 inputToken = IERC20(input);
        IERC20 outputToken = IERC20(output);
        uint256 inputBefore = inputToken.balanceOf(address(this));
        uint256 outputBefore = outputToken.balanceOf(address(this));
        amountOut = abi.decode(
            poolManager.unlock(abi.encode(SwapCall({pool: pool, zeroForOne: zeroForOne, amountIn: amountIn}))),
            (uint256)
        );
        uint256 inputAfter = inputToken.balanceOf(address(this));
        uint256 outputAfter = outputToken.balanceOf(address(this));
        uint256 spent = inputBefore > inputAfter ? inputBefore - inputAfter : 0;
        uint256 received = outputAfter > outputBefore ? outputAfter - outputBefore : 0;
        if (spent != amountIn || received != amountOut) {
            revert UnexpectedTokenMovement(input, amountIn, spent, received);
        }
    }

    function _settle(Currency currency, int128 delta) private {
        if (delta == 0) return;
        address tokenAddress = Currency.unwrap(currency);
        if (tokenAddress == address(0)) revert InvalidRoute();
        IERC20 token = IERC20(tokenAddress);
        uint256 amount = delta < 0 ? uint256(-int256(delta)) : uint256(uint128(delta));
        if (delta < 0) {
            uint256 beforeBalance = token.balanceOf(address(this));
            poolManager.sync(currency);
            token.safeTransfer(address(poolManager), amount);
            uint256 settled = poolManager.settle();
            uint256 afterBalance = token.balanceOf(address(this));
            uint256 spent = beforeBalance > afterBalance ? beforeBalance - afterBalance : 0;
            if (spent != amount || settled != amount) {
                revert UnexpectedSettlement(tokenAddress, amount, spent < settled ? spent : settled);
            }
        } else {
            uint256 beforeBalance = token.balanceOf(address(this));
            poolManager.take(currency, address(this), amount);
            uint256 afterBalance = token.balanceOf(address(this));
            uint256 received = afterBalance > beforeBalance ? afterBalance - beforeBalance : 0;
            if (received != amount) revert UnexpectedSettlement(tokenAddress, amount, received);
        }
    }

    function _validatePool(uint256 basketId, PoolKey memory pool, address basketToken, address asset) private view {
        address currency0 = Currency.unwrap(pool.currency0);
        address currency1 = Currency.unwrap(pool.currency1);
        IStaticsBasketLiquidity.CanonicalPoolView memory canonical =
            IStaticsBasketLiquidity(staticsDiamond).canonicalPool(basketId, asset);
        if (
            canonical.basketToken != basketToken || canonical.asset != asset || canonical.currency0 != currency0
                || canonical.currency1 != currency1 || canonical.hook != address(pool.hooks)
                || canonical.lpFee != pool.fee || canonical.tickSpacing != pool.tickSpacing
                || (currency0 != basketToken && currency1 != basketToken)
        ) revert InvalidPool(basketToken, asset);
    }

    function _pullExact(IERC20 token, address from, uint256 amount) private {
        uint256 beforeBalance = token.balanceOf(address(this));
        token.safeTransferFrom(from, address(this), amount);
        uint256 afterBalance = token.balanceOf(address(this));
        uint256 received = afterBalance > beforeBalance ? afterBalance - beforeBalance : 0;
        if (received != amount) revert UnexpectedTokenMovement(address(token), amount, amount, received);
    }

    function _pushExact(IERC20 token, address receiver, uint256 amount) private {
        uint256 senderBefore = token.balanceOf(address(this));
        uint256 receiverBefore = token.balanceOf(receiver);
        token.safeTransfer(receiver, amount);
        uint256 senderAfter = token.balanceOf(address(this));
        uint256 receiverAfter = token.balanceOf(receiver);
        uint256 spent = senderBefore > senderAfter ? senderBefore - senderAfter : 0;
        uint256 received = receiverAfter > receiverBefore ? receiverAfter - receiverBefore : 0;
        if (spent != amount || received != amount) {
            revert UnexpectedTokenMovement(address(token), amount, spent, received);
        }
    }
}
