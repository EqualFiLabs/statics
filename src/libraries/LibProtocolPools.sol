// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IStaticsProtocolPools} from "../interfaces/IStaticsProtocolPools.sol";
import {LibBasket} from "./LibBasket.sol";
import {LibBasketLiquidity} from "./LibBasketLiquidity.sol";

/// @notice Normalized protocol-pool registry resolving both basket canonical and general pools.
/// @dev Uses a fresh namespaced storage version so the layout cannot be confused with the replaced
/// governance-pool registry. Fee rates and allocation profiles live in `StaticsSwapFeeHook`; this
/// library stores only general-pool identity, creator attribution, creation nonces, and the creation
/// fee.
library LibProtocolPools {
    using PoolIdLibrary for PoolKey;

    bytes32 internal constant PROTOCOL_POOL_STORAGE_POSITION = keccak256("statics.storage.protocol.pools.v2");

    struct GeneralPool {
        PoolKey key;
        address creator;
        bool registered;
    }

    struct ProtocolPoolStorage {
        mapping(PoolId poolId => GeneralPool pool) generalPools;
        mapping(address creator => mapping(uint256 nonce => bool used)) poolCreationNonceUsed;
        uint256 poolCreationFeeAmount;
    }

    error ProtocolPoolNotRegistered(PoolId poolId);
    error ProtocolPoolAlreadyRegistered(PoolId poolId, IStaticsProtocolPools.ProtocolPoolKind kind);
    error GeneralPoolNotRegistered(PoolId poolId);

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

        GeneralPool storage general = protocolPoolStorage().generalPools[poolId];
        if (general.registered && PoolId.unwrap(general.key.toId()) == PoolId.unwrap(poolId)) {
            return (IStaticsProtocolPools.ProtocolPoolKind.General, general.key, 0, address(0));
        }
    }

    /// @dev Normalized immutable creator resolver. Basket canonical -> basket creator; general ->
    /// stored general-pool creator. Downstream fee routing consumes this rather than duplicating
    /// pool-class-specific lookups.
    function creatorOf(PoolId poolId) internal view returns (address creator) {
        (IStaticsProtocolPools.ProtocolPoolKind kind,, uint256 basketId,) = resolve(poolId);
        if (kind == IStaticsProtocolPools.ProtocolPoolKind.BasketCanonical) {
            return LibBasket.basketStorage().baskets[basketId].creator;
        }
        if (kind == IStaticsProtocolPools.ProtocolPoolKind.General) {
            return protocolPoolStorage().generalPools[poolId].creator;
        }
        return address(0);
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

    function generalPool(PoolId poolId) internal view returns (GeneralPool storage pool) {
        pool = protocolPoolStorage().generalPools[poolId];
        if (!pool.registered) revert GeneralPoolNotRegistered(poolId);
    }
}
