// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {LibDeploymentPhases} from "../libraries/LibDeploymentPhases.sol";
import {LibDiamond} from "../libraries/LibDiamond.sol";

/// @notice Atomic one-time initialization for basket, credit, flash, and Genesis selectors.
contract StaticsPhaseTwoInit {
    struct InitArgs {
        uint256 creationFeeAmount;
        uint256 singleAssetFlashFeeBps;
    }

    function initialize(InitArgs calldata args) external {
        LibDiamond.enforceIsContractOwner();
        LibDeploymentPhases.initializePhaseTwo(args.creationFeeAmount, args.singleAssetFlashFeeBps);
    }
}
