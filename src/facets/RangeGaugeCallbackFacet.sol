// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IStaticsProtocolPools} from "../interfaces/IStaticsProtocolPools.sol";
import {IStaticsRangeGaugeCallback} from "../interfaces/IStaticsRangeGaugeCallback.sol";
import {LibBasketLiquidity} from "../libraries/LibBasketLiquidity.sol";
import {LibProtocolPools} from "../libraries/LibProtocolPools.sol";

/// @notice Swap-critical entrypoint for the Diamond-owned public range-gauge kernel.
/// @dev Stage one authenticates the installed hook and public-pool registry only. Boundary and
/// reward accounting are added behind this selector without expanding the hook's permissions.
contract RangeGaugeCallbackFacet is IStaticsRangeGaugeCallback {
    error PublicLiquidityIntegrationNotInstalled();
    error OnlyInstalledPublicHook(address caller, address expectedHook);
    error InvalidPublicPoolKind(PoolId poolId, IStaticsProtocolPools.ProtocolPoolKind kind);
    error PublicPoolHookMismatch(PoolId poolId, address expectedHook, address actualHook);

    function afterProtocolPoolSwap(PoolId poolId) external view override {
        LibBasketLiquidity.LiquidityStorage storage ls = LibBasketLiquidity.liquidityStorage();
        if (!ls.integrationInstalled) revert PublicLiquidityIntegrationNotInstalled();

        address expectedHook = ls.hook;
        if (msg.sender != expectedHook) revert OnlyInstalledPublicHook(msg.sender, expectedHook);

        (IStaticsProtocolPools.ProtocolPoolKind kind, PoolKey memory key,,) = LibProtocolPools.enforceRegistered(poolId);
        if (
            kind != IStaticsProtocolPools.ProtocolPoolKind.General
                && kind != IStaticsProtocolPools.ProtocolPoolKind.BasketCanonical
        ) {
            revert InvalidPublicPoolKind(poolId, kind);
        }

        address actualHook = address(key.hooks);
        if (actualHook != expectedHook) revert PublicPoolHookMismatch(poolId, expectedHook, actualHook);
    }
}
