// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

library LibRewardPolicy {
    bytes32 internal constant REWARD_POLICY_STORAGE_POSITION = keccak256("statics.storage.reward.policy.v2");

    struct RestrictionState {
        bool restricted;
        uint64 nonce;
        mapping(uint64 epoch => uint40 firstRestrictedAt) firstRestrictedAt;
        mapping(uint64 epoch => uint64 lastRestrictionSequence) lastRestrictionSequence;
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

    function lastRestrictionSequence(address asset, uint64 epoch) internal view returns (uint64) {
        return rewardPolicyStorage().restrictions[asset].lastRestrictionSequence[epoch];
    }
}
