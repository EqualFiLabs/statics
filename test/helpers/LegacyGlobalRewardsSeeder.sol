// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {LibCustody} from "../../src/libraries/LibCustody.sol";

/// @dev Exact global-reward storage layout from PR #43 at commit
/// c868697862b4e63c9c7ddcbb14294da8ffb15e6a. The rehearsal writes through
/// this historical layout before installing the PR #44 facets.
contract LegacyGlobalRewardsSeeder {
    using SafeCast for uint256;

    bytes32 private constant REWARD_STORAGE_POSITION = keccak256("statics.storage.global.rewards.v3");
    uint256 private constant RAY = 1e27;
    uint256 private constant REWARD_BUCKET_SIZE = 1 hours;

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

    error LegacyStateNotEmpty();
    error InvalidLegacyMaturity(uint256 eligibleAt, uint256 currentTime);

    function seedLegacyGlobalRewards(uint256 positionId, address assetA, address assetB, uint256 eligibleAt_) external {
        RewardStorage storage rs = _rewardStorage();
        StakePosition storage position = rs.positions[positionId];
        if (rs.totalStaked != 0 || position.balance != 0) revert LegacyStateNotEmpty();
        if (eligibleAt_ != block.timestamp + 24 hours || eligibleAt_ % REWARD_BUCKET_SIZE != 0) {
            revert InvalidLegacyMaturity(eligibleAt_, block.timestamp);
        }

        uint40 eligibleAt = eligibleAt_.toUint40();
        uint40 currentEpoch = (block.timestamp / REWARD_BUCKET_SIZE).toUint40();
        rs.totalStaked = 150 ether;
        position.balance = 150 ether;
        position.claimAssetCount = 2;
        position.optedInAssets.push(assetA);
        position.optedInAssets.push(assetB);
        position.optedInIndexPlusOne[assetA] = 1;
        position.optedInIndexPlusOne[assetB] = 2;

        RewardBook storage bookA = rs.books[assetA];
        bookA.eligibleStake = 100 ether;
        bookA.pendingStake = 50 ether;
        bookA.indexRay = 5 * RAY;
        bookA.indexedAmount = 1_000 ether;
        bookA.crystallizedAmount = 200 ether;
        bookA.nextBucketEpoch = currentEpoch + 1;
        bookA.bucketCursor = 7;
        bookA.pendingBuckets[5] = 50 ether;

        PositionSelection storage selectionA = position.selections[assetA];
        selectionA.eligibleStake = 100 ether;
        selectionA.pendingStake = 50 ether;
        selectionA.checkpointRay = 4 * RAY;
        selectionA.pendingStartTime = uint40(block.timestamp);
        selectionA.eligibleAt = eligibleAt;
        position.claimable[assetA] = 11 ether;
        rs.totalClaimable[assetA] = 11 ether;
        rs.treasuryAccrued[assetA] = 13 ether;

        RewardBook storage bookB = rs.books[assetB];
        bookB.eligibleStake = 150 ether;
        bookB.indexRay = 8 * RAY;
        bookB.indexedAmount = 2_000 ether;
        bookB.crystallizedAmount = 300 ether;
        bookB.nextBucketEpoch = currentEpoch + 1;
        bookB.bucketCursor = 2;

        PositionSelection storage selectionB = position.selections[assetB];
        selectionB.eligibleStake = 150 ether;
        selectionB.checkpointRay = 7 * RAY;
        position.claimable[assetB] = 22 ether;
        rs.totalClaimable[assetB] = 22 ether;
        rs.treasuryAccrued[assetB] = 17 ether;
    }

    function reserveLegacyRewardAsset(address asset, uint256 amount) external {
        LibCustody.pullAndReserve(LibCustody.feeAccount(), asset, msg.sender, amount);
    }

    function legacyPendingBucket(address asset, uint256 index) external view returns (uint256) {
        return _rewardStorage().books[asset].pendingBuckets[index];
    }

    function _rewardStorage() private pure returns (RewardStorage storage rs) {
        bytes32 position = REWARD_STORAGE_POSITION;
        assembly ("memory-safe") {
            rs.slot := position
        }
    }
}
