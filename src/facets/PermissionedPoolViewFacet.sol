// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IStaticsPermissionedPools} from "../interfaces/IStaticsPermissionedPools.sol";
import {IStaticsPermissionedSwapFeeHook} from "../interfaces/IStaticsPermissionedSwapFeeHook.sol";
import {LibBasketLiquidity} from "../libraries/LibBasketLiquidity.sol";
import {LibPermissionedPools} from "../libraries/LibPermissionedPools.sol";

contract PermissionedPoolViewFacet {
    error PermissionedLiquidityIntegrationNotInstalled();

    function permissionedPool(PoolId poolId)
        external
        view
        returns (IStaticsPermissionedPools.PermissionedPoolView memory pool)
    {
        LibPermissionedPools.PermissionedPool storage stored = LibPermissionedPools.enforceRegistered(poolId);
        IStaticsPermissionedSwapFeeHook hook = _hook();
        pool = IStaticsPermissionedPools.PermissionedPoolView({
            poolId: poolId,
            key: stored.key,
            creator: stored.creator,
            controller: hook.poolRegistration(poolId).controller,
            decommissioned: stored.decommissioned,
            configurationNonce: stored.configurationNonce,
            economics: hook.poolEconomics(poolId)
        });
    }

    function isPermissionedPool(PoolId poolId) external view returns (bool registered) {
        return LibPermissionedPools.resolve(poolId).registered;
    }

    function isPermissionedAuthorizationNonceUsed(address creator, uint256 nonce) external view returns (bool used) {
        return LibPermissionedPools.permissionedPoolStorage().authorizationNonceUsed[creator][nonce];
    }

    function _hook() private view returns (IStaticsPermissionedSwapFeeHook hook) {
        LibBasketLiquidity.LiquidityStorage storage ls = LibBasketLiquidity.liquidityStorage();
        if (!ls.permissionedIntegrationInstalled) revert PermissionedLiquidityIntegrationNotInstalled();
        hook = IStaticsPermissionedSwapFeeHook(ls.permissionedHook);
    }
}
