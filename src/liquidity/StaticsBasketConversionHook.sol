// SPDX-License-Identifier: BUSL-1.1
// ============================================================================
//                              STATICS PROTOCOL
//                         Markets that work for you.
//                       https://staticsprotocol.com
//                              EqualFi Labs
// ============================================================================
pragma solidity 0.8.33;

import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {IERC173} from "../interfaces/IERC173.sol";
import {IStaticsBasket} from "../interfaces/IStaticsBasket.sol";
import {IStaticsBasketConversion, IStaticsBasketConversionDelivery} from "../interfaces/IStaticsBasketConversion.sol";
import {IStaticsBasketSettlement} from "../interfaces/IStaticsBasketSettlement.sol";
import {
    BasketConversionRoute,
    BasketConversionRequest,
    IStaticsBasketConversionRoutes
} from "../interfaces/IStaticsBasketConversionRoutes.sol";
import {LibBasketConversion} from "../libraries/LibBasketConversion.sol";

/// @notice LP-free fixed-bundle conversion. Each registered PoolId identifies one basket/quote pair.
contract StaticsBasketConversionHook is BaseHook, IStaticsBasketConversionRoutes, IStaticsBasketConversionDelivery {
    using PoolIdLibrary for PoolKey;

    IStaticsBasket public immutable core;
    mapping(PoolId => mapping(bool => bytes)) private presets;

    error OnlyDiamond();
    error OnlyOwner();
    error NoConversionLiquidity();
    error UnsupportedConversionMode();

    constructor(IPoolManager pm, IStaticsBasket diamond) BaseHook(pm) {
        core = diamond;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory p) {
        p.beforeInitialize = true;
        p.beforeAddLiquidity = true;
        p.beforeSwap = true;
        p.beforeSwapReturnDelta = true;
    }

    function setPreset(PoolId id, bool buying, BasketConversionRoute[] calldata paths) external {
        if (msg.sender != IERC173(address(core)).owner()) revert OnlyOwner();
        LibBasketConversion.Context memory c = LibBasketConversion.context(poolManager, core, address(this), id);
        if (paths.length != 0) LibBasketConversion.validate(c, paths);
        bytes memory encoded = abi.encode(paths);
        presets[id][buying] = encoded;
        emit BasketConversionPresetSet(id, buying, keccak256(encoded));
    }

    function preset(PoolId id, bool buying) external view returns (BasketConversionRoute[] memory) {
        bytes memory encoded = presets[id][buying];
        if (encoded.length == 0) return new BasketConversionRoute[](0);
        return abi.decode(encoded, (BasketConversionRoute[]));
    }

    function deliverBasketConversion(
        PoolId id,
        uint256 basketId,
        uint256 shares,
        address receiver,
        uint256[] calldata amounts
    ) external {
        LibBasketConversion.deliver(poolManager, core, id, basketId, shares, receiver, amounts);
    }

    function _beforeInitialize(address sender, PoolKey calldata key, uint160) internal view override returns (bytes4) {
        if (sender != address(core)) revert OnlyDiamond();
        IStaticsBasketConversion.Market memory m =
            IStaticsBasketConversion(address(core)).basketConversionMarket(key.toId());
        if (!m.active) revert LibBasketConversion.ConversionUnavailable();
        return IHooks.beforeInitialize.selector;
    }

    function _beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        internal
        pure
        override
        returns (bytes4)
    {
        revert NoConversionLiquidity();
    }

    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata data)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        LibBasketConversion.enter();
        LibBasketConversion.Context memory c = LibBasketConversion.context(poolManager, core, address(this), key.toId());
        bool buying = params.zeroForOne == (Currency.unwrap(key.currency0) == c.market.quote);
        if ((buying && params.amountSpecified <= 0) || (!buying && params.amountSpecified >= 0)) {
            revert UnsupportedConversionMode();
        }
        uint256 shares = uint256(buying ? params.amountSpecified : -params.amountSpecified);
        int128 s = LibBasketConversion.signed(shares);
        int128 q = _convert(c, buying, shares, data);
        BalanceDelta callerDelta = Currency.unwrap(key.currency0) == c.market.basketToken
            ? toBalanceDelta(buying ? s : -s, buying ? -q : q)
            : toBalanceDelta(buying ? -q : q, buying ? s : -s);
        IStaticsBasketSettlement(address(core)).authorizeBasketPoolSettlement(key.toId(), callerDelta, 0);
        LibBasketConversion.exit();
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(buying ? -s : s, buying ? q : -q), 0);
    }

    function _convert(LibBasketConversion.Context memory c, bool buying, uint256 shares, bytes calldata data)
        private
        returns (int128)
    {
        BasketConversionRequest memory r = abi.decode(data, (BasketConversionRequest));
        BasketConversionRoute[] memory paths = LibBasketConversion.routes(c, r, buying);
        uint256 quoteAmount;
        if (buying) {
            quoteAmount = LibBasketConversion.buy(c, shares, address(poolManager), paths, r.routeLimits);
            if (quoteAmount > r.limit) revert LibBasketConversion.ConversionBound();
        } else {
            IStaticsBasketSettlement(address(core))
                .authorizeBasketPoolClaim(c.poolId, Currency.wrap(c.market.basketToken), address(this), shares);
            poolManager.take(Currency.wrap(c.market.basketToken), address(this), shares);
            quoteAmount = LibBasketConversion.sell(c, shares, paths, r.routeLimits);
            if (quoteAmount < r.limit) revert LibBasketConversion.ConversionBound();
        }
        return LibBasketConversion.signed(quoteAmount);
    }
}
