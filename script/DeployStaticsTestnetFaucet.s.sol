// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Script} from "forge-std/Script.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {StaticsTestnetFaucet} from "../src/testnet/StaticsTestnetFaucet.sol";

contract DeployStaticsTestnetFaucet is Script {
    uint256 internal constant ROBINHOOD_TESTNET_CHAIN_ID = 46630;

    error UnsupportedChain(uint256 chainId);
    error InvalidAsset(uint256 index, address asset);
    error DuplicateAsset(uint256 index, uint256 firstIndex, address asset);
    error InvalidAssetDecimals(uint256 index, address asset, uint8 expected, uint8 actual);

    function run() external returns (StaticsTestnetFaucet faucet) {
        if (block.chainid != ROBINHOOD_TESTNET_CHAIN_ID) revert UnsupportedChain(block.chainid);

        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address[5] memory assets = loadAssets();

        vm.startBroadcast(privateKey);
        faucet = deploy(assets);
        vm.stopBroadcast();
    }

    function deploy(address[5] memory assets) public returns (StaticsTestnetFaucet faucet) {
        faucet = new StaticsTestnetFaucet(assets);
    }

    function loadAssets() public view returns (address[5] memory assets) {
        assets = [
            vm.envAddress("STATICS_FAUCET_USDG"),
            vm.envAddress("STATICS_FAUCET_STATICS"),
            vm.envAddress("STATICS_FAUCET_TSLA"),
            vm.envAddress("STATICS_FAUCET_PLTR"),
            vm.envAddress("STATICS_FAUCET_AMD")
        ];

        for (uint256 i; i < assets.length; ++i) {
            address asset = assets[i];
            if (asset.code.length == 0) revert InvalidAsset(i, asset);
            for (uint256 j; j < i; ++j) {
                if (assets[j] == asset) revert DuplicateAsset(i, j, asset);
            }
            uint8 expectedDecimals = i == 0 ? 6 : 18;
            uint8 actualDecimals = IERC20Metadata(asset).decimals();
            if (actualDecimals != expectedDecimals) {
                revert InvalidAssetDecimals(i, asset, expectedDecimals, actualDecimals);
            }
        }
    }
}
