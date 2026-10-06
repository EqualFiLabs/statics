// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IStaticsBasket} from "../interfaces/IStaticsBasket.sol";
import {LibBasket} from "./LibBasket.sol";
import {LibRestrictedBasket} from "./LibRestrictedBasket.sol";

/// @notice Permanent identities; canonical pointers may never erase historical settlement records.
library LibBasketMarkets {
    using PoolIdLibrary for PoolKey;

    bytes32 private constant STORAGE_POSITION = keccak256("statics.storage.basket.markets.v1");

    enum Lifecycle {
        None,
        Active,
        ExitOnly,
        Decommissioned
    }

    struct Market {
        PoolKey key;
        address creator;
        uint256 basketId;
        address basketAsset;
        uint256 version;
        bool restricted0;
        bool restricted1;
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
    error InvalidLifecycleTransition(Lifecycle current, Lifecycle next);

    function marketStorage() internal pure returns (MarketStorage storage ms) {
        bytes32 slot = STORAGE_POSITION;
        assembly ("memory-safe") { ms.slot := slot }
    }

    function register(PoolKey memory key, address creator, uint256 basketId, address basketAsset, uint256 version)
        internal
    {
        PoolId id = key.toId();
        Market storage market = marketStorage().markets[id];
        if (market.lifecycle != Lifecycle.None) revert BasketMarketAlreadyRegistered(id);
        address token0 = Currency.unwrap(key.currency0);
        address token1 = Currency.unwrap(key.currency1);
        bool restricted0 = LibRestrictedBasket.isRestricted(token0);
        bool restricted1 = LibRestrictedBasket.isRestricted(token1);
        if (
            !restricted0 && !restricted1 || token0 == address(0) || token0 >= token1 || creator == address(0)
                || address(key.hooks).code.length == 0 || version == 0
        ) {
            revert InvalidBasketMarket(id);
        }
        market.key = key;
        market.creator = creator;
        market.basketId = basketId;
        market.basketAsset = basketAsset;
        market.version = version;
        market.restricted0 = restricted0;
        market.restricted1 = restricted1;
        market.lifecycle = Lifecycle.Active;
    }

    function requireMarket(PoolId id) internal view returns (Market storage market) {
        market = marketStorage().markets[id];
        if (market.lifecycle == Lifecycle.None || PoolId.unwrap(market.key.toId()) != PoolId.unwrap(id)) {
            revert InvalidBasketMarket(id);
        }
    }

    function authenticate(PoolId id) internal view returns (Market storage market) {
        market = requireMarket(id);
        if (msg.sender != address(market.key.hooks)) {
            revert OnlyRegisteredBasketHook(msg.sender, address(market.key.hooks));
        }
    }

    function validate(Market storage market, PoolId id, uint256 action) internal view {
        if (action > 3) revert InvalidSettlementAction(action);
        if (action == 2) return; // Historical removal, collection, and claims stay available.
        if (market.lifecycle != Lifecycle.Active) revert BasketMarketNotActive(id);
        if (market.restricted0) _requireCurrencyActive(Currency.unwrap(market.key.currency0));
        if (market.restricted1) _requireCurrencyActive(Currency.unwrap(market.key.currency1));
    }

    function transition(PoolId id, Lifecycle next) internal {
        Market storage market = requireMarket(id);
        Lifecycle current = market.lifecycle;
        if (next <= current || next == Lifecycle.None) revert InvalidLifecycleTransition(current, next);
        market.lifecycle = next;
    }

    function _requireCurrencyActive(address token) private view {
        uint256 basketId = LibRestrictedBasket.restrictedStorage().basketIds[token] - 1;
        LibBasket.enforceActive(LibBasket.basketStorage().baskets[basketId], basketId);
    }
}
