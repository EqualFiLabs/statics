// SPDX-License-Identifier: BUSL-1.1
// ============================================================================
//                              STATICS PROTOCOL
//                         Markets that work for you.
//                       https://staticsprotocol.com
//                              EqualFi Labs
// ============================================================================
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {TransientSlot} from "@openzeppelin/contracts/utils/TransientSlot.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IStaticsBasket} from "../interfaces/IStaticsBasket.sol";
import {IStaticsGovernance} from "../interfaces/IStaticsGovernance.sol";
import {IStaticsBasketConversion} from "../interfaces/IStaticsBasketConversion.sol";
import {IStaticsBasketSettlement} from "../interfaces/IStaticsBasketSettlement.sol";
import {
    BasketConversionRoute,
    BasketConversionRequest,
    IStaticsBasketConversionRoutes
} from "../interfaces/IStaticsBasketConversionRoutes.sol";

/// @notice Unlock-compatible conversion execution; all balances remain in the calling adapter's account.
library LibBasketConversion {
    using SafeERC20 for IERC20;
    using TransientSlot for *;

    bytes32 private constant LOCK_SLOT = keccak256("statics.basket.conversion.lock");
    bytes32 private constant DELIVERY_SLOT = keccak256("statics.basket.conversion.delivery");

    struct Context {
        IPoolManager manager;
        IStaticsBasket core;
        PoolId poolId;
        IStaticsBasketConversion.Market market;
        address hook;
        address[] assets;
    }

    error InvalidConversionRoute();
    error ConversionBound();
    error InexactConversionTransfer();
    error ConversionReentered();
    error UnauthorizedConversionCallback();
    error ConversionExpired();
    error ConversionUnavailable();

    function enter() internal {
        if (LOCK_SLOT.asBoolean().tload()) revert ConversionReentered();
        LOCK_SLOT.asBoolean().tstore(true);
    }

    function exit() internal {
        LOCK_SLOT.asBoolean().tstore(false);
    }

    function context(IPoolManager pm, IStaticsBasket core, address hook, PoolId id)
        internal
        view
        returns (Context memory c)
    {
        IStaticsBasketConversion.Market memory m = IStaticsBasketConversion(address(core)).basketConversionMarket(id);
        IStaticsBasket.BasketView memory b = core.basket(m.basketId);
        if (
            !m.active || address(m.key.hooks) != hook || b.status != IStaticsBasket.BasketStatus.Active
                || IStaticsGovernance(address(core)).protocolPoolSwapsBlocked(id)
        ) revert ConversionUnavailable();
        c = Context(pm, core, id, m, hook, b.assets);
    }

    function routes(Context memory c, BasketConversionRequest memory r, bool buying)
        internal
        view
        returns (BasketConversionRoute[] memory paths)
    {
        if (block.timestamp > r.deadline) revert ConversionExpired();
        if (r.routeLimits.length != c.assets.length) revert InvalidConversionRoute();
        if (r.preset) {
            if (r.routes.length != 0) revert InvalidConversionRoute();
            paths = IStaticsBasketConversionRoutes(c.hook).preset(c.poolId, buying);
        } else {
            paths = r.routes;
        }
        validate(c, paths);
    }

    function validate(Context memory c, BasketConversionRoute[] memory paths) internal view {
        if (paths.length != c.assets.length) revert InvalidConversionRoute();
        for (uint256 i; i < paths.length; ++i) {
            BasketConversionRoute memory r = paths[i];
            uint256 n = r.pools.length;
            if (
                n > 4 || r.currencies.length != n + 1 || r.hookData.length != n || r.currencies[0] != c.market.quote
                    || r.currencies[n] != c.assets[i]
            ) revert InvalidConversionRoute();
            for (uint256 j; j <= n; ++j) {
                address a = r.currencies[j];
                if (a == address(0) || IStaticsBasketSettlement(address(c.core)).isBasketToken(a)) {
                    revert InvalidConversionRoute();
                }
                for (uint256 p; p < j; ++p) {
                    if (r.currencies[p] == a) revert InvalidConversionRoute();
                }
                if (j == n) continue;
                address b = r.currencies[j + 1];
                PoolKey memory k = r.pools[j];
                if (
                    address(k.hooks) == c.hook || Currency.unwrap(k.currency0) != (a < b ? a : b)
                        || Currency.unwrap(k.currency1) != (a < b ? b : a)
                ) revert InvalidConversionRoute();
            }
        }
    }

    function buy(
        Context memory c,
        uint256 shares,
        address receiver,
        BasketConversionRoute[] memory paths,
        uint256[] memory limits
    ) internal returns (uint256 cost) {
        signed(shares);
        uint256[] memory required = c.core.quoteMint(c.market.basketId, shares);
        for (uint256 i; i < c.assets.length; ++i) {
            uint256 input = required[i];
            BasketConversionRoute memory r = paths[i];
            for (uint256 j = r.pools.length; j != 0; --j) {
                input = swap(c.manager, r.pools[j - 1], r.currencies[j - 1], input, false, r.hookData[j - 1]);
            }
            if (input > limits[i]) revert ConversionBound();
            cost += input;
        }
        DELIVERY_SLOT.asBytes32().tstore(keccak256(abi.encode(c.poolId, c.market.basketId, shares, receiver, required)));
        if (receiver == address(c.manager)) c.manager.sync(Currency.wrap(c.market.basketToken));
        IStaticsBasketConversion(address(c.core)).mintBasketConversion(c.poolId, shares, receiver, required);
        if (DELIVERY_SLOT.asBytes32().tload() != bytes32(0)) revert UnauthorizedConversionCallback();
        if (receiver == address(c.manager) && c.manager.settle() != shares) revert InexactConversionTransfer();
    }

    function deliver(
        IPoolManager pm,
        IStaticsBasket core,
        PoolId id,
        uint256 basketId,
        uint256 shares,
        address receiver,
        uint256[] calldata amounts
    ) internal {
        bytes32 commitment = DELIVERY_SLOT.asBytes32().tload();
        if (
            msg.sender != address(core) || !LOCK_SLOT.asBoolean().tload() || commitment == bytes32(0)
                || commitment != keccak256(abi.encode(id, basketId, shares, receiver, amounts))
        ) revert UnauthorizedConversionCallback();
        DELIVERY_SLOT.asBytes32().tstore(bytes32(0));
        address[] memory assets = core.basket(basketId).assets;
        for (uint256 i; i < assets.length; ++i) {
            pm.take(Currency.wrap(assets[i]), address(core), amounts[i]);
        }
    }

    function sell(Context memory c, uint256 shares, BasketConversionRoute[] memory paths, uint256[] memory limits)
        internal
        returns (uint256 proceeds)
    {
        signed(shares);
        uint256[] memory floors = new uint256[](c.assets.length);
        for (uint256 i; i < c.assets.length; ++i) {
            floors[i] = IERC20(c.assets[i]).balanceOf(address(this));
        }
        uint256[] memory amounts =
            c.core.redeem(c.market.basketId, shares, address(this), new uint256[](c.assets.length));
        for (uint256 i; i < c.assets.length; ++i) {
            address asset = c.assets[i];
            uint256 output = amounts[i];
            if (IERC20(asset).balanceOf(address(this)) != floors[i] + output) revert InexactConversionTransfer();
            c.manager.sync(Currency.wrap(asset));
            IERC20(asset).safeTransfer(address(c.manager), output);
            if (c.manager.settle() != output) revert InexactConversionTransfer();
            BasketConversionRoute memory r = paths[i];
            for (uint256 j = r.pools.length; j != 0; --j) {
                output = swap(c.manager, r.pools[j - 1], r.currencies[j], output, true, r.hookData[j - 1]);
            }
            if (output < limits[i]) revert ConversionBound();
            proceeds += output;
            if (IERC20(asset).balanceOf(address(this)) != floors[i]) revert InexactConversionTransfer();
        }
    }

    function swap(IPoolManager pm, PoolKey memory k, address input, uint256 amount, bool exactInput, bytes memory data)
        private
        returns (uint256 result)
    {
        if (amount == 0) return 0;
        bool zeroForOne = Currency.unwrap(k.currency0) == input;
        BalanceDelta d = pm.swap(
            k,
            SwapParams(
                zeroForOne,
                exactInput ? -int256(signed(amount)) : int256(signed(amount)),
                zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            ),
            data
        );
        int128 debit = zeroForOne ? d.amount0() : d.amount1();
        int128 credit = zeroForOne ? d.amount1() : d.amount0();
        if (debit >= 0 || credit <= 0) revert ConversionBound();
        if (exactInput) {
            if (uint256(-int256(debit)) != amount) revert ConversionBound();
            return uint256(uint128(credit));
        }
        if (uint256(uint128(credit)) != amount) revert ConversionBound();
        return uint256(-int256(debit));
    }

    function signed(uint256 amount) internal pure returns (int128) {
        if (amount == 0 || amount > uint256(uint128(type(int128).max))) revert ConversionBound();
        return int128(uint128(amount));
    }
}
