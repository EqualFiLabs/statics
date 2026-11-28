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
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IStaticsBasket} from "../interfaces/IStaticsBasket.sol";
import {IStaticsBasketConversionDelivery} from "../interfaces/IStaticsBasketConversion.sol";
import {BasketConversionRoute, BasketConversionRequest} from "../interfaces/IStaticsBasketConversionRoutes.sol";
import {LibBasketConversion} from "../libraries/LibBasketConversion.sol";

contract StaticsBasketConversionZap is IStaticsBasketConversionDelivery {
    using SafeERC20 for IERC20;
    using TransientSlot for *;

    IPoolManager public immutable poolManager;
    IStaticsBasket public immutable core;
    address public immutable hook;
    bytes32 private constant COMMITMENT_SLOT = keccak256("statics.basket.conversion.zap.commitment");

    constructor(IPoolManager pm, IStaticsBasket diamond, address conversionHook) {
        poolManager = pm;
        core = diamond;
        hook = conversionHook;
    }

    function buy(PoolId id, uint256 shares, address receiver, BasketConversionRequest calldata r)
        external
        returns (uint256)
    {
        return _execute(id, true, shares, receiver, r);
    }

    function sell(PoolId id, uint256 shares, address receiver, BasketConversionRequest calldata r)
        external
        returns (uint256)
    {
        return _execute(id, false, shares, receiver, r);
    }

    function _execute(PoolId id, bool buying, uint256 shares, address receiver, BasketConversionRequest calldata r)
        private
        returns (uint256 result)
    {
        LibBasketConversion.enter();
        if (receiver == address(0) || receiver == address(this) || receiver == address(poolManager)) {
            revert LibBasketConversion.InvalidConversionRoute();
        }
        IERC20 basketToken;
        uint256 beforeBalance;
        if (!buying) {
            LibBasketConversion.Context memory c = LibBasketConversion.context(poolManager, core, hook, id);
            LibBasketConversion.signed(shares);
            basketToken = IERC20(c.market.basketToken);
            beforeBalance = basketToken.balanceOf(address(this));
            basketToken.safeTransferFrom(msg.sender, address(this), shares);
            if (basketToken.balanceOf(address(this)) != beforeBalance + shares) {
                revert LibBasketConversion.InexactConversionTransfer();
            }
        }
        bytes memory data = abi.encode(id, buying, shares, msg.sender, receiver, r);
        COMMITMENT_SLOT.asBytes32().tstore(keccak256(data));
        result = abi.decode(poolManager.unlock(data), (uint256));
        if (COMMITMENT_SLOT.asBytes32().tload() != bytes32(0)) {
            revert LibBasketConversion.UnauthorizedConversionCallback();
        }
        if (!buying && basketToken.balanceOf(address(this)) != beforeBalance) {
            revert LibBasketConversion.InexactConversionTransfer();
        }
        LibBasketConversion.exit();
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        bytes32 commitment = COMMITMENT_SLOT.asBytes32().tload();
        if (msg.sender != address(poolManager) || commitment == bytes32(0) || commitment != keccak256(data)) {
            revert LibBasketConversion.UnauthorizedConversionCallback();
        }
        COMMITMENT_SLOT.asBytes32().tstore(bytes32(0));
        (PoolId id, bool buying, uint256 shares, address payer, address receiver, BasketConversionRequest memory r) =
            abi.decode(data, (PoolId, bool, uint256, address, address, BasketConversionRequest));
        LibBasketConversion.Context memory c = LibBasketConversion.context(poolManager, core, hook, id);
        BasketConversionRoute[] memory paths = LibBasketConversion.routes(c, r, buying);
        uint256 q;
        if (buying) {
            q = LibBasketConversion.buy(c, shares, receiver, paths, r.routeLimits);
            if (q > r.limit) revert LibBasketConversion.ConversionBound();
            poolManager.sync(Currency.wrap(c.market.quote));
            IERC20(c.market.quote).safeTransferFrom(payer, address(poolManager), q);
            if (poolManager.settle() != q) revert LibBasketConversion.InexactConversionTransfer();
        } else {
            q = LibBasketConversion.sell(c, shares, paths, r.routeLimits);
            if (q < r.limit) revert LibBasketConversion.ConversionBound();
            poolManager.take(Currency.wrap(c.market.quote), receiver, q);
        }
        return abi.encode(q);
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
}
