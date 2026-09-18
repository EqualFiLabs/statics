// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IStaticsRewardPolicy} from "../interfaces/IStaticsRewardPolicy.sol";
import {LibDiamond} from "../libraries/LibDiamond.sol";
import {LibGovernance} from "../libraries/LibGovernance.sol";
import {LibRewardPolicy} from "../libraries/LibRewardPolicy.sol";

/// @notice Technical reward-delivery restrictions. This policy never blocks pool creation or trading.
contract RewardPolicyFacet is IStaticsRewardPolicy {
    error InvalidRewardAsset(address asset);
    error NotGuardianOrOwner(address caller);
    error RewardRestrictionAlreadySet(address asset);
    error RewardRestrictionNotSet(address asset);

    function addRewardRestriction(address asset) external {
        if (asset == address(0)) revert InvalidRewardAsset(asset);
        LibGovernance.GovernanceStorage storage gs = LibGovernance.governanceStorage();
        if (msg.sender != gs.guardian && msg.sender != LibDiamond.diamondStorage().contractOwner) {
            revert NotGuardianOrOwner(msg.sender);
        }
        LibRewardPolicy.RewardPolicyStorage storage ps = LibRewardPolicy.rewardPolicyStorage();
        if (ps.rewardRestricted[asset]) revert RewardRestrictionAlreadySet(asset);
        ps.rewardRestricted[asset] = true;
        emit RewardRestrictionAdded(asset, msg.sender);
    }

    function removeRewardRestriction(address asset) external {
        LibDiamond.enforceIsContractOwner();
        LibRewardPolicy.RewardPolicyStorage storage ps = LibRewardPolicy.rewardPolicyStorage();
        if (!ps.rewardRestricted[asset]) revert RewardRestrictionNotSet(asset);
        ps.rewardRestricted[asset] = false;
        emit RewardRestrictionRemoved(asset);
    }

    function rewardRestricted(address asset) external view returns (bool restricted) {
        return LibRewardPolicy.isRestricted(asset);
    }
}
