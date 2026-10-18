// SPDX-License-Identifier: BUSL-1.1
// ============================================================================
//                              STATICS PROTOCOL
//                         Markets that work for you.
//                       https://staticsprotocol.com
//                              EqualFi Labs
// ============================================================================
pragma solidity 0.8.33;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

interface IStaticsBasketMarkets {
    struct MarketParams {
        address tokenA;
        address tokenB;
        uint24 lpFee;
        int24 tickSpacing;
        uint160 sqrtPriceBPerAX96;
        uint256 maximumCreationFee;
        uint256 deadline;
        bool activateManagedPol;
    }

    event BasketMarketCreated(PoolId indexed poolId, address indexed creator, address indexed hook, uint256 basketId);
    function createBasketMarket(MarketParams calldata params) external payable returns (PoolId poolId);
}
