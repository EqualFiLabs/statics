// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Script} from "forge-std/Script.sol";

import {StaticsToken} from "../src/tokens/StaticsToken.sol";

contract DeployStaticsToken is Script {
    function run() external returns (StaticsToken token) {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address recipient = vm.envAddress("STATICS_TOKEN_RECIPIENT");
        uint256 initialSupply = vm.envUint("STATICS_TOKEN_INITIAL_SUPPLY");

        vm.startBroadcast(privateKey);
        token = deploy(recipient, initialSupply);
        vm.stopBroadcast();
    }

    function deploy(address recipient, uint256 initialSupply) public returns (StaticsToken token) {
        token = new StaticsToken(recipient, initialSupply);
    }
}
