// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IStaticsBasket} from "./IStaticsBasket.sol";

interface IStaticsBasketLaunchModule {
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
