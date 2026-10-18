// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IStaticsBasketSettlement} from "../interfaces/IStaticsBasketSettlement.sol";
import {IStaticsBasketToken} from "../interfaces/IStaticsBasketToken.sol";
import {IStaticsLiquidityManager} from "../interfaces/IStaticsLiquidityManager.sol";
import {IStaticsBasket} from "../interfaces/IStaticsBasket.sol";
import {IMsgSender} from "@uniswap/v4-periphery/src/interfaces/IMsgSender.sol";
import {LibBasket} from "../libraries/LibBasket.sol";
import {LibBasketRewards} from "../libraries/LibBasketRewards.sol";
import {LibBasketLiquidity} from "../libraries/LibBasketLiquidity.sol";
import {LibBasketMarkets} from "../libraries/LibBasketMarkets.sol";
import {LibBasketManagerSettlement} from "../libraries/LibBasketManagerSettlement.sol";
import {LibBasketArbitrageSettlement} from "../libraries/LibBasketArbitrageSettlement.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @notice Hook-authenticated capabilities. Deliberately callable during guarded protocol actions.
contract BasketSettlementFacet is IStaticsBasketSettlement, ReentrancyGuard {
    function beginBasketArbitrage(uint256 basketId, uint256 shares, address executor) external nonReentrant {
        LibBasketArbitrageSettlement.begin(basketId, shares, executor);
    }

    function settleBasketArbitrageInput(address token, address executor, uint256 amount) external nonReentrant {
        LibBasketArbitrageSettlement.settleInput(token, executor, amount);
    }

    function settleBasketArbitrageOutput(address token, address executor, uint256 amount) external nonReentrant {
        LibBasketArbitrageSettlement.settleOutput(token, executor, amount);
    }

    function endBasketArbitrage() external nonReentrant {
        LibBasketArbitrageSettlement.end();
    }

    function isBasketToken(address token) external view returns (bool) {
        return LibBasket.isBasketToken(token);
    }

    function canAccrueBasketCurrencyRewards(PoolId poolId, address asset) external view returns (bool) {
        LibBasketMarkets.Market storage market = LibBasketMarkets.marketStorage().markets[poolId];
        return market.lifecycle != LibBasketMarkets.Lifecycle.None && LibBasketRewards.canAccrue(market.basketId)
            && LibBasketRewards.isRewardAsset(LibBasket.basketStorage().baskets[market.basketId], asset);
    }

    function settleBasketManagerDelivery(address token, address receiver, uint256 amount)
        external
        returns (uint256 spent, uint256 received)
    {
        return LibBasketManagerSettlement.settle(token, receiver, amount);
    }
    error InvalidClaimCurrency(address token);

    function validateBasketPool(PoolId poolId, uint8 action, address caller) external view {
        LibBasketMarkets.Market storage market = LibBasketMarkets.authenticate(poolId);
        LibBasketMarkets.validate(market, poolId, action);
        if (
            action == 1
                && LibBasket.basketStorage().baskets[market.basketId].status == IStaticsBasket.BasketStatus.Pending
        ) {
            address manager = LibBasketLiquidity.liquidityStorage().manager;
            if (
                caller != IStaticsLiquidityManager(manager).positionManager()
                    || IMsgSender(caller).msgSender() != manager
            ) {
                revert LibBasketMarkets.BasketMarketNotActive(poolId);
            }
        }
    }

    function authorizeBasketPoolSettlement(PoolId poolId, BalanceDelta callerDelta, uint8 action) external {
        LibBasketMarkets.Market storage market = LibBasketMarkets.authenticate(poolId);
        LibBasketMarkets.validate(market, poolId, action);
        if (market.basket0) _authorize(Currency.unwrap(market.key.currency0), callerDelta.amount0());
        if (market.basket1) _authorize(Currency.unwrap(market.key.currency1), callerDelta.amount1());
    }

    function authorizeBasketPoolClaim(PoolId poolId, Currency currency, address receiver, uint256 amount) external {
        LibBasketMarkets.Market storage market = LibBasketMarkets.authenticate(poolId);
        address token = Currency.unwrap(currency);
        bool basketCurrency;
        if (token == Currency.unwrap(market.key.currency0)) basketCurrency = market.basket0;
        else if (token == Currency.unwrap(market.key.currency1)) basketCurrency = market.basket1;
        else revert InvalidClaimCurrency(token);
        if (basketCurrency && amount != 0) IStaticsBasketToken(token).authorizePoolClaim(receiver, amount);
    }

    function _authorize(address token, int128 delta) private {
        if (delta == 0) return;
        uint256 inbound = delta < 0 ? uint256(-int256(delta)) : 0;
        uint256 outbound = delta > 0 ? uint256(uint128(delta)) : 0;
        IStaticsBasketToken(token).authorizePoolSettlement(inbound, outbound);
    }
}
