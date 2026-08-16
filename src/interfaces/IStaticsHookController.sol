// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

enum RevenueChannel {
    LiquidityProvider,
    BasketStaker,
    StaticsStaker,
    Partner,
    Creator,
    Treasury
}

interface IStaticsHookController {
    event HookBound(address indexed hook);
    event RevenueAccrued(
        PoolId indexed poolId,
        Currency indexed currency,
        RevenueChannel indexed channel,
        address recipient,
        uint256 amount
    );
    event RevenueClaimed(
        PoolId indexed poolId,
        Currency indexed currency,
        RevenueChannel indexed channel,
        address recipient,
        address receiver,
        uint256 amount
    );

    function hook() external view returns (address);
    function bindHook(address hook_) external;
    function accrueRevenue(PoolId poolId, Currency currency, RevenueChannel channel, address recipient, uint256 amount)
        external;
    function claimRevenue(PoolId poolId, Currency currency, RevenueChannel channel, address receiver)
        external
        returns (uint256 amount);
    function claimableRevenue(PoolId poolId, Currency currency, RevenueChannel channel, address recipient)
        external
        view
        returns (uint256 amount);
    function totalRevenueLiability(Currency currency) external view returns (uint256 amount);
}
