// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

interface IStaticsBasketSettlement {
    function isRestrictedBasketToken(address token) external view returns (bool);
    function settleBasketManagerDelivery(address token, address receiver, uint256 amount)
        external
        returns (uint256 spent, uint256 received);
    // Actions: 0 swap, 1 liquidity ingress, 2 removal/collection, 3 initialization.
    function validateBasketPool(PoolId poolId, uint8 action) external view;
    function authorizeBasketPoolSettlement(PoolId poolId, BalanceDelta callerDelta, uint8 action) external;
    function authorizeBasketPoolClaim(PoolId poolId, Currency currency, address receiver, uint256 amount) external;
}
