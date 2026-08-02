// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Script} from "forge-std/Script.sol";

import {StaticsTestnetFaucet} from "../src/testnet/StaticsTestnetFaucet.sol";

contract DeployStaticsTestnetFaucet is Script {
    uint256 internal constant ROBINHOOD_TESTNET_CHAIN_ID = 46630;

    address internal constant USDG = 0x2c0DEA86D8fBdb652305B37ea7cF3f1cdC2A1371;
    address internal constant STATICS = 0x309b077A86d0d9365987793A470be98367c0A305;
    address internal constant TSLA = 0xC9f9c86933092BbbfFF3CCb4b105A4A94bf3Bd4E;
    address internal constant PLTR = 0x1FBE1a0e43594b3455993B5dE5Fd0A7A266298d0;
    address internal constant AMD = 0x71178BAc73cBeb415514eB542a8995b82669778d;

    error UnsupportedChain(uint256 chainId);

    function run() external returns (StaticsTestnetFaucet faucet) {
        if (block.chainid != ROBINHOOD_TESTNET_CHAIN_ID) revert UnsupportedChain(block.chainid);

        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address[5] memory assets = [USDG, STATICS, TSLA, PLTR, AMD];

        vm.startBroadcast(privateKey);
        faucet = deploy(assets);
        vm.stopBroadcast();
    }

    function deploy(address[5] memory assets) public returns (StaticsTestnetFaucet faucet) {
        faucet = new StaticsTestnetFaucet(assets);
    }
}
