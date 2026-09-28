// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IStaticsMarketTape} from "../interfaces/IStaticsMarketTape.sol";
import {IStaticsGaugeIncentives} from "../interfaces/IStaticsGaugeIncentives.sol";
import {IStaticsProtocolPools} from "../interfaces/IStaticsProtocolPools.sol";
import {IStaticsMarketObservations} from "../interfaces/IStaticsMarketObservations.sol";
import {IStaticsSwapCallback} from "../interfaces/IStaticsSwapCallback.sol";
import {LibBasketLiquidity} from "../libraries/LibBasketLiquidity.sol";
import {LibMarketTape} from "../libraries/LibMarketTape.sol";
import {LibGlobalRewards} from "../libraries/LibGlobalRewards.sol";
import {LibGaugeRouting} from "../libraries/LibGaugeRouting.sol";
import {LibProtocolPools} from "../libraries/LibProtocolPools.sol";
import {LibRangeGauge} from "../libraries/LibRangeGauge.sol";

/// @notice Swap-critical dispatcher for canonical market accounting and public range topology.
/// @dev Ordinary swaps avoid routing work. A managed-boundary crossing performs one bounded
///      schedule step and settles the affected pool before changing its active-liquidity denominator.
contract RangeGaugeCallbackFacet is IStaticsSwapCallback {
    using StateLibrary for IPoolManager;

    uint256 private constant OBSERVATION_GAS_STIPEND = 500_000;
    uint256 private constant OBSERVATION_FAILURE_GAS_RESERVE = 100_000;

    struct CallbackState {
        PoolKey key;
        int24 finalTick;
        uint256 sequence;
        bool permissioned;
    }

    error LiquidityIntegrationNotInstalled(bool permissioned);
    error OnlyInstalledSwapHook(address caller, address expectedHook);
    error InvalidSwapPoolKind(PoolId poolId, IStaticsProtocolPools.ProtocolPoolKind kind, bool permissioned);
    error SwapPoolHookMismatch(PoolId poolId, address expectedHook, address actualHook);
    error InvalidPermissionedSwapFlags(uint8 flags);

    function afterStaticsPoolSwap(
        PoolId poolId,
        BalanceDelta poolDelta,
        uint256 staticsFeesPacked,
        uint256 staticsStakerFeesPacked,
        uint8 flags
    ) external override {
        CallbackState memory state = _recordAuthenticatedSwap(poolId, poolDelta, staticsFeesPacked, flags);
        if (state.permissioned) {
            if (staticsStakerFeesPacked != 0) revert InvalidPermissionedSwapFlags(flags);
        } else {
            _crystallizeStakerFees(state.key, staticsStakerFeesPacked);
        }
        if (!state.permissioned) {
            LibRangeGauge.GaugePool storage gauge = LibRangeGauge.rangeGaugeStorage().gauges[poolId];
            if (!gauge.initialized) revert LibRangeGauge.GaugeNotInitialized(poolId);
            if (!gauge.stopped) {
                uint40 currentTime = LibRangeGauge.timestamp40(block.timestamp);
                if (LibRangeGauge.wouldCrossManagedBoundary(poolId, state.key.tickSpacing, state.finalTick)) {
                    (uint256 credited, uint256 recycled) =
                        LibGaugeRouting.checkpointPoolWithLimit(poolId, currentTime, 1);
                    if (credited != 0) emit IStaticsGaugeIncentives.ProtocolGaugeRewardCredited(poolId, credited);
                    if (recycled != 0) emit IStaticsGaugeIncentives.ProtocolGaugeRewardRecycled(poolId, recycled);
                }
                LibRangeGauge.synchronizeAfterSwap(poolId, state.key.tickSpacing, state.finalTick, currentTime);
            }
        }
        if (flags & LibMarketTape.FLAG_INTERNAL == 0) _tryRecordObservation(poolId, state.sequence);
    }

    function _crystallizeStakerFees(PoolKey memory key, uint256 packed) private {
        uint256 amount0 = uint128(packed);
        uint256 amount1 = uint128(packed >> 128);
        if (amount0 != 0) LibGlobalRewards.crystallizeUnfundedSwapFee(Currency.unwrap(key.currency0), amount0);
        if (amount1 != 0) LibGlobalRewards.crystallizeUnfundedSwapFee(Currency.unwrap(key.currency1), amount1);
    }

    function _recordAuthenticatedSwap(PoolId poolId, BalanceDelta poolDelta, uint256 staticsFeesPacked, uint8 flags)
        private
        returns (CallbackState memory state)
    {
        LibBasketLiquidity.LiquidityStorage storage ls = LibBasketLiquidity.liquidityStorage();
        state.permissioned = flags & LibMarketTape.FLAG_PERMISSIONED != 0;
        bool installed = state.permissioned ? ls.permissionedIntegrationInstalled : ls.integrationInstalled;
        if (!installed) revert LiquidityIntegrationNotInstalled(state.permissioned);

        address expectedHook = state.permissioned ? ls.permissionedHook : ls.hook;
        if (msg.sender != expectedHook) revert OnlyInstalledSwapHook(msg.sender, expectedHook);

        IStaticsProtocolPools.ProtocolPoolKind kind;
        (kind, state.key,,) = LibProtocolPools.enforceRegistered(poolId);
        bool publicKind = kind == IStaticsProtocolPools.ProtocolPoolKind.General
            || kind == IStaticsProtocolPools.ProtocolPoolKind.BasketCanonical;
        if (state.permissioned ? kind != IStaticsProtocolPools.ProtocolPoolKind.PermissionedGeneral : !publicKind) {
            revert InvalidSwapPoolKind(poolId, kind, state.permissioned);
        }

        address actualHook = address(state.key.hooks);
        if (actualHook != expectedHook) revert SwapPoolHookMismatch(poolId, expectedHook, actualHook);
        if (
            state.permissioned
                && (flags & LibMarketTape.FLAG_EXACT_OUTPUT != 0
                    || flags & LibMarketTape.FLAG_INTERNAL != 0
                    && staticsFeesPacked != 0)
        ) revert InvalidPermissionedSwapFlags(flags);

        uint24 nativeLpFee;
        (, state.finalTick,, nativeLpFee) = IPoolManager(ls.poolManager).getSlot0(poolId);
        state.sequence = _recordMarket(poolId, poolDelta, staticsFeesPacked, flags, state.finalTick, nativeLpFee);
    }

    function _recordMarket(
        PoolId poolId,
        BalanceDelta poolDelta,
        uint256 staticsFeesPacked,
        uint8 flags,
        int24 finalTick,
        uint24 nativeLpFee
    ) private returns (uint256 sequence) {
        (uint256 amount0, uint256 amount1) = _absoluteAmounts(poolDelta);
        sequence = LibMarketTape.record(
            poolId,
            amount0,
            amount1,
            uint128(staticsFeesPacked),
            uint128(staticsFeesPacked >> 128),
            finalTick,
            nativeLpFee,
            flags,
            block.timestamp
        );
        emit IStaticsMarketTape.MarketSwapRecorded(
            poolId, sequence, poolDelta, staticsFeesPacked, finalTick, nativeLpFee, flags
        );
    }

    function _tryRecordObservation(PoolId poolId, uint256 sequence) private {
        uint256 available = gasleft();
        if (available <= OBSERVATION_FAILURE_GAS_RESERVE) {
            emit IStaticsMarketObservations.MarketObservationWriteFailed(poolId, sequence);
            return;
        }

        uint256 stipend = available - OBSERVATION_FAILURE_GAS_RESERVE;
        if (stipend > OBSERVATION_GAS_STIPEND) stipend = OBSERVATION_GAS_STIPEND;
        bytes4 selector = IStaticsMarketObservations.recordMarketObservation.selector;
        bool success;
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr, selector)
            mstore(add(ptr, 4), poolId)
            mstore(add(ptr, 36), sequence)
            success := call(stipend, address(), 0, ptr, 68, 0, 0)
        }
        if (success) return;
        LibMarketTape.recordObservationFailure(poolId, sequence);
        emit IStaticsMarketObservations.MarketObservationWriteFailed(poolId, sequence);
    }

    function _absoluteAmounts(BalanceDelta delta) private pure returns (uint256 amount0, uint256 amount1) {
        int128 signed0 = delta.amount0();
        int128 signed1 = delta.amount1();
        amount0 = signed0 < 0 ? uint256(-int256(signed0)) : uint256(uint128(signed0));
        amount1 = signed1 < 0 ? uint256(-int256(signed1)) : uint256(uint128(signed1));
    }
}
