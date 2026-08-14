// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";

import {DeployStatics} from "../../script/DeployStatics.s.sol";
import {RobinhoodDeploymentConfig} from "../../script/RobinhoodDeploymentConfig.sol";

contract RobinhoodDeploymentConfigHarness is DeployStatics {
    function manifestPath(uint256 chainId) external pure returns (string memory) {
        return _robinhoodManifestPath(chainId);
    }

    function loadV4Config() external view returns (V4Config memory) {
        return _loadRobinhoodV4Config();
    }
}

contract RobinhoodDeploymentConfigTest is Test {
    RobinhoodDeploymentConfigHarness private harness;

    function setUp() public {
        harness = new RobinhoodDeploymentConfigHarness();
    }

    function testSelectsMainnetManifest() public view {
        assertEq(harness.manifestPath(4663), "deployments/robinhood-chain-4663.json");
    }

    function testSelectsTestnetManifest() public view {
        assertEq(harness.manifestPath(46630), "deployments/robinhood-chain-testnet-46630.json");
    }

    function testRejectsUnsupportedChain() public {
        vm.expectRevert(abi.encodeWithSelector(RobinhoodDeploymentConfig.UnsupportedRobinhoodChain.selector, 31337));
        harness.manifestPath(31337);
    }

    function testLoadsTestnetV4Configuration() public {
        vm.chainId(46630);

        DeployStatics.V4Config memory config = harness.loadV4Config();

        assertEq(config.poolManager, 0x8366a39CC670B4001A1121B8F6A443A643e40951);
        assertEq(config.positionManager, 0x58daec3116aae6D93017bAAea7749052E8a04fA7);
        assertEq(config.permit2, 0x000000000022D473030F116dDEE9F6B43aC78BA3);
        assertEq(config.inputFeeBps, 50);
        assertEq(config.outputFeeBps, 50);
        assertEq(config.positionManagerCodeHash, 0xf3a0edb689229fa4bf135a728f2ec2eb4a2fbee2e41e3e74ffadb7b4c56e8a6d);
    }

    function testTestnetManifestPinsVerifiedWeth() public view {
        string memory manifest = vm.readFile("deployments/robinhood-chain-testnet-46630.json");

        assertEq(
            vm.parseJsonAddress(manifest, ".staticsDollarDependencies.weth.address"),
            0x33e4191705c386532ba27cBF171Db86919200B94
        );
        assertEq(
            vm.parseJsonBytes32(manifest, ".staticsDollarDependencies.weth.runtimeCodeHash"),
            0x55f8ac53c64450f01880d8249fc5cb0c69c064e4bcb097ea80a02fff40485a7c
        );
    }

    function testRobinhoodManifestsRequireDonationGuardedHook() public view {
        string memory mainnetManifest = vm.readFile("deployments/robinhood-chain-4663.json");
        string memory testnetManifest = vm.readFile("deployments/robinhood-chain-testnet-46630.json");

        assertEq(vm.parseJsonString(mainnetManifest, ".staticsLiquidityCalibration.hookPermissionMask"), "0x10ec");
        assertEq(vm.parseJsonString(testnetManifest, ".staticsLiquidityCalibration.hookPermissionMask"), "0x10ec");
    }

    function testRobinhoodManifestsPinSevenWayFeeSplit() public view {
        _assertSevenWayFeeSplit(vm.readFile("deployments/robinhood-chain-4663.json"));
        _assertSevenWayFeeSplit(vm.readFile("deployments/robinhood-chain-testnet-46630.json"));
    }

    function _assertSevenWayFeeSplit(string memory manifest) private pure {
        string memory root = ".staticsLiquidityCalibration";
        assertEq(vm.parseJsonUint(manifest, string.concat(root, ".lockedLiquidityShareBps")), 1_000);
        assertEq(vm.parseJsonUint(manifest, string.concat(root, ".liquidityProviderShareBps")), 2_000);
        assertEq(vm.parseJsonUint(manifest, string.concat(root, ".basketStakerShareBps")), 2_000);
        assertEq(vm.parseJsonUint(manifest, string.concat(root, ".staticsStakerShareBps")), 1_500);
        assertEq(vm.parseJsonUint(manifest, string.concat(root, ".stonkBrokersShareBps")), 1_000);
        assertEq(vm.parseJsonUint(manifest, string.concat(root, ".indexCreatorShareBps")), 500);
        assertEq(vm.parseJsonUint(manifest, string.concat(root, ".treasuryShareBps")), 2_000);
    }
}
