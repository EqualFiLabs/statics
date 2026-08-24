// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Narrow transition model for the Global Rewards raw-stake and weight invariants.
/// @dev Halmos 0.3.3 cannot reload LibGlobalRewards' assembly-selected diamond storage
///      soundly. Production-source behavior is covered by the GlobalRewards Foundry and
///      invariant suites; this model isolates the arithmetic and transition invariants.
contract GlobalRewardsHarness {
    uint256 public constant BASE_REWARD_MULTIPLIER_BPS = 10_000;
    uint256 public constant REWARD_ELIGIBILITY_DELAY = 24 hours;

    uint256 private selectionEligibleStake;
    uint256 private selectionPendingStake;
    uint256 private selectionEligibleWeight;
    uint256 private selectionPendingWeight;
    uint40 private selectionPendingStartTime;
    uint40 private selectionEligibleAt;
    uint256 private selectionCheckpointRay;
    bool private selectionWeightInitialized;

    uint256 private bookEligibleStake;
    uint256 private bookPendingStake;
    uint256 private bookEligibleWeight;
    uint256 private bookPendingWeight;
    uint256 private bookIndexRay;
    bool private bookWeightInitialized;

    uint16 private rewardMultiplierBps;

    function seedCurrent(uint256 eligibleStake, uint256 pendingStake, uint256 indexRay) public {
        _seed(eligibleStake, pendingStake, indexRay, true);
    }

    function seedLegacy(uint256 eligibleStake, uint256 pendingStake, uint256 indexRay) public {
        _seed(eligibleStake, pendingStake, indexRay, false);
    }

    function transition(uint256 nextMultiplierBps) public {
        if (nextMultiplierBps < BASE_REWARD_MULTIPLIER_BPS || nextMultiplierBps > type(uint16).max) revert();
        _ensureWeights();
        selectionEligibleWeight = weightFor(selectionEligibleStake, nextMultiplierBps);
        selectionPendingWeight = weightFor(selectionPendingStake, nextMultiplierBps);
        bookEligibleWeight = selectionEligibleWeight;
        bookPendingWeight = selectionPendingWeight;
        rewardMultiplierBps = uint16(nextMultiplierBps);
    }

    function settle() public {
        _ensureWeights();
        if (selectionPendingStake == 0 || block.timestamp < selectionEligibleAt) return;
        selectionEligibleStake += selectionPendingStake;
        selectionEligibleWeight += selectionPendingWeight;
        selectionPendingStake = 0;
        selectionPendingWeight = 0;
        selectionPendingStartTime = 0;
        selectionEligibleAt = 0;
        bookEligibleStake = selectionEligibleStake;
        bookPendingStake = 0;
        bookEligibleWeight = selectionEligibleWeight;
        bookPendingWeight = 0;
    }

    function selection()
        public
        view
        returns (
            uint256 eligibleStake,
            uint256 pendingStake,
            uint256 eligibleWeight,
            uint256 pendingWeight,
            uint40 pendingStartTime,
            uint40 eligibleAt,
            uint256 checkpointRay,
            bool weightInitialized
        )
    {
        return (
            selectionEligibleStake,
            selectionPendingStake,
            selectionEligibleWeight,
            selectionPendingWeight,
            selectionPendingStartTime,
            selectionEligibleAt,
            selectionCheckpointRay,
            selectionWeightInitialized
        );
    }

    function book()
        public
        view
        returns (
            uint256 eligibleStake,
            uint256 pendingStake,
            uint256 eligibleWeight,
            uint256 pendingWeight,
            uint256 indexRay,
            uint40 nextBucketEpoch,
            uint8 bucketCursor,
            uint32 pendingBucketBitmap,
            bool weightInitialized
        )
    {
        return (
            bookEligibleStake,
            bookPendingStake,
            bookEligibleWeight,
            bookPendingWeight,
            bookIndexRay,
            0,
            0,
            bookPendingStake == 0 ? 0 : 1,
            bookWeightInitialized
        );
    }

    function bucket() public view returns (uint256 stake, uint256 weight) {
        return (bookPendingStake, bookPendingWeight);
    }

    function multiplierBps() external view returns (uint16) {
        return rewardMultiplierBps == 0 ? uint16(BASE_REWARD_MULTIPLIER_BPS) : rewardMultiplierBps;
    }

    function weightFor(uint256 stake, uint256 multiplier) public pure returns (uint256) {
        return Math.mulDiv(stake, multiplier, BASE_REWARD_MULTIPLIER_BPS);
    }

    function _seed(uint256 eligibleStake, uint256 pendingStake, uint256 indexRay, bool initializeWeights) private {
        selectionEligibleStake = eligibleStake;
        selectionPendingStake = pendingStake;
        selectionCheckpointRay = indexRay;
        selectionPendingStartTime = uint40(block.timestamp);
        selectionEligibleAt = uint40(block.timestamp + REWARD_ELIGIBILITY_DELAY);
        selectionEligibleWeight = initializeWeights ? eligibleStake : 0;
        selectionPendingWeight = initializeWeights ? pendingStake : 0;
        selectionWeightInitialized = initializeWeights;

        bookEligibleStake = eligibleStake;
        bookPendingStake = pendingStake;
        bookEligibleWeight = initializeWeights ? eligibleStake : 0;
        bookPendingWeight = initializeWeights ? pendingStake : 0;
        bookIndexRay = indexRay;
        bookWeightInitialized = initializeWeights;
        rewardMultiplierBps = uint16(BASE_REWARD_MULTIPLIER_BPS);
    }

    function _ensureWeights() private {
        if (!selectionWeightInitialized) {
            selectionEligibleWeight = selectionEligibleStake;
            selectionPendingWeight = selectionPendingStake;
            selectionWeightInitialized = true;
        }
        if (!bookWeightInitialized) {
            bookEligibleWeight = bookEligibleStake;
            bookPendingWeight = bookPendingStake;
            bookWeightInitialized = true;
        }
    }
}
