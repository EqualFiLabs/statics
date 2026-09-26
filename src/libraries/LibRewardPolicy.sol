// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

library LibRewardPolicy {
    bytes32 internal constant REWARD_POLICY_STORAGE_POSITION = keccak256("statics.storage.reward.policy.v2");

    struct RestrictionSequenceCheckpoint {
        uint64 epoch;
        uint64 sequence;
    }

    struct RestrictionState {
        bool restricted;
        uint64 nonce;
        mapping(uint64 epoch => uint40 firstRestrictedAt) firstRestrictedAt;
        RestrictionSequenceCheckpoint[] sequenceHistory;
    }

    struct RewardPolicyStorage {
        mapping(address asset => RestrictionState state) restrictions;
        uint64 restrictionSequence;
    }

    function rewardPolicyStorage() internal pure returns (RewardPolicyStorage storage ps) {
        bytes32 position = REWARD_POLICY_STORAGE_POSITION;
        assembly ("memory-safe") {
            ps.slot := position
        }
    }

    function isRestricted(address asset) internal view returns (bool) {
        return rewardPolicyStorage().restrictions[asset].restricted;
    }

    function restrictionNonce(address asset) internal view returns (uint64) {
        return rewardPolicyStorage().restrictions[asset].nonce;
    }

    function firstRestrictedAt(address asset, uint64 epoch) internal view returns (uint40) {
        return rewardPolicyStorage().restrictions[asset].firstRestrictedAt[epoch];
    }

    function restrictionSequence() internal view returns (uint64) {
        return rewardPolicyStorage().restrictionSequence;
    }

    function recordRestrictionSequence(address asset, uint64 epoch, uint64 sequence) internal {
        RestrictionState storage state = rewardPolicyStorage().restrictions[asset];
        RestrictionSequenceCheckpoint[] storage history = state.sequenceHistory;
        uint256 length = history.length;
        if (length != 0 && history[length - 1].epoch == epoch) {
            history[length - 1].sequence = sequence;
            return;
        }
        history.push(RestrictionSequenceCheckpoint({epoch: epoch, sequence: sequence}));
    }

    function restrictionSequenceAt(address asset, uint64 epoch) internal view returns (uint64 sequence) {
        RestrictionSequenceCheckpoint[] storage history = rewardPolicyStorage().restrictions[asset].sequenceHistory;
        uint256 low;
        uint256 high = history.length;
        while (low < high) {
            uint256 mid = low + ((high - low) >> 1);
            if (history[mid].epoch <= epoch) low = mid + 1;
            else high = mid;
        }
        if (low != 0) sequence = history[low - 1].sequence;
    }
}
