// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {BitMath} from "@uniswap/v4-core/src/libraries/BitMath.sol";
import {TickBitmap} from "@uniswap/v4-core/src/libraries/TickBitmap.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {LibCustody} from "./LibCustody.sol";
import {LibGlobalRewards} from "./LibGlobalRewards.sol";
import {LibIndexMath} from "./LibIndexMath.sol";

/// @notice Diamond storage and accounting primitives for public-pool PNFT range gauges.
library LibRangeGauge {
    using TickBitmap for mapping(int16 wordPos => uint256 word);

    bytes32 internal constant STORAGE_POSITION = keccak256("statics.storage.range.gauge.v1");
    bytes32 internal constant RANGE_REWARD_ACCOUNT_DOMAIN = keccak256("statics.custody.account.range.rewards.v1");
    uint256 internal constant RAY = 1e27;
    uint8 internal constant MAX_REWARD_SLOTS = 4;
    uint8 internal constant STATICS_SLOT = 0;
    uint40 internal constant DEFAULT_REWARD_DURATION = 7 days;
    uint40 internal constant MIN_REWARD_DURATION = 1 days;
    uint40 internal constant MAX_REWARD_DURATION = 30 days;

    struct PoolRewardConfig {
        bool initialized;
        uint8 slotCount;
        address[4] assets;
        mapping(address asset => uint8 slotPlusOne) slotPlusOne;
    }

    struct LpLeg {
        address manager;
        uint256 posmTokenId;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint256[4] checkpointInsideRay;
        uint256[4] rewardRemainderRay;
        uint256[4] claimable;
    }

    struct PoolIndex {
        PoolId[] poolIds;
        mapping(PoolId poolId => uint256 indexPlusOne) indexPlusOne;
    }

    struct GaugeBoundary {
        uint128 grossLiquidity;
        int128 netLiquidity;
        uint256[4] rewardOutsideRay;
    }

    struct GaugeRewardStream {
        uint40 periodStart;
        uint40 periodFinish;
        uint40 lastUpdate;
        uint256 periodBudget;
        uint256 periodEmitted;
        uint256 globalIndexRay;
        uint256 indexRemainder;
        uint256 indexedLiability;
        uint256 claimLiability;
    }

    struct GaugePool {
        bool initialized;
        bool stopped;
        int24 referenceTick;
        uint128 activeGaugeLiquidity;
        uint64 managedLegCount;
        uint64 unresolvedLegCount;
        mapping(int16 wordPos => uint256 word) boundaryBitmap;
        mapping(int8 summaryWordPos => uint256 word) boundaryWordBitmap;
        uint256 boundarySummaryBitmap;
        mapping(int24 tick => GaugeBoundary boundary) boundaries;
        GaugeRewardStream[4] streams;
    }

    struct RangeGaugeStorage {
        uint40 gaugeRewardDuration;
        mapping(address asset => bool allowed) rewardAssetAllowed;
        mapping(PoolId poolId => PoolRewardConfig config) rewardConfig;
        mapping(PoolId poolId => GaugePool gauge) gauges;
        mapping(uint256 positionId => mapping(PoolId poolId => LpLeg leg)) lpLegs;
        mapping(uint256 positionId => PoolIndex index) positionPools;
        mapping(uint256 posmTokenId => bytes32 binding) posmBinding;
    }

    error RangeGaugeAlreadyInitialized();
    error InvalidRewardDuration(uint40 duration);
    error InvalidRewardAsset(address asset);
    error PoolRewardConfigAlreadyInitialized(PoolId poolId);
    error PoolRewardConfigNotInitialized(PoolId poolId);
    error RewardAssetAlreadyAssigned(PoolId poolId, address asset);
    error RewardSlotLimitReached(PoolId poolId);
    error InvalidRewardSlot(PoolId poolId, uint8 slot);
    error GaugeAlreadyInitialized(PoolId poolId);
    error GaugeNotInitialized(PoolId poolId);
    error InvalidTimestamp(uint256 timestamp);
    error TimestampRegression(uint40 previousTimestamp, uint40 currentTimestamp);
    error TimestampOverflow(uint40 timestamp, uint256 delta);
    error InvalidFundingAmount();
    error InvalidLiquidity();
    error InvalidTickRange(int24 tickLower, int24 tickUpper);
    error BoundaryNotInitialized(int24 tick);
    error BoundaryLiquidityUnderflow(int24 tick, uint128 available, uint128 requested);
    error BoundaryNetLiquidityOverflow(int24 tick, int256 netLiquidity);
    error ActiveLiquidityOverflow(uint128 activeLiquidity, int128 netLiquidity, bool rightward);
    error IndexedLiabilityUnderflow(uint256 liability, uint256 amount);
    error InvalidPositionRemainder(uint256 remainder);
    error PositionPoolAlreadyIndexed(uint256 positionId, PoolId poolId);
    error PositionPoolNotIndexed(uint256 positionId, PoolId poolId);
    error PosmAlreadyBound(uint256 posmTokenId, bytes32 binding);
    error PosmBindingMismatch(uint256 posmTokenId, bytes32 expected, bytes32 actual);

    function rangeGaugeStorage() internal pure returns (RangeGaugeStorage storage rgs) {
        bytes32 slot = STORAGE_POSITION;
        assembly ("memory-safe") {
            rgs.slot := slot
        }
    }

    function initializeGlobalConfig() internal {
        RangeGaugeStorage storage rgs = rangeGaugeStorage();
        if (rgs.gaugeRewardDuration != 0) revert RangeGaugeAlreadyInitialized();
        rgs.gaugeRewardDuration = DEFAULT_REWARD_DURATION;
    }

    function setRewardDuration(uint40 duration) internal {
        if (duration < MIN_REWARD_DURATION || duration > MAX_REWARD_DURATION) {
            revert InvalidRewardDuration(duration);
        }
        rangeGaugeStorage().gaugeRewardDuration = duration;
    }

    function setRewardAssetAllowed(address asset, bool allowed) internal {
        if (asset == address(0)) revert InvalidRewardAsset(asset);
        rangeGaugeStorage().rewardAssetAllowed[asset] = allowed;
    }

    function staticsToken() internal view returns (address) {
        return LibGlobalRewards.rewardStorage().stakingToken;
    }

    function initializePool(PoolId poolId, int24 referenceTick) internal {
        RangeGaugeStorage storage rgs = rangeGaugeStorage();
        GaugePool storage gauge = rgs.gauges[poolId];
        if (gauge.initialized) revert GaugeAlreadyInitialized(poolId);
        _initializeRewardConfig(rgs.rewardConfig[poolId], poolId);
        gauge.initialized = true;
        gauge.referenceTick = referenceTick;
    }

    function appendRewardAsset(PoolId poolId, address asset) internal returns (uint8 slot) {
        if (asset == address(0)) revert InvalidRewardAsset(asset);
        PoolRewardConfig storage config = rangeGaugeStorage().rewardConfig[poolId];
        if (!config.initialized) revert PoolRewardConfigNotInitialized(poolId);
        if (config.slotPlusOne[asset] != 0) revert RewardAssetAlreadyAssigned(poolId, asset);
        slot = config.slotCount;
        if (slot == MAX_REWARD_SLOTS) revert RewardSlotLimitReached(poolId);
        config.assets[slot] = asset;
        config.slotPlusOne[asset] = slot + 1;
        config.slotCount = slot + 1;
    }

    function rewardSlot(PoolId poolId, address asset) internal view returns (uint8 slot, bool assigned) {
        uint8 slotPlusOne = rangeGaugeStorage().rewardConfig[poolId].slotPlusOne[asset];
        if (slotPlusOne == 0) return (0, false);
        return (slotPlusOne - 1, true);
    }

    function rewardAccount(PoolId poolId, uint8 slot) internal pure returns (bytes32) {
        return keccak256(abi.encode(RANGE_REWARD_ACCOUNT_DOMAIN, PoolId.unwrap(poolId), slot));
    }

    function addPositionPool(uint256 positionId, PoolId poolId) internal {
        PoolIndex storage index = rangeGaugeStorage().positionPools[positionId];
        if (index.indexPlusOne[poolId] != 0) revert PositionPoolAlreadyIndexed(positionId, poolId);
        index.poolIds.push(poolId);
        index.indexPlusOne[poolId] = index.poolIds.length;
    }

    function removePositionPool(uint256 positionId, PoolId poolId) internal {
        PoolIndex storage index = rangeGaugeStorage().positionPools[positionId];
        uint256 indexPlusOne = index.indexPlusOne[poolId];
        if (indexPlusOne == 0) revert PositionPoolNotIndexed(positionId, poolId);
        uint256 poolIndex = indexPlusOne - 1;
        uint256 lastIndex = index.poolIds.length - 1;
        if (poolIndex != lastIndex) {
            PoolId moved = index.poolIds[lastIndex];
            index.poolIds[poolIndex] = moved;
            index.indexPlusOne[moved] = indexPlusOne;
        }
        index.poolIds.pop();
        delete index.indexPlusOne[poolId];
    }

    function positionPools(uint256 positionId, uint256 cursor, uint256 size)
        internal
        view
        returns (PoolId[] memory poolIds, uint256 nextCursor)
    {
        PoolId[] storage stored = rangeGaugeStorage().positionPools[positionId].poolIds;
        uint256 length = stored.length;
        if (cursor >= length || size == 0) return (new PoolId[](0), cursor);
        uint256 remaining = length - cursor;
        uint256 end = size >= remaining ? length : cursor + size;
        poolIds = new PoolId[](end - cursor);
        for (uint256 i; i < poolIds.length; ++i) {
            poolIds[i] = stored[cursor + i];
        }
        nextCursor = end;
    }

    function bindingFor(uint256 positionId, PoolId poolId) internal pure returns (bytes32) {
        return keccak256(abi.encode(positionId, PoolId.unwrap(poolId)));
    }

    function bindPosm(uint256 posmTokenId, uint256 positionId, PoolId poolId) internal returns (bytes32 binding) {
        RangeGaugeStorage storage rgs = rangeGaugeStorage();
        bytes32 current = rgs.posmBinding[posmTokenId];
        if (current != bytes32(0)) revert PosmAlreadyBound(posmTokenId, current);
        binding = bindingFor(positionId, poolId);
        rgs.posmBinding[posmTokenId] = binding;
    }

    function unbindPosm(uint256 posmTokenId, uint256 positionId, PoolId poolId) internal {
        RangeGaugeStorage storage rgs = rangeGaugeStorage();
        bytes32 expected = bindingFor(positionId, poolId);
        bytes32 actual = rgs.posmBinding[posmTokenId];
        if (actual != expected) revert PosmBindingMismatch(posmTokenId, expected, actual);
        delete rgs.posmBinding[posmTokenId];
    }

    function timestamp40(uint256 timestamp) internal pure returns (uint40 value) {
        if (timestamp > type(uint40).max) revert InvalidTimestamp(timestamp);
        value = uint40(timestamp);
    }

    function checkpointStream(GaugeRewardStream storage stream, uint40 currentTime, uint128 activeLiquidity)
        internal
        returns (uint256 emission)
    {
        if (currentTime < stream.lastUpdate) revert TimestampRegression(stream.lastUpdate, currentTime);
        if (stream.periodBudget == stream.periodEmitted || currentTime == stream.lastUpdate) return 0;

        if (activeLiquidity == 0) {
            uint256 idle = uint256(currentTime) - stream.lastUpdate;
            stream.periodStart = _addTimestamp(stream.periodStart, idle);
            stream.periodFinish = _addTimestamp(stream.periodFinish, idle);
            stream.lastUpdate = currentTime;
            return 0;
        }

        uint40 effectiveNow = currentTime < stream.periodFinish ? currentTime : stream.periodFinish;
        uint256 elapsed = uint256(effectiveNow) - stream.periodStart;
        uint256 duration = uint256(stream.periodFinish) - stream.periodStart;
        uint256 targetEmitted = effectiveNow == stream.periodFinish
            ? stream.periodBudget
            : Math.mulDiv(stream.periodBudget, elapsed, duration);
        emission = targetEmitted - stream.periodEmitted;
        stream.periodEmitted = targetEmitted;
        stream.lastUpdate = effectiveNow;
        if (emission != 0) _increaseIndex(stream, emission, activeLiquidity);
    }

    function fundStream(
        GaugeRewardStream storage stream,
        uint256 received,
        uint40 currentTime,
        uint40 duration,
        uint128 activeLiquidity
    ) internal returns (uint256 emission, uint40 remainingDuration) {
        if (received == 0) revert InvalidFundingAmount();
        if (duration < MIN_REWARD_DURATION || duration > MAX_REWARD_DURATION) {
            revert InvalidRewardDuration(duration);
        }
        emission = checkpointStream(stream, currentTime, activeLiquidity);
        uint256 remainingBudget = stream.periodBudget - stream.periodEmitted;
        if (remainingBudget == 0) {
            stream.periodStart = currentTime;
            stream.periodFinish = _addTimestamp(currentTime, duration);
            stream.lastUpdate = currentTime;
            stream.periodBudget = received;
            stream.periodEmitted = 0;
            return (emission, duration);
        }

        uint40 finish = stream.periodFinish;
        stream.periodStart = currentTime;
        stream.lastUpdate = currentTime;
        stream.periodBudget = remainingBudget + received;
        stream.periodEmitted = 0;
        remainingDuration = finish - currentTime;
    }

    function positionAccrual(uint128 liquidity, uint256 growthDeltaRay, uint256 priorRemainderRay)
        internal
        pure
        returns (uint256 claimableDelta, uint256 newRemainderRay)
    {
        return combinePositionAccrual(
            Math.mulDiv(liquidity, growthDeltaRay, RAY), mulmod(liquidity, growthDeltaRay, RAY), priorRemainderRay
        );
    }

    function combinePositionAccrual(uint256 whole, uint256 productRemainderRay, uint256 priorRemainderRay)
        internal
        pure
        returns (uint256 claimableDelta, uint256 newRemainderRay)
    {
        if (productRemainderRay >= RAY) revert InvalidPositionRemainder(productRemainderRay);
        if (priorRemainderRay >= RAY) revert InvalidPositionRemainder(priorRemainderRay);
        uint256 combined = productRemainderRay + priorRemainderRay;
        claimableDelta = whole + combined / RAY;
        newRemainderRay = combined % RAY;
    }

    function settleLegSlot(GaugeRewardStream storage stream, LpLeg storage leg, uint8 slot, uint256 insideGrowthRay)
        internal
        returns (uint256 claimableDelta)
    {
        uint256 checkpoint = leg.checkpointInsideRay[slot];
        uint256 growthDelta;
        unchecked {
            growthDelta = insideGrowthRay - checkpoint;
        }
        uint256 newRemainder;
        (claimableDelta, newRemainder) = positionAccrual(leg.liquidity, growthDelta, leg.rewardRemainderRay[slot]);
        leg.checkpointInsideRay[slot] = insideGrowthRay;
        leg.rewardRemainderRay[slot] = newRemainder;
        if (claimableDelta == 0) return 0;
        if (claimableDelta > stream.indexedLiability) {
            revert IndexedLiabilityUnderflow(stream.indexedLiability, claimableDelta);
        }
        stream.indexedLiability -= claimableDelta;
        stream.claimLiability += claimableDelta;
        leg.claimable[slot] += claimableDelta;
    }

    function flushDenominatorRemainder(PoolId poolId, uint8 slot) internal returns (uint256 dust) {
        RangeGaugeStorage storage rgs = rangeGaugeStorage();
        PoolRewardConfig storage config = rgs.rewardConfig[poolId];
        if (!config.initialized) revert PoolRewardConfigNotInitialized(poolId);
        if (slot >= config.slotCount) revert InvalidRewardSlot(poolId, slot);
        GaugeRewardStream storage stream = rgs.gauges[poolId].streams[slot];
        uint256 remainder = stream.indexRemainder;
        if (remainder == 0) return 0;
        stream.indexRemainder = 0;
        dust = remainder / RAY;
        if (dust == 0) return 0;
        if (dust > stream.indexedLiability) revert IndexedLiabilityUnderflow(stream.indexedLiability, dust);
        stream.indexedLiability -= dust;
        address asset = config.assets[slot];
        LibCustody.moveReservation(rewardAccount(poolId, slot), LibCustody.feeAccount(), asset, dust);
        LibGlobalRewards.accrueReservedTreasuryFee(asset, dust);
    }

    function addRangeBoundaries(
        PoolId poolId,
        int24 tickLower,
        int24 tickUpper,
        int24 tickSpacing,
        int24 currentTick,
        uint128 liquidity
    ) internal {
        if (tickLower >= tickUpper) revert InvalidTickRange(tickLower, tickUpper);
        if (liquidity == 0 || liquidity > uint128(type(int128).max)) revert InvalidLiquidity();
        RangeGaugeStorage storage rgs = rangeGaugeStorage();
        GaugePool storage gauge = rgs.gauges[poolId];
        if (!gauge.initialized) revert GaugeNotInitialized(poolId);
        uint8 slotCount = rgs.rewardConfig[poolId].slotCount;
        _addBoundary(gauge, tickLower, tickSpacing, currentTick, liquidity, true, slotCount);
        _addBoundary(gauge, tickUpper, tickSpacing, currentTick, liquidity, false, slotCount);
    }

    function removeRangeBoundaries(
        PoolId poolId,
        int24 tickLower,
        int24 tickUpper,
        int24 tickSpacing,
        uint128 liquidity
    ) internal {
        if (tickLower >= tickUpper) revert InvalidTickRange(tickLower, tickUpper);
        if (liquidity == 0 || liquidity > uint128(type(int128).max)) revert InvalidLiquidity();
        GaugePool storage gauge = rangeGaugeStorage().gauges[poolId];
        if (!gauge.initialized) revert GaugeNotInitialized(poolId);
        _removeBoundary(gauge, tickLower, tickSpacing, liquidity, true);
        _removeBoundary(gauge, tickUpper, tickSpacing, liquidity, false);
    }

    function crossBoundary(GaugePool storage gauge, int24 tick, uint8 slotCount)
        internal
        returns (int128 netLiquidity)
    {
        GaugeBoundary storage boundary = gauge.boundaries[tick];
        if (boundary.grossLiquidity == 0) revert BoundaryNotInitialized(tick);
        for (uint8 slot; slot < slotCount; ++slot) {
            unchecked {
                boundary.rewardOutsideRay[slot] = gauge.streams[slot].globalIndexRay - boundary.rewardOutsideRay[slot];
            }
        }
        netLiquidity = boundary.netLiquidity;
    }

    function applyCrossingLiquidity(uint128 activeLiquidity, int128 netLiquidity, bool rightward)
        internal
        pure
        returns (uint128 updated)
    {
        int256 signed = int256(uint256(activeLiquidity));
        signed = rightward ? signed + netLiquidity : signed - netLiquidity;
        if (signed < 0 || uint256(signed) > type(uint128).max) {
            revert ActiveLiquidityOverflow(activeLiquidity, netLiquidity, rightward);
        }
        updated = uint128(uint256(signed));
    }

    function addBoundaryLiquidity(
        uint128 grossLiquidity,
        int128 netLiquidity,
        uint128 liquidity,
        bool lower,
        int24 tick
    ) internal pure returns (uint128 updatedGross, int128 updatedNet) {
        updatedGross = grossLiquidity + liquidity;
        int256 net = int256(netLiquidity) + (lower ? int256(uint256(liquidity)) : -int256(uint256(liquidity)));
        if (net < type(int128).min || net > type(int128).max) revert BoundaryNetLiquidityOverflow(tick, net);
        updatedNet = int128(net);
    }

    function removeBoundaryLiquidity(
        uint128 grossLiquidity,
        int128 netLiquidity,
        uint128 liquidity,
        bool lower,
        int24 tick
    ) internal pure returns (uint128 updatedGross, int128 updatedNet) {
        if (grossLiquidity == 0) revert BoundaryNotInitialized(tick);
        if (liquidity > grossLiquidity) revert BoundaryLiquidityUnderflow(tick, grossLiquidity, liquidity);
        int256 net = int256(netLiquidity) + (lower ? -int256(uint256(liquidity)) : int256(uint256(liquidity)));
        if (net < type(int128).min || net > type(int128).max) revert BoundaryNetLiquidityOverflow(tick, net);
        updatedGross = grossLiquidity - liquidity;
        if (updatedGross == 0 && net != 0) revert BoundaryNetLiquidityOverflow(tick, net);
        updatedNet = int128(net);
    }

    function growthInside(GaugePool storage gauge, int24 tickLower, int24 tickUpper, int24 currentTick, uint8 slot)
        internal
        view
        returns (uint256 inside)
    {
        return growthInsideValues(
            gauge.streams[slot].globalIndexRay,
            gauge.boundaries[tickLower].rewardOutsideRay[slot],
            gauge.boundaries[tickUpper].rewardOutsideRay[slot],
            tickLower,
            tickUpper,
            currentTick
        );
    }

    function growthInsideValues(
        uint256 global,
        uint256 lowerOutside,
        uint256 upperOutside,
        int24 tickLower,
        int24 tickUpper,
        int24 currentTick
    ) internal pure returns (uint256 inside) {
        unchecked {
            if (currentTick < tickLower) return lowerOutside - upperOutside;
            if (currentTick >= tickUpper) return upperOutside - lowerOutside;
            return global - lowerOutside - upperOutside;
        }
    }

    function nextInitializedBoundary(GaugePool storage gauge, int24 tick, int24 tickSpacing, bool lte)
        internal
        view
        returns (int24 next, bool initialized)
    {
        (next, initialized) = gauge.boundaryBitmap.nextInitializedTickWithinOneWord(tick, tickSpacing, lte);
        if (initialized) return (next, true);

        int24 searchedCompressed = TickBitmap.compress(next, tickSpacing);
        (int16 searchedWord,) = TickBitmap.position(searchedCompressed);
        (int16 nextWord, bool wordInitialized) = _nextInitializedWord(gauge, searchedWord, lte);
        if (!wordInitialized) return (0, false);
        uint256 word = gauge.boundaryBitmap[nextWord];
        uint8 bit = lte ? BitMath.mostSignificantBit(word) : BitMath.leastSignificantBit(word);
        int24 compressed = int24(int256(nextWord) * 256 + int256(uint256(bit)));
        next = compressed * tickSpacing;
        initialized = true;
    }

    function _initializeRewardConfig(PoolRewardConfig storage config, PoolId poolId) private {
        if (config.initialized) revert PoolRewardConfigAlreadyInitialized(poolId);
        address statics = staticsToken();
        if (statics == address(0)) revert InvalidRewardAsset(statics);
        config.initialized = true;
        config.slotCount = 1;
        config.assets[STATICS_SLOT] = statics;
        config.slotPlusOne[statics] = STATICS_SLOT + 1;
    }

    function _increaseIndex(GaugeRewardStream storage stream, uint256 amount, uint128 denominator) private {
        (uint256 delta, uint256 remainder) = LibIndexMath.indexDelta(amount, denominator, stream.indexRemainder);
        unchecked {
            stream.globalIndexRay += delta;
        }
        stream.indexRemainder = remainder;
        stream.indexedLiability += amount;
    }

    function _addBoundary(
        GaugePool storage gauge,
        int24 tick,
        int24 tickSpacing,
        int24 currentTick,
        uint128 liquidity,
        bool lower,
        uint8 slotCount
    ) private {
        GaugeBoundary storage boundary = gauge.boundaries[tick];
        if (boundary.grossLiquidity == 0) {
            _setBoundaryBit(gauge, tick, tickSpacing, true);
            if (tick <= currentTick) {
                for (uint8 slot; slot < slotCount; ++slot) {
                    boundary.rewardOutsideRay[slot] = gauge.streams[slot].globalIndexRay;
                }
            }
        }
        (boundary.grossLiquidity, boundary.netLiquidity) =
            addBoundaryLiquidity(boundary.grossLiquidity, boundary.netLiquidity, liquidity, lower, tick);
    }

    function _removeBoundary(GaugePool storage gauge, int24 tick, int24 tickSpacing, uint128 liquidity, bool lower)
        private
    {
        GaugeBoundary storage boundary = gauge.boundaries[tick];
        (uint128 remaining, int128 net) =
            removeBoundaryLiquidity(boundary.grossLiquidity, boundary.netLiquidity, liquidity, lower, tick);
        if (remaining == 0) {
            _setBoundaryBit(gauge, tick, tickSpacing, false);
            delete gauge.boundaries[tick];
            return;
        }
        boundary.grossLiquidity = remaining;
        boundary.netLiquidity = net;
    }

    function _setBoundaryBit(GaugePool storage gauge, int24 tick, int24 tickSpacing, bool initialized) private {
        int24 compressed = TickBitmap.compress(tick, tickSpacing);
        (int16 wordPos,) = TickBitmap.position(compressed);
        uint256 beforeWord = gauge.boundaryBitmap[wordPos];
        bool wasInitialized = beforeWord != 0;
        gauge.boundaryBitmap.flipTick(tick, tickSpacing);
        uint256 afterWord = gauge.boundaryBitmap[wordPos];
        if (initialized) {
            assert(afterWord != 0);
            if (!wasInitialized) _setSummaryWord(gauge, wordPos, true);
        } else {
            if (afterWord == 0) _setSummaryWord(gauge, wordPos, false);
        }
    }

    function _setSummaryWord(GaugePool storage gauge, int16 wordPos, bool initialized) private {
        (int8 summaryWordPos, uint8 bitPos) = _summaryPosition(wordPos);
        uint256 mask = uint256(1) << bitPos;
        uint256 beforeWord = gauge.boundaryWordBitmap[summaryWordPos];
        uint256 afterWord = initialized ? beforeWord | mask : beforeWord & ~mask;
        gauge.boundaryWordBitmap[summaryWordPos] = afterWord;
        uint8 summaryBit = uint8(uint16(int16(summaryWordPos) + 128));
        uint256 summaryMask = uint256(1) << summaryBit;
        if (beforeWord == 0 && afterWord != 0) gauge.boundarySummaryBitmap |= summaryMask;
        if (beforeWord != 0 && afterWord == 0) gauge.boundarySummaryBitmap &= ~summaryMask;
    }

    function _nextInitializedWord(GaugePool storage gauge, int16 wordPos, bool lte)
        private
        view
        returns (int16 nextWord, bool initialized)
    {
        (int8 summaryWordPos, uint8 bitPos) = _summaryPosition(wordPos);
        uint256 localWord = gauge.boundaryWordBitmap[summaryWordPos];
        uint256 localMask;
        if (lte) {
            localMask = bitPos == 0 ? 0 : (uint256(1) << bitPos) - 1;
            localWord &= localMask;
            if (localWord != 0) {
                return (_wordPosition(summaryWordPos, BitMath.mostSignificantBit(localWord)), true);
            }
        } else {
            localMask = bitPos == type(uint8).max ? 0 : ~((uint256(1) << (uint256(bitPos) + 1)) - 1);
            localWord &= localMask;
            if (localWord != 0) {
                return (_wordPosition(summaryWordPos, BitMath.leastSignificantBit(localWord)), true);
            }
        }

        uint8 summaryBit = uint8(uint16(int16(summaryWordPos) + 128));
        uint256 summary = gauge.boundarySummaryBitmap;
        if (lte) {
            uint256 lteSummaryMask = summaryBit == 0 ? 0 : (uint256(1) << summaryBit) - 1;
            summary &= lteSummaryMask;
            if (summary == 0) return (0, false);
            uint8 lteSummaryBit = BitMath.mostSignificantBit(summary);
            int8 lteSummaryWord = int8(int16(uint16(lteSummaryBit)) - 128);
            uint256 lteLocalWord = gauge.boundaryWordBitmap[lteSummaryWord];
            return (_wordPosition(lteSummaryWord, BitMath.mostSignificantBit(lteLocalWord)), true);
        }

        uint256 gtSummaryMask = summaryBit == type(uint8).max ? 0 : ~((uint256(1) << (uint256(summaryBit) + 1)) - 1);
        summary &= gtSummaryMask;
        if (summary == 0) return (0, false);
        uint8 gtSummaryBit = BitMath.leastSignificantBit(summary);
        int8 gtSummaryWord = int8(int16(uint16(gtSummaryBit)) - 128);
        uint256 gtLocalWord = gauge.boundaryWordBitmap[gtSummaryWord];
        return (_wordPosition(gtSummaryWord, BitMath.leastSignificantBit(gtLocalWord)), true);
    }

    function _summaryPosition(int16 wordPos) private pure returns (int8 summaryWordPos, uint8 bitPos) {
        summaryWordPos = int8(wordPos >> 8);
        bitPos = uint8(uint16(wordPos));
    }

    function _wordPosition(int8 summaryWordPos, uint8 bitPos) private pure returns (int16 wordPos) {
        wordPos = int16(summaryWordPos) * 256 + int16(uint16(bitPos));
    }

    function _addTimestamp(uint40 timestamp, uint256 delta) private pure returns (uint40 result) {
        uint256 sum = uint256(timestamp) + delta;
        if (sum > type(uint40).max) revert TimestampOverflow(timestamp, delta);
        result = uint40(sum);
    }
}
