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

    bytes32 internal constant REWARD_STORAGE_POSITION = keccak256("statics.storage.global.rewards.v4");
    uint256 internal constant RAY = 1e27;
    uint256 internal constant MAX_REWARD_ASSETS_PER_POSITION = 64;
    uint256 internal constant MAX_CHECKPOINT_ASSETS = 8;
    uint256 internal constant REWARD_ELIGIBILITY_DELAY = 24 hours;
    uint256 internal constant REWARD_BUCKET_SIZE = 1 hours;
    uint8 internal constant REWARD_BUCKET_COUNT = 25;
    uint256 internal constant STAKER_SHARE_BPS = 9_000;
    uint256 internal constant MULTIPLIER_BPS = 10_000;

    struct RewardBook {
        uint256 actualEligibleStake;
        uint256 actualPendingStake;
        uint256 effectiveEligibleWeight;
        uint256 effectivePendingWeight;
        uint256 indexRay;
        uint256 indexRemainder;
        uint256 indexedAmount;
        uint256 crystallizedAmount;
        uint40 nextBucketEpoch;
        uint8 bucketCursor;
        uint32 pendingBucketBitmap;
        uint256[25] pendingStakeBuckets;
        uint256[25] pendingWeightBuckets;
        mapping(uint40 epoch => uint256 indexRay) activationIndexRay;
        mapping(uint40 epoch => bool recorded) activationRecorded;
    }

    struct PositionSelection {
        uint256 actualEligibleStake;
        uint256 actualPendingStake;
        uint256 effectiveEligibleWeight;
        uint256 effectivePendingWeight;
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
    error InvalidMultiplier(uint16 multiplierBps);
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
        if (book.effectiveEligibleWeight != 0) {
            stakerAmount = Math.mulDiv(grossFee, STAKER_SHARE_BPS, LibBasket.BPS);
            _increaseIndex(book, stakerAmount, book.effectiveEligibleWeight);
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
        if (book.effectiveEligibleWeight == 0) revert InvalidRewardAsset(asset);
        _increaseIndex(book, amount, book.effectiveEligibleWeight);
        emit IStaticsGlobalRewards.GlobalFeeAccrued(asset, amount, amount, 0, book.indexRay);
    }

    function accrueReservedTreasuryFee(address asset, uint256 amount) internal {
        if (amount == 0) return;
        rewardStorage().treasuryAccrued[asset] += amount;
        emit IStaticsGlobalRewards.GlobalFeeAccrued(asset, amount, 0, amount, 0);
    }

    function optIn(uint256 positionId, address asset, uint16 multiplierBps) internal {
        if (asset == address(0)) revert InvalidRewardAsset(asset);
        _validateMultiplier(multiplierBps);
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
        if (position.balance != 0) {
            _increasePending(positionId, asset, selection, book, position.balance, multiplierBps);
        }
        emit IStaticsGlobalRewards.RewardAssetOptedIn(
            positionId, asset, selection.actualPendingStake, selection.effectivePendingWeight, selection.eligibleAt
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
        uint256 removedActualEligible = selection.actualEligibleStake;
        uint256 removedActualPending = selection.actualPendingStake;
        uint256 removedEligibleWeight = selection.effectiveEligibleWeight;
        uint256 removedPendingWeight = selection.effectivePendingWeight;
        if (removedEligibleWeight != 0) {
            book.actualEligibleStake -= removedActualEligible;
            book.effectiveEligibleWeight -= removedEligibleWeight;
        }
        if (removedPendingWeight != 0) {
            _removePendingBucket(book, selection.eligibleAt, removedActualPending, removedPendingWeight);
            book.actualPendingStake -= removedActualPending;
            book.effectivePendingWeight -= removedPendingWeight;
        }
        _removeOptIn(position, asset, indexPlusOne);
        if (position.claimable[asset] == 0) LibPositionPortfolio.removeGlobalRewardAsset(positionId, asset);
        _routeDustIfEmpty(rs, asset, book);
        emit IStaticsGlobalRewards.RewardAssetOptedOut(
            positionId, asset, removedActualEligible, removedActualPending, removedEligibleWeight, removedPendingWeight
        );
    }

    function increaseStake(uint256 positionId, uint256 amount, uint16 multiplierBps) internal {
        _validateMultiplier(multiplierBps);
        RewardStorage storage rs = rewardStorage();
        StakePosition storage position = rs.positions[positionId];
        _enforcePositionBooksFresh(rs, position);
        uint256 length = position.optedInAssets.length;
        for (uint256 i; i < length; ++i) {
            address asset = position.optedInAssets[i];
            RewardBook storage book = rs.books[asset];
            _rollMatured(asset, book);
            PositionSelection storage selection = position.selections[asset];
            _settleEligible(rs, position, positionId, asset, selection, book);
            _syncMatured(position, positionId, asset, selection, book);
            _increasePending(positionId, asset, selection, book, amount, multiplierBps);
        }
    }

    function decreaseStake(uint256 positionId, uint256 amount, uint16 multiplierBps) internal {
        _validateMultiplier(multiplierBps);
        RewardStorage storage rs = rewardStorage();
        StakePosition storage position = rs.positions[positionId];
        _enforcePositionBooksFresh(rs, position);
        uint256 length = position.optedInAssets.length;
        for (uint256 i; i < length; ++i) {
            address asset = position.optedInAssets[i];
            RewardBook storage book = rs.books[asset];
            _rollMatured(asset, book);
            PositionSelection storage selection = position.selections[asset];
            _settleEligible(rs, position, positionId, asset, selection, book);
            _syncMatured(position, positionId, asset, selection, book);

            uint256 pendingReduction = amount < selection.actualPendingStake ? amount : selection.actualPendingStake;
            if (pendingReduction != 0) {
                uint256 priorActual = selection.actualPendingStake;
                uint256 priorWeight = selection.effectivePendingWeight;
                _removePendingBucket(book, selection.eligibleAt, priorActual, priorWeight);
                uint256 remainingActual = priorActual - pendingReduction;
                uint256 remainingWeight = _weight(remainingActual, multiplierBps);
                selection.actualPendingStake = remainingActual;
                selection.effectivePendingWeight = remainingWeight;
                book.actualPendingStake -= pendingReduction;
                book.effectivePendingWeight = book.effectivePendingWeight - priorWeight + remainingWeight;
                if (remainingActual == 0) {
                    selection.pendingStartTime = 0;
                    selection.eligibleAt = 0;
                } else {
                    _addPendingBucket(book, selection.eligibleAt, remainingActual, remainingWeight);
                }
            }
            uint256 eligibleReduction = amount - pendingReduction;
            if (eligibleReduction != 0) {
                uint256 priorActual = selection.actualEligibleStake;
                uint256 priorWeight = selection.effectiveEligibleWeight;
                uint256 remainingActual = priorActual - eligibleReduction;
                uint256 remainingWeight = _weight(remainingActual, multiplierBps);
                selection.actualEligibleStake = remainingActual;
                selection.effectiveEligibleWeight = remainingWeight;
                book.actualEligibleStake -= eligibleReduction;
                book.effectiveEligibleWeight = book.effectiveEligibleWeight - priorWeight + remainingWeight;
            }
            _routeDustIfEmpty(rs, asset, book);
        }
    }

    function transitionPositionWeight(uint256 positionId, uint16 previousMultiplierBps, uint16 newMultiplierBps)
        internal
    {
        _validateMultiplier(previousMultiplierBps);
        _validateMultiplier(newMultiplierBps);
        RewardStorage storage rs = rewardStorage();
        StakePosition storage position = rs.positions[positionId];
        uint256 length = position.optedInAssets.length;
        for (uint256 i; i < length; ++i) {
            address asset = position.optedInAssets[i];
            if (_needsCheckpoint(rs.books[asset])) revert RewardBookNeedsCheckpoint(asset);
        }
        for (uint256 i; i < length; ++i) {
            address asset = position.optedInAssets[i];
            RewardBook storage book = rs.books[asset];
            PositionSelection storage selection = position.selections[asset];
            _settleEligible(rs, position, positionId, asset, selection, book);
            _syncMatured(position, positionId, asset, selection, book);

            uint256 oldEligibleWeight = selection.effectiveEligibleWeight;
            uint256 newEligibleWeight = _weight(selection.actualEligibleStake, newMultiplierBps);
            selection.effectiveEligibleWeight = newEligibleWeight;
            book.effectiveEligibleWeight = book.effectiveEligibleWeight - oldEligibleWeight + newEligibleWeight;

            uint256 oldPendingWeight = selection.effectivePendingWeight;
            if (selection.actualPendingStake != 0) {
                _removePendingBucket(
                    book, selection.eligibleAt, selection.actualPendingStake, selection.effectivePendingWeight
                );
                uint256 newPendingWeight = _weight(selection.actualPendingStake, newMultiplierBps);
                selection.effectivePendingWeight = newPendingWeight;
                book.effectivePendingWeight = book.effectivePendingWeight - oldPendingWeight + newPendingWeight;
                _addPendingBucket(book, selection.eligibleAt, selection.actualPendingStake, newPendingWeight);
            }
            emit IStaticsGlobalRewards.PositionRewardWeightChanged(
                positionId,
                asset,
                previousMultiplierBps,
                newMultiplierBps,
                newEligibleWeight,
                selection.effectivePendingWeight
            );
        }
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

    function rewardBookNeedsCheckpoint(address asset) internal view returns (bool) {
        return _needsCheckpoint(rewardStorage().books[asset]);
    }

    function clearOptInsAfterFullUnstake(uint256 positionId) internal {
        StakePosition storage position = rewardStorage().positions[positionId];
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
        if (selection.effectiveEligibleWeight != 0 && book.indexRay > selection.checkpointRay) {
            amount += Math.mulDiv(selection.effectiveEligibleWeight, book.indexRay - selection.checkpointRay, RAY);
        }
        if (selection.effectivePendingWeight != 0) {
            uint40 epoch = uint40(uint256(selection.eligibleAt) / REWARD_BUCKET_SIZE);
            if (book.activationRecorded[epoch]) {
                uint256 activationIndex = book.activationIndexRay[epoch];
                if (book.indexRay > activationIndex) {
                    amount += Math.mulDiv(selection.effectivePendingWeight, book.indexRay - activationIndex, RAY);
                }
            }
        }
    }

    function effectiveActualEligibleStake(RewardBook storage book) internal view returns (uint256 total) {
        total = book.actualEligibleStake + _duePending(book, false);
    }

    function effectiveActualPendingStake(RewardBook storage book) internal view returns (uint256) {
        return book.actualPendingStake - _duePending(book, false);
    }

    function effectiveEligibleWeight(RewardBook storage book) internal view returns (uint256 total) {
        total = book.effectiveEligibleWeight + _duePending(book, true);
    }

    function effectivePendingWeight(RewardBook storage book) internal view returns (uint256) {
        return book.effectivePendingWeight - _duePending(book, true);
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
        result.actualEligibleStake = selection.actualEligibleStake;
        result.actualPendingStake = selection.actualPendingStake;
        result.effectiveEligibleWeight = selection.effectiveEligibleWeight;
        result.effectivePendingWeight = selection.effectivePendingWeight;
        result.eligibleAt = selection.eligibleAt;
        if (selection.actualPendingStake == 0) return result;
        RewardBook storage book = rewardStorage().books[asset];
        uint40 epoch = uint40(uint256(selection.eligibleAt) / REWARD_BUCKET_SIZE);
        if (book.activationRecorded[epoch] || block.timestamp >= selection.eligibleAt) {
            result.actualEligibleStake += result.actualPendingStake;
            result.actualPendingStake = 0;
            result.effectiveEligibleWeight += result.effectivePendingWeight;
            result.effectivePendingWeight = 0;
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
        if (book.effectiveEligibleWeight != 0) return;
        book.indexRemainder = 0;
        if (book.indexedAmount == 0) return;
        uint256 dust = book.indexedAmount - book.crystallizedAmount;
        book.indexedAmount = 0;
        book.crystallizedAmount = 0;
        if (dust == 0) return;
        rs.treasuryAccrued[asset] += dust;
        emit IStaticsGlobalRewards.RewardAssetDustRouted(asset, dust);
    }

    function _increaseIndex(RewardBook storage book, uint256 amount, uint256 denominator) private {
        uint256 priorRemainder = book.indexRemainder;
        uint256 delta = Math.mulDiv(amount, RAY, denominator) + priorRemainder / denominator;
        uint256 remainder = mulmod(amount, RAY, denominator) + priorRemainder % denominator;
        if (remainder >= denominator) {
            ++delta;
            remainder -= denominator;
        }
        book.indexRay += delta;
        book.indexRemainder = remainder;
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
        uint256 priorPending = selection.actualPendingStake;
        uint256 priorWeight = selection.effectivePendingWeight;
        uint256 priorCredit;
        if (priorPending != 0) {
            _removePendingBucket(book, selection.eligibleAt, priorPending, priorWeight);
            if (block.timestamp > selection.pendingStartTime) {
                priorCredit = block.timestamp - selection.pendingStartTime;
                if (priorCredit > REWARD_ELIGIBILITY_DELAY) priorCredit = REWARD_ELIGIBILITY_DELAY;
            }
        }

        uint256 totalPending = priorPending + amount;
        uint256 totalWeight = _weight(totalPending, multiplierBps);
        uint256 weightedCredit = priorPending == 0 ? 0 : Math.mulDiv(priorPending, priorCredit, totalPending);
        uint256 pendingStart = block.timestamp - weightedCredit;
        uint40 eligibleAt = _eligibleAt(pendingStart);

        selection.actualPendingStake = totalPending;
        selection.effectivePendingWeight = totalWeight;
        selection.pendingStartTime = pendingStart.toUint40();
        selection.eligibleAt = eligibleAt;
        book.actualPendingStake += amount;
        book.effectivePendingWeight = book.effectivePendingWeight - priorWeight + totalWeight;
        _addPendingBucket(book, eligibleAt, totalPending, totalWeight);
        emit IStaticsGlobalRewards.RewardStakeScheduled(positionId, asset, totalPending, totalWeight, eligibleAt);
    }

    function _syncMatured(
        StakePosition storage position,
        uint256 positionId,
        address asset,
        PositionSelection storage selection,
        RewardBook storage book
    ) private {
        uint256 pendingStake = selection.actualPendingStake;
        if (pendingStake == 0) return;
        uint40 eligibleAt = selection.eligibleAt;
        uint40 epoch = uint40(uint256(eligibleAt) / REWARD_BUCKET_SIZE);
        if (!book.activationRecorded[epoch]) return;

        uint256 activationIndex = book.activationIndexRay[epoch];
        uint256 pendingWeight = selection.effectivePendingWeight;
        uint256 added;
        if (book.indexRay > activationIndex) {
            added = Math.mulDiv(pendingWeight, book.indexRay - activationIndex, RAY);
            _increaseClaimable(rewardStorage(), position, asset, added);
            book.crystallizedAmount += added;
        }

        selection.actualEligibleStake += pendingStake;
        selection.effectiveEligibleWeight += pendingWeight;
        selection.actualPendingStake = 0;
        selection.effectivePendingWeight = 0;
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
        if (selection.effectiveEligibleWeight != 0 && book.indexRay > priorIndex) {
            added = Math.mulDiv(selection.effectiveEligibleWeight, book.indexRay - priorIndex, RAY);
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
        if ((book.pendingBucketBitmap & _bucketMask(cursor, elapsed)) == 0) {
            _advanceBucketWindow(book, currentEpoch, nextEpoch, elapsed);
            return;
        }
        for (uint256 i; i < elapsed; ++i) {
            uint8 index = uint8((uint256(cursor) + i) % REWARD_BUCKET_COUNT);
            uint40 epoch = nextEpoch + uint40(i);
            uint256 stake = book.pendingStakeBuckets[index];
            uint256 weight = book.pendingWeightBuckets[index];
            if (stake != 0) {
                book.pendingBucketBitmap &= ~(uint32(1) << index);
                book.pendingStakeBuckets[index] = 0;
                book.pendingWeightBuckets[index] = 0;
                book.actualPendingStake -= stake;
                book.actualEligibleStake += stake;
                book.effectivePendingWeight -= weight;
                book.effectiveEligibleWeight += weight;
                book.activationIndexRay[epoch] = book.indexRay;
                book.activationRecorded[epoch] = true;
                emit IStaticsGlobalRewards.RewardBucketMatured(
                    asset,
                    (uint256(epoch) * REWARD_BUCKET_SIZE).toUint40(),
                    stake,
                    weight,
                    book.actualEligibleStake,
                    book.effectiveEligibleWeight,
                    book.indexRay
                );
            }
        }

        _advanceBucketWindow(book, currentEpoch, nextEpoch, elapsed);
    }

    function _addPendingBucket(RewardBook storage book, uint40 eligibleAt, uint256 stake, uint256 weight) private {
        uint8 index = _bucketIndex(book, eligibleAt);
        book.pendingStakeBuckets[index] += stake;
        book.pendingWeightBuckets[index] += weight;
        book.pendingBucketBitmap |= uint32(1) << index;
    }

    function _removePendingBucket(RewardBook storage book, uint40 eligibleAt, uint256 stake, uint256 weight) private {
        uint8 index = _bucketIndex(book, eligibleAt);
        book.pendingStakeBuckets[index] -= stake;
        book.pendingWeightBuckets[index] -= weight;
        if (book.pendingStakeBuckets[index] == 0) book.pendingBucketBitmap &= ~(uint32(1) << index);
    }

    function _bucketIndex(RewardBook storage book, uint40 eligibleAt) private view returns (uint8 index) {
        uint40 epoch = uint40(uint256(eligibleAt) / REWARD_BUCKET_SIZE);
        uint40 nextEpoch = book.nextBucketEpoch;
        if (epoch < nextEpoch) revert InvalidMaturitySchedule(eligibleAt);
        uint256 offset = uint256(epoch - nextEpoch);
        if (offset >= REWARD_BUCKET_COUNT) revert InvalidMaturitySchedule(eligibleAt);
        index = uint8((uint256(book.bucketCursor) + offset) % REWARD_BUCKET_COUNT);
    }

    function _duePending(RewardBook storage book, bool weight) private view returns (uint256 total) {
        uint40 nextEpoch = book.nextBucketEpoch;
        if (nextEpoch == 0) return 0;
        uint40 currentEpoch = (block.timestamp / REWARD_BUCKET_SIZE).toUint40();
        if (currentEpoch < nextEpoch) return 0;
        uint256 elapsed = uint256(currentEpoch - nextEpoch) + 1;
        if (elapsed > REWARD_BUCKET_COUNT) elapsed = REWARD_BUCKET_COUNT;
        uint8 cursor = book.bucketCursor;
        for (uint256 i; i < elapsed; ++i) {
            uint8 index = uint8((uint256(cursor) + i) % REWARD_BUCKET_COUNT);
            total += weight ? book.pendingWeightBuckets[index] : book.pendingStakeBuckets[index];
        }
    }

    function _needsCheckpoint(RewardBook storage book) private view returns (bool) {
        uint40 nextEpoch = book.nextBucketEpoch;
        if (nextEpoch == 0) return false;
        uint40 currentEpoch = (block.timestamp / REWARD_BUCKET_SIZE).toUint40();
        if (currentEpoch < nextEpoch) return false;
        uint256 elapsed = uint256(currentEpoch - nextEpoch) + 1;
        if (elapsed > REWARD_BUCKET_COUNT) elapsed = REWARD_BUCKET_COUNT;
        return (book.pendingBucketBitmap & _bucketMask(book.bucketCursor, elapsed)) != 0;
    }

    function _bucketMask(uint8 cursor, uint256 elapsed) private pure returns (uint32 mask) {
        if (elapsed >= REWARD_BUCKET_COUNT) return uint32((uint256(1) << REWARD_BUCKET_COUNT) - 1);
        uint256 untilWrap = REWARD_BUCKET_COUNT - cursor;
        if (elapsed <= untilWrap) return uint32(((uint256(1) << elapsed) - 1) << cursor);
        uint256 wrapped = elapsed - untilWrap;
        mask = uint32((((uint256(1) << untilWrap) - 1) << cursor) | ((uint256(1) << wrapped) - 1));
    }

    function _advanceBucketWindow(RewardBook storage book, uint40 currentEpoch, uint40 nextEpoch, uint256 elapsed)
        private
    {
        if (uint256(currentEpoch - nextEpoch) + 1 >= REWARD_BUCKET_COUNT) {
            book.nextBucketEpoch = currentEpoch + 1;
            book.bucketCursor = 0;
        } else {
            book.nextBucketEpoch = nextEpoch + uint40(elapsed);
            book.bucketCursor = uint8((uint256(book.bucketCursor) + elapsed) % REWARD_BUCKET_COUNT);
        }
    }

    function _enforcePositionBooksFresh(RewardStorage storage rs, StakePosition storage position) private view {
        uint256 length = position.optedInAssets.length;
        for (uint256 i; i < length; ++i) {
            address asset = position.optedInAssets[i];
            if (_needsCheckpoint(rs.books[asset])) revert RewardBookNeedsCheckpoint(asset);
        }
    }

    function _eligibleAt(uint256 pendingStart) private pure returns (uint40) {
        uint256 raw = pendingStart + REWARD_ELIGIBILITY_DELAY;
        uint256 rounded = Math.ceilDiv(raw, REWARD_BUCKET_SIZE) * REWARD_BUCKET_SIZE;
        return rounded.toUint40();
    }

    function _weight(uint256 actualStake, uint16 multiplierBps) private pure returns (uint256) {
        return Math.mulDiv(actualStake, multiplierBps, MULTIPLIER_BPS);
    }

    function _validateMultiplier(uint16 multiplierBps) private pure {
        if (multiplierBps < MULTIPLIER_BPS) revert InvalidMultiplier(multiplierBps);
    }
}
