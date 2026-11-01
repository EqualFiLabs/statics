// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;
import {IStaticsExternalModules} from "../interfaces/IStaticsExternalModules.sol";
import {LibDiamond} from "../libraries/LibDiamond.sol";

/// @notice Executed atomically with installation on an existing Diamond.
contract StaticsExternalModulesInit {
    function initialize() external {
        LibDiamond.enforceIsContractOwner();
        LibDiamond.diamondStorage().supportedInterfaces[type(IStaticsExternalModules).interfaceId] = true;
    }
}
