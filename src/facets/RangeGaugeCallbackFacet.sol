// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IStaticsProtocolPools} from "../interfaces/IStaticsProtocolPools.sol";
import {IStaticsRangeGaugeCallback} from "../interfaces/IStaticsRangeGaugeCallback.sol";
import {LibBasketLiquidity} from "../libraries/LibBasketLiquidity.sol";
import {LibProtocolPools} from "../libraries/LibProtocolPools.sol";
import {LibRangeGauge} from "../libraries/LibRangeGauge.sol";

/// @notice Swap-critical entrypoint for the Diamond-owned public range-gauge kernel.
/// @dev Authenticates the installed hook and public-pool registry before synchronizing only the
/// Statics-owned boundary and reward state crossed by the final canonical PoolManager tick.
contract RangeGaugeCallbackFacet is IStaticsRangeGaugeCallback {
    using StateLibrary for IPoolManager;

    error PublicLiquidityIntegrationNotInstalled();
    error OnlyInstalledPublicHook(address caller, address expectedHook);
    error InvalidPublicPoolKind(PoolId poolId, IStaticsProtocolPools.ProtocolPoolKind kind);
    error PublicPoolHookMismatch(PoolId poolId, address expectedHook, address actualHook);

    function afterProtocolPoolSwap(PoolId poolId) external override {
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

        LibRangeGauge.GaugePool storage gauge = LibRangeGauge.rangeGaugeStorage().gauges[poolId];
        if (!gauge.initialized) revert LibRangeGauge.GaugeNotInitialized(poolId);
        if (gauge.stopped) return;

        (, int24 finalTick,,) = IPoolManager(ls.poolManager).getSlot0(poolId);
        LibRangeGauge.synchronizeAfterSwap(
            poolId, key.tickSpacing, finalTick, LibRangeGauge.timestamp40(block.timestamp)
        );
    }
}
