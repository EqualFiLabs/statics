// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IStaticsPermissionedSwapFeeHook} from "./IStaticsPermissionedSwapFeeHook.sol";

interface IStaticsPermissionedPools {
    struct CreatePermissionedPoolParams {
        address tokenA;
        address tokenB;
        uint24 lpFee;
        int24 tickSpacing;
        uint160 sqrtPriceBPerAX96;
        address creator;
        address controller;
        IStaticsPermissionedSwapFeeHook.PoolEconomics economics;
        uint256 authorizationNonce;
        uint256 deadline;
        bytes32 agreementHash;
    }

    struct PermissionedPoolQuote {
        PoolKey key;
        PoolId poolId;
        uint160 sqrtPriceX96;
        bytes32 authorizationDigest;
    }

    struct PermissionedPoolView {
        PoolId poolId;
        PoolKey key;
        address creator;
        address controller;
        bool decommissioned;
        uint256 configurationNonce;
        IStaticsPermissionedSwapFeeHook.PoolEconomics economics;
    }

    event PermissionedPoolCreated(
        PoolId indexed poolId,
        address indexed creator,
        address indexed controller,
        address currency0,
        address currency1,
        uint24 lpFee,
        int24 tickSpacing,
        uint160 sqrtPriceX96,
        int24 tick,
        bytes32 agreementHash
    );
    event PermissionedAuthorizationNonceInvalidated(address indexed creator, uint256 indexed nonce);
    event PermissionedConfigurationNonceInvalidated(PoolId indexed poolId, uint256 oldNonce, uint256 newNonce);
    event PermissionedPoolTermsChanged(
        PoolId indexed poolId,
        uint256 indexed nonce,
        bytes32 indexed agreementHash,
        IStaticsPermissionedSwapFeeHook.PoolEconomics oldEconomics,
        IStaticsPermissionedSwapFeeHook.PoolEconomics newEconomics
    );
    event PermissionedPoolDecommissioned(PoolId indexed poolId);
    event PermissionedTrustedPeripherySet(address indexed periphery, bool trusted);

    function quotePermissionedPool(CreatePermissionedPoolParams calldata params)
        external
        view
        returns (PermissionedPoolQuote memory quote);
    function createPermissionedPool(CreatePermissionedPoolParams calldata params, bytes calldata creatorAuthorization)
        external
        returns (PoolId poolId);
    function invalidatePermissionedAuthorizationNonce(uint256 nonce) external;
    function applyPermissionedPoolTerms(
        PoolId poolId,
        IStaticsPermissionedSwapFeeHook.PoolEconomics calldata economics,
        uint256 nonce,
        uint256 deadline,
        bytes32 agreementHash,
        bytes calldata creatorAuthorization
    ) external;
    function invalidatePermissionedConfigurationNonce(PoolId poolId, uint256 nonce) external;
    function decommissionPermissionedPool(PoolId poolId) external;
    function setPermissionedTrustedPeriphery(address periphery, bool trusted) external;
    function permissionedPool(PoolId poolId) external view returns (PermissionedPoolView memory pool);
    function isPermissionedPool(PoolId poolId) external view returns (bool registered);
    function isPermissionedAuthorizationNonceUsed(address creator, uint256 nonce) external view returns (bool used);
    function permissionedTermsDigest(
        PoolId poolId,
        IStaticsPermissionedSwapFeeHook.PoolEconomics calldata economics,
        uint256 nonce,
        uint256 deadline,
        bytes32 agreementHash
    ) external view returns (bytes32 digest);
}
