// SPDX-License-Identifier: BUSL-1.1
// ============================================================================
//                              STATICS PROTOCOL
//                         Markets that work for you.
//                       https://staticsprotocol.com
//                              EqualFi Labs
// ============================================================================
pragma solidity 0.8.33;

import {IStaticsBasket} from "./IStaticsBasket.sol";

interface IStaticsBasketLaunchModule {
    struct PoolBatch {
        uint256 basketId;
        address payer;
        uint256 firstPool;
        uint256 poolCount;
    }

    function launchBasketPoolBatch(
        PoolBatch calldata batch,
        IStaticsBasket.PoolLaunchParams[] calldata pools,
        uint256[] calldata maxAmountsIn
    ) external returns (uint256 shares, uint256[] memory debits);

    function launchBasketPools(
        uint256 basketId,
        address payer,
        IStaticsBasket.PoolLaunchParams[] calldata pools,
        uint256[] calldata maxAmountsIn
    ) external returns (uint256 basketShares);

    function mintBasketLaunch(
        uint256 basketId,
        address payer,
        uint256 basketShares,
        uint256[] calldata assetAmounts,
        uint256[] calldata maxAmountsIn
    ) external;
}
