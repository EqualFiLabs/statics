// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {RangeGaugeCallbackFacet} from "../../src/facets/RangeGaugeCallbackFacet.sol";
import {IStaticsMarketTape} from "../../src/interfaces/IStaticsMarketTape.sol";
import {IStaticsSwapCallback} from "../../src/interfaces/IStaticsSwapCallback.sol";
import {LibBasketLiquidity} from "../../src/libraries/LibBasketLiquidity.sol";
import {LibCustody} from "../../src/libraries/LibCustody.sol";
import {LibGlobalRewards} from "../../src/libraries/LibGlobalRewards.sol";
import {LibGaugeReserve} from "../../src/libraries/LibGaugeReserve.sol";
import {LibGaugeRouting} from "../../src/libraries/LibGaugeRouting.sol";
import {LibMarketTape} from "../../src/libraries/LibMarketTape.sol";
import {LibPermissionedPools} from "../../src/libraries/LibPermissionedPools.sol";
import {LibProtocolPools} from "../../src/libraries/LibProtocolPools.sol";
import {LibRangeGauge} from "../../src/libraries/LibRangeGauge.sol";

contract RangeGaugeCallbackHarness is RangeGaugeCallbackFacet {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    function initialize(address statics) external {
        LibGlobalRewards.initialize(statics);
        LibRangeGauge.initializeGlobalConfig();
        LibGaugeRouting.initialize(400);
    }

    function checkpointGaugePool(PoolId poolId) external returns (uint256 committed, uint256 recycled) {
        return LibGaugeRouting.checkpointPool(poolId, LibRangeGauge.timestamp40(block.timestamp));
    }

    function setGaugeAllocations(uint256 positionId, PoolId[] calldata poolIds, uint256[] calldata amounts) external {
        LibGaugeRouting.setAllocations(
            positionId, poolIds, amounts, type(uint256).max, LibRangeGauge.timestamp40(block.timestamp)
        );
    }

    /// @dev The callback harness models the existing PositionNFT used by its direct library allocation setup.
    function ownerOf(uint256 positionId) external view returns (address owner) {
        if (positionId != 1) revert();
        return address(this);
    }

    function activateFundedGaugeSchedule(uint256 amount) external returns (uint256 budget) {
        address statics = LibRangeGauge.staticsToken();
        LibCustody.reserve(LibCustody.gaugeReserveAccount(), statics, amount);
        LibGaugeReserve.makeAvailable(amount);
        budget = LibGaugeRouting.activate(LibRangeGauge.timestamp40(block.timestamp));
    }

    function installPublicIntegration(address poolManager, address hook) external {
        LibBasketLiquidity.LiquidityStorage storage ls = LibBasketLiquidity.liquidityStorage();
        ls.poolManager = poolManager;
        ls.hook = hook;
        ls.integrationInstalled = true;
    }

    function installPermissionedIntegration(address poolManager, address hook) external {
        LibBasketLiquidity.LiquidityStorage storage ls = LibBasketLiquidity.liquidityStorage();
        ls.poolManager = poolManager;
        ls.permissionedHook = hook;
        ls.permissionedIntegrationInstalled = true;
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

    function initializeGauge(PoolId poolId, int256 referenceTick) external {
        LibRangeGauge.initializePool(poolId, _toInt24(referenceTick));
    }

    function appendRewardAsset(PoolId poolId, address asset) external returns (uint8 slot) {
        slot = LibRangeGauge.appendRewardAsset(poolId, asset);
    }

    function fundStream(PoolId poolId, uint256 slot, uint256 amount, uint256 timestamp, uint256 duration) external {
        LibRangeGauge.GaugePool storage gauge = LibRangeGauge.rangeGaugeStorage().gauges[poolId];
        uint8 narrowedSlot = _toUint8(slot);
        LibRangeGauge.fundStream(
            gauge.streams[narrowedSlot],
            gauge.capacities[narrowedSlot],
            amount,
            LibRangeGauge.timestamp40(timestamp),
            _toUint40(duration),
            gauge.activeGaugeLiquidity
        );
    }

    function addRange(
        PoolId poolId,
        int256 tickLower,
        int256 tickUpper,
        int256 tickSpacing,
        int256 currentTick,
        uint256 liquidity
    ) external {
        LibRangeGauge.addRangeBoundaries(
            poolId,
            _toInt24(tickLower),
            _toInt24(tickUpper),
            _toInt24(tickSpacing),
            _toInt24(currentTick),
            _toUint128(liquidity)
        );
    }

    function setActiveLiquidity(PoolId poolId, uint256 liquidity) external {
        LibRangeGauge.rangeGaugeStorage().gauges[poolId].activeGaugeLiquidity = _toUint128(liquidity);
    }

    function setStopped(PoolId poolId, bool stopped) external {
        LibRangeGauge.rangeGaugeStorage().gauges[poolId].stopped = stopped;
    }

    function synchronizeTopology(PoolId poolId, int256 tickSpacing) external returns (bool crossed) {
        LibBasketLiquidity.LiquidityStorage storage ls = LibBasketLiquidity.liquidityStorage();
        (, int24 liveTick,,) = IPoolManager(ls.poolManager).getSlot0(poolId);
        crossed = LibRangeGauge.synchronizeTopology(
            poolId, _toInt24(tickSpacing), liveTick, LibRangeGauge.timestamp40(block.timestamp)
        );
    }

    function gaugeState(PoolId poolId)
        external
        view
        returns (bool initialized, bool stopped, int24 referenceTick, uint128 activeLiquidity)
    {
        LibRangeGauge.GaugePool storage gauge = LibRangeGauge.rangeGaugeStorage().gauges[poolId];
        return (gauge.initialized, gauge.stopped, gauge.referenceTick, gauge.activeGaugeLiquidity);
    }

    function currentGaugePeriod() external view returns (uint64 period) {
        return LibGaugeRouting.routingStorage().currentPeriod;
    }

    function canonicalMarketState(PoolId poolId)
        external
        view
        returns (IStaticsMarketTape.CanonicalMarketState memory state)
    {
        return LibMarketTape.marketTapeStorage().canonical[poolId];
    }

    function primeCanonicalMarketStateForSaturation(PoolId poolId) external {
        IStaticsMarketTape.CanonicalMarketState storage state = LibMarketTape.marketTapeStorage().canonical[poolId];
        state.externalVolume0 = type(uint256).max - 1;
        state.externalVolume1 = type(uint256).max - 1;
        state.internalVolume0 = type(uint256).max - 1;
        state.internalVolume1 = type(uint256).max - 1;
        state.staticsFees0 = type(uint256).max - 1;
        state.staticsFees1 = type(uint256).max - 1;
        state.externalSwapCount = type(uint256).max;
        state.internalSwapCount = type(uint256).max;
        state.sequence = type(uint256).max;
        state.lastTimestamp = LibRangeGauge.timestamp40(block.timestamp);
    }

    function observationFailures(PoolId poolId) external view returns (uint256 count, uint256 lastSequence) {
        LibMarketTape.ObservationFailures storage failures =
            LibMarketTape.marketTapeStorage().observationFailures[poolId];
        return (failures.count, failures.lastSequence);
    }

    function stream(PoolId poolId, uint256 slot) external view returns (LibRangeGauge.GaugeRewardStream memory value) {
        value = LibRangeGauge.rangeGaugeStorage().gauges[poolId].streams[_toUint8(slot)];
    }

    function boundary(PoolId poolId, int256 tick)
        external
        view
        returns (uint128 grossLiquidity, int128 netLiquidity, uint256[5] memory rewardOutsideRay)
    {
        LibRangeGauge.GaugeBoundary storage stored =
            LibRangeGauge.rangeGaugeStorage().gauges[poolId].boundaries[_toInt24(tick)];
        return (stored.grossLiquidity, stored.netLiquidity, stored.rewardOutsideRay);
    }

    function _toUint128(uint256 value) private pure returns (uint128 narrowed) {
        if (value > type(uint128).max) revert();
        narrowed = uint128(value);
    }

    function _toUint40(uint256 value) private pure returns (uint40 narrowed) {
        if (value > type(uint40).max) revert();
        narrowed = uint40(value);
    }

    function _toUint8(uint256 value) private pure returns (uint8 narrowed) {
        if (value > type(uint8).max) revert();
        narrowed = uint8(value);
    }

    function _toInt24(int256 value) private pure returns (int24 narrowed) {
        if (value < type(int24).min || value > type(int24).max) revert();
        narrowed = int24(value);
    }
}

contract RangeGaugeHookCaller {
    function notify(address diamond, PoolId poolId) external {
        IStaticsSwapCallback(diamond).afterStaticsPoolSwap(poolId, toBalanceDelta(0, 0), 0, 0, 0);
    }

    function notify(address diamond, PoolId poolId, BalanceDelta delta, uint256 fees, uint8 flags) external {
        IStaticsSwapCallback(diamond).afterStaticsPoolSwap(poolId, delta, fees, 0, flags);
    }
}

contract RangeGaugePoolManagerMock {
    mapping(bytes32 slot => bytes32 value) private slots;

    function setTick(PoolId poolId, int256 tickValue) external {
        _setSlot0(poolId, tickValue, 0);
    }

    function setTickAndLpFee(PoolId poolId, int256 tickValue, uint256 lpFee) external {
        if (lpFee > type(uint24).max) revert();
        _setSlot0(poolId, tickValue, uint24(lpFee));
    }

    function _setSlot0(PoolId poolId, int256 tickValue, uint24 lpFee) private {
        if (tickValue < type(int24).min || tickValue > type(int24).max) revert();
        int24 tick = int24(tickValue);
        uint24 tickBits;
        assembly ("memory-safe") {
            tickBits := and(tick, 0xffffff)
        }
        uint256 packed = uint256(uint160(1 << 96)) | (uint256(tickBits) << 160) | (uint256(lpFee) << 208);
        slots[_poolStateSlot(poolId)] = bytes32(packed);
    }

    function extsload(bytes32 slot) external view returns (bytes32 value) {
        value = slots[slot];
    }

    function _poolStateSlot(PoolId poolId) private pure returns (bytes32) {
        return keccak256(abi.encode(PoolId.unwrap(poolId), StateLibrary.POOLS_SLOT));
    }
}
