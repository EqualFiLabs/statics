// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IStaticsGlobalRewards} from "../interfaces/IStaticsGlobalRewards.sol";
import {LibBasket} from "./LibBasket.sol";
import {LibCustody} from "./LibCustody.sol";
import {LibPosition} from "../position/LibPosition.sol";

library LibGlobalRewards {
    bytes32 internal constant REWARD_STORAGE_POSITION = keccak256("statics.storage.global.rewards.v2");
    uint256 internal constant RAY = 1e27;
    uint256 internal constant MAX_REWARD_ASSETS_PER_POSITION = 64;
    uint256 internal constant UNSTAKE_COOLDOWN = 24 hours;
    uint256 internal constant STAKER_SHARE_BPS = 9_000;

    struct RewardBook {
        uint256 eligibleStake;
        uint256 indexRay;
        uint256 indexedAmount;
        uint256 crystallizedAmount;
    }

    struct StakePosition {
        uint256 balance;
        uint256 lastIncreaseTimestamp;
        uint256 claimAssetCount;
        address[] optedInAssets;
        mapping(address asset => uint256 indexPlusOne) optedInIndexPlusOne;
        mapping(address asset => uint256 indexRay) checkpoints;
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
        position.checkpoints[asset] = book.indexRay;
        position.optedInAssets.push(asset);
        position.optedInIndexPlusOne[asset] = position.optedInAssets.length;
        book.eligibleStake += position.balance;
        emit IStaticsGlobalRewards.RewardAssetOptedIn(positionId, asset, book.eligibleStake);
    }

    function optOut(uint256 positionId, address asset) internal {
        RewardStorage storage rs = rewardStorage();
        StakePosition storage position = rs.positions[positionId];
        uint256 indexPlusOne = position.optedInIndexPlusOne[asset];
        if (indexPlusOne == 0) revert RewardAssetNotOptedIn(positionId, asset);
        settleAsset(positionId, asset);
        RewardBook storage book = rs.books[asset];
        book.eligibleStake -= position.balance;
        _removeOptIn(position, asset, indexPlusOne);
        _routeDustIfEmpty(rs, asset, book);
        emit IStaticsGlobalRewards.RewardAssetOptedOut(positionId, asset, book.eligibleStake);
    }

    function settleSelected(uint256 positionId) internal {
        StakePosition storage position = rewardStorage().positions[positionId];
        uint256 length = position.optedInAssets.length;
        for (uint256 i; i < length; ++i) {
            settleAsset(positionId, position.optedInAssets[i]);
        }
    }

    function increaseEligibleStake(uint256 positionId, uint256 amount) internal {
        RewardStorage storage rs = rewardStorage();
        StakePosition storage position = rs.positions[positionId];
        uint256 length = position.optedInAssets.length;
        for (uint256 i; i < length; ++i) {
            address asset = position.optedInAssets[i];
            RewardBook storage book = rs.books[asset];
            book.eligibleStake += amount;
        }
    }

    function decreaseEligibleStake(uint256 positionId, uint256 amount) internal {
        RewardStorage storage rs = rewardStorage();
        StakePosition storage position = rs.positions[positionId];
        uint256 length = position.optedInAssets.length;
        for (uint256 i; i < length; ++i) {
            address asset = position.optedInAssets[i];
            RewardBook storage book = rs.books[asset];
            book.eligibleStake -= amount;
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
            delete position.checkpoints[asset];
            emit IStaticsGlobalRewards.RewardAssetOptedOut(positionId, asset, rs.books[asset].eligibleStake);
        }
    }

    function settleAsset(uint256 positionId, address asset) internal {
        RewardStorage storage rs = rewardStorage();
        StakePosition storage position = rs.positions[positionId];
        if (position.optedInIndexPlusOne[asset] == 0) return;
        RewardBook storage book = rs.books[asset];
        uint256 priorIndex = position.checkpoints[asset];
        uint256 added;
        if (position.balance != 0 && book.indexRay > priorIndex) {
            added = Math.mulDiv(position.balance, book.indexRay - priorIndex, RAY);
            if (added != 0) {
                if (position.claimable[asset] == 0) ++position.claimAssetCount;
                position.claimable[asset] += added;
                rs.totalClaimable[asset] += added;
                book.crystallizedAmount += added;
            }
        }
        position.checkpoints[asset] = book.indexRay;
        emit IStaticsGlobalRewards.PositionRewardSettled(positionId, asset, added);
    }

    function pending(uint256 positionId, address asset) internal view returns (uint256 amount) {
        RewardStorage storage rs = rewardStorage();
        StakePosition storage position = rs.positions[positionId];
        amount = position.claimable[asset];
        if (position.optedInIndexPlusOne[asset] == 0) return amount;
        RewardBook storage book = rs.books[asset];
        uint256 priorIndex = position.checkpoints[asset];
        if (position.balance != 0 && book.indexRay > priorIndex) {
            amount += Math.mulDiv(position.balance, book.indexRay - priorIndex, RAY);
        }
    }

    function activateStakingLeg(uint256 positionId) internal {
        bytes32 key = LibPosition.stakingLegKey();
        LibPosition.PositionStorage storage ps = LibPosition.positionStorage();
        if (!ps.activeLeg[positionId][key]) LibPosition.activateLeg(positionId, key);
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
        delete position.checkpoints[asset];
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
}
