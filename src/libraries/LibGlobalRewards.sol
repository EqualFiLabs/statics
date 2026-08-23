// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IStaticsGlobalRewards} from "../interfaces/IStaticsGlobalRewards.sol";
import {LibBasket} from "./LibBasket.sol";
import {LibCustody} from "./LibCustody.sol";
import {LibPosition} from "../position/LibPosition.sol";
import {LibPositionPortfolio} from "./LibPositionPortfolio.sol";

library LibGlobalRewards {
    using SafeCast for uint256;

    bytes32 internal constant REWARD_STORAGE_POSITION = keccak256("statics.storage.global.rewards.v3");
    uint256 internal constant RAY = 1e27;
    uint256 internal constant MAX_REWARD_ASSETS_PER_POSITION = 64;
    uint256 internal constant MAX_CHECKPOINT_ASSETS = 8;
    uint256 internal constant REWARD_ELIGIBILITY_DELAY = 24 hours;
    uint256 internal constant REWARD_BUCKET_SIZE = 1 hours;
    uint8 internal constant REWARD_BUCKET_COUNT = 25;
    uint256 internal constant STAKER_SHARE_BPS = 9_000;
    uint16 internal constant BASE_REWARD_MULTIPLIER_BPS = 10_000;

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
        uint256 eligibleWeight;
        uint256 pendingWeight;
        uint256[25] pendingWeightBuckets;
        uint32 pendingBucketBitmap;
        bool weightInitialized;
    }

    struct PositionSelection {
        uint256 eligibleStake;
        uint256 pendingStake;
        uint256 checkpointRay;
        uint40 pendingStartTime;
        uint40 eligibleAt;
        uint256 eligibleWeight;
        uint256 pendingWeight;
        bool weightInitialized;
    }

    struct StakePosition {
        uint256 balance;
        uint256 claimAssetCount;
        address[] optedInAssets;
        mapping(address asset => uint256 indexPlusOne) optedInIndexPlusOne;
        mapping(address asset => PositionSelection selection) selections;
        mapping(address asset => uint256 amount) claimable;
        uint16 rewardMultiplierBps;
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
    error InvalidRewardMultiplier(uint16 multiplierBps);
    error InvalidCheckpointAssetCount(uint256 count);
    error RewardBookNeedsCheckpoint(address asset);

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
        if (book.eligibleWeight != 0) {
            stakerAmount = Math.mulDiv(grossFee, STAKER_SHARE_BPS, LibBasket.BPS);
            _increaseIndex(book, stakerAmount, book.eligibleWeight);
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
        if (book.eligibleWeight == 0) revert InvalidRewardAsset(asset);
        _increaseIndex(book, amount, book.eligibleWeight);
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
        LibPositionPortfolio.addGlobalRewardAsset(positionId, asset);
        PositionSelection storage selection = position.selections[asset];
        selection.checkpointRay = book.indexRay;
        selection.weightInitialized = true;
        if (position.balance != 0) {
            _increasePending(positionId, asset, selection, book, position.balance, effectiveRewardMultiplier(position));
        }
        emit IStaticsGlobalRewards.RewardAssetOptedIn(
            positionId, asset, selection.pendingStake, selection.pendingWeight, selection.eligibleAt
        );
    }

    function optOut(uint256 positionId, address asset) internal {
        RewardStorage storage rs = rewardStorage();
        StakePosition storage position = rs.positions[positionId];
        uint256 indexPlusOne = position.optedInIndexPlusOne[asset];
        if (indexPlusOne == 0) revert RewardAssetNotOptedIn(positionId, asset);
        settleAsset(positionId, asset);
        RewardBook storage book = rs.books[asset];
        PositionSelection storage selection = position.selections[asset];
        _ensureSelectionWeight(selection);
        uint256 removedEligible = selection.eligibleStake;
        uint256 removedPending = selection.pendingStake;
        uint256 removedEligibleWeight = selection.eligibleWeight;
        uint256 removedPendingWeight = selection.pendingWeight;
        if (removedEligible != 0) {
            book.eligibleStake -= removedEligible;
            book.eligibleWeight -= removedEligibleWeight;
        }
        if (removedPending != 0) {
            _removePendingBucket(book, selection.eligibleAt, removedPending, removedPendingWeight);
            book.pendingStake -= removedPending;
            book.pendingWeight -= removedPendingWeight;
        }
        _removeOptIn(position, asset, indexPlusOne);
        if (position.claimable[asset] == 0) LibPositionPortfolio.removeGlobalRewardAsset(positionId, asset);
        _routeDustIfEmpty(rs, asset, book);
        emit IStaticsGlobalRewards.RewardAssetOptedOut(
            positionId, asset, removedEligible, removedPending, removedEligibleWeight, removedPendingWeight
        );
    }

    function increaseStake(uint256 positionId, uint256 amount) internal {
        RewardStorage storage rs = rewardStorage();
        StakePosition storage position = rs.positions[positionId];
        uint16 multiplierBps = effectiveRewardMultiplier(position);
        uint256 length = position.optedInAssets.length;
        for (uint256 i; i < length; ++i) {
            address asset = position.optedInAssets[i];
            RewardBook storage book = rs.books[asset];
            _rollMatured(asset, book);
            PositionSelection storage selection = position.selections[asset];
            _ensureSelectionWeight(selection);
            _settleEligible(rs, position, positionId, asset, selection, book);
            _syncMatured(position, positionId, asset, selection, book);
            _increasePending(positionId, asset, selection, book, amount, multiplierBps);
        }
    }

    function decreaseStake(uint256 positionId, uint256 amount) internal {
        RewardStorage storage rs = rewardStorage();
        StakePosition storage position = rs.positions[positionId];
        uint16 multiplierBps = effectiveRewardMultiplier(position);
        uint256 length = position.optedInAssets.length;
        for (uint256 i; i < length; ++i) {
            address asset = position.optedInAssets[i];
            RewardBook storage book = rs.books[asset];
            _rollMatured(asset, book);
            PositionSelection storage selection = position.selections[asset];
            _ensureSelectionWeight(selection);
            _settleEligible(rs, position, positionId, asset, selection, book);
            _syncMatured(position, positionId, asset, selection, book);

            uint256 pendingReduction = amount < selection.pendingStake ? amount : selection.pendingStake;
            if (pendingReduction != 0) {
                uint256 priorPending = selection.pendingStake;
                uint256 priorPendingWeight = selection.pendingWeight;
                _removePendingBucket(book, selection.eligibleAt, priorPending, priorPendingWeight);
                uint256 remainingPending = priorPending - pendingReduction;
                uint256 remainingPendingWeight = _weight(remainingPending, multiplierBps);
                selection.pendingStake = remainingPending;
                selection.pendingWeight = remainingPendingWeight;
                book.pendingStake -= pendingReduction;
                book.pendingWeight = book.pendingWeight - priorPendingWeight + remainingPendingWeight;
                if (remainingPending == 0) {
                    selection.pendingStartTime = 0;
                    selection.eligibleAt = 0;
                } else {
                    _addPendingBucket(book, selection.eligibleAt, remainingPending, remainingPendingWeight);
                }
            }
            uint256 eligibleReduction = amount - pendingReduction;
            if (eligibleReduction != 0) {
                uint256 priorEligible = selection.eligibleStake;
                uint256 priorEligibleWeight = selection.eligibleWeight;
                uint256 remainingEligible = priorEligible - eligibleReduction;
                uint256 remainingEligibleWeight = _weight(remainingEligible, multiplierBps);
                selection.eligibleStake = remainingEligible;
                selection.eligibleWeight = remainingEligibleWeight;
                book.eligibleStake -= eligibleReduction;
                book.eligibleWeight = book.eligibleWeight - priorEligibleWeight + remainingEligibleWeight;
            }
            _routeDustIfEmpty(rs, asset, book);
        }
    }

    function transitionPositionWeight(uint256 positionId, uint16 newMultiplierBps) internal {
        _validateMultiplier(newMultiplierBps);
        RewardStorage storage rs = rewardStorage();
        StakePosition storage position = rs.positions[positionId];
        uint16 previousMultiplierBps = effectiveRewardMultiplier(position);
        if (previousMultiplierBps == newMultiplierBps) {
            position.rewardMultiplierBps = newMultiplierBps;
            return;
        }

        _enforcePositionBooksFresh(rs, position);
        uint256 length = position.optedInAssets.length;
        for (uint256 i; i < length; ++i) {
            address asset = position.optedInAssets[i];
            RewardBook storage book = rs.books[asset];
            PositionSelection storage selection = position.selections[asset];
            _ensureSelectionWeight(selection);
            _settleEligible(rs, position, positionId, asset, selection, book);
            _syncMatured(position, positionId, asset, selection, book);

            uint256 previousEligibleWeight = selection.eligibleWeight;
            uint256 nextEligibleWeight = _weight(selection.eligibleStake, newMultiplierBps);
            selection.eligibleWeight = nextEligibleWeight;
            book.eligibleWeight = book.eligibleWeight - previousEligibleWeight + nextEligibleWeight;

            uint256 previousPendingWeight = selection.pendingWeight;
            if (selection.pendingStake != 0) {
                _removePendingBucket(book, selection.eligibleAt, selection.pendingStake, previousPendingWeight);
                uint256 nextPendingWeight = _weight(selection.pendingStake, newMultiplierBps);
                selection.pendingWeight = nextPendingWeight;
                book.pendingWeight = book.pendingWeight - previousPendingWeight + nextPendingWeight;
                _addPendingBucket(book, selection.eligibleAt, selection.pendingStake, nextPendingWeight);
            }

            emit IStaticsGlobalRewards.PositionRewardWeightChanged(
                positionId, asset, previousMultiplierBps, newMultiplierBps, nextEligibleWeight, selection.pendingWeight
            );
        }
        position.rewardMultiplierBps = newMultiplierBps;
    }

    function checkpointRewardAssets(address[] calldata assets) internal {
        uint256 length = assets.length;
        if (length == 0 || length > MAX_CHECKPOINT_ASSETS) revert InvalidCheckpointAssetCount(length);
        RewardStorage storage rs = rewardStorage();
        for (uint256 i; i < length; ++i) {
            address asset = assets[i];
            if (asset == address(0)) revert InvalidRewardAsset(asset);
            _rollMatured(asset, rs.books[asset]);
            emit IStaticsGlobalRewards.RewardBookCheckpointed(asset);
        }
    }

    function enforcePositionRewardBooksFresh(uint256 positionId) internal view {
        RewardStorage storage rs = rewardStorage();
        _enforcePositionBooksFresh(rs, rs.positions[positionId]);
    }

    function rewardBookNeedsCheckpoint(address asset) internal view returns (bool) {
        return _needsCheckpoint(rewardStorage().books[asset]);
    }

    function effectiveRewardMultiplier(StakePosition storage position) internal view returns (uint16) {
        uint16 multiplierBps = position.rewardMultiplierBps;
        return multiplierBps == 0 ? BASE_REWARD_MULTIPLIER_BPS : multiplierBps;
    }

    function clearOptInsAfterFullUnstake(uint256 positionId) internal {
        RewardStorage storage rs = rewardStorage();
        StakePosition storage position = rs.positions[positionId];
        while (position.optedInAssets.length != 0) {
            address asset = position.optedInAssets[position.optedInAssets.length - 1];
            position.optedInAssets.pop();
            delete position.optedInIndexPlusOne[asset];
            delete position.selections[asset];
            if (position.claimable[asset] == 0) LibPositionPortfolio.removeGlobalRewardAsset(positionId, asset);
            emit IStaticsGlobalRewards.RewardAssetOptedOut(positionId, asset, 0, 0, 0, 0);
        }
    }

    function settleAsset(uint256 positionId, address asset) internal {
        RewardStorage storage rs = rewardStorage();
        StakePosition storage position = rs.positions[positionId];
        if (position.optedInIndexPlusOne[asset] == 0) return;
        RewardBook storage book = rs.books[asset];
        _rollMatured(asset, book);
        PositionSelection storage selection = position.selections[asset];
        _ensureSelectionWeight(selection);
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
        uint256 eligibleWeight = _selectionEligibleWeight(selection);
        if (eligibleWeight != 0 && book.indexRay > selection.checkpointRay) {
            amount += Math.mulDiv(eligibleWeight, book.indexRay - selection.checkpointRay, RAY);
        }
        uint256 pendingWeight = _selectionPendingWeight(selection);
        if (pendingWeight != 0) {
            uint40 epoch = uint40(uint256(selection.eligibleAt) / REWARD_BUCKET_SIZE);
            if (book.activationRecorded[epoch]) {
                uint256 activationIndex = book.activationIndexRay[epoch];
                if (book.indexRay > activationIndex) {
                    amount += Math.mulDiv(pendingWeight, book.indexRay - activationIndex, RAY);
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

    function effectiveEligibleWeight(RewardBook storage book) internal view returns (uint256 total) {
        total = _bookEligibleWeight(book) + _duePendingWeight(book);
    }

    function effectivePendingWeight(RewardBook storage book) internal view returns (uint256) {
        return _bookPendingWeight(book) - _duePendingWeight(book);
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
        result.eligibleWeight = _selectionEligibleWeight(selection);
        result.pendingStake = selection.pendingStake;
        result.pendingWeight = _selectionPendingWeight(selection);
        result.eligibleAt = selection.eligibleAt;
        if (selection.pendingStake == 0) return result;
        RewardBook storage book = rewardStorage().books[asset];
        uint40 epoch = uint40(uint256(selection.eligibleAt) / REWARD_BUCKET_SIZE);
        if (book.activationRecorded[epoch] || block.timestamp >= selection.eligibleAt) {
            result.eligibleStake += result.pendingStake;
            result.eligibleWeight += result.pendingWeight;
            result.pendingStake = 0;
            result.pendingWeight = 0;
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
        if (book.eligibleWeight != 0 || book.indexedAmount == 0) return;
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
        uint256 amount,
        uint16 multiplierBps
    ) private {
        uint256 priorPending = selection.pendingStake;
        uint256 priorPendingWeight = selection.pendingWeight;
        uint256 priorCredit;
        if (priorPending != 0) {
            _removePendingBucket(book, selection.eligibleAt, priorPending, priorPendingWeight);
            if (block.timestamp > selection.pendingStartTime) {
                priorCredit = block.timestamp - selection.pendingStartTime;
                if (priorCredit > REWARD_ELIGIBILITY_DELAY) priorCredit = REWARD_ELIGIBILITY_DELAY;
            }
        }

        uint256 totalPending = priorPending + amount;
        uint256 totalPendingWeight = _weight(totalPending, multiplierBps);
        uint256 weightedCredit = priorPending == 0 ? 0 : Math.mulDiv(priorPending, priorCredit, totalPending);
        uint256 pendingStart = block.timestamp - weightedCredit;
        uint40 eligibleAt = _eligibleAt(pendingStart);

        selection.pendingStake = totalPending;
        selection.pendingWeight = totalPendingWeight;
        selection.pendingStartTime = pendingStart.toUint40();
        selection.eligibleAt = eligibleAt;
        book.pendingStake += amount;
        book.pendingWeight = book.pendingWeight - priorPendingWeight + totalPendingWeight;
        _addPendingBucket(book, eligibleAt, totalPending, totalPendingWeight);
        emit IStaticsGlobalRewards.RewardStakeScheduled(positionId, asset, totalPending, totalPendingWeight, eligibleAt);
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
        uint256 pendingWeight = selection.pendingWeight;
        uint256 added;
        if (book.indexRay > activationIndex) {
            added = Math.mulDiv(pendingWeight, book.indexRay - activationIndex, RAY);
            _increaseClaimable(rewardStorage(), position, asset, added);
            book.crystallizedAmount += added;
        }

        selection.eligibleStake += pendingStake;
        selection.eligibleWeight += pendingWeight;
        selection.pendingStake = 0;
        selection.pendingWeight = 0;
        selection.pendingStartTime = 0;
        selection.eligibleAt = 0;
        selection.checkpointRay = book.indexRay;
        emit IStaticsGlobalRewards.PositionRewardEligibilityActivated(
            positionId, asset, pendingStake, pendingWeight, eligibleAt, activationIndex
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
        if (selection.eligibleWeight != 0 && book.indexRay > priorIndex) {
            added = Math.mulDiv(selection.eligibleWeight, book.indexRay - priorIndex, RAY);
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
        _ensureBookWeights(book);
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
            _matureBucket(asset, book, index, epoch);
        }

        if (uint256(currentEpoch - nextEpoch) + 1 >= REWARD_BUCKET_COUNT) {
            book.nextBucketEpoch = currentEpoch + 1;
            book.bucketCursor = 0;
        } else {
            book.nextBucketEpoch = nextEpoch + uint40(elapsed);
            book.bucketCursor = uint8((uint256(cursor) + elapsed) % REWARD_BUCKET_COUNT);
        }
    }

    function _matureBucket(address asset, RewardBook storage book, uint8 index, uint40 epoch) private {
        uint256 stake = book.pendingBuckets[index];
        if (stake == 0) return;
        uint256 weight = book.pendingWeightBuckets[index];
        book.pendingBucketBitmap &= ~(uint32(1) << index);
        book.pendingBuckets[index] = 0;
        book.pendingWeightBuckets[index] = 0;
        book.pendingStake -= stake;
        book.eligibleStake += stake;
        book.pendingWeight -= weight;
        book.eligibleWeight += weight;
        book.activationIndexRay[epoch] = book.indexRay;
        book.activationRecorded[epoch] = true;
        emit IStaticsGlobalRewards.RewardBucketMatured(
            asset,
            (uint256(epoch) * REWARD_BUCKET_SIZE).toUint40(),
            stake,
            weight,
            book.eligibleStake,
            book.eligibleWeight,
            book.indexRay
        );
    }

    function _addPendingBucket(RewardBook storage book, uint40 eligibleAt, uint256 amount, uint256 weight) private {
        uint40 epoch = uint40(uint256(eligibleAt) / REWARD_BUCKET_SIZE);
        uint40 nextEpoch = book.nextBucketEpoch;
        if (epoch < nextEpoch) revert InvalidMaturitySchedule(eligibleAt);
        uint256 offset = uint256(epoch - nextEpoch);
        if (offset >= REWARD_BUCKET_COUNT) revert InvalidMaturitySchedule(eligibleAt);
        uint8 index = uint8((uint256(book.bucketCursor) + offset) % REWARD_BUCKET_COUNT);
        book.pendingBuckets[index] += amount;
        book.pendingWeightBuckets[index] += weight;
        book.pendingBucketBitmap |= uint32(1) << index;
    }

    function _removePendingBucket(RewardBook storage book, uint40 eligibleAt, uint256 amount, uint256 weight) private {
        uint40 epoch = uint40(uint256(eligibleAt) / REWARD_BUCKET_SIZE);
        uint40 nextEpoch = book.nextBucketEpoch;
        if (epoch < nextEpoch) revert InvalidMaturitySchedule(eligibleAt);
        uint256 offset = uint256(epoch - nextEpoch);
        if (offset >= REWARD_BUCKET_COUNT) revert InvalidMaturitySchedule(eligibleAt);
        uint8 index = uint8((uint256(book.bucketCursor) + offset) % REWARD_BUCKET_COUNT);
        book.pendingBuckets[index] -= amount;
        book.pendingWeightBuckets[index] -= weight;
        if (book.pendingBuckets[index] == 0) book.pendingBucketBitmap &= ~(uint32(1) << index);
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

    function _duePendingWeight(RewardBook storage book) private view returns (uint256 total) {
        uint40 nextEpoch = book.nextBucketEpoch;
        if (nextEpoch == 0) return 0;
        uint40 currentEpoch = (block.timestamp / REWARD_BUCKET_SIZE).toUint40();
        if (currentEpoch < nextEpoch) return 0;
        uint256 elapsed = uint256(currentEpoch - nextEpoch) + 1;
        if (elapsed > REWARD_BUCKET_COUNT) elapsed = REWARD_BUCKET_COUNT;
        uint8 cursor = book.bucketCursor;
        bool initialized = book.weightInitialized;
        for (uint256 i; i < elapsed; ++i) {
            uint8 index = uint8((uint256(cursor) + i) % REWARD_BUCKET_COUNT);
            total += initialized ? book.pendingWeightBuckets[index] : book.pendingBuckets[index];
        }
    }

    function _needsCheckpoint(RewardBook storage book) private view returns (bool) {
        if (!book.weightInitialized && (book.eligibleStake != 0 || book.pendingStake != 0)) return true;
        uint40 nextEpoch = book.nextBucketEpoch;
        if (nextEpoch == 0) return false;
        uint40 currentEpoch = (block.timestamp / REWARD_BUCKET_SIZE).toUint40();
        if (currentEpoch < nextEpoch) return false;
        uint256 elapsed = uint256(currentEpoch - nextEpoch) + 1;
        if (elapsed > REWARD_BUCKET_COUNT) elapsed = REWARD_BUCKET_COUNT;
        uint32 bitmap = book.pendingBucketBitmap;
        uint8 cursor = book.bucketCursor;
        if (!book.weightInitialized) {
            for (uint256 i; i < elapsed; ++i) {
                uint8 index = uint8((uint256(cursor) + i) % REWARD_BUCKET_COUNT);
                if (book.pendingBuckets[index] != 0) return true;
            }
        } else {
            for (uint256 i; i < elapsed; ++i) {
                uint8 index = uint8((uint256(cursor) + i) % REWARD_BUCKET_COUNT);
                if (bitmap & (uint32(1) << index) != 0) return true;
            }
        }
        return elapsed >= REWARD_BUCKET_COUNT - 1;
    }

    function _enforcePositionBooksFresh(RewardStorage storage rs, StakePosition storage position) private view {
        uint256 length = position.optedInAssets.length;
        for (uint256 i; i < length; ++i) {
            address asset = position.optedInAssets[i];
            if (_needsCheckpoint(rs.books[asset])) revert RewardBookNeedsCheckpoint(asset);
        }
    }

    function _ensureBookWeights(RewardBook storage book) private {
        if (book.weightInitialized) return;
        book.eligibleWeight = book.eligibleStake;
        book.pendingWeight = book.pendingStake;
        uint32 bitmap;
        for (uint256 i; i < REWARD_BUCKET_COUNT; ++i) {
            uint256 pendingAmount = book.pendingBuckets[i];
            book.pendingWeightBuckets[i] = pendingAmount;
            if (pendingAmount != 0) bitmap |= uint32(1) << uint32(i);
        }
        book.pendingBucketBitmap = bitmap;
        book.weightInitialized = true;
    }

    function _ensureSelectionWeight(PositionSelection storage selection) private {
        if (selection.weightInitialized) return;
        selection.eligibleWeight = selection.eligibleStake;
        selection.pendingWeight = selection.pendingStake;
        selection.weightInitialized = true;
    }

    function _bookEligibleWeight(RewardBook storage book) private view returns (uint256) {
        return book.weightInitialized ? book.eligibleWeight : book.eligibleStake;
    }

    function _bookPendingWeight(RewardBook storage book) private view returns (uint256) {
        return book.weightInitialized ? book.pendingWeight : book.pendingStake;
    }

    function _selectionEligibleWeight(PositionSelection storage selection) private view returns (uint256) {
        return selection.weightInitialized ? selection.eligibleWeight : selection.eligibleStake;
    }

    function _selectionPendingWeight(PositionSelection storage selection) private view returns (uint256) {
        return selection.weightInitialized ? selection.pendingWeight : selection.pendingStake;
    }

    function _eligibleAt(uint256 pendingStart) private pure returns (uint40) {
        uint256 raw = pendingStart + REWARD_ELIGIBILITY_DELAY;
        uint256 rounded = Math.ceilDiv(raw, REWARD_BUCKET_SIZE) * REWARD_BUCKET_SIZE;
        return rounded.toUint40();
    }

    function _weight(uint256 stake, uint16 multiplierBps) private pure returns (uint256) {
        return Math.mulDiv(stake, multiplierBps, BASE_REWARD_MULTIPLIER_BPS);
    }

    function _validateMultiplier(uint16 multiplierBps) private pure {
        if (multiplierBps < BASE_REWARD_MULTIPLIER_BPS) revert InvalidRewardMultiplier(multiplierBps);
    }
}
