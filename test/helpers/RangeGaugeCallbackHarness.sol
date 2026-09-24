// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {RangeGaugeCallbackFacet} from "../../src/facets/RangeGaugeCallbackFacet.sol";
import {IStaticsRangeGaugeCallback} from "../../src/interfaces/IStaticsRangeGaugeCallback.sol";
import {LibBasketLiquidity} from "../../src/libraries/LibBasketLiquidity.sol";
import {LibPermissionedPools} from "../../src/libraries/LibPermissionedPools.sol";
import {LibProtocolPools} from "../../src/libraries/LibProtocolPools.sol";

contract RangeGaugeCallbackHarness is RangeGaugeCallbackFacet {
    using PoolIdLibrary for PoolKey;

    function installPublicIntegration(address poolManager, address hook) external {
        LibBasketLiquidity.LiquidityStorage storage ls = LibBasketLiquidity.liquidityStorage();
        ls.poolManager = poolManager;
        ls.hook = hook;
        ls.integrationInstalled = true;
    }

    function registerGeneralPool(PoolKey calldata key, address creator) external returns (PoolId poolId) {
        poolId = key.toId();
        LibProtocolPools.GeneralPool storage pool = LibProtocolPools.protocolPoolStorage().generalPools[poolId];
        pool.key = key;
        pool.creator = creator;
        pool.registered = true;
    }

    function registerBasketPool(PoolKey calldata key, uint256 basketId, address asset)
        external
        returns (PoolId poolId)
    {
        poolId = key.toId();
        LibBasketLiquidity.LiquidityStorage storage ls = LibBasketLiquidity.liquidityStorage();
        ls.canonicalPools[basketId][asset].key = key;
        ls.poolAssociations[poolId] =
            LibBasketLiquidity.PoolAssociation({basketId: basketId, asset: asset, associated: true});
    }

    function registerPermissionedPool(PoolKey calldata key, address creator) external returns (PoolId poolId) {
        poolId = key.toId();
        LibPermissionedPools.PermissionedPool storage pool =
            LibPermissionedPools.permissionedPoolStorage().pools[poolId];
        pool.key = key;
        pool.creator = creator;
        pool.registered = true;
    }
}

contract RangeGaugeHookCaller {
    function notify(address diamond, PoolId poolId) external {
        IStaticsRangeGaugeCallback(diamond).afterProtocolPoolSwap(poolId);
    }
}
