// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IStaticsProtocolPools} from "../interfaces/IStaticsProtocolPools.sol";
import {LibBasketLiquidity} from "./LibBasketLiquidity.sol";

library LibProtocolPools {
    using PoolIdLibrary for PoolKey;

    bytes32 internal constant PROTOCOL_POOL_STORAGE_POSITION = keccak256("statics.storage.protocol.pools.v1");

    struct GovernancePool {
        PoolKey key;
        bool registered;
    }

    struct ProtocolPoolStorage {
        mapping(PoolId poolId => GovernancePool pool) governancePools;
    }

    error ProtocolPoolNotRegistered(PoolId poolId);
    error ProtocolPoolAlreadyRegistered(PoolId poolId, IStaticsProtocolPools.ProtocolPoolKind kind);
    error GovernancePoolNotRegistered(PoolId poolId);

    function protocolPoolStorage() internal pure returns (ProtocolPoolStorage storage ps) {
        bytes32 position = PROTOCOL_POOL_STORAGE_POSITION;
        assembly ("memory-safe") {
            ps.slot := position
        }
    }

    function resolve(PoolId poolId)
        internal
        view
        returns (IStaticsProtocolPools.ProtocolPoolKind kind, PoolKey memory key, uint256 basketId, address basketAsset)
    {
        LibBasketLiquidity.LiquidityStorage storage ls = LibBasketLiquidity.liquidityStorage();
        LibBasketLiquidity.PoolAssociation storage association = ls.poolAssociations[poolId];
        if (association.associated) {
            LibBasketLiquidity.CanonicalPool storage canonical =
                ls.canonicalPools[association.basketId][association.asset];
            if (PoolId.unwrap(canonical.key.toId()) == PoolId.unwrap(poolId)) {
                return (
                    IStaticsProtocolPools.ProtocolPoolKind.BasketCanonical,
                    canonical.key,
                    association.basketId,
                    association.asset
                );
            }
        }

        GovernancePool storage governance = protocolPoolStorage().governancePools[poolId];
        if (governance.registered && PoolId.unwrap(governance.key.toId()) == PoolId.unwrap(poolId)) {
            return (IStaticsProtocolPools.ProtocolPoolKind.Governance, governance.key, 0, address(0));
        }
    }

    function enforceUnregistered(PoolId poolId) internal view {
        (IStaticsProtocolPools.ProtocolPoolKind kind,,,) = resolve(poolId);
        if (kind != IStaticsProtocolPools.ProtocolPoolKind.None) {
            revert ProtocolPoolAlreadyRegistered(poolId, kind);
        }
    }

    function enforceRegistered(PoolId poolId)
        internal
        view
        returns (IStaticsProtocolPools.ProtocolPoolKind kind, PoolKey memory key, uint256 basketId, address basketAsset)
    {
        (kind, key, basketId, basketAsset) = resolve(poolId);
        if (kind == IStaticsProtocolPools.ProtocolPoolKind.None) revert ProtocolPoolNotRegistered(poolId);
    }

    function governancePool(PoolId poolId) internal view returns (GovernancePool storage pool) {
        pool = protocolPoolStorage().governancePools[poolId];
        if (!pool.registered) revert GovernancePoolNotRegistered(poolId);
    }
}
