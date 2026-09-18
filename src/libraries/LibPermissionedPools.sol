// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

library LibPermissionedPools {
    using PoolIdLibrary for PoolKey;

    bytes32 internal constant PERMISSIONED_POOL_STORAGE_POSITION =
        keccak256("statics.storage.permissioned.protocol.pools.v1");

    struct PermissionedPool {
        PoolKey key;
        address creator;
        uint256 configurationNonce;
        bool registered;
        bool decommissioned;
    }

    struct PermissionedPoolStorage {
        mapping(PoolId poolId => PermissionedPool pool) pools;
        mapping(address creator => mapping(uint256 nonce => bool used)) authorizationNonceUsed;
    }

    error PermissionedPoolNotRegistered(PoolId poolId);
    error PermissionedPoolAlreadyRegistered(PoolId poolId);

    function permissionedPoolStorage() internal pure returns (PermissionedPoolStorage storage ps) {
        bytes32 position = PERMISSIONED_POOL_STORAGE_POSITION;
        assembly ("memory-safe") {
            ps.slot := position
        }
    }

    function resolve(PoolId poolId) internal view returns (PermissionedPool storage pool) {
        pool = permissionedPoolStorage().pools[poolId];
    }

    function enforceRegistered(PoolId poolId) internal view returns (PermissionedPool storage pool) {
        pool = resolve(poolId);
        if (!pool.registered || PoolId.unwrap(pool.key.toId()) != PoolId.unwrap(poolId)) {
            revert PermissionedPoolNotRegistered(poolId);
        }
    }

    function enforceUnregistered(PoolId poolId) internal view {
        if (resolve(poolId).registered) revert PermissionedPoolAlreadyRegistered(poolId);
    }
}
