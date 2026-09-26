// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IStaticsPermissionedSwapFeeHook} from "../interfaces/IStaticsPermissionedSwapFeeHook.sol";

/// @notice Exact fee-allocation math shared by the permissioned hook and formal harnesses.
library LibPermissionedFeeMath {
    uint256 internal constant BPS = 10_000;
    uint256 internal constant BOTH_RESTRICTED_CREATOR_SHARE_BPS = 8_000;

    struct Distribution {
        uint256 basketStaker;
        uint256 staticsStaker;
        uint256 creator;
        uint256 treasury;
    }

    /// @notice Charges a gross-output fee with the same ceiling semantics as the public hook.
    function feeFromGross(uint256 grossOutput, uint16 feeBps) internal pure returns (uint256 fee) {
        return Math.mulDiv(grossOutput, feeBps, BPS, Math.Rounding.Ceil);
    }

    function split(uint256 fee, IStaticsPermissionedSwapFeeHook.FeeAllocation memory allocation)
        internal
        pure
        returns (Distribution memory distribution)
    {
        distribution.creator = Math.mulDiv(fee, allocation.creatorShareBps, BPS);
        distribution.staticsStaker = Math.mulDiv(fee, allocation.staticsStakerShareBps, BPS);
        distribution.basketStaker = Math.mulDiv(fee, allocation.basketStakerShareBps, BPS);
        distribution.treasury = fee - distribution.creator - distribution.staticsStaker - distribution.basketStaker;
    }

    function removeStakerRewards(Distribution memory distribution)
        internal
        pure
        returns (Distribution memory updated, uint256 removed)
    {
        updated = distribution;
        removed = updated.staticsStaker + updated.basketStaker;
        updated.staticsStaker = 0;
        updated.basketStaker = 0;
    }

    /// @notice Applies the fixed no-incentive policy when both pool currencies are reward-restricted.
    function bothRestricted(uint256 fee) internal pure returns (Distribution memory distribution) {
        distribution.creator = Math.mulDiv(fee, BOTH_RESTRICTED_CREATOR_SHARE_BPS, BPS);
        distribution.treasury = fee - distribution.creator;
    }
}
