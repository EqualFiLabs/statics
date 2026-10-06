// SPDX-License-Identifier: BUSL-1.1
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
    }

    event BasketMarketCreated(PoolId indexed poolId, address indexed creator, address indexed hook, uint256 basketId);

    function prepareBasketMarket(MarketParams calldata params, bytes32 hookSalt)
        external
        returns (bytes32 preparationId, address hook);
    function createBasketMarket(MarketParams calldata params, bytes32 preparationId)
        external
        payable
        returns (PoolId poolId);
}
