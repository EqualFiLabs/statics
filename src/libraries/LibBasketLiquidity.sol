// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

library LibBasketLiquidity {
    bytes32 internal constant LIQUIDITY_STORAGE_POSITION = keccak256("statics.storage.basket.liquidity.v3");

    struct CanonicalPool {
        PoolKey key;
    }

    struct PoolAssociation {
        uint256 basketId;
        address asset;
        bool associated;
    }

    struct LiquidityStorage {
        address poolManager;
        address hook;
        bool integrationInstalled;
        address manager;
        bool managerInstalled;
        mapping(uint256 basketId => mapping(address asset => CanonicalPool pool)) canonicalPools;
        mapping(PoolId poolId => PoolAssociation association) poolAssociations;
    }

    function liquidityStorage() internal pure returns (LiquidityStorage storage ls) {
        bytes32 position = LIQUIDITY_STORAGE_POSITION;
        assembly ("memory-safe") {
            ls.slot := position
        }
    }
}
