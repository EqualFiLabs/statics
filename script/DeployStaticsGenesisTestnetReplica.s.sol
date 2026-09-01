// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {
    DeployStaticsGenesis,
    StaticsGenesisDeployment,
    StaticsGenesisDeploymentConfig
} from "./DeployStaticsGenesis.s.sol";
import {StaticsDopplerLaunchConfig} from "../src/genesis/doppler/StaticsDopplerLaunchConfig.sol";

/// @notice One-shot Robinhood testnet wrapper for the deployed standalone Genesis launcher.
/// @dev The canonical launcher remains unchanged; only disposable dependencies and testnet roles vary.
contract DeployStaticsGenesisTestnetReplica is DeployStaticsGenesis {
    string public constant MAINNET_GENESIS_SOURCE_COMMIT = "43018f109006aa2c2eef2808adc2aa74dfc9a6d4";
    uint24 public constant MAINNET_DOPPLER_FEE = 15_000;
    uint16 public constant MAINNET_GENESIS_REWARD_SHARE_BPS = 4_000;
    uint16 public constant MAINNET_RESERVE_SHARE_BPS = 500;
    uint256 public constant MAINNET_CREDIT_ORIGINATION_FEE = 0.02 ether;
    uint256 public constant MAINNET_CREDIT_EXTENSION_FEE = 0.008 ether;
    uint16 public constant MAINNET_RECOVERY_CALLER_SHARE_BPS = 2_000;

    error InvalidTestnetChain(uint256 chainId);
    error InvalidDopplerArtifactChain(uint256 expected, uint256 actual);
    error InvalidDependencyAddress(address expected, address actual);
    error InvalidDependencyCodeHash(address dependency, bytes32 expected, bytes32 actual);

    function run() external returns (StaticsGenesisDeployment memory deployment) {
        if (block.chainid != ROBINHOOD_TESTNET_CHAIN_ID) revert InvalidTestnetChain(block.chainid);

        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(privateKey);
        uint256 genesisEpochEnd = vm.envUint("STATICS_GENESIS_EPOCH_END");
        if (genesisEpochEnd <= block.timestamp) revert InvalidEpochEnd(genesisEpochEnd);

        string memory dopplerArtifactPath = vm.envString("STATICS_TESTNET_DOPPLER_ARTIFACT");
        string memory dopplerArtifact = vm.readFile(dopplerArtifactPath);
        StaticsDopplerLaunchConfig.Modules memory modules = _loadModules(dopplerArtifact);
        address weth = _validateChainDependencies(dopplerArtifact);
        StaticsGenesisDeploymentConfig memory config = genesisConfig(
            deployer,
            vm.envOr("STATICS_GENESIS_GOVERNANCE", deployer),
            vm.envOr("STATICS_GENESIS_TREASURY", deployer),
            weth,
            vm.envOr("STATICS_DOPPLER_INTEGRATOR", deployer),
            modules,
            vm.envBytes32("STATICS_DOPPLER_SALT"),
            genesisEpochEnd
        );

        vm.startBroadcast(privateKey);
        deployment = deploy(config, deployer);
        vm.stopBroadcast();

        writeDeploymentArtifact(vm.envString("STATICS_GENESIS_TESTNET_ARTIFACT"), deployer, config, deployment);
        _log(deployment);
    }

    function genesisConfig(
        address deployer,
        address governance,
        address treasury,
        address weth,
        address integrator,
        StaticsDopplerLaunchConfig.Modules memory modules,
        bytes32 salt,
        uint256 genesisEpochEnd
    ) public view returns (StaticsGenesisDeploymentConfig memory config) {
        if (genesisEpochEnd <= block.timestamp) revert InvalidEpochEnd(genesisEpochEnd);
        config = StaticsGenesisDeploymentConfig({
            governance: governance,
            treasury: treasury,
            numeraire: weth,
            integrator: integrator,
            modules: modules,
            salt: salt,
            fee: MAINNET_DOPPLER_FEE,
            genesisRewardShareBps: MAINNET_GENESIS_REWARD_SHARE_BPS,
            reserveShareBps: MAINNET_RESERVE_SHARE_BPS,
            creditOriginationFee: MAINNET_CREDIT_ORIGINATION_FEE,
            creditExtensionFee: MAINNET_CREDIT_EXTENSION_FEE,
            recoveryCallerShareBps: MAINNET_RECOVERY_CALLER_SHARE_BPS,
            genesisEpochEnd: genesisEpochEnd,
            tokenURI: staticsTokenURI(),
            contractURI: staticsGenesisContractURI()
        });
        if (deployer == address(0)) revert ZeroAddress();
    }

    function writeDeploymentArtifact(
        string memory path,
        address deployer,
        StaticsGenesisDeploymentConfig memory config,
        StaticsGenesisDeployment memory deployment
    ) public {
        string memory objectKey = "genesis-testnet-replica";
        vm.serializeUint(objectKey, "schemaVersion", 1);
        vm.serializeString(objectKey, "mainnetGenesisSourceCommit", MAINNET_GENESIS_SOURCE_COMMIT);
        vm.serializeUint(objectKey, "chainId", block.chainid);
        vm.serializeAddress(objectKey, "deployer", deployer);
        vm.serializeAddress(objectKey, "governance", config.governance);
        vm.serializeAddress(objectKey, "treasury", config.treasury);
        vm.serializeAddress(objectKey, "integrator", config.integrator);
        vm.serializeAddress(objectKey, "weth", config.numeraire);
        vm.serializeAddress(objectKey, "dopplerAirlock", config.modules.airlock);
        vm.serializeAddress(objectKey, "dopplerTokenFactory", config.modules.tokenFactory);
        vm.serializeAddress(objectKey, "dopplerGovernanceFactory", config.modules.governanceFactory);
        vm.serializeAddress(objectKey, "dopplerPoolInitializer", config.modules.poolInitializer);
        vm.serializeAddress(objectKey, "dopplerNoOpMigrator", config.modules.noOpMigrator);
        vm.serializeBytes32(objectKey, "salt", config.salt);
        vm.serializeUint(objectKey, "fee", config.fee);
        vm.serializeUint(objectKey, "genesisRewardShareBps", config.genesisRewardShareBps);
        vm.serializeUint(objectKey, "reserveShareBps", config.reserveShareBps);
        vm.serializeUint(objectKey, "creditOriginationFee", config.creditOriginationFee);
        vm.serializeUint(objectKey, "creditExtensionFee", config.creditExtensionFee);
        vm.serializeUint(objectKey, "recoveryCallerShareBps", config.recoveryCallerShareBps);
        vm.serializeUint(objectKey, "genesisEpochEnd", config.genesisEpochEnd);
        vm.serializeAddress(objectKey, "statics", deployment.statics);
        vm.serializeBytes32(objectKey, "poolId", deployment.poolId);
        vm.serializeAddress(objectKey, "feeReceiver", deployment.feeReceiver);
        vm.serializeAddress(objectKey, "treasuryVesting", deployment.treasuryVesting);
        vm.serializeAddress(objectKey, "activationRegistry", deployment.activationRegistry);
        vm.serializeAddress(objectKey, "genesis", deployment.genesis);
        vm.serializeAddress(objectKey, "genesisVault", deployment.genesisVault);
        vm.serializeAddress(objectKey, "genesisDistributor", deployment.genesisDistributor);
        vm.serializeAddress(objectKey, "genesisRenderer", deployment.genesisRenderer);
        string memory json = vm.serializeAddress(objectKey, "avatarSVG", deployment.avatarSVG);
        vm.writeJson(json, path);
    }

    function _loadModules(string memory artifact)
        private
        view
        returns (StaticsDopplerLaunchConfig.Modules memory modules)
    {
        uint256 artifactChainId = vm.parseJsonUint(artifact, ".chainId");
        if (artifactChainId != block.chainid) {
            revert InvalidDopplerArtifactChain(block.chainid, artifactChainId);
        }
        modules = StaticsDopplerLaunchConfig.Modules({
            airlock: vm.parseJsonAddress(artifact, ".airlock"),
            tokenFactory: vm.parseJsonAddress(artifact, ".tokenFactory"),
            governanceFactory: vm.parseJsonAddress(artifact, ".governanceFactory"),
            poolInitializer: vm.parseJsonAddress(artifact, ".poolInitializer"),
            noOpMigrator: vm.parseJsonAddress(artifact, ".noOpMigrator")
        });
    }

    function _validateChainDependencies(string memory dopplerArtifact) private view returns (address weth) {
        string memory chainManifest = vm.readFile(_robinhoodManifestPath(block.chainid));
        weth = vm.parseJsonAddress(chainManifest, ".staticsDollarDependencies.weth.address");
        _requireCodeHash(weth, vm.parseJsonBytes32(chainManifest, ".staticsDollarDependencies.weth.runtimeCodeHash"));

        address expectedPoolManager = vm.parseJsonAddress(chainManifest, ".contracts.poolManager.address");
        address artifactPoolManager = vm.parseJsonAddress(dopplerArtifact, ".poolManager");
        if (artifactPoolManager != expectedPoolManager) {
            revert InvalidDependencyAddress(expectedPoolManager, artifactPoolManager);
        }
        _requireCodeHash(
            expectedPoolManager, vm.parseJsonBytes32(chainManifest, ".contracts.poolManager.runtimeCodeHash")
        );
    }

    function _requireCodeHash(address dependency, bytes32 expectedCodeHash) private view {
        bytes32 actualCodeHash = dependency.codehash;
        if (actualCodeHash != expectedCodeHash) {
            revert InvalidDependencyCodeHash(dependency, expectedCodeHash, actualCodeHash);
        }
    }
}
