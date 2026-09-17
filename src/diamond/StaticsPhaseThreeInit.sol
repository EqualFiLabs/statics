// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {LibPeriphery} from "../dollar/periphery/libraries/LibPeriphery.sol";
import {LibDeploymentPhases} from "../libraries/LibDeploymentPhases.sol";
import {LibDiamond} from "../libraries/LibDiamond.sol";

/// @notice Atomic one-time initialization for the Statics Dollar periphery selectors.
contract StaticsPhaseThreeInit {
    function initialize(LibPeriphery.InitArgs calldata args) external {
        LibDiamond.enforceIsContractOwner();
        LibDeploymentPhases.initializePhaseThree(args);
    }
}
