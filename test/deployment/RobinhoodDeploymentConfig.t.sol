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

    function testMainnetManifestPinsVerifiedWeth() public view {
        string memory manifest = vm.readFile("deployments/robinhood-chain-4663.json");

        assertEq(vm.parseJsonAddress(manifest, ".contracts.weth.address"), 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73);
        assertEq(
            vm.parseJsonBytes32(manifest, ".contracts.weth.runtimeCodeHash"),
            0x5706be52f64875fee65a2cec0d80e47a23d8793cbe85d214b48445e2d05f5353
        );
    }

    function testMainnetManifestPinsVerifiedDopplerModules() public view {
        string memory manifest = vm.readFile("deployments/robinhood-chain-4663.json");

        _assertManifestContract(
            manifest,
            ".contracts.dopplerAirlock",
            0xeb7C034704eF8Dcd2D32324c1545f62fB4aD0862,
            0x86b37100cbe9841771c452a592985b4e921254b127a380246073b84ec953f7f8
        );
        _assertManifestContract(
            manifest,
            ".contracts.dopplerTokenFactory",
            0x1B37D3a72082029c44B35B604Ea473617580b69a,
            0x27abd63146eb5743b7871e211da17163afbb495863a626c0d002312af6813459
        );
        _assertManifestContract(
            manifest,
            ".contracts.dopplerGovernanceFactory",
            0xdb036746D65DD52126b1915f1AdF555e6C5237Cf,
            0xefce8ac4a6fe83ae3dd1c3cfebc0e370e1595a66608bed5610ffdd1f291b7f63
        );
        _assertManifestContract(
            manifest,
            ".contracts.dopplerPoolInitializer",
            0x4e3468951D49f2EEa976eD0D6e75fFCb44a9a544,
            0xc41a91106002f15bf70ae266824317f3f3ac638ac72ca5253bae395fa47ee631
        );
        _assertManifestContract(
            manifest,
            ".contracts.dopplerNoOpMigrator",
            0xba2F330EDb16cD8056f5988d8CE19BbC63475A0e,
            0x7bf5115543e8e0769ceabe4da9b8e23547c9e95c1cce15d24d96f164406129e3
        );
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

    function _assertManifestContract(
        string memory manifest,
        string memory path,
        address expectedAddress,
        bytes32 expectedCodeHash
    ) private pure {
        assertEq(vm.parseJsonAddress(manifest, string.concat(path, ".address")), expectedAddress);
        assertEq(vm.parseJsonBytes32(manifest, string.concat(path, ".runtimeCodeHash")), expectedCodeHash);
    }
}
