// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IStaticsBasket} from "./IStaticsBasket.sol";

interface IStaticsBasketPreparation {
    function prepareBasketToken(
        IStaticsBasket.CreateBasketParams calldata params,
        IStaticsBasket.PoolLaunchParams[] calldata pools,
        uint256[] calldata maxAmountsIn,
        uint256 deadline,
        uint256 tokenNonce
    ) external returns (bytes32 id, uint256 basketId, address token);
    function preparedBasketContracts(bytes32 id) external view returns (uint256 basketId, address token, bool finalized);
    function basketCreationConfigurationHash(
        IStaticsBasket.CreateBasketParams calldata params,
        IStaticsBasket.PoolLaunchParams[] calldata pools,
        uint256[] calldata maxAmountsIn,
        uint256 deadline
    ) external view returns (bytes32);
}
