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
import {StaticsLiquidityManager} from "../src/liquidity/StaticsLiquidityManager.sol";
import {StaticsPermanentLiquidityMath} from "../src/liquidity/StaticsPermanentLiquidityMath.sol";
import {StaticsSwapFeeHook} from "../src/liquidity/StaticsSwapFeeHook.sol";

interface IPhaseOnePositionManagerBindings {
    function poolManager() external view returns (address);
    function permit2() external view returns (address);
}

struct StaticsPhaseOneDeployment {
    address diamond;
    address positionNFT;
    address weth;
    address poolManager;
    address positionManager;
    address permit2;
    address permanentLiquidityMath;
    address swapFeeHook;
    address liquidityManager;
}

/// @notice Deploys only the independently launchable Statics Phase 1 surface.
/// @dev Basket and general-pool creation fees are deliberately fixed at zero. In the
/// current protocol semantics that keeps creation owner-curated without an economic cap.
contract DeployStaticsPhaseOne is Script, DeployStaticsProtocol, RobinhoodDeploymentConfig {
    struct Config {
        address multisig;
        address guardian;
        address treasury;
        address stakingToken;
        address weth;
        uint256 positionCreationFeeAmount;
        uint256 singleAssetFlashFeeBps;
    }

    struct V4Config {
        address poolManager;
        address positionManager;
        address permit2;
        uint16 inputFeeBps;
        uint16 outputFeeBps;
        bytes32 poolManagerCodeHash;
        bytes32 positionManagerCodeHash;
        bytes32 permit2CodeHash;
    }

    error InvalidConfig();
    error InvalidChain(uint256 expected, uint256 actual);
    error InvalidV4Contract(address target);
    error InvalidV4CodeHash(address target, bytes32 expected, bytes32 actual);
    error InvalidV4Binding(address target, address expected, address actual);
    error InvalidHookFees(uint256 inputFeeBps, uint256 outputFeeBps);
    error HookAddressMismatch(address expected, address actual);

    uint160 private constant REQUIRED_HOOK_FLAGS = Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG
        | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        | Hooks.BEFORE_DONATE_FLAG;
    address public constant FOUNDRY_CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function run() external returns (StaticsPhaseOneDeployment memory deployment, StaticsTimelock timelock) {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        Config memory config = Config({
            multisig: vm.envAddress("MULTISIG"),
            guardian: vm.envAddress("GUARDIAN"),
            treasury: vm.envAddress("TREASURY"),
            stakingToken: vm.envAddress("STAKING_TOKEN"),
            weth: vm.envAddress("WETH_ADDRESS"),
            positionCreationFeeAmount: vm.envUint("POSITION_CREATION_FEE_AMOUNT"),
            singleAssetFlashFeeBps: vm.envUint("STATICS_SINGLE_ASSET_FLASH_FEE_BPS")
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
            ProtocolDeploymentConfig({
                pool: address(0),
                weth: config.weth,
                finalOwner: address(timelock),
                guardian: config.guardian,
                treasury: config.treasury,
                stakingToken: config.stakingToken,
                creationFeeAmount: 0,
                positionCreationFeeAmount: config.positionCreationFeeAmount,
                poolCreationFeeAmount: 0,
                singleAssetFlashFeeBps: config.singleAssetFlashFeeBps
            })
        );
        deployment.weth = config.weth;
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
        StaticsLiquidityManager manager =
            new StaticsLiquidityManager(deployment.diamond, config.positionManager, config.poolManager, config.permit2);

        deployment.poolManager = config.poolManager;
        deployment.positionManager = config.positionManager;
        deployment.permit2 = config.permit2;
        deployment.permanentLiquidityMath = address(permanentLiquidityMath);
        deployment.swapFeeHook = address(hook);
        deployment.liquidityManager = address(manager);
    }

    function _validateConfig(Config memory config) private view {
        if (
            config.multisig == address(0) || config.guardian == address(0) || config.treasury == address(0)
                || config.stakingToken == address(0) || config.weth == address(0)
                || config.stakingToken.code.length == 0 || config.weth.code.length == 0
        ) revert InvalidConfig();
    }

    function _validateV4(V4Config memory config) private view {
        if (
            config.inputFeeBps == 0 || config.outputFeeBps == 0
                || uint256(config.inputFeeBps) + uint256(config.outputFeeBps) > 200
        ) revert InvalidHookFees(config.inputFeeBps, config.outputFeeBps);
        _validateContract(config.poolManager, config.poolManagerCodeHash);
        _validateContract(config.positionManager, config.positionManagerCodeHash);
        _validateContract(config.permit2, config.permit2CodeHash);
        address boundPoolManager = IPhaseOnePositionManagerBindings(config.positionManager).poolManager();
        if (boundPoolManager != config.poolManager) {
            revert InvalidV4Binding(config.positionManager, config.poolManager, boundPoolManager);
        }
        address boundPermit2 = IPhaseOnePositionManagerBindings(config.positionManager).permit2();
        if (boundPermit2 != config.permit2) {
            revert InvalidV4Binding(config.positionManager, config.permit2, boundPermit2);
        }
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
            positionManager: vm.parseJsonAddress(manifest, ".contracts.positionManager.address"),
            permit2: vm.parseJsonAddress(manifest, ".contracts.permit2.address"),
            inputFeeBps: uint16(inputFee),
            outputFeeBps: uint16(outputFee),
            poolManagerCodeHash: vm.parseJsonBytes32(manifest, ".contracts.poolManager.runtimeCodeHash"),
            positionManagerCodeHash: vm.parseJsonBytes32(manifest, ".contracts.positionManager.runtimeCodeHash"),
            permit2CodeHash: vm.parseJsonBytes32(manifest, ".contracts.permit2.runtimeCodeHash")
        });
    }

    function _logDeployment(StaticsPhaseOneDeployment memory deployment, StaticsTimelock timelock) private view {
        console2.log("STATICS_DIAMOND_ADDRESS", deployment.diamond);
        console2.log("STATICS_POSITION_NFT_ADDRESS", deployment.positionNFT);
        console2.log("STATICS_TIMELOCK_ADDRESS", address(timelock));
        console2.log("WETH_ADDRESS", deployment.weth);
        console2.log("STATICS_POOL_MANAGER_ADDRESS", deployment.poolManager);
        console2.log("STATICS_POSITION_MANAGER_ADDRESS", deployment.positionManager);
        console2.log("STATICS_PERMIT2_ADDRESS", deployment.permit2);
        console2.log("STATICS_PERMANENT_LIQUIDITY_MATH_ADDRESS", deployment.permanentLiquidityMath);
        console2.log("STATICS_PERMANENT_LIQUIDITY_MATH_RUNTIME_CODE_HASH");
        console2.logBytes32(deployment.permanentLiquidityMath.codehash);
        console2.log("STATICS_SWAP_FEE_HOOK_ADDRESS", deployment.swapFeeHook);
        console2.log("STATICS_SWAP_FEE_HOOK_RUNTIME_CODE_HASH");
        console2.logBytes32(deployment.swapFeeHook.codehash);
        console2.log("STATICS_LIQUIDITY_MANAGER_ADDRESS", deployment.liquidityManager);
        console2.log("STATICS_LIQUIDITY_MANAGER_RUNTIME_CODE_HASH");
        console2.logBytes32(deployment.liquidityManager.codehash);
    }
}
