// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IStaticsBasket} from "./IStaticsBasket.sol";

interface IStaticsBasketPreparation {
    function installBasketFactory(address factory) external;
    function basketFactory() external view returns (address);
    function basketCreationConfigurationHash(
        IStaticsBasket.CreateBasketParams calldata params,
        IStaticsBasket.PoolLaunchParams[] calldata pools,
        uint256[] calldata maxAmountsIn,
        uint256 deadline
    ) external view returns (bytes32);
    function prepareBasketCreation(
        IStaticsBasket.CreateBasketParams calldata params,
        IStaticsBasket.PoolLaunchParams[] calldata pools,
        uint256[] calldata maxAmountsIn,
        uint256 deadline,
        uint256 tokenNonce,
        uint256[] calldata hookNonces
    ) external returns (bytes32 id, address token);
}
