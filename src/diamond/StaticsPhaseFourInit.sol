// SPDX-License-Identifier: BUSL-1.1
// ============================================================================
//                              STATICS PROTOCOL
//                         Markets that work for you.
//                       https://staticsprotocol.com
//                              EqualFi Labs
// ============================================================================
pragma solidity 0.8.33;

import {LibDeploymentPhases} from "../libraries/LibDeploymentPhases.sol";
import {LibDiamond} from "../libraries/LibDiamond.sol";

/// @notice Atomic one-time activation for the Morpho selector surface.
contract StaticsPhaseFourInit {
    function initialize() external {
        LibDiamond.enforceIsContractOwner();
        LibDeploymentPhases.initializePhaseFour();
    }
}
