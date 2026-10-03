// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

library LibRewardPolicy {
    bytes32 internal constant REWARD_POLICY_STORAGE_POSITION = keccak256("statics.storage.reward.policy.v2");

    struct RestrictionCheckpoint {
        uint64 sequence;
        uint40 timestamp;
        uint256 routingIndexX160;
    }

    struct RestrictionState {
        bool restricted;
        uint64 nonce;
        RestrictionCheckpoint[] history;
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

    function restrictionSequence() internal view returns (uint64) {
        return rewardPolicyStorage().restrictionSequence;
    }

    function recordRestriction(address asset, uint64 sequence, uint40 timestamp, uint256 routingIndexX160) internal {
        RestrictionState storage state = rewardPolicyStorage().restrictions[asset];
        state.history
            .push(RestrictionCheckpoint({sequence: sequence, timestamp: timestamp, routingIndexX160: routingIndexX160}));
    }

    function firstRestrictionAfter(address asset, uint64 sequence)
        internal
        view
        returns (bool found, uint64 restrictionSequence_, uint40 timestamp, uint256 routingIndexX160)
    {
        RestrictionCheckpoint[] storage history = rewardPolicyStorage().restrictions[asset].history;
        uint256 low;
        uint256 high = history.length;
        while (low < high) {
            uint256 mid = low + ((high - low) >> 1);
            if (history[mid].sequence <= sequence) low = mid + 1;
            else high = mid;
        }
        if (low == history.length) return (false, 0, 0, 0);
        RestrictionCheckpoint storage checkpoint = history[low];
        return (true, checkpoint.sequence, checkpoint.timestamp, checkpoint.routingIndexX160);
    }
}
