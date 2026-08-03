// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IStaticsLiquidityRewards} from "../interfaces/IStaticsLiquidityRewards.sol";
import {LibGlobalRewards} from "./LibGlobalRewards.sol";
import {LibPosition} from "../position/LibPosition.sol";

library LibLiquidityRewards {
    bytes32 internal constant STORAGE_POSITION = keccak256("statics.storage.liquidity.rewards.v1");
    uint256 internal constant RAY = 1e27;

    struct PoolRewards {
        uint256 totalEligibleLiquidity;
        uint256 index0Ray;
        uint256 index1Ray;
        uint256 indexRemainder0;
        uint256 indexRemainder1;
        uint256 indexed0;
        uint256 indexed1;
        uint256 crystallized0;
        uint256 crystallized1;
        uint256 totalClaimable0;
        uint256 totalClaimable1;
    }

    struct LiquidityPosition {
        uint256 positionId;
        uint256 basketId;
        address asset;
        PoolId poolId;
        address currency0;
        address currency1;
        uint128 eligibleLiquidity;
        uint128 pendingLiquidity;
        uint64 eligibleAtBlock;
        uint256 checkpoint0Ray;
        uint256 checkpoint1Ray;
        uint256 claimable0;
        uint256 claimable1;
        bool staked;
    }

    struct RewardStorage {
        mapping(PoolId poolId => PoolRewards rewards) pools;
        mapping(uint256 tokenId => LiquidityPosition position) positions;
        mapping(uint256 positionId => uint256 count) positionRecordCount;
    }

    error InvalidLiquidityRecord(uint256 tokenId);
    error LiquidityAlreadyStaked(uint256 tokenId);
    error OutstandingLiquidityClaims(uint256 tokenId, uint256 positionId);
    error LiquidityNotActivatable(uint256 tokenId, uint256 eligibleAtBlock);
    error LiquidityOverflow(uint256 liquidity);
    error PoolHasNoEligibleLiquidity(PoolId poolId);

    function rewardStorage() internal pure returns (RewardStorage storage rs) {
        bytes32 slot = STORAGE_POSITION;
        assembly ("memory-safe") {
            rs.slot := slot
        }
    }

    function liquidityLegKey() internal view returns (bytes32) {
        return LibPosition.liquidityLegKey();
    }

    function initializeRecord(
        uint256 tokenId,
        uint256 positionId,
        uint256 basketId,
        address asset,
        PoolId poolId,
        address currency0,
        address currency1,
        uint256 liquidity
    ) internal returns (LiquidityPosition storage position) {
        if (liquidity > type(uint128).max) revert LiquidityOverflow(liquidity);
        RewardStorage storage rs = rewardStorage();
        position = rs.positions[tokenId];
        if (position.staked) revert LiquidityAlreadyStaked(tokenId);
        if (position.positionId != 0 && position.positionId != positionId) {
            revert OutstandingLiquidityClaims(tokenId, position.positionId);
        }
        if (position.positionId == 0) {
            position.positionId = positionId;
            position.basketId = basketId;
            position.asset = asset;
            position.poolId = poolId;
            position.currency0 = currency0;
            position.currency1 = currency1;
            ++rs.positionRecordCount[positionId];
            if (rs.positionRecordCount[positionId] == 1) {
                LibPosition.activateLeg(positionId, LibPosition.LIQUIDITY_MODULE, bytes32(uint256(1)));
            }
        }
        PoolRewards storage pool = rs.pools[poolId];
        position.checkpoint0Ray = pool.index0Ray;
        position.checkpoint1Ray = pool.index1Ray;
        position.pendingLiquidity = uint128(liquidity);
        position.eligibleLiquidity = 0;
        position.eligibleAtBlock = _nextBlock();
        position.staked = true;
    }

    function activate(uint256 tokenId) internal returns (uint256 activated) {
        LiquidityPosition storage position = rewardStorage().positions[tokenId];
        if (!position.staked || position.pendingLiquidity == 0) revert InvalidLiquidityRecord(tokenId);
        if (block.number < position.eligibleAtBlock) {
            revert LiquidityNotActivatable(tokenId, position.eligibleAtBlock);
        }
        settle(tokenId);
        activated = position.pendingLiquidity;
        position.pendingLiquidity = 0;
        position.eligibleAtBlock = 0;
        position.eligibleLiquidity += uint128(activated);
        PoolRewards storage pool = rewardStorage().pools[position.poolId];
        pool.totalEligibleLiquidity += activated;
        pool.indexRemainder0 = 0;
        pool.indexRemainder1 = 0;
        position.checkpoint0Ray = pool.index0Ray;
        position.checkpoint1Ray = pool.index1Ray;
    }

    function activateIfMatured(uint256 tokenId) internal returns (uint256 activated) {
        LiquidityPosition storage position = rewardStorage().positions[tokenId];
        if (position.pendingLiquidity != 0 && block.number >= position.eligibleAtBlock) return activate(tokenId);
    }

    function addPending(uint256 tokenId, uint256 liquidity) internal {
        if (liquidity == 0 || liquidity > type(uint128).max) revert LiquidityOverflow(liquidity);
        LiquidityPosition storage position = rewardStorage().positions[tokenId];
        if (!position.staked) revert InvalidLiquidityRecord(tokenId);
        uint256 combined = uint256(position.pendingLiquidity) + liquidity;
        if (combined > type(uint128).max) revert LiquidityOverflow(combined);
        position.pendingLiquidity = uint128(combined);
        position.eligibleAtBlock = _nextBlock();
    }

    function settle(uint256 tokenId) internal returns (uint256 amount0, uint256 amount1) {
        RewardStorage storage rs = rewardStorage();
        LiquidityPosition storage position = rs.positions[tokenId];
        if (position.positionId == 0) revert InvalidLiquidityRecord(tokenId);
        PoolRewards storage pool = rs.pools[position.poolId];
        uint256 liquidity = position.eligibleLiquidity;
        if (liquidity != 0) {
            if (pool.index0Ray > position.checkpoint0Ray) {
                amount0 = Math.mulDiv(liquidity, pool.index0Ray - position.checkpoint0Ray, RAY);
                if (amount0 != 0) {
                    position.claimable0 += amount0;
                    pool.crystallized0 += amount0;
                    pool.totalClaimable0 += amount0;
                }
            }
            if (pool.index1Ray > position.checkpoint1Ray) {
                amount1 = Math.mulDiv(liquidity, pool.index1Ray - position.checkpoint1Ray, RAY);
                if (amount1 != 0) {
                    position.claimable1 += amount1;
                    pool.crystallized1 += amount1;
                    pool.totalClaimable1 += amount1;
                }
            }
        }
        position.checkpoint0Ray = pool.index0Ray;
        position.checkpoint1Ray = pool.index1Ray;
    }

    function removeEligibility(uint256 tokenId) internal {
        RewardStorage storage rs = rewardStorage();
        LiquidityPosition storage position = rs.positions[tokenId];
        settle(tokenId);
        PoolRewards storage pool = rs.pools[position.poolId];
        uint256 eligible = position.eligibleLiquidity;
        if (eligible != 0) {
            pool.totalEligibleLiquidity -= eligible;
            position.eligibleLiquidity = 0;
            pool.indexRemainder0 = 0;
            pool.indexRemainder1 = 0;
        }
        position.pendingLiquidity = 0;
        position.eligibleAtBlock = 0;
        position.staked = false;
    }

    function accrue(PoolId poolId, address asset, uint256 amount) internal returns (uint256 indexRay) {
        if (amount == 0) return 0;
        RewardStorage storage rs = rewardStorage();
        PoolRewards storage pool = rs.pools[poolId];
        uint256 total = pool.totalEligibleLiquidity;
        if (total == 0) revert PoolHasNoEligibleLiquidity(poolId);
        (address currency0, address currency1) = currenciesForPool(poolId);
        if (asset == currency0) {
            (uint256 delta, uint256 remainder) = _indexDelta(amount, pool.indexRemainder0, total);
            pool.indexRemainder0 = remainder;
            pool.index0Ray += delta;
            pool.indexed0 += amount;
            return pool.index0Ray;
        }
        if (asset == currency1) {
            (uint256 delta, uint256 remainder) = _indexDelta(amount, pool.indexRemainder1, total);
            pool.indexRemainder1 = remainder;
            pool.index1Ray += delta;
            pool.indexed1 += amount;
            return pool.index1Ray;
        }
        revert InvalidLiquidityRecord(0);
    }

    function currenciesForPool(PoolId poolId) internal view returns (address currency0, address currency1) {
        // Every live pool has at least one staked record when this helper is used.
        // The caller-facing facet validates assets against canonical pool storage.
        // Currency lookup is supplied through records; this scan-free cache is set by the facet.
        PoolCurrency storage cached = _poolCurrencyStorage().currencies[poolId];
        return (cached.currency0, cached.currency1);
    }

    struct PoolCurrency {
        address currency0;
        address currency1;
    }

    struct PoolCurrencyStorage {
        mapping(PoolId poolId => PoolCurrency currencies) currencies;
    }

    bytes32 private constant POOL_CURRENCY_STORAGE_POSITION =
        keccak256("statics.storage.liquidity.reward.currencies.v1");

    function _poolCurrencyStorage() private pure returns (PoolCurrencyStorage storage pcs) {
        bytes32 slot = POOL_CURRENCY_STORAGE_POSITION;
        assembly ("memory-safe") {
            pcs.slot := slot
        }
    }

    function cachePoolCurrencies(PoolId poolId, address currency0, address currency1) internal {
        PoolCurrency storage cached = _poolCurrencyStorage().currencies[poolId];
        if (cached.currency0 == address(0)) {
            cached.currency0 = currency0;
            cached.currency1 = currency1;
        }
    }

    function clearIfEmpty(uint256 tokenId) internal {
        RewardStorage storage rs = rewardStorage();
        LiquidityPosition storage position = rs.positions[tokenId];
        if (position.staked || position.claimable0 != 0 || position.claimable1 != 0) return;
        uint256 positionId = position.positionId;
        delete rs.positions[tokenId];
        uint256 count = --rs.positionRecordCount[positionId];
        if (count == 0) LibPosition.deactivateLeg(positionId, liquidityLegKey());
    }

    function pending(uint256 tokenId) internal view returns (uint256 amount0, uint256 amount1) {
        RewardStorage storage rs = rewardStorage();
        LiquidityPosition storage position = rs.positions[tokenId];
        amount0 = position.claimable0;
        amount1 = position.claimable1;
        uint256 liquidity = position.eligibleLiquidity;
        if (liquidity == 0) return (amount0, amount1);
        PoolRewards storage pool = rs.pools[position.poolId];
        if (pool.index0Ray > position.checkpoint0Ray) {
            amount0 += Math.mulDiv(liquidity, pool.index0Ray - position.checkpoint0Ray, RAY);
        }
        if (pool.index1Ray > position.checkpoint1Ray) {
            amount1 += Math.mulDiv(liquidity, pool.index1Ray - position.checkpoint1Ray, RAY);
        }
    }

    function finishEpoch(PoolId poolId) internal {
        PoolRewards storage pool = rewardStorage().pools[poolId];
        if (pool.totalEligibleLiquidity != 0) return;
        uint256 dust0 = pool.indexed0 - pool.crystallized0;
        uint256 dust1 = pool.indexed1 - pool.crystallized1;
        (address currency0, address currency1) = currenciesForPool(poolId);
        if (dust0 != 0) LibGlobalRewards.accrueReservedTreasuryFee(currency0, dust0);
        if (dust1 != 0) LibGlobalRewards.accrueReservedTreasuryFee(currency1, dust1);
        pool.index0Ray = 0;
        pool.index1Ray = 0;
        pool.indexRemainder0 = 0;
        pool.indexRemainder1 = 0;
        pool.indexed0 = 0;
        pool.indexed1 = 0;
        pool.crystallized0 = 0;
        pool.crystallized1 = 0;
    }

    function _nextBlock() private view returns (uint64 eligibleAtBlock) {
        uint256 next = block.number + 1;
        if (next > type(uint64).max) revert LiquidityOverflow(next);
        return uint64(next);
    }

    function _indexDelta(uint256 amount, uint256 priorRemainder, uint256 denominator)
        private
        pure
        returns (uint256 delta, uint256 remainder)
    {
        delta = Math.mulDiv(amount, RAY, denominator);
        remainder = mulmod(amount, RAY, denominator);
        delta += priorRemainder / denominator;
        uint256 normalizedPrior = priorRemainder % denominator;
        uint256 room = denominator - normalizedPrior;
        if (remainder >= room) {
            ++delta;
            remainder -= room;
        } else {
            remainder += normalizedPrior;
        }
    }
}
