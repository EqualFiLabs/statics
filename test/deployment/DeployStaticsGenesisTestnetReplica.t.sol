// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {DeployStaticsGenesis, StaticsGenesisDeploymentConfig} from "../../script/DeployStaticsGenesis.s.sol";
import {DeployStaticsGenesisTestnetReplica} from "../../script/DeployStaticsGenesisTestnetReplica.s.sol";
import {StaticsDopplerLaunchConfig} from "../../src/genesis/doppler/StaticsDopplerLaunchConfig.sol";

contract DeployStaticsGenesisTestnetReplicaTest is Test {
    DeployStaticsGenesisTestnetReplica private replica;

    function setUp() public {
        replica = new DeployStaticsGenesisTestnetReplica();
    }

    function testPinsMainnetGenesisEconomics() public {
        StaticsDopplerLaunchConfig.Modules memory modules = StaticsDopplerLaunchConfig.Modules({
            airlock: makeAddr("airlock"),
            tokenFactory: makeAddr("tokenFactory"),
            governanceFactory: makeAddr("governanceFactory"),
            poolInitializer: makeAddr("poolInitializer"),
            noOpMigrator: makeAddr("noOpMigrator")
        });
        address deployer = makeAddr("deployer");
        address governance = makeAddr("governance");
        address treasury = makeAddr("treasury");
        address weth = makeAddr("weth");
        address integrator = makeAddr("integrator");
        bytes32 salt = keccak256("testnet-replica");
        uint256 epochEnd = block.timestamp + 15 days;

        StaticsGenesisDeploymentConfig memory config =
            replica.genesisConfig(deployer, governance, treasury, weth, integrator, modules, salt, epochEnd);

        assertEq(config.governance, governance);
        assertEq(config.treasury, treasury);
        assertEq(config.numeraire, weth);
        assertEq(config.integrator, integrator);
        assertEq(config.salt, salt);
        assertEq(config.fee, 15_000);
        assertEq(config.genesisRewardShareBps, 4_000);
        assertEq(config.reserveShareBps, 500);
        assertEq(config.creditOriginationFee, 0.02 ether);
        assertEq(config.creditExtensionFee, 0.008 ether);
        assertEq(config.recoveryCallerShareBps, 2_000);
        assertEq(config.genesisEpochEnd, epochEnd);
        assertEq(config.modules.airlock, modules.airlock);
        assertEq(config.modules.tokenFactory, modules.tokenFactory);
        assertEq(config.modules.governanceFactory, modules.governanceFactory);
        assertEq(config.modules.poolInitializer, modules.poolInitializer);
        assertEq(config.modules.noOpMigrator, modules.noOpMigrator);
    }

    function testUsesTheCanonicalMainnetLaunchScriptCommitment() public {
        DeployStaticsGenesis canonical = new DeployStaticsGenesis();
        assertEq(replica.launchScriptCodeHash(), canonical.launchScriptCodeHash());
    }

    function testRejectsExpiredEpoch() public {
        StaticsDopplerLaunchConfig.Modules memory modules;
        vm.expectRevert(abi.encodeWithSelector(DeployStaticsGenesis.InvalidEpochEnd.selector, block.timestamp));
        replica.genesisConfig(
            makeAddr("deployer"),
            makeAddr("governance"),
            makeAddr("treasury"),
            makeAddr("weth"),
            makeAddr("integrator"),
            modules,
            bytes32(0),
            block.timestamp
        );
    }

    function testRunRejectsWrongChainBeforeReadingSecrets() public {
        vm.expectRevert(
            abi.encodeWithSelector(DeployStaticsGenesisTestnetReplica.InvalidTestnetChain.selector, block.chainid)
        );
        replica.run();
    }
}
