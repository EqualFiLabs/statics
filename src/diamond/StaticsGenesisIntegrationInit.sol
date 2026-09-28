// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC5192} from "../interfaces/IERC5192.sol";
import {IStaticsGenesisIntegration} from "../interfaces/IStaticsGenesisIntegration.sol";
import {LibDiamond} from "../libraries/LibDiamond.sol";
import {LibGenesisIntegration} from "../libraries/LibGenesisIntegration.sol";

/// @notice One-time governed binding of separately deployed Genesis infrastructure to Statics.
contract StaticsGenesisIntegrationInit {
    function initialize(LibGenesisIntegration.InitArgs calldata args) external {
        LibDiamond.enforceIsContractOwner();
        LibGenesisIntegration.initialize(args);

        LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
        ds.supportedInterfaces[type(IERC5192).interfaceId] = true;
        ds.supportedInterfaces[type(IStaticsGenesisIntegration).interfaceId] = true;
    }
}
