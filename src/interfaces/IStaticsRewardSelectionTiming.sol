// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.26 <0.9.0;

import {IStaticsGlobalRewards} from "./IStaticsGlobalRewards.sol";

/// @notice Additive timing view for position-selected staking rewards.
interface IStaticsRewardSelectionTiming {
    /// @notice Returns the effective selection and its weighted pending start in one read.
    /// @dev Top-ups reset the start using weighted age credit; it is not the first deposit time.
    /// The start is zero when no stake is effectively pending, including matured but unrolled stake.
    /// Existing positions are publicly readable; a nonexistent PositionNFT reverts.
    function rewardSelectionWithTiming(uint256 positionId, address asset)
        external
        view
        returns (IStaticsGlobalRewards.RewardSelectionView memory selection, uint40 pendingStartTime);
}
