// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Script} from "forge-std/Script.sol";
import {IDiamondCut} from "../src/interfaces/IDiamondCut.sol";
import {ExternalModuleFacet} from "../src/facets/ExternalModuleFacet.sol";
import {StaticsExternalModulesInit} from "../src/diamond/StaticsExternalModulesInit.sol";
import {StaticsSelectors} from "../src/libraries/StaticsSelectors.sol";

library StaticsExternalModulesUpgradeCut {
    function build(address externalModules) internal pure returns (IDiamondCut.FacetCut[] memory cut) {
        cut = new IDiamondCut.FacetCut[](1);
        cut[0] =
            IDiamondCut.FacetCut(externalModules, IDiamondCut.FacetCutAction.Add, StaticsSelectors.externalModules());
    }
}

/// @notice Prepares a governed atomic cut; does not execute the upgrade.
contract PrepareStaticsExternalModulesUpgrade is Script {
    function deploy() public returns (IDiamondCut.FacetCut[] memory cut, address initializer, bytes memory data) {
        cut = StaticsExternalModulesUpgradeCut.build(address(new ExternalModuleFacet()));
        initializer = address(new StaticsExternalModulesInit());
        data = abi.encodeCall(StaticsExternalModulesInit.initialize, ());
    }
}
