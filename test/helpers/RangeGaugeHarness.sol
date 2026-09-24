// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {LibCustody} from "../../src/libraries/LibCustody.sol";
import {LibGlobalRewards} from "../../src/libraries/LibGlobalRewards.sol";
import {LibRangeGauge} from "../../src/libraries/LibRangeGauge.sol";
import {LibPosition} from "../../src/position/LibPosition.sol";

contract RangeGaugeHarness {
    function initialize(address statics) external {
        LibGlobalRewards.initialize(statics);
        LibRangeGauge.initializeGlobalConfig();
    }

    function initializePool(PoolId poolId, int256 referenceTick) external {
        LibRangeGauge.initializePool(poolId, _toInt24(referenceTick));
    }

    function setRewardDuration(uint256 duration) external {
        if (duration > type(uint40).max) revert();
        LibRangeGauge.setRewardDuration(uint40(duration));
    }

    function rewardDuration() external view returns (uint40) {
        return LibRangeGauge.rangeGaugeStorage().gaugeRewardDuration;
    }

    function setRewardAssetAllowed(address asset, bool allowed) external {
        LibRangeGauge.setRewardAssetAllowed(asset, allowed);
    }

    function rewardAssetAllowed(address asset) external view returns (bool) {
        return LibRangeGauge.rangeGaugeStorage().rewardAssetAllowed[asset];
    }

    function appendRewardAsset(PoolId poolId, address asset) external returns (uint8) {
        return LibRangeGauge.appendRewardAsset(poolId, asset);
    }

    function rewardConfig(PoolId poolId)
        external
        view
        returns (bool initialized, uint8 slotCount, address[5] memory assets)
    {
        LibRangeGauge.PoolRewardConfig storage config = LibRangeGauge.rangeGaugeStorage().rewardConfig[poolId];
        return (config.initialized, config.slotCount, config.assets);
    }

    function rewardSlot(PoolId poolId, address asset) external view returns (uint8 slot, bool assigned) {
        return LibRangeGauge.rewardSlot(poolId, asset);
    }

    function rewardAsset(PoolId poolId, uint256 slot) external view returns (address asset, bool assigned) {
        return LibRangeGauge.rewardAsset(poolId, _toUint8(slot));
    }

    function staticsToken() external view returns (address) {
        return LibRangeGauge.staticsToken();
    }

    function storagePosition() external pure returns (bytes32) {
        return LibRangeGauge.STORAGE_POSITION;
    }

    function lpModule() external pure returns (bytes32) {
        return LibPosition.LP_MODULE;
    }

    function lpLegKey(address authority, PoolId poolId) external pure returns (bytes32) {
        return LibPosition.lpLegKey(authority, poolId);
    }

    function seedLeg(
        uint256 positionId,
        PoolId poolId,
        address manager,
        uint256 posmTokenId,
        int256 tickLower,
        int256 tickUpper,
        uint256 liquidity
    ) external {
        LibRangeGauge.LpLeg storage storedLeg = LibRangeGauge.rangeGaugeStorage().lpLegs[positionId][poolId];
        storedLeg.manager = manager;
        storedLeg.posmTokenId = posmTokenId;
        storedLeg.tickLower = _toInt24(tickLower);
        storedLeg.tickUpper = _toInt24(tickUpper);
        storedLeg.liquidity = _toUint128(liquidity);
    }

    function leg(PoolId poolId, uint256 positionId)
        external
        view
        returns (address manager, uint256 posmTokenId, int24 tickLower, int24 tickUpper, uint128 liquidity)
    {
        LibRangeGauge.LpLeg storage stored = LibRangeGauge.rangeGaugeStorage().lpLegs[positionId][poolId];
        return (stored.manager, stored.posmTokenId, stored.tickLower, stored.tickUpper, stored.liquidity);
    }

    function addPositionPool(uint256 positionId, PoolId poolId) external {
        LibRangeGauge.addPositionPool(positionId, poolId);
    }

    function removePositionPool(uint256 positionId, PoolId poolId) external {
        LibRangeGauge.removePositionPool(positionId, poolId);
    }

    function positionPools(uint256 positionId, uint256 cursor, uint256 size)
        external
        view
        returns (PoolId[] memory poolIds, uint256 nextCursor)
    {
        return LibRangeGauge.positionPools(positionId, cursor, size);
    }

    function bindPosm(uint256 posmTokenId, uint256 positionId, PoolId poolId) external returns (bytes32) {
        return LibRangeGauge.bindPosm(posmTokenId, positionId, poolId);
    }

    function unbindPosm(uint256 posmTokenId, uint256 positionId, PoolId poolId) external {
        LibRangeGauge.unbindPosm(posmTokenId, positionId, poolId);
    }

    function posmBinding(uint256 posmTokenId) external view returns (bytes32) {
        return LibRangeGauge.rangeGaugeStorage().posmBinding[posmTokenId];
    }

    function fundStream(
        PoolId poolId,
        uint256 slot,
        uint256 received,
        uint256 currentTime,
        uint256 duration,
        uint256 activeLiquidity
    ) external returns (uint256 emission, uint40 remainingDuration) {
        if (duration > type(uint40).max) revert();
        LibRangeGauge.GaugePool storage gauge = LibRangeGauge.rangeGaugeStorage().gauges[poolId];
        uint8 narrowedSlot = _toUint8(slot);
        return LibRangeGauge.fundStream(
            gauge.streams[narrowedSlot],
            gauge.capacities[narrowedSlot],
            received,
            LibRangeGauge.timestamp40(currentTime),
            uint40(duration),
            _toUint128(activeLiquidity)
        );
    }

    function checkpointStream(PoolId poolId, uint256 slot, uint256 currentTime, uint256 activeLiquidity)
        external
        returns (uint256 emission)
    {
        return LibRangeGauge.checkpointStream(
            LibRangeGauge.rangeGaugeStorage().gauges[poolId].streams[_toUint8(slot)],
            LibRangeGauge.timestamp40(currentTime),
            _toUint128(activeLiquidity)
        );
    }

    function stream(PoolId poolId, uint256 slot) external view returns (LibRangeGauge.GaugeRewardStream memory value) {
        value = LibRangeGauge.rangeGaugeStorage().gauges[poolId].streams[_toUint8(slot)];
    }

    function indexCapacityUsed(PoolId poolId, uint256 slot) external view returns (uint256) {
        return LibRangeGauge.rangeGaugeStorage().gauges[poolId].capacities[_toUint8(slot)].used;
    }

    function seedStreamAccounting(
        PoolId poolId,
        uint256 slot,
        uint256 globalIndexRay,
        uint256 indexRemainder,
        uint256 indexedLiability,
        uint256 claimLiability
    ) external {
        LibRangeGauge.GaugeRewardStream storage stored =
            LibRangeGauge.rangeGaugeStorage().gauges[poolId].streams[_toUint8(slot)];
        stored.globalIndexRay = globalIndexRay;
        stored.indexRemainder = indexRemainder;
        stored.indexedLiability = indexedLiability;
        stored.claimLiability = claimLiability;
    }

    function seedLegReward(
        uint256 positionId,
        PoolId poolId,
        uint256 slot,
        uint256 liquidity,
        uint256 checkpoint,
        uint256 remainder
    ) external {
        LibRangeGauge.LpLeg storage stored = LibRangeGauge.rangeGaugeStorage().lpLegs[positionId][poolId];
        stored.liquidity = _toUint128(liquidity);
        uint8 narrowedSlot = _toUint8(slot);
        stored.checkpointInsideRay[narrowedSlot] = checkpoint;
        stored.rewardRemainderRay[narrowedSlot] = remainder;
    }

    function settleLegSlot(uint256 positionId, PoolId poolId, uint256 slot, uint256 insideGrowthRay)
        external
        returns (uint256)
    {
        LibRangeGauge.RangeGaugeStorage storage rgs = LibRangeGauge.rangeGaugeStorage();
        uint8 narrowedSlot = _toUint8(slot);
        return LibRangeGauge.settleLegSlot(
            rgs.gauges[poolId].streams[narrowedSlot], rgs.lpLegs[positionId][poolId], narrowedSlot, insideGrowthRay
        );
    }

    function legReward(uint256 positionId, PoolId poolId, uint256 slot)
        external
        view
        returns (uint256 checkpoint, uint256 remainder, uint256 claimable)
    {
        LibRangeGauge.LpLeg storage stored = LibRangeGauge.rangeGaugeStorage().lpLegs[positionId][poolId];
        uint8 narrowedSlot = _toUint8(slot);
        return (
            stored.checkpointInsideRay[narrowedSlot],
            stored.rewardRemainderRay[narrowedSlot],
            stored.claimable[narrowedSlot]
        );
    }

    function positionAccrual(uint256 liquidity, uint256 growthDeltaRay, uint256 priorRemainderRay)
        external
        pure
        returns (uint256 claimableDelta, uint256 newRemainderRay)
    {
        return LibRangeGauge.positionAccrual(_toUint128(liquidity), growthDeltaRay, priorRemainderRay);
    }

    function reserveReward(PoolId poolId, uint256 slot, address asset, uint256 amount) external {
        LibCustody.reserve(LibRangeGauge.rewardAccount(poolId, _toUint8(slot)), asset, amount);
    }

    function flushDenominatorRemainder(PoolId poolId, uint256 slot) external returns (uint256) {
        return LibRangeGauge.flushDenominatorRemainder(poolId, _toUint8(slot));
    }

    function rewardReservation(PoolId poolId, uint256 slot, address asset) external view returns (uint256) {
        return LibCustody.accountReserved(LibRangeGauge.rewardAccount(poolId, _toUint8(slot)), asset);
    }

    function feeReservation(address asset) external view returns (uint256) {
        return LibCustody.accountReserved(LibCustody.feeAccount(), asset);
    }

    function treasuryAccrued(address asset) external view returns (uint256) {
        return LibGlobalRewards.rewardStorage().treasuryAccrued[asset];
    }

    function addRangeBoundaries(
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

    function removeRangeBoundaries(
        PoolId poolId,
        int256 tickLower,
        int256 tickUpper,
        int256 tickSpacing,
        uint256 liquidity
    ) external {
        LibRangeGauge.removeRangeBoundaries(
            poolId, _toInt24(tickLower), _toInt24(tickUpper), _toInt24(tickSpacing), _toUint128(liquidity)
        );
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

    function boundaryWord(PoolId poolId, int256 wordPos) external view returns (uint256) {
        if (wordPos < type(int16).min || wordPos > type(int16).max) revert();
        return LibRangeGauge.rangeGaugeStorage().gauges[poolId].boundaryBitmap[int16(wordPos)];
    }

    function boundarySummary(PoolId poolId) external view returns (uint256) {
        return LibRangeGauge.rangeGaugeStorage().gauges[poolId].boundarySummaryBitmap;
    }

    function nextInitializedBoundary(PoolId poolId, int256 tick, int256 tickSpacing, bool lte)
        external
        view
        returns (int24 next, bool initialized)
    {
        return LibRangeGauge.nextInitializedBoundary(
            LibRangeGauge.rangeGaugeStorage().gauges[poolId], _toInt24(tick), _toInt24(tickSpacing), lte
        );
    }

    function crossBoundary(PoolId poolId, int256 tick, bool rightward) external returns (uint128 updated) {
        LibRangeGauge.RangeGaugeStorage storage rgs = LibRangeGauge.rangeGaugeStorage();
        LibRangeGauge.GaugePool storage gauge = rgs.gauges[poolId];
        int128 net = LibRangeGauge.crossBoundary(gauge, _toInt24(tick), rgs.rewardConfig[poolId].slotCount);
        updated = LibRangeGauge.applyCrossingLiquidity(gauge.activeGaugeLiquidity, net, rightward);
        gauge.activeGaugeLiquidity = updated;
    }

    function setActiveGaugeLiquidity(PoolId poolId, uint256 liquidity) external {
        LibRangeGauge.rangeGaugeStorage().gauges[poolId].activeGaugeLiquidity = _toUint128(liquidity);
    }

    function activeGaugeLiquidity(PoolId poolId) external view returns (uint128) {
        return LibRangeGauge.rangeGaugeStorage().gauges[poolId].activeGaugeLiquidity;
    }

    function growthInside(PoolId poolId, int256 tickLower, int256 tickUpper, int256 currentTick, uint256 slot)
        external
        view
        returns (uint256)
    {
        return LibRangeGauge.growthInside(
            LibRangeGauge.rangeGaugeStorage().gauges[poolId],
            _toInt24(tickLower),
            _toInt24(tickUpper),
            _toInt24(currentTick),
            _toUint8(slot)
        );
    }

    function _toUint128(uint256 value) private pure returns (uint128 narrowed) {
        if (value > type(uint128).max) revert();
        narrowed = uint128(value);
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
