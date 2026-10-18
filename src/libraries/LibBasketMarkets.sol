// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IStaticsBasket} from "../interfaces/IStaticsBasket.sol";
import {LibBasketLaunchExecution} from "./LibBasketLaunchExecution.sol";
import {LibBasket} from "./LibBasket.sol";

/// @notice Permanent identities; canonical pointers may never erase historical settlement records.
library LibBasketMarkets {
    using PoolIdLibrary for PoolKey;

    bytes32 private constant STORAGE_POSITION = keccak256("statics.storage.basket.markets");

    enum Lifecycle {
        None,
        Active,
        Decommissioned
    }

    struct Market {
        PoolKey key;
        address creator;
        uint256 basketId;
        address basketAsset;
        bool basket0;
        bool basket1;
        Lifecycle lifecycle;
    }

    struct MarketStorage {
        mapping(PoolId poolId => Market market) markets;
    }

    error InvalidBasketMarket(PoolId poolId);
    error BasketMarketAlreadyRegistered(PoolId poolId);
    error OnlyRegisteredBasketHook(address caller, address expected);
    error BasketMarketNotActive(PoolId poolId);
    error InvalidSettlementAction(uint256 action);

    function marketStorage() internal pure returns (MarketStorage storage ms) {
        bytes32 slot = STORAGE_POSITION;
        assembly ("memory-safe") { ms.slot := slot }
    }

    function register(PoolKey memory key, address creator, uint256 basketId, address basketAsset) internal {
        PoolId id = key.toId();
        Market storage market = marketStorage().markets[id];
        if (market.lifecycle != Lifecycle.None) revert BasketMarketAlreadyRegistered(id);
        address token0 = Currency.unwrap(key.currency0);
        address token1 = Currency.unwrap(key.currency1);
        bool basket0 = LibBasket.isBasketToken(token0);
        bool basket1 = LibBasket.isBasketToken(token1);
        if (!basket0 && !basket1 || token0 >= token1 || creator == address(0) || address(key.hooks).code.length == 0) {
            revert InvalidBasketMarket(id);
        }
        market.key = key;
        market.creator = creator;
        market.basketId = basketId;
        market.basketAsset = basketAsset;
        market.basket0 = basket0;
        market.basket1 = basket1;
        market.lifecycle = Lifecycle.Active;
    }

    function requireMarket(PoolId id) internal view returns (Market storage market) {
        market = marketStorage().markets[id];
        if (market.lifecycle == Lifecycle.None) revert InvalidBasketMarket(id);
    }

    function authenticate(PoolId id) internal view returns (Market storage market) {
        market = requireMarket(id);
        if (msg.sender != address(market.key.hooks)) {
            revert OnlyRegisteredBasketHook(msg.sender, address(market.key.hooks));
        }
    }

    function validate(Market storage market, PoolId id, uint256 action) internal view {
        if (action > 2) revert InvalidSettlementAction(action);
        if (action == 2) return; // Historical removal, collection, and claims stay available.
        if (market.lifecycle != Lifecycle.Active) revert BasketMarketNotActive(id);
        if (market.basket0) _requireCurrencyActive(Currency.unwrap(market.key.currency0), id, action);
        if (market.basket1) _requireCurrencyActive(Currency.unwrap(market.key.currency1), id, action);
    }

    function decommission(PoolId id) internal {
        Market storage market = requireMarket(id);
        if (market.lifecycle != Lifecycle.Active) revert BasketMarketNotActive(id);
        market.lifecycle = Lifecycle.Decommissioned;
    }

    function _requireCurrencyActive(address token, PoolId id, uint256 action) private view {
        uint256 basketId = LibBasket.basketStorage().basketIds[token] - 1;
        LibBasket.Basket storage configured = LibBasket.basketStorage().baskets[basketId];
        if (
            configured.status == IStaticsBasket.BasketStatus.Pending && action == 1
                && LibBasketLaunchExecution.permits(id)
        ) return;
        LibBasket.enforceActive(configured, basketId);
    }
}
