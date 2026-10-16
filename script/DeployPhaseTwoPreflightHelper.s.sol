// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {console2} from "forge-std/console2.sol";
import {Script} from "forge-std/Script.sol";
import {PhaseTwoRehearsalBatch} from "../scripts/phase-one-rehearsal/helpers/PhaseTwoRehearsalActors.sol";

/// @dev Deploys only a disposable delegatecall batch on a loopback Anvil fork.
contract DeployPhaseTwoPreflightHelper is Script {
    function run() external {
        vm.rpc("anvil_nodeInfo", "[]");
        require(block.chainid == 4663, "wrong preflight chain");
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        address batch = address(new PhaseTwoRehearsalBatch());
        vm.stopBroadcast();
        string memory key = "helper";
        string memory result = vm.serializeAddress(key, "batch", batch);
        vm.writeJson(result, vm.envString("STATICS_PHASE_TWO_PREFLIGHT_HELPER"));
        console2.log("PHASE_TWO_PREFLIGHT_BATCH", batch);
    }
}
