// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IStaticsBasketSettlement} from "../interfaces/IStaticsBasketSettlement.sol";
import {IStaticsRestrictedBasketToken} from "../interfaces/IStaticsRestrictedBasketToken.sol";
import {LibBasketMarkets} from "../libraries/LibBasketMarkets.sol";
import {LibRestrictedBasket} from "../libraries/LibRestrictedBasket.sol";
import {LibBasketManagerSettlement} from "../libraries/LibBasketManagerSettlement.sol";
import {LibBasketArbitrageSettlement} from "../libraries/LibBasketArbitrageSettlement.sol";
import {LibBootstrapSettlement} from "../libraries/LibBootstrapSettlement.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @notice Hook-authenticated capabilities. Deliberately callable during guarded protocol actions.
contract BasketSettlementFacet is IStaticsBasketSettlement, ReentrancyGuard {
    function installBootstrapFactory(address factory, bytes32 runtimeHash, bytes32 creationCodeHash) external {
        LibBootstrapSettlement.install(factory, runtimeHash, creationCodeHash);
    }

    function bootstrapFactoryApproved(address factory) external view returns (bool) {
        return LibBootstrapSettlement.approved(factory);
    }

    function registerBootstrapCampaign(address campaign) external nonReentrant {
        LibBootstrapSettlement.register(campaign);
    }

    function settleBootstrapToken(address token, address sender, address receiver, uint256 amount)
        external
        nonReentrant
    {
        LibBootstrapSettlement.settle(token, sender, receiver, amount);
    }

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

    function isRestrictedBasketToken(address token) external view returns (bool) {
        return LibRestrictedBasket.isRestricted(token);
    }

    function settleBasketManagerDelivery(address token, address receiver, uint256 amount)
        external
        returns (uint256 spent, uint256 received)
    {
        return LibBasketManagerSettlement.settle(token, receiver, amount);
    }
    error InvalidClaimCurrency(address token);

    function validateBasketPool(PoolId poolId, uint8 action) external view {
        LibBasketMarkets.Market storage market = LibBasketMarkets.authenticate(poolId);
        LibBasketMarkets.validate(market, poolId, action);
    }

    function authorizeBasketPoolSettlement(PoolId poolId, BalanceDelta callerDelta, uint8 action) external {
        LibBasketMarkets.Market storage market = LibBasketMarkets.authenticate(poolId);
        // Initialization never creates settlement credit.
        if (action > 2) revert LibBasketMarkets.InvalidSettlementAction(action);
        LibBasketMarkets.validate(market, poolId, action);
        if (market.restricted0) _authorize(Currency.unwrap(market.key.currency0), callerDelta.amount0());
        if (market.restricted1) _authorize(Currency.unwrap(market.key.currency1), callerDelta.amount1());
    }

    function authorizeBasketPoolClaim(PoolId poolId, Currency currency, address receiver, uint256 amount) external {
        LibBasketMarkets.Market storage market = LibBasketMarkets.authenticate(poolId);
        address token = Currency.unwrap(currency);
        bool restricted;
        if (token == Currency.unwrap(market.key.currency0)) restricted = market.restricted0;
        else if (token == Currency.unwrap(market.key.currency1)) restricted = market.restricted1;
        else revert InvalidClaimCurrency(token);
        if (restricted && amount != 0) IStaticsRestrictedBasketToken(token).authorizePoolClaim(receiver, amount);
    }

    function _authorize(address token, int128 delta) private {
        if (delta == 0) return;
        uint256 inbound = delta < 0 ? uint256(-int256(delta)) : 0;
        uint256 outbound = delta > 0 ? uint256(uint128(delta)) : 0;
        IStaticsRestrictedBasketToken(token).authorizePoolSettlement(inbound, outbound);
    }
}
