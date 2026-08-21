// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IStaticsBasket} from "../../src/interfaces/IStaticsBasket.sol";
import {IStaticsBasketLiquidity} from "../../src/interfaces/IStaticsBasketLiquidity.sol";
import {IStaticsFlashBorrower} from "../../src/interfaces/IStaticsFlashBorrower.sol";
import {IStaticsFlashLoan} from "../../src/interfaces/IStaticsFlashLoan.sol";

interface ICanonicalV4SwapRouter {
    function swap(PoolKey calldata key, SwapParams calldata params) external returns (BalanceDelta delta);
}

contract FlashArbitrageReceiver is IStaticsFlashBorrower {
    using SafeERC20 for IERC20;

    bytes32 private constant CALLBACK_SUCCESS = keccak256("IStaticsFlashBorrower.onStaticsFlashLoan");
    uint8 private constant MINT_AND_SELL = 1;
    uint8 private constant BUY_AND_REDEEM = 2;

    struct MintAndSellRoute {
        uint256 shares;
        PoolKey[] pools;
        uint256[] basketAmountsIn;
        uint256[] startingBalances;
        uint256[] minimumProfits;
    }

    struct BuyAndRedeemRoute {
        PoolKey pool;
        uint256 underlyingAmountIn;
        uint256 startingBalance;
        uint256 minimumProfit;
    }

    address public immutable protocol;
    ICanonicalV4SwapRouter public immutable router;
    mapping(address asset => uint256 amount) public lastProfit;

    error OnlyProtocol(address caller);
    error InvalidInitiator(address initiator);
    error InvalidRoute();
    error InvalidPool(address basketToken, address asset);
    error MinimumProfitNotMet(address asset, uint256 required, uint256 available);

    constructor(address protocol_, ICanonicalV4SwapRouter router_) {
        protocol = protocol_;
        router = router_;
    }

    function executeMintAndSell(
        uint256 basketId,
        uint256 shares,
        PoolKey[] calldata pools,
        uint256[] calldata basketAmountsIn,
        uint256[] calldata minimumProfits
    ) external {
        (address[] memory assets,,) = IStaticsFlashLoan(protocol).quoteFlashLoan(basketId, shares);
        uint256 length = assets.length;
        if (pools.length != length || basketAmountsIn.length != length || minimumProfits.length != length) {
            revert InvalidRoute();
        }
        uint256[] memory startingBalances = new uint256[](length);
        for (uint256 i; i < length; ++i) {
            startingBalances[i] = IERC20(assets[i]).balanceOf(address(this));
            lastProfit[assets[i]] = 0;
        }
        MintAndSellRoute memory route = MintAndSellRoute({
            shares: shares,
            pools: pools,
            basketAmountsIn: basketAmountsIn,
            startingBalances: startingBalances,
            minimumProfits: minimumProfits
        });
        IStaticsFlashLoan(protocol).flashLoan(basketId, shares, address(this), abi.encode(MINT_AND_SELL, route));
        for (uint256 i; i < length; ++i) {
            uint256 endingBalance = IERC20(assets[i]).balanceOf(address(this));
            uint256 requiredBalance = startingBalances[i] + minimumProfits[i];
            if (endingBalance < requiredBalance) {
                revert MinimumProfitNotMet(assets[i], requiredBalance, endingBalance);
            }
            lastProfit[assets[i]] = endingBalance - startingBalances[i];
        }
    }

    function executeBuyAndRedeem(
        uint256 basketId,
        uint256 shares,
        PoolKey calldata pool,
        uint256 underlyingAmountIn,
        uint256 minimumProfit
    ) external {
        (address[] memory assets,,) = IStaticsFlashLoan(protocol).quoteFlashLoan(basketId, shares);
        if (assets.length != 1) revert InvalidRoute();
        address underlying = assets[0];
        uint256 startingBalance = IERC20(underlying).balanceOf(address(this));
        lastProfit[underlying] = 0;
        BuyAndRedeemRoute memory route = BuyAndRedeemRoute({
            pool: pool,
            underlyingAmountIn: underlyingAmountIn,
            startingBalance: startingBalance,
            minimumProfit: minimumProfit
        });
        IStaticsFlashLoan(protocol).flashLoan(basketId, shares, address(this), abi.encode(BUY_AND_REDEEM, route));
        uint256 endingBalance = IERC20(underlying).balanceOf(address(this));
        uint256 requiredBalance = startingBalance + minimumProfit;
        if (endingBalance < requiredBalance) {
            revert MinimumProfitNotMet(underlying, requiredBalance, endingBalance);
        }
        lastProfit[underlying] = endingBalance - startingBalance;
    }

    function onStaticsFlashLoan(
        address initiator,
        uint256 basketId,
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata fees,
        bytes calldata data
    ) external returns (bytes32) {
        if (msg.sender != protocol) revert OnlyProtocol(msg.sender);
        if (initiator != address(this)) revert InvalidInitiator(initiator);
        uint8 routeType = abi.decode(data, (uint8));
        if (routeType == MINT_AND_SELL) {
            (, MintAndSellRoute memory route) = abi.decode(data, (uint8, MintAndSellRoute));
            _mintAndSell(basketId, assets, amounts, fees, route);
        } else if (routeType == BUY_AND_REDEEM) {
            (, BuyAndRedeemRoute memory route) = abi.decode(data, (uint8, BuyAndRedeemRoute));
            _buyAndRedeem(basketId, assets, amounts, fees, route);
        } else {
            revert InvalidRoute();
        }
        return CALLBACK_SUCCESS;
    }

    function _mintAndSell(
        uint256 basketId,
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata fees,
        MintAndSellRoute memory route
    ) private {
        uint256 length = assets.length;
        if (
            route.pools.length != length || route.basketAmountsIn.length != length
                || route.startingBalances.length != length || route.minimumProfits.length != length
        ) revert InvalidRoute();
        IStaticsBasket basket = IStaticsBasket(protocol);
        address basketToken = basket.basket(basketId).token;
        uint256[] memory maximums = basket.quoteMint(basketId, route.shares);
        uint256 totalBasketAmountIn;
        for (uint256 i; i < length; ++i) {
            IERC20(assets[i]).forceApprove(protocol, maximums[i]);
            totalBasketAmountIn += route.basketAmountsIn[i];
        }
        if (totalBasketAmountIn != route.shares) revert InvalidRoute();
        basket.mint(basketId, route.shares, address(this), maximums);

        _sellMintedBasket(basketId, basketToken, assets, route);
        _enforceProfitsAndApproveRepayment(assets, amounts, fees, route.startingBalances, route.minimumProfits);
    }

    function _sellMintedBasket(
        uint256 basketId,
        address basketToken,
        address[] calldata assets,
        MintAndSellRoute memory route
    ) private {
        for (uint256 i; i < assets.length; ++i) {
            _validatePool(basketId, route.pools[i], basketToken, assets[i]);
            uint256 amountIn = route.basketAmountsIn[i];
            IERC20(basketToken).forceApprove(address(router), amountIn);
            _swapExactInput(route.pools[i], basketToken, amountIn);
            IERC20(basketToken).forceApprove(address(router), 0);
        }
    }

    function _buyAndRedeem(
        uint256 basketId,
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata fees,
        BuyAndRedeemRoute memory route
    ) private {
        if (assets.length != 1 || route.underlyingAmountIn > amounts[0]) {
            revert InvalidRoute();
        }
        IStaticsBasket basket = IStaticsBasket(protocol);
        address basketToken = basket.basket(basketId).token;
        uint256 acquired = _buyBasketTokens(basketId, basketToken, assets[0], route);
        uint256[] memory minimums = basket.quoteRedeem(basketId, acquired);
        basket.redeem(basketId, acquired, address(this), minimums);
        _repayAndCheckProfit(assets[0], amounts[0] + fees[0], route);
    }

    function _buyBasketTokens(
        uint256 basketId,
        address basketToken,
        address underlying,
        BuyAndRedeemRoute memory route
    ) private returns (uint256 acquired) {
        _validatePool(basketId, route.pool, basketToken, underlying);
        uint256 basketBalanceBefore = IERC20(basketToken).balanceOf(address(this));
        IERC20(underlying).forceApprove(address(router), route.underlyingAmountIn);
        _swapExactInput(route.pool, underlying, route.underlyingAmountIn);
        IERC20(underlying).forceApprove(address(router), 0);
        acquired = IERC20(basketToken).balanceOf(address(this)) - basketBalanceBefore;
    }

    function _repayAndCheckProfit(address underlying, uint256 repayment, BuyAndRedeemRoute memory route) private {
        uint256 available = IERC20(underlying).balanceOf(address(this));
        uint256 required = route.startingBalance + repayment + route.minimumProfit;
        if (available < required) revert MinimumProfitNotMet(underlying, required, available);
        IERC20(underlying).forceApprove(protocol, repayment);
    }

    function _swapExactInput(PoolKey memory pool, address input, uint256 amountIn) private {
        bool zeroForOne = Currency.unwrap(pool.currency0) == input;
        router.swap(
            pool,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            })
        );
    }

    function _validatePool(uint256 basketId, PoolKey memory pool, address basketToken, address asset) private view {
        address currency0 = Currency.unwrap(pool.currency0);
        address currency1 = Currency.unwrap(pool.currency1);
        IStaticsBasketLiquidity.CanonicalPoolView memory canonical =
            IStaticsBasketLiquidity(protocol).canonicalPool(basketId, asset);
        if (
            canonical.basketToken != basketToken || canonical.asset != asset || canonical.currency0 != currency0
                || canonical.currency1 != currency1 || canonical.hook != address(pool.hooks)
                || canonical.lpFee != pool.fee || canonical.tickSpacing != pool.tickSpacing
        ) revert InvalidPool(basketToken, asset);
    }

    function _enforceProfitsAndApproveRepayment(
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata fees,
        uint256[] memory startingBalances,
        uint256[] memory minimumProfits
    ) private {
        uint256 length = assets.length;
        for (uint256 i; i < length; ++i) {
            uint256 available = IERC20(assets[i]).balanceOf(address(this));
            uint256 repayment = amounts[i] + fees[i];
            uint256 required = startingBalances[i] + repayment + minimumProfits[i];
            if (available < required) revert MinimumProfitNotMet(assets[i], required, available);
            IERC20(assets[i]).forceApprove(protocol, repayment);
        }
    }
}
