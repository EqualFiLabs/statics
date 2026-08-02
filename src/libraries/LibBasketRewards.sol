// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IStaticsBasketRewards} from "../interfaces/IStaticsBasketRewards.sol";
import {LibBasket} from "./LibBasket.sol";
import {LibBasketLiquidity} from "./LibBasketLiquidity.sol";
import {LibPosition} from "../position/LibPosition.sol";

library LibBasketRewards {
    bytes32 internal constant REWARD_STORAGE_POSITION = keccak256("statics.storage.basket.rewards.v1");
    uint256 internal constant RAY = 1e27;

    struct RewardIndex {
        uint256 accumulatedPerShareRay;
        uint256 remainder;
    }

    struct PositionBasket {
        uint256 eligibleShares;
        uint256 lockedShares;
        uint256 lastDepositBlock;
        mapping(address asset => uint256 checkpointRay) checkpointRay;
        mapping(address asset => uint256 amount) claimable;
    }

    struct RewardStorage {
        mapping(uint256 basketId => uint256 shares) totalEligibleShares;
        mapping(uint256 basketId => mapping(address asset => RewardIndex index)) indexes;
        mapping(uint256 basketId => mapping(address asset => uint256 amount)) feeYieldReserve;
        mapping(uint256 basketId => mapping(address asset => uint256 amount)) totalClaimable;
        mapping(uint256 positionId => mapping(uint256 basketId => PositionBasket position)) positions;
    }

    error InsufficientPositionShares(uint256 requested, uint256 available);
    error PositionSharesLocked(uint256 requested, uint256 unlocked);
    error InsufficientLockedShares(uint256 requested, uint256 locked);
    error PositionDepositTooRecent(uint256 positionId, uint256 basketId, uint256 withdrawableAfterBlock);

    function rewardStorage() internal pure returns (RewardStorage storage rs) {
        bytes32 position = REWARD_STORAGE_POSITION;
        assembly ("memory-safe") {
            rs.slot := position
        }
    }

    function accrueFee(LibBasket.BasketStorage storage bs, uint256 basketId, address asset, uint256 fee) internal {
        if (fee == 0) return;
        RewardStorage storage rs = rewardStorage();
        uint256 totalEligible = rs.totalEligibleShares[basketId];
        uint256 holderAmount = totalEligible == 0 ? 0 : Math.mulDiv(fee, bs.feeAllocation.holderShareBps, LibBasket.BPS);
        uint256 liquidityAmount = Math.mulDiv(fee, bs.feeAllocation.liquidityShareBps, LibBasket.BPS);
        uint256 protocolAmount = fee - holderAmount - liquidityAmount;
        bs.protocolRevenue[basketId][asset] += protocolAmount;

        LibBasketLiquidity.LiquidityStorage storage ls = LibBasketLiquidity.liquidityStorage();
        ls.liquidityReserve[basketId][asset] += liquidityAmount;
        LibBasketLiquidity.PrimaryFeeTotals storage totals = ls.cumulativePrimaryFees[basketId][asset];
        totals.holderAmount += holderAmount;
        totals.liquidityAmount += liquidityAmount;
        totals.protocolAmount += protocolAmount;

        RewardIndex storage index = rs.indexes[basketId][asset];
        if (holderAmount != 0) {
            rs.feeYieldReserve[basketId][asset] += holderAmount;
            (uint256 delta, uint256 remainder) = _indexDelta(holderAmount, totalEligible, index.remainder);
            index.accumulatedPerShareRay += delta;
            index.remainder = remainder;
        }
        emit IStaticsBasketRewards.BasketFeesAccrued(
            basketId, asset, fee, holderAmount, liquidityAmount, protocolAmount, index.accumulatedPerShareRay
        );
    }

    function settlePosition(LibBasket.Basket storage configured, uint256 positionId, uint256 basketId) internal {
        RewardStorage storage rs = rewardStorage();
        PositionBasket storage position = rs.positions[positionId][basketId];
        uint256 shares = position.eligibleShares;
        uint256 length = configured.assets.length;
        for (uint256 i; i < length; ++i) {
            address asset = configured.assets[i];
            uint256 currentIndex = rs.indexes[basketId][asset].accumulatedPerShareRay;
            uint256 checkpoint = position.checkpointRay[asset];
            uint256 added;
            if (shares != 0 && currentIndex > checkpoint) {
                added = Math.mulDiv(shares, currentIndex - checkpoint, RAY);
                if (added != 0) {
                    position.claimable[asset] += added;
                    rs.totalClaimable[basketId][asset] += added;
                }
            }
            position.checkpointRay[asset] = currentIndex;
            emit IStaticsBasketRewards.BasketPositionRewardsSettled(positionId, basketId, asset, added);
        }
    }

    function increasePosition(LibBasket.Basket storage configured, uint256 positionId, uint256 basketId, uint256 shares)
        internal
    {
        settlePosition(configured, positionId, basketId);
        RewardStorage storage rs = rewardStorage();
        PositionBasket storage position = rs.positions[positionId][basketId];
        bytes32 legKey = LibPosition.basketLegKey(basketId);
        LibPosition.PositionStorage storage ps = LibPosition.positionStorage();
        if (!ps.activeLeg[positionId][legKey]) LibPosition.activateLeg(positionId, legKey);
        position.eligibleShares += shares;
        position.lastDepositBlock = block.number;
        rs.totalEligibleShares[basketId] += shares;
    }

    function decreasePosition(
        LibBasket.BasketStorage storage bs,
        LibBasket.Basket storage configured,
        uint256 positionId,
        uint256 basketId,
        uint256 shares
    ) internal {
        settlePosition(configured, positionId, basketId);
        RewardStorage storage rs = rewardStorage();
        PositionBasket storage position = rs.positions[positionId][basketId];
        uint256 eligible = position.eligibleShares;
        if (shares > eligible) revert InsufficientPositionShares(shares, eligible);
        uint256 unlocked = eligible - position.lockedShares;
        if (shares > unlocked) revert PositionSharesLocked(shares, unlocked);
        uint256 withdrawableAfterBlock = position.lastDepositBlock + 1;
        if (block.number < withdrawableAfterBlock) {
            revert PositionDepositTooRecent(positionId, basketId, withdrawableAfterBlock);
        }
        position.eligibleShares = eligible - shares;
        rs.totalEligibleShares[basketId] -= shares;
        if (rs.totalEligibleShares[basketId] == 0) _sweepUnallocated(bs, configured, basketId);
    }

    function lockForLoan(
        LibBasket.Basket storage configured,
        uint256 positionId,
        uint256 basketId,
        uint256 sharesIn,
        uint256 feeShares,
        uint256 collateralShares
    ) internal {
        settlePosition(configured, positionId, basketId);
        RewardStorage storage rs = rewardStorage();
        PositionBasket storage position = rs.positions[positionId][basketId];
        uint256 eligible = position.eligibleShares;
        uint256 unlocked = eligible - position.lockedShares;
        if (sharesIn > unlocked) revert PositionSharesLocked(sharesIn, unlocked);
        position.eligibleShares = eligible - feeShares;
        position.lockedShares += collateralShares;
        rs.totalEligibleShares[basketId] -= feeShares;
    }

    function unlockAfterRepay(
        LibBasket.Basket storage configured,
        uint256 positionId,
        uint256 basketId,
        uint256 collateralShares
    ) internal {
        settlePosition(configured, positionId, basketId);
        PositionBasket storage position = rewardStorage().positions[positionId][basketId];
        uint256 locked = position.lockedShares;
        if (collateralShares > locked) revert InsufficientLockedShares(collateralShares, locked);
        position.lockedShares = locked - collateralShares;
    }

    function removeRecoveredCollateral(
        LibBasket.BasketStorage storage bs,
        LibBasket.Basket storage configured,
        uint256 positionId,
        uint256 basketId,
        uint256 collateralShares
    ) internal {
        settlePosition(configured, positionId, basketId);
        RewardStorage storage rs = rewardStorage();
        PositionBasket storage position = rs.positions[positionId][basketId];
        uint256 locked = position.lockedShares;
        if (collateralShares > locked) revert InsufficientLockedShares(collateralShares, locked);
        uint256 eligible = position.eligibleShares;
        if (collateralShares > eligible) revert InsufficientPositionShares(collateralShares, eligible);
        position.lockedShares = locked - collateralShares;
        position.eligibleShares = eligible - collateralShares;
        rs.totalEligibleShares[basketId] -= collateralShares;
        if (rs.totalEligibleShares[basketId] == 0) _sweepUnallocated(bs, configured, basketId);
    }

    function deactivateIfEmpty(LibBasket.Basket storage configured, uint256 positionId, uint256 basketId) internal {
        RewardStorage storage rs = rewardStorage();
        PositionBasket storage position = rs.positions[positionId][basketId];
        if (position.eligibleShares != 0 || position.lockedShares != 0) return;
        uint256 length = configured.assets.length;
        for (uint256 i; i < length; ++i) {
            if (position.claimable[configured.assets[i]] != 0) return;
        }
        bytes32 key = LibPosition.basketLegKey(basketId);
        LibPosition.PositionStorage storage ps = LibPosition.positionStorage();
        if (ps.activeLeg[positionId][key]) LibPosition.deactivateLeg(positionId, key);
    }

    function pending(LibBasket.Basket storage configured, uint256 positionId, uint256 basketId)
        internal
        view
        returns (address[] memory assets, uint256[] memory amounts)
    {
        RewardStorage storage rs = rewardStorage();
        PositionBasket storage position = rs.positions[positionId][basketId];
        uint256 length = configured.assets.length;
        assets = configured.assets;
        amounts = new uint256[](length);
        for (uint256 i; i < length; ++i) {
            address asset = assets[i];
            uint256 amount = position.claimable[asset];
            uint256 currentIndex = rs.indexes[basketId][asset].accumulatedPerShareRay;
            uint256 checkpoint = position.checkpointRay[asset];
            if (position.eligibleShares != 0 && currentIndex > checkpoint) {
                amount += Math.mulDiv(position.eligibleShares, currentIndex - checkpoint, RAY);
            }
            amounts[i] = amount;
        }
    }

    function _sweepUnallocated(
        LibBasket.BasketStorage storage bs,
        LibBasket.Basket storage configured,
        uint256 basketId
    ) private {
        RewardStorage storage rs = rewardStorage();
        uint256 length = configured.assets.length;
        for (uint256 i; i < length; ++i) {
            address asset = configured.assets[i];
            uint256 reserve = rs.feeYieldReserve[basketId][asset];
            uint256 claimable = rs.totalClaimable[basketId][asset];
            if (reserve > claimable) {
                uint256 unallocated = reserve - claimable;
                rs.feeYieldReserve[basketId][asset] = claimable;
                bs.protocolRevenue[basketId][asset] += unallocated;
            }
            rs.indexes[basketId][asset].remainder = 0;
        }
    }

    function _indexDelta(uint256 amount, uint256 denominator, uint256 priorRemainder)
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
