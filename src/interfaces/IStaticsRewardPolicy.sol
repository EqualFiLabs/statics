// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

interface IStaticsRewardPolicy {
    event RewardRestrictionAdded(address indexed asset, address indexed caller);
    event RewardRestrictionRemoved(address indexed asset);

    function addRewardRestriction(address asset) external;
    function removeRewardRestriction(address asset) external;
    function rewardRestricted(address asset) external view returns (bool restricted);
    function rewardRestrictionNonce(address asset) external view returns (uint64 nonce);
    function rewardRestrictionTimestamp(address asset, uint64 epoch) external view returns (uint40 timestamp);
}
