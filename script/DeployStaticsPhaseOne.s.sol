// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {DeployStaticsProtocol} from "./dollar/DeployStaticsProtocol.s.sol";
import {RobinhoodDeploymentConfig} from "./RobinhoodDeploymentConfig.sol";
import {StaticsTimelock} from "../src/governance/StaticsTimelock.sol";
import {IDiamondLoupe} from "../src/interfaces/IDiamondLoupe.sol";
import {StaticsPermanentLiquidityMath} from "../src/liquidity/StaticsPermanentLiquidityMath.sol";
import {StaticsPermissionedSwapFeeHook} from "../src/liquidity/StaticsPermissionedSwapFeeHook.sol";
import {StaticsSwapFeeHook} from "../src/liquidity/StaticsSwapFeeHook.sol";
import {DefaultVenueControllerFactory} from "../src/permissioned/DefaultVenueControllerFactory.sol";

struct StaticsPhaseOneDeployment {
    address diamond;
    address positionNFT;
    address weth;
    address poolManager;
    address permanentLiquidityMath;
    address swapFeeHook;
    address permissionedSwapFeeHook;
    address defaultVenueControllerFactory;
}

/// @notice Deploys only the independently launchable Statics Phase 1 surface.
/// @dev The general-pool creation fee is deliberately fixed at zero. Under current semantics this
/// keeps creation owner-curated until governance deliberately enables permissionless creation.
contract DeployStaticsPhaseOne is Script, DeployStaticsProtocol, RobinhoodDeploymentConfig {
    struct Config {
        address multisig;
        address guardian;
        address treasury;
        address stakingToken;
        address weth;
        uint256 positionCreationFeeAmount;
    }

    struct V4Config {
        address poolManager;
        uint16 inputFeeBps;
        uint16 outputFeeBps;
        bytes32 poolManagerCodeHash;
    }

    error InvalidConfig();
    error InvalidChain(uint256 expected, uint256 actual);
    error InvalidGenesisBinding(address expected, address actual);
    error InvalidV4Contract(address target);
    error InvalidV4CodeHash(address target, bytes32 expected, bytes32 actual);
    error InvalidHookFees(uint256 inputFeeBps, uint256 outputFeeBps);
    error HookAddressMismatch(address expected, address actual);

    uint160 private constant REQUIRED_HOOK_FLAGS = Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG
        | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        | Hooks.BEFORE_DONATE_FLAG;
    uint160 private constant REQUIRED_PERMISSIONED_HOOK_FLAGS = Hooks.AFTER_INITIALIZE_FLAG
        | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_DONATE_FLAG;
    address public constant FOUNDRY_CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function run() external returns (StaticsPhaseOneDeployment memory deployment, StaticsTimelock timelock) {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        Config memory config = Config({
            multisig: vm.envAddress("MULTISIG"),
            guardian: vm.envAddress("GUARDIAN"),
            treasury: vm.envAddress("TREASURY"),
            stakingToken: vm.envAddress("STAKING_TOKEN"),
            weth: vm.envAddress("WETH_ADDRESS"),
            positionCreationFeeAmount: vm.envUint("POSITION_CREATION_FEE_AMOUNT")
        });
        V4Config memory v4 = _loadRobinhoodV4Config();

        vm.startBroadcast(privateKey);
        (deployment, timelock) = _deploy(config);
        _deployLiquidityContracts(deployment, v4, FOUNDRY_CREATE2_DEPLOYER);
        vm.stopBroadcast();
        _logDeployment(deployment, timelock);
    }

    function deploy(Config memory config)
        public
        returns (StaticsPhaseOneDeployment memory deployment, StaticsTimelock timelock)
    {
        return _deploy(config);
    }

    function deployWithLiquidity(Config memory config, V4Config memory v4)
        public
        returns (StaticsPhaseOneDeployment memory deployment, StaticsTimelock timelock)
    {
        (deployment, timelock) = _deploy(config);
        _deployLiquidityContracts(deployment, v4, address(this));
    }

    function _deploy(Config memory config)
        private
        returns (StaticsPhaseOneDeployment memory deployment, StaticsTimelock timelock)
    {
        _validateConfig(config);
        timelock = _deployTimelock(config.multisig, config.guardian);
        (deployment.diamond, deployment.positionNFT) = _deployPhaseOneStaticsProtocol(
            PhaseOneProtocolDeploymentConfig({
                weth: config.weth,
                finalOwner: address(timelock),
                guardian: config.guardian,
                treasury: config.treasury,
                stakingToken: config.stakingToken,
                positionCreationFeeAmount: config.positionCreationFeeAmount,
                poolCreationFeeAmount: 0
            })
        );
        deployment.weth = config.weth;
        deployment.defaultVenueControllerFactory = address(new DefaultVenueControllerFactory());
    }

    function _deployTimelock(address multisig, address guardian) private returns (StaticsTimelock timelock) {
        address[] memory proposers = new address[](1);
        proposers[0] = multisig;
        address[] memory executors = new address[](1);
        executors[0] = address(0);
        address[] memory cancellers = new address[](1);
        cancellers[0] = guardian;
        timelock = new StaticsTimelock(proposers, executors, cancellers, address(0));
    }

    function _deployLiquidityContracts(
        StaticsPhaseOneDeployment memory deployment,
        V4Config memory config,
        address create2Deployer
    ) private {
        _validateV4(config);
        StaticsPermanentLiquidityMath permanentLiquidityMath = new StaticsPermanentLiquidityMath();
        bytes memory constructorArgs = abi.encode(
            IPoolManager(config.poolManager),
            deployment.diamond,
            config.inputFeeBps,
            config.outputFeeBps,
            permanentLiquidityMath
        );
        (address expectedHook, bytes32 salt) =
            HookMiner.find(create2Deployer, REQUIRED_HOOK_FLAGS, type(StaticsSwapFeeHook).creationCode, constructorArgs);
        StaticsSwapFeeHook hook = new StaticsSwapFeeHook{salt: salt}(
            IPoolManager(config.poolManager),
            deployment.diamond,
            config.inputFeeBps,
            config.outputFeeBps,
            permanentLiquidityMath
        );
        if (address(hook) != expectedHook) revert HookAddressMismatch(expectedHook, address(hook));

        bytes memory permissionedConstructorArgs = abi.encode(IPoolManager(config.poolManager), deployment.diamond);
        (address expectedPermissionedHook, bytes32 permissionedSalt) = HookMiner.find(
            create2Deployer,
            REQUIRED_PERMISSIONED_HOOK_FLAGS,
            type(StaticsPermissionedSwapFeeHook).creationCode,
            permissionedConstructorArgs
        );
        StaticsPermissionedSwapFeeHook permissionedHook = new StaticsPermissionedSwapFeeHook{salt: permissionedSalt}(
            IPoolManager(config.poolManager), deployment.diamond
        );
        if (address(permissionedHook) != expectedPermissionedHook) {
            revert HookAddressMismatch(expectedPermissionedHook, address(permissionedHook));
        }

        deployment.poolManager = config.poolManager;
        deployment.permanentLiquidityMath = address(permanentLiquidityMath);
        deployment.swapFeeHook = address(hook);
        deployment.permissionedSwapFeeHook = address(permissionedHook);
    }

    function _validateConfig(Config memory config) private view {
        if (
            config.multisig == address(0) || config.guardian == address(0) || config.treasury == address(0)
                || config.stakingToken == address(0) || config.weth == address(0)
                || config.stakingToken.code.length == 0 || config.weth.code.length == 0
        ) revert InvalidConfig();
        _validateMainnetGenesisBindings(config);
    }

    function _validateMainnetGenesisBindings(Config memory config) private view {
        if (block.chainid != ROBINHOOD_MAINNET_CHAIN_ID) return;
        string memory manifest = vm.readFile("deployments/robinhood-mainnet-genesis.json");
        uint256 expectedChainId = vm.parseJsonUint(manifest, ".network.chainId");
        if (block.chainid != expectedChainId) revert InvalidChain(expectedChainId, block.chainid);

        address expectedStatics = vm.parseJsonAddress(manifest, ".contracts.staticsToken.address");
        address expectedWeth = vm.parseJsonAddress(manifest, ".externalDependencies.weth.address");
        address expectedTreasury = vm.parseJsonAddress(manifest, ".roles.treasury");
        if (config.stakingToken != expectedStatics) revert InvalidGenesisBinding(expectedStatics, config.stakingToken);
        if (config.weth != expectedWeth) revert InvalidGenesisBinding(expectedWeth, config.weth);
        if (config.treasury != expectedTreasury) revert InvalidGenesisBinding(expectedTreasury, config.treasury);
        _validateContract(config.stakingToken, vm.parseJsonBytes32(manifest, ".contracts.staticsToken.runtimeCodeHash"));
        _validateContract(config.weth, vm.parseJsonBytes32(manifest, ".externalDependencies.weth.runtimeCodeHash"));
    }

    function _validateV4(V4Config memory config) private view {
        if (
            config.inputFeeBps == 0 || config.outputFeeBps == 0
                || uint256(config.inputFeeBps) + uint256(config.outputFeeBps) > 200
        ) revert InvalidHookFees(config.inputFeeBps, config.outputFeeBps);
        _validateContract(config.poolManager, config.poolManagerCodeHash);
    }

    function _validateContract(address target, bytes32 expectedHash) private view {
        if (target.code.length == 0) revert InvalidV4Contract(target);
        bytes32 actualHash = target.codehash;
        if (expectedHash != bytes32(0) && actualHash != expectedHash) {
            revert InvalidV4CodeHash(target, expectedHash, actualHash);
        }
    }

    function _loadRobinhoodV4Config() private view returns (V4Config memory config) {
        string memory manifest = vm.readFile(_robinhoodManifestPath(block.chainid));
        uint256 expectedChainId = vm.parseJsonUint(manifest, ".chainId");
        if (block.chainid != expectedChainId) revert InvalidChain(expectedChainId, block.chainid);
        uint256 inputFee = vm.parseJsonUint(manifest, ".staticsLiquidityCalibration.inputFeeBps");
        uint256 outputFee = vm.parseJsonUint(manifest, ".staticsLiquidityCalibration.outputFeeBps");
        if (inputFee > type(uint16).max || outputFee > type(uint16).max) {
            revert InvalidHookFees(inputFee, outputFee);
        }
        config = V4Config({
            poolManager: vm.parseJsonAddress(manifest, ".contracts.poolManager.address"),
            inputFeeBps: uint16(inputFee),
            outputFeeBps: uint16(outputFee),
            poolManagerCodeHash: vm.parseJsonBytes32(manifest, ".contracts.poolManager.runtimeCodeHash")
        });
    }

    function _logDeployment(StaticsPhaseOneDeployment memory deployment, StaticsTimelock timelock) private view {
        console2.log("STATICS_DIAMOND_ADDRESS", deployment.diamond);
        console2.log("STATICS_DIAMOND_RUNTIME_CODE_HASH");
        console2.logBytes32(deployment.diamond.codehash);
        console2.log("STATICS_POSITION_NFT_ADDRESS", deployment.positionNFT);
        console2.log("STATICS_TIMELOCK_ADDRESS", address(timelock));
        console2.log("STATICS_TIMELOCK_RUNTIME_CODE_HASH");
        console2.logBytes32(address(timelock).codehash);
        console2.log("WETH_ADDRESS", deployment.weth);
        console2.log("STATICS_POOL_MANAGER_ADDRESS", deployment.poolManager);
        console2.log("STATICS_PERMANENT_LIQUIDITY_MATH_ADDRESS", deployment.permanentLiquidityMath);
        console2.log("STATICS_PERMANENT_LIQUIDITY_MATH_RUNTIME_CODE_HASH");
        console2.logBytes32(deployment.permanentLiquidityMath.codehash);
        console2.log("STATICS_SWAP_FEE_HOOK_ADDRESS", deployment.swapFeeHook);
        console2.log("STATICS_SWAP_FEE_HOOK_RUNTIME_CODE_HASH");
        console2.logBytes32(deployment.swapFeeHook.codehash);
        console2.log("STATICS_PERMISSIONED_SWAP_FEE_HOOK_ADDRESS", deployment.permissionedSwapFeeHook);
        console2.log("STATICS_PERMISSIONED_SWAP_FEE_HOOK_RUNTIME_CODE_HASH");
        console2.logBytes32(deployment.permissionedSwapFeeHook.codehash);
        console2.log("STATICS_DEFAULT_VENUE_CONTROLLER_FACTORY", deployment.defaultVenueControllerFactory);
        console2.log("STATICS_DEFAULT_VENUE_CONTROLLER_FACTORY_RUNTIME_CODE_HASH");
        console2.logBytes32(deployment.defaultVenueControllerFactory.codehash);
        address[] memory facets = IDiamondLoupe(deployment.diamond).facetAddresses();
        for (uint256 i; i < facets.length; ++i) {
            console2.log("STATICS_PHASE_ONE_FACET_ADDRESS", facets[i]);
            console2.log("STATICS_PHASE_ONE_FACET_RUNTIME_CODE_HASH");
            console2.logBytes32(facets[i].codehash);
            console2.log(
                "STATICS_PHASE_ONE_FACET_SELECTOR_COUNT",
                IDiamondLoupe(deployment.diamond).facetFunctionSelectors(facets[i]).length
            );
        }
    }
}
