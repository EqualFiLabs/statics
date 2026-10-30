// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Script} from "forge-std/Script.sol";
import {IDiamondCut} from "../src/interfaces/IDiamondCut.sol";
import {IDiamondLoupe} from "../src/interfaces/IDiamondLoupe.sol";
import {IStaticsGenesisIntegration} from "../src/interfaces/IStaticsGenesisIntegration.sol";
import {ExternalModuleFacet} from "../src/facets/ExternalModuleFacet.sol";
import {GenesisNFTFacet} from "../src/facets/GenesisNFTFacet.sol";
import {PositionNFTFacet} from "../src/position/PositionNFTFacet.sol";
import {StaticsExternalModulesInit} from "../src/diamond/StaticsExternalModulesInit.sol";
import {StaticsSelectors} from "../src/libraries/StaticsSelectors.sol";

library StaticsExternalModulesUpgradeCut {
    function build(address diamond, address externalModules, address position, address genesis)
        internal
        view
        returns (IDiamondCut.FacetCut[] memory cut)
    {
        bool hasGenesis = IDiamondLoupe(diamond).facetAddress(IStaticsGenesisIntegration.onGenesisTransition.selector)
        != address(0);
        cut = new IDiamondCut.FacetCut[](hasGenesis ? 3 : 2);
        cut[0] =
            IDiamondCut.FacetCut(externalModules, IDiamondCut.FacetCutAction.Add, StaticsSelectors.externalModules());
        cut[1] = IDiamondCut.FacetCut(position, IDiamondCut.FacetCutAction.Replace, StaticsSelectors.position());
        if (hasGenesis) {
            cut[2] = IDiamondCut.FacetCut(genesis, IDiamondCut.FacetCutAction.Replace, StaticsSelectors.genesisNFT());
        }
    }
}

/// @notice Prepares a governed atomic cut; does not execute the upgrade.
contract PrepareStaticsExternalModulesUpgrade is Script {
    function deploy(address diamond)
        public
        returns (IDiamondCut.FacetCut[] memory cut, address initializer, bytes memory data)
    {
        address externalModules = address(new ExternalModuleFacet());
        address position = address(new PositionNFTFacet());
        address genesis = address(new GenesisNFTFacet());
        cut = StaticsExternalModulesUpgradeCut.build(diamond, externalModules, position, genesis);
        initializer = address(new StaticsExternalModulesInit());
        data = abi.encodeCall(StaticsExternalModulesInit.initialize, ());
    }
}
