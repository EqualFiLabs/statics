// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IStaticsBasketRewards} from "../interfaces/IStaticsBasketRewards.sol";
import {LibBasket} from "./LibBasket.sol";
import {LibBasketCollateral} from "./LibBasketCollateral.sol";
import {LibGlobalRewards} from "./LibGlobalRewards.sol";
import {LibMorpho} from "./LibMorpho.sol";

library LibBasketRewards {
    bytes32 internal constant STORAGE_POSITION = keccak256("statics.storage.basket.rewards.v2");
    uint256 internal constant RAY = 1e27;
    uint256 internal constant REWARD_ELIGIBILITY_DELAY = 24 hours;
    uint256 internal constant REWARD_BUCKET_SIZE = 1 hours;
    uint8 internal constant REWARD_BUCKET_COUNT = 25;

    struct RewardBook {
        uint256 indexRay;
        uint256 indexedAmount;
        uint256 crystallizedAmount;
        mapping(uint40 epoch => uint256 indexRay) activationIndexRay;
        mapping(uint40 epoch => bool recorded) activationRecorded;
    }

    struct EligibilityBook {
        uint256 pendingShares;
        uint40 nextBucketEpoch;
        uint8 bucketCursor;
        uint256[25] pendingBuckets;
    }

    struct PositionRewards {
        uint256 claimAssetCount;
        mapping(address asset => uint256 indexRay) checkpoints;
        mapping(address asset => uint256 amount) claimable;
        uint256 eligibleShares;
        uint256 pendingShares;
        uint40 pendingStartTime;
        uint40 eligibleAt;
    }

    struct RewardStorage {
        mapping(uint256 basketId => uint256 shares) totalEligibleShares;
        mapping(uint256 basketId => mapping(address asset => RewardBook book)) books;
        mapping(uint256 positionId => mapping(uint256 basketId => PositionRewards rewards)) positions;
        mapping(uint256 basketId => mapping(address asset => uint256 amount)) totalClaimable;
        mapping(uint256 basketId => EligibilityBook book) eligibility;
    }

    error InvalidBasketRewardAsset(uint256 basketId, address asset);
    error BasketHasNoEligibleShares(uint256 basketId);

    function rewardStorage() internal pure returns (RewardStorage storage rs) {
        bytes32 slot = STORAGE_POSITION;
        assembly ("memory-safe") {
            rs.slot := slot
        }
    }

    function rewardAssets(LibBasket.Basket storage configured) internal view returns (address[] memory assets) {
        uint256 length = configured.assets.length;
        assets = new address[](length + 1);
        assets[0] = configured.token;
        for (uint256 i; i < length; ++i) {
            assets[i + 1] = configured.assets[i];
        }
    }

    function isRewardAsset(LibBasket.Basket storage configured, address asset) internal view returns (bool) {
        if (asset == configured.token) return true;
        uint256 length = configured.assets.length;
        for (uint256 i; i < length; ++i) {
            if (configured.assets[i] == asset) return true;
        }
        return false;
    }

    function canAccrue(uint256 basketId) internal view returns (bool) {
        RewardStorage storage rs = rewardStorage();
        return rs.totalEligibleShares[basketId] + _duePendingShares(rs.eligibility[basketId]) != 0;
    }

    function effectiveEligibleShares(uint256 basketId) internal view returns (uint256) {
        RewardStorage storage rs = rewardStorage();
        return rs.totalEligibleShares[basketId] + _duePendingShares(rs.eligibility[basketId]);
    }

    function accrueReserved(uint256 basketId, LibBasket.Basket storage configured, address asset, uint256 amount)
        internal
        returns (uint256 indexRay)
    {
        if (amount == 0) return 0;
        if (!isRewardAsset(configured, asset)) revert InvalidBasketRewardAsset(basketId, asset);
        RewardStorage storage rs = rewardStorage();
        _rollMatured(rs, basketId, configured);
        uint256 total = rs.totalEligibleShares[basketId];
        if (total == 0) revert BasketHasNoEligibleShares(basketId);
        RewardBook storage book = rs.books[basketId][asset];
        book.indexRay += Math.mulDiv(amount, RAY, total);
        book.indexedAmount += amount;
        emit IStaticsBasketRewards.BasketRewardAccrued(basketId, asset, amount, book.indexRay);
        return book.indexRay;
    }

    function settle(uint256 positionId, uint256 basketId, LibBasket.Basket storage configured) internal {
        RewardStorage storage rs = rewardStorage();
        _rollMatured(rs, basketId, configured);
        PositionRewards storage position = rs.positions[positionId][basketId];
        uint256 shares = position.eligibleShares;
        _settleAsset(rs, position, positionId, basketId, configured.token, shares);
        uint256 length = configured.assets.length;
        for (uint256 i; i < length; ++i) {
            _settleAsset(rs, position, positionId, basketId, configured.assets[i], shares);
        }
        _syncMatured(rs, position, positionId, basketId, configured);
    }

    function pending(uint256 positionId, uint256 basketId, LibBasket.Basket storage configured)
        internal
        view
        returns (address[] memory assets, uint256[] memory amounts)
    {
        RewardStorage storage rs = rewardStorage();
        PositionRewards storage position = rs.positions[positionId][basketId];
        uint256 shares = position.eligibleShares;
        assets = rewardAssets(configured);
        uint256 length = assets.length;
        amounts = new uint256[](length);
        for (uint256 i; i < length; ++i) {
            amounts[i] = _pendingAsset(rs, position, basketId, assets[i], shares);
        }
    }

    function _pendingAsset(
        RewardStorage storage rs,
        PositionRewards storage position,
        uint256 basketId,
        address asset,
        uint256 eligibleShares
    ) private view returns (uint256 amount) {
        amount = position.claimable[asset];
        RewardBook storage book = rs.books[basketId][asset];
        uint256 current = book.indexRay;
        uint256 prior = position.checkpoints[asset];
        if (eligibleShares != 0 && current > prior) amount += Math.mulDiv(eligibleShares, current - prior, RAY);
        if (position.pendingShares == 0) return amount;
        uint40 epoch = uint40(uint256(position.eligibleAt) / REWARD_BUCKET_SIZE);
        if (book.activationRecorded[epoch] && current > book.activationIndexRay[epoch]) {
            amount += Math.mulDiv(position.pendingShares, current - book.activationIndexRay[epoch], RAY);
        }
    }

    function increasePosition(uint256 positionId, uint256 basketId, LibBasket.Basket storage configured, uint256 shares)
        internal
    {
        settle(positionId, basketId, configured);
        LibBasketCollateral.increasePosition(positionId, basketId, shares);
        _increasePending(rewardStorage(), positionId, basketId, shares);
    }

    function decreasePosition(uint256 positionId, uint256 basketId, LibBasket.Basket storage configured, uint256 shares)
        internal
    {
        settle(positionId, basketId, configured);
        LibBasketCollateral.decreasePosition(positionId, basketId, shares);
        RewardStorage storage rs = rewardStorage();
        _decreaseEligibility(rs, positionId, basketId, shares);
        if (rs.totalEligibleShares[basketId] == 0) _routeDust(basketId, configured);
    }

    function lockForLoan(
        uint256 positionId,
        uint256 basketId,
        LibBasket.Basket storage configured,
        uint256 sharesIn,
        uint256 feeShares,
        uint256 collateralShares
    ) internal {
        settle(positionId, basketId, configured);
        LibBasketCollateral.lockForLoan(positionId, basketId, sharesIn, feeShares, collateralShares);
        if (feeShares == 0) return;
        RewardStorage storage rs = rewardStorage();
        _decreaseEligibility(rs, positionId, basketId, feeShares);
        if (rs.totalEligibleShares[basketId] == 0) _routeDust(basketId, configured);
    }

    function unlockAfterRepay(
        uint256 positionId,
        uint256 basketId,
        LibBasket.Basket storage configured,
        uint256 collateralShares
    ) internal {
        settle(positionId, basketId, configured);
        LibBasketCollateral.unlockAfterRepay(positionId, basketId, collateralShares);
    }

    function releaseAfterRecovery(
        uint256 positionId,
        uint256 basketId,
        LibBasket.Basket storage configured,
        uint256 collateralShares,
        uint256 burnShares
    ) internal {
        settle(positionId, basketId, configured);
        LibBasketCollateral.releaseAfterRecovery(positionId, basketId, collateralShares, burnShares);
        RewardStorage storage rs = rewardStorage();
        _decreaseEligibility(rs, positionId, basketId, burnShares);
        if (rs.totalEligibleShares[basketId] == 0) _routeDust(basketId, configured);
    }

    function applyMorphoLoss(
        uint256 positionId,
        uint256 basketId,
        LibBasket.Basket storage configured,
        uint256 amount,
        address keeper,
        uint16 bountyBps
    ) internal {
        if (amount == 0) return;
        RewardStorage storage rs = rewardStorage();
        _rollMatured(rs, basketId, configured);
        PositionRewards storage position = rs.positions[positionId][basketId];
        _activateForMorphoLoss(rs, position, basketId, configured);
        uint256 deposited = LibBasketCollateral.collateralStorage().positions[positionId][basketId].depositedShares;
        uint256 eligibleLoss = Math.mulDiv(amount, position.eligibleShares, deposited);
        uint256 pendingLoss = amount - eligibleLoss;
        _applyAssetLoss(rs, position, basketId, configured.token, eligibleLoss, keeper, bountyBps);
        uint256 length = configured.assets.length;
        for (uint256 i; i < length; ++i) {
            _applyAssetLoss(rs, position, basketId, configured.assets[i], eligibleLoss, keeper, bountyBps);
        }
        if (pendingLoss != 0) {
            EligibilityBook storage eligibility = rs.eligibility[basketId];
            _removePendingBucket(eligibility, position.eligibleAt, position.pendingShares);
            position.pendingShares -= pendingLoss;
            eligibility.pendingShares -= pendingLoss;
            if (position.pendingShares == 0) {
                position.pendingStartTime = 0;
                position.eligibleAt = 0;
            } else {
                _addPendingBucket(eligibility, position.eligibleAt, position.pendingShares);
            }
        }
        if (eligibleLoss != 0) {
            position.eligibleShares -= eligibleLoss;
            rs.totalEligibleShares[basketId] -= eligibleLoss;
        }
        LibBasketCollateral.collateralStorage().positions[positionId][basketId].depositedShares = deposited - amount;
        if (rs.totalEligibleShares[basketId] == 0) _routeDust(basketId, configured);
    }

    function _activateForMorphoLoss(
        RewardStorage storage rs,
        PositionRewards storage position,
        uint256 basketId,
        LibBasket.Basket storage configured
    ) private {
        uint256 shares = position.pendingShares;
        if (shares == 0) return;
        uint40 epoch = uint40(uint256(position.eligibleAt) / REWARD_BUCKET_SIZE);
        RewardBook storage primary = rs.books[basketId][configured.token];
        if (!primary.activationRecorded[epoch]) return;
        position.checkpoints[configured.token] = primary.activationIndexRay[epoch];
        uint256 length = configured.assets.length;
        for (uint256 i; i < length; ++i) {
            RewardBook storage book = rs.books[basketId][configured.assets[i]];
            position.checkpoints[configured.assets[i]] = book.activationIndexRay[epoch];
        }
        position.eligibleShares += shares;
        position.pendingShares = 0;
        position.pendingStartTime = 0;
        position.eligibleAt = 0;
    }

    function deactivateIfEmpty(uint256 positionId, uint256 basketId) internal {
        PositionRewards storage rewards = rewardStorage().positions[positionId][basketId];
        if (rewards.claimAssetCount != 0) return;
        LibBasketCollateral.deactivateIfEmpty(positionId, basketId);
    }

    function clearClaim(uint256 positionId, uint256 basketId, address asset) internal returns (uint256 amount) {
        RewardStorage storage rs = rewardStorage();
        PositionRewards storage position = rs.positions[positionId][basketId];
        amount = position.claimable[asset];
        if (amount == 0) return 0;
        position.claimable[asset] = 0;
        --position.claimAssetCount;
        rs.totalClaimable[basketId][asset] -= amount;
    }

    function _settleAsset(
        RewardStorage storage rs,
        PositionRewards storage position,
        uint256 positionId,
        uint256 basketId,
        address asset,
        uint256 shares
    ) private {
        RewardBook storage book = rs.books[basketId][asset];
        uint256 prior = position.checkpoints[asset];
        uint256 added;
        if (shares != 0 && book.indexRay > prior) {
            added = Math.mulDiv(shares, book.indexRay - prior, RAY);
            if (added != 0) {
                if (position.claimable[asset] == 0) ++position.claimAssetCount;
                position.claimable[asset] += added;
                rs.totalClaimable[basketId][asset] += added;
                book.crystallizedAmount += added;
            }
        }
        position.checkpoints[asset] = book.indexRay;
        emit IStaticsBasketRewards.BasketRewardSettled(positionId, basketId, asset, added);
    }

    function _routeDust(uint256 basketId, LibBasket.Basket storage configured) private {
        RewardStorage storage rs = rewardStorage();
        _routeAssetDust(rs, basketId, configured.token);
        uint256 length = configured.assets.length;
        for (uint256 i; i < length; ++i) {
            _routeAssetDust(rs, basketId, configured.assets[i]);
        }
    }

    function _routeAssetDust(RewardStorage storage rs, uint256 basketId, address asset) private {
        RewardBook storage book = rs.books[basketId][asset];
        uint256 dust = book.indexedAmount - book.crystallizedAmount;
        book.indexedAmount = 0;
        book.crystallizedAmount = 0;
        if (dust == 0) return;
        LibGlobalRewards.accrueReservedTreasuryFee(asset, dust);
        emit IStaticsBasketRewards.BasketRewardDustRouted(basketId, asset, dust);
    }

    function _applyAssetLoss(
        RewardStorage storage rs,
        PositionRewards storage position,
        uint256 basketId,
        address asset,
        uint256 eligibleLoss,
        address keeper,
        uint16 bountyBps
    ) private {
        RewardBook storage book = rs.books[basketId][asset];
        uint256 eligible = position.eligibleShares;
        uint256 accrued;
        if (eligible != 0 && book.indexRay > position.checkpoints[asset]) {
            accrued = Math.mulDiv(eligible, book.indexRay - position.checkpoints[asset], RAY);
        }
        uint256 forfeited = eligible == 0 ? 0 : Math.mulDiv(accrued, eligibleLoss, eligible);
        uint256 survivor = accrued - forfeited;
        if (survivor != 0) {
            if (position.claimable[asset] == 0) ++position.claimAssetCount;
            position.claimable[asset] += survivor;
            rs.totalClaimable[basketId][asset] += survivor;
            book.crystallizedAmount += survivor;
        }
        position.checkpoints[asset] = book.indexRay;
        if (forfeited == 0) return;
        uint256 bounty = Math.mulDiv(forfeited, bountyBps, LibBasket.BPS);
        if (bounty != 0) {
            LibMorpho.creditSyncBounty(keeper, asset, bounty);
            book.indexedAmount -= bounty;
        }
        uint256 remainder = forfeited - bounty;
        uint256 otherEligible = rs.totalEligibleShares[basketId] - eligible;
        if (remainder != 0 && otherEligible != 0) {
            book.indexRay += Math.mulDiv(remainder, RAY, otherEligible);
            position.checkpoints[asset] = book.indexRay;
        } else if (remainder != 0) {
            LibGlobalRewards.accrueReservedTreasuryFee(asset, remainder);
            book.indexedAmount -= remainder;
        }
    }

    function _increasePending(RewardStorage storage rs, uint256 positionId, uint256 basketId, uint256 amount) private {
        PositionRewards storage position = rs.positions[positionId][basketId];
        EligibilityBook storage book = rs.eligibility[basketId];
        uint256 priorPending = position.pendingShares;
        uint256 priorCredit;
        if (priorPending != 0) {
            _removePendingBucket(book, position.eligibleAt, priorPending);
            if (block.timestamp > position.pendingStartTime) {
                priorCredit = block.timestamp - position.pendingStartTime;
                if (priorCredit > REWARD_ELIGIBILITY_DELAY) priorCredit = REWARD_ELIGIBILITY_DELAY;
            }
        }
        uint256 totalPending = priorPending + amount;
        uint256 weightedCredit = priorPending == 0 ? 0 : Math.mulDiv(priorPending, priorCredit, totalPending);
        uint256 pendingStart = block.timestamp - weightedCredit;
        uint40 eligibleAt = _eligibleAt(pendingStart);
        position.pendingShares = totalPending;
        position.pendingStartTime = uint40(pendingStart);
        position.eligibleAt = eligibleAt;
        book.pendingShares += amount;
        _addPendingBucket(book, eligibleAt, totalPending);
    }

    function _decreaseEligibility(RewardStorage storage rs, uint256 positionId, uint256 basketId, uint256 amount)
        private
    {
        PositionRewards storage position = rs.positions[positionId][basketId];
        EligibilityBook storage book = rs.eligibility[basketId];
        uint256 pendingReduction = amount < position.pendingShares ? amount : position.pendingShares;
        if (pendingReduction != 0) {
            uint256 priorPending = position.pendingShares;
            _removePendingBucket(book, position.eligibleAt, priorPending);
            position.pendingShares = priorPending - pendingReduction;
            book.pendingShares -= pendingReduction;
            if (position.pendingShares == 0) {
                position.pendingStartTime = 0;
                position.eligibleAt = 0;
            } else {
                _addPendingBucket(book, position.eligibleAt, position.pendingShares);
            }
        }
        uint256 eligibleReduction = amount - pendingReduction;
        if (eligibleReduction != 0) {
            position.eligibleShares -= eligibleReduction;
            rs.totalEligibleShares[basketId] -= eligibleReduction;
        }
    }

    function _syncMatured(
        RewardStorage storage rs,
        PositionRewards storage position,
        uint256 positionId,
        uint256 basketId,
        LibBasket.Basket storage configured
    ) private {
        uint256 shares = position.pendingShares;
        if (shares == 0) return;
        uint40 epoch = uint40(uint256(position.eligibleAt) / REWARD_BUCKET_SIZE);
        RewardBook storage primary = rs.books[basketId][configured.token];
        if (!primary.activationRecorded[epoch]) return;
        _settleMaturedAsset(rs, position, positionId, basketId, configured.token, shares, epoch);
        uint256 length = configured.assets.length;
        for (uint256 i; i < length; ++i) {
            _settleMaturedAsset(rs, position, positionId, basketId, configured.assets[i], shares, epoch);
        }
        position.eligibleShares += shares;
        position.pendingShares = 0;
        position.pendingStartTime = 0;
        position.eligibleAt = 0;
    }

    function _settleMaturedAsset(
        RewardStorage storage rs,
        PositionRewards storage position,
        uint256,
        uint256 basketId,
        address asset,
        uint256 shares,
        uint40 epoch
    ) private {
        RewardBook storage book = rs.books[basketId][asset];
        uint256 activationIndex = book.activationIndexRay[epoch];
        uint256 added;
        if (book.indexRay > activationIndex) added = Math.mulDiv(shares, book.indexRay - activationIndex, RAY);
        if (added != 0) {
            if (position.claimable[asset] == 0) ++position.claimAssetCount;
            position.claimable[asset] += added;
            rs.totalClaimable[basketId][asset] += added;
            book.crystallizedAmount += added;
        }
        position.checkpoints[asset] = book.indexRay;
    }

    function _rollMatured(RewardStorage storage rs, uint256 basketId, LibBasket.Basket storage configured) private {
        EligibilityBook storage book = rs.eligibility[basketId];
        uint40 currentEpoch = uint40(block.timestamp / REWARD_BUCKET_SIZE);
        uint40 nextEpoch = book.nextBucketEpoch;
        if (nextEpoch == 0) {
            book.nextBucketEpoch = currentEpoch + 1;
            return;
        }
        if (currentEpoch < nextEpoch) return;
        uint256 elapsed = uint256(currentEpoch - nextEpoch) + 1;
        if (elapsed > REWARD_BUCKET_COUNT) elapsed = REWARD_BUCKET_COUNT;
        uint8 cursor = book.bucketCursor;
        for (uint256 i; i < elapsed; ++i) {
            uint8 index = uint8((uint256(cursor) + i) % REWARD_BUCKET_COUNT);
            uint256 shares = book.pendingBuckets[index];
            if (shares != 0) {
                uint40 epoch = nextEpoch + uint40(i);
                book.pendingBuckets[index] = 0;
                book.pendingShares -= shares;
                rs.totalEligibleShares[basketId] += shares;
                _recordActivation(rs.books[basketId][configured.token], epoch);
                uint256 assetsLength = configured.assets.length;
                for (uint256 j; j < assetsLength; ++j) {
                    _recordActivation(rs.books[basketId][configured.assets[j]], epoch);
                }
            }
        }
        if (uint256(currentEpoch - nextEpoch) + 1 >= REWARD_BUCKET_COUNT) {
            book.nextBucketEpoch = currentEpoch + 1;
            book.bucketCursor = 0;
        } else {
            book.nextBucketEpoch = nextEpoch + uint40(elapsed);
            book.bucketCursor = uint8((uint256(cursor) + elapsed) % REWARD_BUCKET_COUNT);
        }
    }

    function _recordActivation(RewardBook storage book, uint40 epoch) private {
        book.activationIndexRay[epoch] = book.indexRay;
        book.activationRecorded[epoch] = true;
    }

    function _eligibleAt(uint256 pendingStart) private pure returns (uint40) {
        uint256 raw = pendingStart + REWARD_ELIGIBILITY_DELAY;
        return uint40(((raw + REWARD_BUCKET_SIZE - 1) / REWARD_BUCKET_SIZE) * REWARD_BUCKET_SIZE);
    }

    function _addPendingBucket(EligibilityBook storage book, uint40 eligibleAt, uint256 amount) private {
        uint40 epoch = uint40(uint256(eligibleAt) / REWARD_BUCKET_SIZE);
        uint256 offset = uint256(epoch - book.nextBucketEpoch);
        uint8 index = uint8((uint256(book.bucketCursor) + offset) % REWARD_BUCKET_COUNT);
        book.pendingBuckets[index] += amount;
    }

    function _removePendingBucket(EligibilityBook storage book, uint40 eligibleAt, uint256 amount) private {
        uint40 epoch = uint40(uint256(eligibleAt) / REWARD_BUCKET_SIZE);
        uint256 offset = uint256(epoch - book.nextBucketEpoch);
        uint8 index = uint8((uint256(book.bucketCursor) + offset) % REWARD_BUCKET_COUNT);
        book.pendingBuckets[index] -= amount;
    }

    function _duePendingShares(EligibilityBook storage book) private view returns (uint256 total) {
        uint40 nextEpoch = book.nextBucketEpoch;
        if (nextEpoch == 0) return 0;
        uint40 currentEpoch = uint40(block.timestamp / REWARD_BUCKET_SIZE);
        if (currentEpoch < nextEpoch) return 0;
        uint256 elapsed = uint256(currentEpoch - nextEpoch) + 1;
        if (elapsed > REWARD_BUCKET_COUNT) elapsed = REWARD_BUCKET_COUNT;
        for (uint256 i; i < elapsed; ++i) {
            total += book.pendingBuckets[uint8((uint256(book.bucketCursor) + i) % REWARD_BUCKET_COUNT)];
        }
    }
}
