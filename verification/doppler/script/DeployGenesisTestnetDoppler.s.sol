// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Hooks} from "@v4-core/libraries/Hooks.sol";
import {IPoolManager} from "@v4-core/interfaces/IPoolManager.sol";
import {HookMiner} from "@v4-periphery/utils/HookMiner.sol";
import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {Airlock, ModuleState} from "src/Airlock.sol";
import {LaunchpadGovernanceFactory} from "src/governance/LaunchpadGovernanceFactory.sol";
import {DopplerHookInitializer} from "src/initializers/DopplerHookInitializer.sol";
import {NoOpMigrator} from "src/migrators/NoOpMigrator.sol";
import {DopplerERC20V1Factory} from "src/tokens/DopplerERC20V1Factory.sol";

struct GenesisTestnetDopplerDeployment {
    address airlock;
    address tokenFactory;
    address tokenImplementation;
    address governanceFactory;
    address poolInitializer;
    address noOpMigrator;
}

/// @notice Deploys only the pinned Doppler modules used by the standalone Statics Genesis launch.
contract DeployGenesisTestnetDoppler is Script {
    uint256 public constant ROBINHOOD_TESTNET_CHAIN_ID = 46_630;
    address public constant FOUNDRY_CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    uint160 public constant REQUIRED_HOOK_FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
            | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
    );

    error UnsupportedChain(uint256 chainId);
    error ZeroAddress();
    error MissingCode(address target);
    error UnexpectedHookAddress(address expected, address actual);

    function run() external returns (GenesisTestnetDopplerDeployment memory deployment) {
        if (block.chainid != ROBINHOOD_TESTNET_CHAIN_ID) revert UnsupportedChain(block.chainid);

        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(privateKey);
        address feeRecipient = vm.envOr("DOPPLER_FEE_RECIPIENT", deployer);
        address poolManager = vm.envAddress("ROBINHOOD_POOL_MANAGER");
        string memory outputPath = vm.envString("STATICS_TESTNET_DOPPLER_ARTIFACT");
        if (FOUNDRY_CREATE2_DEPLOYER.code.length == 0) revert MissingCode(FOUNDRY_CREATE2_DEPLOYER);

        vm.startBroadcast(privateKey);
        deployment = deploy(deployer, feeRecipient, poolManager, FOUNDRY_CREATE2_DEPLOYER);
        vm.stopBroadcast();

        writeArtifact(outputPath, deployer, feeRecipient, poolManager, deployment);
        _log(deployment);
    }

    function deploy(address initialOwner, address feeRecipient, address poolManager, address hookDeployer)
        public
        returns (GenesisTestnetDopplerDeployment memory deployment)
    {
        if (initialOwner == address(0) || feeRecipient == address(0) || poolManager == address(0)) {
            revert ZeroAddress();
        }
        if (poolManager.code.length == 0) revert MissingCode(poolManager);

        Airlock airlock = new Airlock(initialOwner);
        DopplerERC20V1Factory tokenFactory = new DopplerERC20V1Factory(address(airlock));
        LaunchpadGovernanceFactory governanceFactory = new LaunchpadGovernanceFactory();
        NoOpMigrator noOpMigrator = new NoOpMigrator(address(airlock));

        bytes memory constructorArgs = abi.encode(address(airlock), IPoolManager(poolManager));
        (address expectedInitializer, bytes32 hookSalt) = HookMiner.find(
            hookDeployer, REQUIRED_HOOK_FLAGS, type(DopplerHookInitializer).creationCode, constructorArgs
        );
        DopplerHookInitializer poolInitializer =
            new DopplerHookInitializer{salt: hookSalt}(address(airlock), IPoolManager(poolManager));
        if (address(poolInitializer) != expectedInitializer) {
            revert UnexpectedHookAddress(expectedInitializer, address(poolInitializer));
        }

        address[] memory modules = new address[](4);
        modules[0] = address(tokenFactory);
        modules[1] = address(governanceFactory);
        modules[2] = address(poolInitializer);
        modules[3] = address(noOpMigrator);
        ModuleState[] memory states = new ModuleState[](4);
        states[0] = ModuleState.TokenFactory;
        states[1] = ModuleState.GovernanceFactory;
        states[2] = ModuleState.PoolInitializer;
        states[3] = ModuleState.LiquidityMigrator;
        airlock.setModuleState(modules, states);
        airlock.transferOwnership(feeRecipient);

        deployment = GenesisTestnetDopplerDeployment({
            airlock: address(airlock),
            tokenFactory: address(tokenFactory),
            tokenImplementation: tokenFactory.IMPLEMENTATION(),
            governanceFactory: address(governanceFactory),
            poolInitializer: address(poolInitializer),
            noOpMigrator: address(noOpMigrator)
        });
    }

    function writeArtifact(
        string memory path,
        address deployer,
        address feeRecipient,
        address poolManager,
        GenesisTestnetDopplerDeployment memory deployment
    ) public {
        string memory objectKey = "genesis-testnet-doppler";
        vm.serializeUint(objectKey, "schemaVersion", 1);
        vm.serializeUint(objectKey, "chainId", block.chainid);
        vm.serializeAddress(objectKey, "deployer", deployer);
        vm.serializeAddress(objectKey, "feeRecipient", feeRecipient);
        vm.serializeAddress(objectKey, "poolManager", poolManager);
        vm.serializeAddress(objectKey, "airlock", deployment.airlock);
        vm.serializeAddress(objectKey, "tokenFactory", deployment.tokenFactory);
        vm.serializeAddress(objectKey, "tokenImplementation", deployment.tokenImplementation);
        vm.serializeAddress(objectKey, "governanceFactory", deployment.governanceFactory);
        vm.serializeAddress(objectKey, "poolInitializer", deployment.poolInitializer);
        string memory json = vm.serializeAddress(objectKey, "noOpMigrator", deployment.noOpMigrator);
        vm.writeJson(json, path);
    }

    function _log(GenesisTestnetDopplerDeployment memory deployment) private pure {
        console2.log("DOPPLER_AIRLOCK", deployment.airlock);
        console2.log("DOPPLER_TOKEN_FACTORY", deployment.tokenFactory);
        console2.log("DOPPLER_TOKEN_IMPLEMENTATION", deployment.tokenImplementation);
        console2.log("DOPPLER_GOVERNANCE_FACTORY", deployment.governanceFactory);
        console2.log("DOPPLER_POOL_INITIALIZER", deployment.poolInitializer);
        console2.log("DOPPLER_NO_OP_MIGRATOR", deployment.noOpMigrator);
    }
}
