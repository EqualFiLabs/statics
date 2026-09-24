// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IStaticsRewardPolicy} from "../interfaces/IStaticsRewardPolicy.sol";
import {LibDiamond} from "../libraries/LibDiamond.sol";
import {LibGaugeEpoch} from "../libraries/LibGaugeEpoch.sol";
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
        LibRewardPolicy.RestrictionState storage state = LibRewardPolicy.rewardPolicyStorage().restrictions[asset];
        if (state.restricted) revert RewardRestrictionAlreadySet(asset);
        state.restricted = true;
        ++state.nonce;
        uint64 epoch = LibGaugeEpoch.epochAt(block.timestamp);
        if (state.firstRestrictedAt[epoch] == 0) state.firstRestrictedAt[epoch] = uint40(block.timestamp);
        emit RewardRestrictionAdded(asset, msg.sender);
    }

    function removeRewardRestriction(address asset) external {
        LibDiamond.enforceIsContractOwner();
        LibRewardPolicy.RestrictionState storage state = LibRewardPolicy.rewardPolicyStorage().restrictions[asset];
        if (!state.restricted) revert RewardRestrictionNotSet(asset);
        state.restricted = false;
        emit RewardRestrictionRemoved(asset);
    }

    function rewardRestricted(address asset) external view returns (bool restricted) {
        return LibRewardPolicy.isRestricted(asset);
    }

    function rewardRestrictionNonce(address asset) external view returns (uint64 nonce) {
        return LibRewardPolicy.restrictionNonce(asset);
    }

    function rewardRestrictionTimestamp(address asset, uint64 epoch) external view returns (uint40 timestamp) {
        return LibRewardPolicy.firstRestrictedAt(asset, epoch);
    }
}
