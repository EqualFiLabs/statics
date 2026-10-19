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
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IStaticsBasket} from "../interfaces/IStaticsBasket.sol";
import {IStaticsBasketConversion} from "../interfaces/IStaticsBasketConversion.sol";
import {LibBasketConversion} from "../libraries/LibBasketConversion.sol";

struct BasketConversionStep {
    PoolKey key;
    SwapParams params;
    bytes data;
}

struct BasketConversionBounds {
    uint256 maxQuoteIn;
    uint256 minQuoteOut;
    uint256 minBasketOut;
    uint256 deadline;
}

/// @notice Bounded basket/quote swaps in one unlock; wallet basket sells explicitly prefund physical shares.
contract StaticsBasketConversionRouter {
    using SafeERC20 for IERC20;
    using TransientSlot for *;
    using TransientStateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    IPoolManager public immutable poolManager;
    IStaticsBasket public immutable core;
    address public immutable hook;
    bytes32 private constant COMMITMENT_SLOT = keccak256("statics.basket.conversion.router.commitment");

    constructor(IPoolManager pm, IStaticsBasket diamond, address conversionHook) {
        poolManager = pm;
        core = diamond;
        hook = conversionHook;
    }

    function execute(
        PoolId id,
        BasketConversionStep[] calldata steps,
        uint256 prefund,
        BasketConversionBounds calldata bounds
    ) external returns (int256 quoteDelta) {
        LibBasketConversion.enter();
        if (block.timestamp > bounds.deadline) revert LibBasketConversion.ConversionExpired();
        LibBasketConversion.Context memory c = LibBasketConversion.context(poolManager, core, hook, id);
        if (steps.length == 0 || steps.length > 4) revert LibBasketConversion.InvalidConversionRoute();
        bool includesConversion;
        for (uint256 i; i < steps.length; ++i) {
            if (
                Currency.unwrap(steps[i].key.currency0) != Currency.unwrap(c.market.key.currency0)
                    || Currency.unwrap(steps[i].key.currency1) != Currency.unwrap(c.market.key.currency1)
            ) revert LibBasketConversion.InvalidConversionRoute();
            if (PoolId.unwrap(steps[i].key.toId()) == PoolId.unwrap(id)) includesConversion = true;
            else if (address(steps[i].key.hooks) == hook) revert LibBasketConversion.InvalidConversionRoute();
        }
        if (!includesConversion) revert LibBasketConversion.InvalidConversionRoute();
        bytes memory data = abi.encode(id, steps, prefund, bounds, msg.sender);
        COMMITMENT_SLOT.asBytes32().tstore(keccak256(data));
        quoteDelta = abi.decode(poolManager.unlock(data), (int256));
        if (COMMITMENT_SLOT.asBytes32().tload() != bytes32(0)) {
            revert LibBasketConversion.UnauthorizedConversionCallback();
        }
        LibBasketConversion.exit();
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        bytes32 commitment = COMMITMENT_SLOT.asBytes32().tload();
        if (msg.sender != address(poolManager) || commitment == bytes32(0) || commitment != keccak256(data)) {
            revert LibBasketConversion.UnauthorizedConversionCallback();
        }
        COMMITMENT_SLOT.asBytes32().tstore(bytes32(0));
        (
            PoolId id,
            BasketConversionStep[] memory steps,
            uint256 prefund,
            BasketConversionBounds memory bounds,
            address payer
        ) = abi.decode(data, (PoolId, BasketConversionStep[], uint256, BasketConversionBounds, address));
        IStaticsBasketConversion.Market memory m = IStaticsBasketConversion(address(core)).basketConversionMarket(id);
        if (prefund != 0) IStaticsBasketConversion(address(core)).prefundBasketConversion(id, payer, prefund);
        for (uint256 i; i < steps.length; ++i) {
            poolManager.swap(steps[i].key, steps[i].params, steps[i].data);
        }
        int256 q = poolManager.currencyDelta(address(this), Currency.wrap(m.quote));
        int256 b = poolManager.currencyDelta(address(this), Currency.wrap(m.basketToken));
        if (q >= 0 ? uint256(q) < bounds.minQuoteOut : bounds.minQuoteOut != 0 || uint256(-q) > bounds.maxQuoteIn) {
            revert LibBasketConversion.ConversionBound();
        }
        if (b < 0 || uint256(b) < bounds.minBasketOut) revert LibBasketConversion.ConversionBound();
        _settle(m.quote, payer);
        _settle(m.basketToken, payer);
        return abi.encode(q);
    }

    function _settle(address token, address payer) private {
        Currency c = Currency.wrap(token);
        int256 delta = poolManager.currencyDelta(address(this), c);
        if (delta > 0) {
            poolManager.take(c, payer, uint256(delta));
        } else if (delta < 0) {
            poolManager.sync(c);
            IERC20(token).safeTransferFrom(payer, address(poolManager), uint256(-delta));
            if (poolManager.settle() != uint256(-delta)) revert LibBasketConversion.InexactConversionTransfer();
        }
    }
}
