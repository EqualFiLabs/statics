// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IStaticsBasket} from "./IStaticsBasket.sol";

interface IStaticsBasketPreparation {
    function deployPreparedBasketContracts(
        IStaticsBasket.CreateBasketParams calldata params,
        IStaticsBasket.PoolLaunchParams[] calldata pools,
        uint256[] calldata maxAmountsIn,
        uint256 deadline,
        bytes32 id
    ) external returns (uint256 basketId, address token);
    function preparedBasketContracts(bytes32 id) external view returns (uint256 basketId, address token, bool finalized);
    /// @notice Compatibility getter for the token-only basket factory.
    function basketFactory() external view returns (address);
    function basketTokenFactory() external view returns (address);
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
        uint256 tokenNonce
    ) external returns (bytes32 id, address token);
}
