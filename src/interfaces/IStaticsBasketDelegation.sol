// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IStaticsBasket} from "./IStaticsBasket.sol";

interface IStaticsBasketDelegation {
    struct Authorization {
        address creator;
        address payer;
        bytes32 preparationId;
        bytes32 configurationHash;
        uint256 nonce;
        uint256 deadline;
        uint256 maxNativeFee;
    }

    function createBasketFor(
        IStaticsBasket.CreateBasketParams calldata params,
        IStaticsBasket.PoolLaunchParams[] calldata pools,
        uint256[] calldata maximums,
        Authorization calldata authorization,
        bytes calldata signature
    ) external payable returns (uint256 basketId, address token);
    function prepareBasketCreationFor(
        IStaticsBasket.CreateBasketParams calldata params,
        IStaticsBasket.PoolLaunchParams[] calldata pools,
        uint256[] calldata maximums,
        uint256 tokenNonce,
        uint256[] calldata hookNonces,
        Authorization calldata authorization,
        bytes calldata signature
    ) external returns (bytes32 id, address token);
    function creationAuthorizationDigest(Authorization calldata authorization) external view returns (bytes32);
    function creationNonceUsed(address creator, uint256 nonce) external view returns (bool);
    function invalidateCreationNonces(uint256 word, uint256 mask) external;
}
