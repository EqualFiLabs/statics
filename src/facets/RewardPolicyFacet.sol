// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IStaticsRewardPolicy} from "../interfaces/IStaticsRewardPolicy.sol";
import {LibDiamond} from "../libraries/LibDiamond.sol";
import {LibGaugeRouting} from "../libraries/LibGaugeRouting.sol";
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
        uint40 currentTime = uint40(block.timestamp);
        LibGaugeRouting.checkpointSchedule(currentTime, LibGaugeRouting.MAX_CATCHUP_PERIODS);
        LibGaugeRouting.enforceScheduleCurrent(currentTime);
        uint64 sequence = ++LibRewardPolicy.rewardPolicyStorage().restrictionSequence;
        LibRewardPolicy.recordRestriction(
            asset, sequence, currentTime, LibGaugeRouting.routingStorage().globalIndexX160
        );
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

    function rewardRestrictionTimestamp(address asset, uint64 sequence) external view returns (uint40 timestamp) {
        (,, timestamp,) = LibRewardPolicy.firstRestrictionAfter(asset, sequence);
    }
}
