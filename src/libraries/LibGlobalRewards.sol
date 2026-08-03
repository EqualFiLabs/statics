// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IStaticsGlobalRewards} from "../interfaces/IStaticsGlobalRewards.sol";
import {LibBasket} from "./LibBasket.sol";
import {LibCustody} from "./LibCustody.sol";
import {LibPosition} from "../position/LibPosition.sol";

library LibGlobalRewards {
    using SafeCast for uint256;

    bytes32 internal constant REWARD_STORAGE_POSITION = keccak256("statics.storage.global.rewards.v3");
    uint256 internal constant RAY = 1e27;
    uint256 internal constant MAX_REWARD_ASSETS_PER_POSITION = 64;
    uint256 internal constant REWARD_ELIGIBILITY_DELAY = 24 hours;
    uint256 internal constant REWARD_BUCKET_SIZE = 1 hours;
    uint8 internal constant REWARD_BUCKET_COUNT = 25;
    uint256 internal constant STAKER_SHARE_BPS = 9_000;

    struct RewardBook {
        uint256 eligibleStake;
        uint256 pendingStake;
        uint256 indexRay;
        uint256 indexedAmount;
        uint256 crystallizedAmount;
        uint40 nextBucketEpoch;
        uint8 bucketCursor;
        uint256[25] pendingBuckets;
        mapping(uint40 epoch => uint256 indexRay) activationIndexRay;
        mapping(uint40 epoch => bool recorded) activationRecorded;
    }

    struct PositionSelection {
        uint256 eligibleStake;
        uint256 pendingStake;
        uint256 checkpointRay;
        uint40 pendingStartTime;
        uint40 eligibleAt;
    }

    struct StakePosition {
        uint256 balance;
        uint256 claimAssetCount;
        address[] optedInAssets;
        mapping(address asset => uint256 indexPlusOne) optedInIndexPlusOne;
        mapping(address asset => PositionSelection selection) selections;
        mapping(address asset => uint256 amount) claimable;
    }

    struct RewardStorage {
        address stakingToken;
        uint256 totalStaked;
        mapping(address asset => RewardBook book) books;
        mapping(uint256 positionId => StakePosition position) positions;
        mapping(address asset => uint256 amount) totalClaimable;
        mapping(address asset => uint256 amount) treasuryAccrued;
    }

    error InvalidStakingToken();
    error InvalidRewardAsset(address asset);
    error RewardAssetAlreadyOptedIn(uint256 positionId, address asset);
    error RewardAssetNotOptedIn(uint256 positionId, address asset);
    error RewardAssetLimitExceeded(uint256 positionId);
    error InvalidMaturitySchedule(uint40 eligibleAt);

    function rewardStorage() internal pure returns (RewardStorage storage rs) {
        bytes32 position = REWARD_STORAGE_POSITION;
        assembly ("memory-safe") {
            rs.slot := position
        }
    }

    function initialize(address stakingToken_) internal {
        if (stakingToken_ == address(0) || stakingToken_.code.length == 0) revert InvalidStakingToken();
        RewardStorage storage rs = rewardStorage();
        if (rs.stakingToken != address(0)) revert InvalidStakingToken();
        rs.stakingToken = stakingToken_;
    }

    function accrueNonSwapFee(bytes32 sourceAccount, address asset, uint256 grossFee) internal {
        if (grossFee == 0) return;
        RewardStorage storage rs = rewardStorage();
        LibCustody.moveReservation(sourceAccount, LibCustody.feeAccount(), asset, grossFee);
        RewardBook storage book = rs.books[asset];
        _rollMatured(asset, book);
        uint256 stakerAmount;
        if (book.eligibleStake != 0) {
            stakerAmount = Math.mulDiv(grossFee, STAKER_SHARE_BPS, LibBasket.BPS);
            _increaseIndex(book, stakerAmount, book.eligibleStake);
        }
        uint256 treasuryAmount = grossFee - stakerAmount;
        rs.treasuryAccrued[asset] += treasuryAmount;
        emit IStaticsGlobalRewards.GlobalFeeAccrued(asset, grossFee, stakerAmount, treasuryAmount, book.indexRay);
    }

    function accrueReservedSwapStakerFee(address asset, uint256 amount) internal {
        if (amount == 0) return;
        RewardStorage storage rs = rewardStorage();
        RewardBook storage book = rs.books[asset];
        _rollMatured(asset, book);
        if (book.eligibleStake == 0) revert InvalidRewardAsset(asset);
        _increaseIndex(book, amount, book.eligibleStake);
        emit IStaticsGlobalRewards.GlobalFeeAccrued(asset, amount, amount, 0, book.indexRay);
    }

    function accrueReservedTreasuryFee(address asset, uint256 amount) internal {
        if (amount == 0) return;
        rewardStorage().treasuryAccrued[asset] += amount;
        emit IStaticsGlobalRewards.GlobalFeeAccrued(asset, amount, 0, amount, 0);
    }

    function optIn(uint256 positionId, address asset) internal {
        if (asset == address(0)) revert InvalidRewardAsset(asset);
        RewardStorage storage rs = rewardStorage();
        StakePosition storage position = rs.positions[positionId];
        if (position.optedInIndexPlusOne[asset] != 0) revert RewardAssetAlreadyOptedIn(positionId, asset);
        if (position.optedInAssets.length == MAX_REWARD_ASSETS_PER_POSITION) {
            revert RewardAssetLimitExceeded(positionId);
        }
        RewardBook storage book = rs.books[asset];
        _rollMatured(asset, book);
        position.optedInAssets.push(asset);
        position.optedInIndexPlusOne[asset] = position.optedInAssets.length;
        PositionSelection storage selection = position.selections[asset];
        selection.checkpointRay = book.indexRay;
        if (position.balance != 0) _increasePending(positionId, asset, selection, book, position.balance);
        emit IStaticsGlobalRewards.RewardAssetOptedIn(positionId, asset, selection.pendingStake, selection.eligibleAt);
    }

    function optOut(uint256 positionId, address asset) internal {
        RewardStorage storage rs = rewardStorage();
        StakePosition storage position = rs.positions[positionId];
        uint256 indexPlusOne = position.optedInIndexPlusOne[asset];
        if (indexPlusOne == 0) revert RewardAssetNotOptedIn(positionId, asset);
        settleAsset(positionId, asset);
        RewardBook storage book = rs.books[asset];
        PositionSelection storage selection = position.selections[asset];
        uint256 removedEligible = selection.eligibleStake;
        uint256 removedPending = selection.pendingStake;
        if (removedEligible != 0) book.eligibleStake -= removedEligible;
        if (removedPending != 0) {
            _removePendingBucket(book, selection.eligibleAt, removedPending);
            book.pendingStake -= removedPending;
        }
        _removeOptIn(position, asset, indexPlusOne);
        _routeDustIfEmpty(rs, asset, book);
        emit IStaticsGlobalRewards.RewardAssetOptedOut(positionId, asset, removedEligible, removedPending);
    }

    function increaseStake(uint256 positionId, uint256 amount) internal {
        RewardStorage storage rs = rewardStorage();
        StakePosition storage position = rs.positions[positionId];
        uint256 length = position.optedInAssets.length;
        for (uint256 i; i < length; ++i) {
            address asset = position.optedInAssets[i];
            RewardBook storage book = rs.books[asset];
            _rollMatured(asset, book);
            PositionSelection storage selection = position.selections[asset];
            _settleEligible(rs, position, positionId, asset, selection, book);
            _syncMatured(position, positionId, asset, selection, book);
            _increasePending(positionId, asset, selection, book, amount);
        }
    }

    function decreaseStake(uint256 positionId, uint256 amount) internal {
        RewardStorage storage rs = rewardStorage();
        StakePosition storage position = rs.positions[positionId];
        uint256 length = position.optedInAssets.length;
        for (uint256 i; i < length; ++i) {
            address asset = position.optedInAssets[i];
            RewardBook storage book = rs.books[asset];
            _rollMatured(asset, book);
            PositionSelection storage selection = position.selections[asset];
            _settleEligible(rs, position, positionId, asset, selection, book);
            _syncMatured(position, positionId, asset, selection, book);

            uint256 pendingReduction = amount < selection.pendingStake ? amount : selection.pendingStake;
            if (pendingReduction != 0) {
                _removePendingBucket(book, selection.eligibleAt, pendingReduction);
                selection.pendingStake -= pendingReduction;
                book.pendingStake -= pendingReduction;
                if (selection.pendingStake == 0) {
                    selection.pendingStartTime = 0;
                    selection.eligibleAt = 0;
                }
            }
            uint256 eligibleReduction = amount - pendingReduction;
            if (eligibleReduction != 0) {
                selection.eligibleStake -= eligibleReduction;
                book.eligibleStake -= eligibleReduction;
            }
            _routeDustIfEmpty(rs, asset, book);
        }
    }

    function clearOptInsAfterFullUnstake(uint256 positionId) internal {
        RewardStorage storage rs = rewardStorage();
        StakePosition storage position = rs.positions[positionId];
        while (position.optedInAssets.length != 0) {
            address asset = position.optedInAssets[position.optedInAssets.length - 1];
            position.optedInAssets.pop();
            delete position.optedInIndexPlusOne[asset];
            delete position.selections[asset];
            emit IStaticsGlobalRewards.RewardAssetOptedOut(positionId, asset, 0, 0);
        }
    }

    function settleAsset(uint256 positionId, address asset) internal {
        RewardStorage storage rs = rewardStorage();
        StakePosition storage position = rs.positions[positionId];
        if (position.optedInIndexPlusOne[asset] == 0) return;
        RewardBook storage book = rs.books[asset];
        _rollMatured(asset, book);
        PositionSelection storage selection = position.selections[asset];
        _settleEligible(rs, position, positionId, asset, selection, book);
        _syncMatured(position, positionId, asset, selection, book);
    }

    function pending(uint256 positionId, address asset) internal view returns (uint256 amount) {
        RewardStorage storage rs = rewardStorage();
        StakePosition storage position = rs.positions[positionId];
        amount = position.claimable[asset];
        if (position.optedInIndexPlusOne[asset] == 0) return amount;
        RewardBook storage book = rs.books[asset];
        PositionSelection storage selection = position.selections[asset];
        if (selection.eligibleStake != 0 && book.indexRay > selection.checkpointRay) {
            amount += Math.mulDiv(selection.eligibleStake, book.indexRay - selection.checkpointRay, RAY);
        }
        if (selection.pendingStake != 0) {
            uint40 epoch = uint40(uint256(selection.eligibleAt) / REWARD_BUCKET_SIZE);
            if (book.activationRecorded[epoch]) {
                uint256 activationIndex = book.activationIndexRay[epoch];
                if (book.indexRay > activationIndex) {
                    amount += Math.mulDiv(selection.pendingStake, book.indexRay - activationIndex, RAY);
                }
            }
        }
    }

    function effectiveEligibleStake(RewardBook storage book) internal view returns (uint256 total) {
        total = book.eligibleStake + _duePendingStake(book);
    }

    function effectivePendingStake(RewardBook storage book) internal view returns (uint256) {
        return book.pendingStake - _duePendingStake(book);
    }

    function selectionView(uint256 positionId, address asset)
        internal
        view
        returns (IStaticsGlobalRewards.RewardSelectionView memory result)
    {
        StakePosition storage position = rewardStorage().positions[positionId];
        result.selected = position.optedInIndexPlusOne[asset] != 0;
        if (!result.selected) return result;
        PositionSelection storage selection = position.selections[asset];
        result.eligibleStake = selection.eligibleStake;
        result.pendingStake = selection.pendingStake;
        result.eligibleAt = selection.eligibleAt;
        if (selection.pendingStake == 0) return result;
        RewardBook storage book = rewardStorage().books[asset];
        uint40 epoch = uint40(uint256(selection.eligibleAt) / REWARD_BUCKET_SIZE);
        if (book.activationRecorded[epoch] || block.timestamp >= selection.eligibleAt) {
            result.eligibleStake += result.pendingStake;
            result.pendingStake = 0;
            result.eligibleAt = 0;
        }
    }

    function activateStakingLeg(uint256 positionId) internal {
        bytes32 key = LibPosition.stakingLegKey();
        LibPosition.PositionStorage storage ps = LibPosition.positionStorage();
        if (!ps.activeLeg[positionId][key]) {
            LibPosition.activateLeg(positionId, LibPosition.STAKING_MODULE, bytes32(uint256(1)));
        }
    }

    function deactivateStakingLegIfEmpty(uint256 positionId) internal {
        StakePosition storage position = rewardStorage().positions[positionId];
        if (position.balance != 0 || position.claimAssetCount != 0 || position.optedInAssets.length != 0) return;
        bytes32 key = LibPosition.stakingLegKey();
        LibPosition.PositionStorage storage ps = LibPosition.positionStorage();
        if (ps.activeLeg[positionId][key]) LibPosition.deactivateLeg(positionId, key);
    }

    function isOptedIn(uint256 positionId, address asset) internal view returns (bool) {
        return rewardStorage().positions[positionId].optedInIndexPlusOne[asset] != 0;
    }

    function _removeOptIn(StakePosition storage position, address asset, uint256 indexPlusOne) private {
        uint256 index = indexPlusOne - 1;
        uint256 lastIndex = position.optedInAssets.length - 1;
        if (index != lastIndex) {
            address moved = position.optedInAssets[lastIndex];
            position.optedInAssets[index] = moved;
            position.optedInIndexPlusOne[moved] = indexPlusOne;
        }
        position.optedInAssets.pop();
        delete position.optedInIndexPlusOne[asset];
        delete position.selections[asset];
    }

    function _routeDustIfEmpty(RewardStorage storage rs, address asset, RewardBook storage book) private {
        if (book.eligibleStake != 0 || book.indexedAmount == 0) return;
        uint256 dust = book.indexedAmount - book.crystallizedAmount;
        book.indexedAmount = 0;
        book.crystallizedAmount = 0;
        if (dust == 0) return;
        rs.treasuryAccrued[asset] += dust;
        emit IStaticsGlobalRewards.RewardAssetDustRouted(asset, dust);
    }

    function _increaseIndex(RewardBook storage book, uint256 amount, uint256 denominator) private {
        uint256 delta = Math.mulDiv(amount, RAY, denominator);
        book.indexRay += delta;
        book.indexedAmount += amount;
    }

    function _increasePending(
        uint256 positionId,
        address asset,
        PositionSelection storage selection,
        RewardBook storage book,
        uint256 amount
    ) private {
        uint256 priorPending = selection.pendingStake;
        uint256 priorCredit;
        if (priorPending != 0) {
            _removePendingBucket(book, selection.eligibleAt, priorPending);
            if (block.timestamp > selection.pendingStartTime) {
                priorCredit = block.timestamp - selection.pendingStartTime;
                if (priorCredit > REWARD_ELIGIBILITY_DELAY) priorCredit = REWARD_ELIGIBILITY_DELAY;
            }
        }

        uint256 totalPending = priorPending + amount;
        uint256 weightedCredit = priorPending == 0 ? 0 : Math.mulDiv(priorPending, priorCredit, totalPending);
        uint256 pendingStart = block.timestamp - weightedCredit;
        uint40 eligibleAt = _eligibleAt(pendingStart);

        selection.pendingStake = totalPending;
        selection.pendingStartTime = pendingStart.toUint40();
        selection.eligibleAt = eligibleAt;
        book.pendingStake += amount;
        _addPendingBucket(book, eligibleAt, totalPending);
        emit IStaticsGlobalRewards.RewardStakeScheduled(positionId, asset, totalPending, eligibleAt);
    }

    function _syncMatured(
        StakePosition storage position,
        uint256 positionId,
        address asset,
        PositionSelection storage selection,
        RewardBook storage book
    ) private {
        uint256 pendingStake = selection.pendingStake;
        if (pendingStake == 0) return;
        uint40 eligibleAt = selection.eligibleAt;
        uint40 epoch = uint40(uint256(eligibleAt) / REWARD_BUCKET_SIZE);
        if (!book.activationRecorded[epoch]) return;

        uint256 activationIndex = book.activationIndexRay[epoch];
        uint256 added;
        if (book.indexRay > activationIndex) {
            added = Math.mulDiv(pendingStake, book.indexRay - activationIndex, RAY);
            _increaseClaimable(rewardStorage(), position, asset, added);
            book.crystallizedAmount += added;
        }

        selection.eligibleStake += pendingStake;
        selection.pendingStake = 0;
        selection.pendingStartTime = 0;
        selection.eligibleAt = 0;
        selection.checkpointRay = book.indexRay;
        emit IStaticsGlobalRewards.PositionRewardEligibilityActivated(
            positionId, asset, pendingStake, eligibleAt, activationIndex
        );
    }

    function _settleEligible(
        RewardStorage storage rs,
        StakePosition storage position,
        uint256 positionId,
        address asset,
        PositionSelection storage selection,
        RewardBook storage book
    ) private {
        uint256 priorIndex = selection.checkpointRay;
        uint256 added;
        if (selection.eligibleStake != 0 && book.indexRay > priorIndex) {
            added = Math.mulDiv(selection.eligibleStake, book.indexRay - priorIndex, RAY);
            _increaseClaimable(rs, position, asset, added);
            book.crystallizedAmount += added;
        }
        selection.checkpointRay = book.indexRay;
        emit IStaticsGlobalRewards.PositionRewardSettled(positionId, asset, added);
    }

    function _increaseClaimable(RewardStorage storage rs, StakePosition storage position, address asset, uint256 amount)
        private
    {
        if (amount == 0) return;
        if (position.claimable[asset] == 0) ++position.claimAssetCount;
        position.claimable[asset] += amount;
        rs.totalClaimable[asset] += amount;
    }

    function _rollMatured(address asset, RewardBook storage book) private {
        uint40 currentEpoch = (block.timestamp / REWARD_BUCKET_SIZE).toUint40();
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
            uint40 epoch = nextEpoch + uint40(i);
            uint256 amount = book.pendingBuckets[index];
            if (amount != 0) {
                book.pendingBuckets[index] = 0;
                book.pendingStake -= amount;
                book.eligibleStake += amount;
                book.activationIndexRay[epoch] = book.indexRay;
                book.activationRecorded[epoch] = true;
                emit IStaticsGlobalRewards.RewardBucketMatured(
                    asset, (uint256(epoch) * REWARD_BUCKET_SIZE).toUint40(), amount, book.eligibleStake, book.indexRay
                );
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

    function _addPendingBucket(RewardBook storage book, uint40 eligibleAt, uint256 amount) private {
        uint40 epoch = uint40(uint256(eligibleAt) / REWARD_BUCKET_SIZE);
        uint40 nextEpoch = book.nextBucketEpoch;
        if (epoch < nextEpoch) revert InvalidMaturitySchedule(eligibleAt);
        uint256 offset = uint256(epoch - nextEpoch);
        if (offset >= REWARD_BUCKET_COUNT) revert InvalidMaturitySchedule(eligibleAt);
        uint8 index = uint8((uint256(book.bucketCursor) + offset) % REWARD_BUCKET_COUNT);
        book.pendingBuckets[index] += amount;
    }

    function _removePendingBucket(RewardBook storage book, uint40 eligibleAt, uint256 amount) private {
        uint40 epoch = uint40(uint256(eligibleAt) / REWARD_BUCKET_SIZE);
        uint40 nextEpoch = book.nextBucketEpoch;
        if (epoch < nextEpoch) revert InvalidMaturitySchedule(eligibleAt);
        uint256 offset = uint256(epoch - nextEpoch);
        if (offset >= REWARD_BUCKET_COUNT) revert InvalidMaturitySchedule(eligibleAt);
        uint8 index = uint8((uint256(book.bucketCursor) + offset) % REWARD_BUCKET_COUNT);
        book.pendingBuckets[index] -= amount;
    }

    function _duePendingStake(RewardBook storage book) private view returns (uint256 total) {
        uint40 nextEpoch = book.nextBucketEpoch;
        if (nextEpoch == 0) return 0;
        uint40 currentEpoch = (block.timestamp / REWARD_BUCKET_SIZE).toUint40();
        if (currentEpoch < nextEpoch) return 0;
        uint256 elapsed = uint256(currentEpoch - nextEpoch) + 1;
        if (elapsed > REWARD_BUCKET_COUNT) elapsed = REWARD_BUCKET_COUNT;
        uint8 cursor = book.bucketCursor;
        for (uint256 i; i < elapsed; ++i) {
            total += book.pendingBuckets[uint8((uint256(cursor) + i) % REWARD_BUCKET_COUNT)];
        }
    }

    function _eligibleAt(uint256 pendingStart) private pure returns (uint40) {
        uint256 raw = pendingStart + REWARD_ELIGIBILITY_DELAY;
        uint256 rounded = Math.ceilDiv(raw, REWARD_BUCKET_SIZE) * REWARD_BUCKET_SIZE;
        return rounded.toUint40();
    }
}
