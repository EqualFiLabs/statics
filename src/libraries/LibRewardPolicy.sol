// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

library LibRewardPolicy {
    bytes32 internal constant REWARD_POLICY_STORAGE_POSITION = keccak256("statics.storage.reward.policy.v1");

    struct RewardPolicyStorage {
        mapping(address asset => bool restricted) rewardRestricted;
    }

    function rewardPolicyStorage() internal pure returns (RewardPolicyStorage storage ps) {
        bytes32 position = REWARD_POLICY_STORAGE_POSITION;
        assembly ("memory-safe") {
            ps.slot := position
        }
    }

    function isRestricted(address asset) internal view returns (bool) {
        return rewardPolicyStorage().rewardRestricted[asset];
    }
}
