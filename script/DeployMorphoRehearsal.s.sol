// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Script} from "forge-std/Script.sol";
import {IDiamondCut} from "../src/interfaces/IDiamondCut.sol";
import {StaticsSelectors} from "../src/libraries/StaticsSelectors.sol";
import {MorphoFacet} from "../src/facets/MorphoFacet.sol";
import {MorphoAdminFacet} from "../src/facets/MorphoAdminFacet.sol";
import {MorphoRecoveryFacet} from "../src/facets/MorphoRecoveryFacet.sol";
import {MorphoSettlementFacet} from "../src/facets/MorphoSettlementFacet.sol";
import {MorphoViewFacet} from "../src/facets/MorphoViewFacet.sol";

/// @dev Deliberately controlled oracle for local liquidation boundary tests only.
contract MorphoRehearsalOracle {
    uint256 public price = 1e36;

    function setPrice(uint256 value) external {
        price = value;
    }
}

/// @dev Separate later-activation experiment; never part of the Phase 2 cut.
contract DeployMorphoRehearsal is Script {
    function run() external {
        vm.rpc("anvil_nodeInfo", "[]");
        require(block.chainid == 4663, "wrong rehearsal chain");
        bytes memory creation = bytes.concat(
            vm.parseJsonBytes(vm.readFile(vm.envString("STATICS_UPSTREAM_MORPHO_ARTIFACT")), ".bytecode.object"),
            abi.encode(vm.envAddress("STATICS_REHEARSAL_MORPHO_OWNER"))
        );
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        IDiamondCut.FacetCut[] memory cut = new IDiamondCut.FacetCut[](5);
        cut[0] = IDiamondCut.FacetCut(
            address(new MorphoAdminFacet()), IDiamondCut.FacetCutAction.Add, StaticsSelectors.morphoAdmin()
        );
        cut[1] = IDiamondCut.FacetCut(
            address(new MorphoFacet()), IDiamondCut.FacetCutAction.Add, StaticsSelectors.morphoActions()
        );
        cut[2] = IDiamondCut.FacetCut(
            address(new MorphoSettlementFacet()), IDiamondCut.FacetCutAction.Add, StaticsSelectors.morphoSettlement()
        );
        cut[3] = IDiamondCut.FacetCut(
            address(new MorphoViewFacet()), IDiamondCut.FacetCutAction.Add, StaticsSelectors.morphoView()
        );
        cut[4] = IDiamondCut.FacetCut(
            address(new MorphoRecoveryFacet()), IDiamondCut.FacetCutAction.Add, StaticsSelectors.morphoRecovery()
        );
        address morpho;
        assembly ("memory-safe") { morpho := create(0, add(creation, 32), mload(creation)) }
        require(morpho != address(0), "upstream deployment failed");
        address oracle = address(new MorphoRehearsalOracle());
        vm.stopBroadcast();
        string memory key = "morpho-rehearsal";
        vm.serializeAddress(key, "morpho", morpho);
        vm.serializeAddress(key, "oracle", oracle);
        string memory result =
            vm.serializeBytes(key, "cut", abi.encodeCall(IDiamondCut.diamondCut, (cut, address(0), bytes(""))));
        vm.writeJson(result, vm.envString("STATICS_REHEARSAL_MORPHO_CANDIDATE"));
    }
}
