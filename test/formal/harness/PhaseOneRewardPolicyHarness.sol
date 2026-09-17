// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {RewardPolicyFacet} from "../../../src/facets/RewardPolicyFacet.sol";
import {LibDiamond} from "../../../src/libraries/LibDiamond.sol";
import {LibGovernance} from "../../../src/libraries/LibGovernance.sol";
import {LibPermissionedFeeMath} from "../../../src/libraries/LibPermissionedFeeMath.sol";

contract PhaseOneRewardPolicyHarness is RewardPolicyFacet {
    address public constant OWNER = address(0xA11CE);
    address public constant GUARDIAN = address(0xBEEF);

    constructor() {
        LibDiamond.initializeOwnership(OWNER);
        LibGovernance.governanceStorage().guardian = GUARDIAN;
    }
}

contract PhaseOnePermissionedFeeMathHarness {
    function bothRestrictedDistribution(uint128 rawFee)
        external
        pure
        returns (uint256 creator, uint256 treasury, uint256 staticsStaker, uint256 basketStaker)
    {
        LibPermissionedFeeMath.Distribution memory distribution = LibPermissionedFeeMath.bothRestricted(rawFee);
        return (distribution.creator, distribution.treasury, distribution.staticsStaker, distribution.basketStaker);
    }
}
