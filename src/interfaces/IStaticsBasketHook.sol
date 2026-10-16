// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

interface IStaticsBasketHook {
    function VERSION() external view returns (uint256);
    function settleStakerRewardsForPool(PoolId poolId, Currency currency, address receiver, uint256 amount)
        external
        returns (uint256 settled);
}
