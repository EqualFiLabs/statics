// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Script} from "forge-std/Script.sol";

import {StaticsToken} from "../src/tokens/StaticsToken.sol";

contract DeployStaticsToken is Script {
    function run() external returns (StaticsToken token) {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address treasury = vm.envAddress("STATICS_TREASURY");

        vm.startBroadcast(privateKey);
        token = deploy(treasury);
        vm.stopBroadcast();
    }

    function deploy(address treasury) public returns (StaticsToken token) {
        token = new StaticsToken(treasury);
    }
}
