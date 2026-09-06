// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Script} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {StaticsTimelock} from "../src/governance/StaticsTimelock.sol";
import {StaticsLaunchLiquidityHook} from "../src/liquidity/StaticsLaunchLiquidityHook.sol";

interface ILaunchPositionManagerBindings {
    function poolManager() external view returns (address);
    function permit2() external view returns (address);
}

/// @notice Deploys the standalone temporary launch hook and a dedicated administration timelock.
/// The governance Safe executes the artifact's `registerAndInitializeCalldata` after reviewing the
/// explicit tick spacing and initial price. No full-protocol or Genesis contract is deployed here.
contract DeployStaticsLaunchLiquidity is Script {
    using PoolIdLibrary for PoolKey;

    uint256 public constant ROBINHOOD_MAINNET_CHAIN_ID = 4_663;
    uint24 public constant NATIVE_LP_FEE = 3_000;
    address public constant FOUNDRY_CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    uint160 public constant REQUIRED_HOOK_FLAGS = Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG
        | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;

    struct Config {
        uint256 chainId;
        address poolManager;
        address positionManager;
        address permit2;
        address statics;
        address weth;
        address governance;
        address feeReceiver;
        address liquidityReceiver;
        address liquidityAdmin;
        int24 tickSpacing;
        uint160 sqrtPriceX96;
        bytes32 poolManagerCodeHash;
        bytes32 positionManagerCodeHash;
        bytes32 permit2CodeHash;
        bytes32 staticsCodeHash;
        bytes32 wethCodeHash;
    }

    struct Deployment {
        StaticsTimelock timelock;
        StaticsLaunchLiquidityHook hook;
        PoolKey key;
        PoolId poolId;
        bytes32 create2Salt;
    }

    error InvalidChain(uint256 expected, uint256 actual);
    error InvalidConfig();
    error InvalidV4Contract(address target);
    error InvalidCodeHash(address target, bytes32 expected, bytes32 actual);
    error InvalidV4Binding(address target, address expected, address actual);
    error HookAddressMismatch(address expected, address actual);
    error HookPermissionMismatch(uint160 expected, uint160 actual);
    error EmptyArtifactPath();

    function run() external returns (Deployment memory deployment) {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        Config memory config = loadRobinhoodConfig();
        vm.startBroadcast(privateKey);
        deployment = deploy(config, FOUNDRY_CREATE2_DEPLOYER);
        vm.stopBroadcast();
        vm.createDir("artifacts/launch-liquidity", true);
        string memory artifactPath =
            vm.envOr("STATICS_LAUNCH_LIQUIDITY_ARTIFACT", string("artifacts/launch-liquidity/robinhood-4663.json"));
        writeArtifact(artifactPath, config, deployment, vm.addr(privateKey));
    }

    function deploy(Config memory config, address create2Deployer) public returns (Deployment memory deployment) {
        _validate(config);
        address[] memory proposers = new address[](1);
        proposers[0] = config.governance;
        address[] memory executors = new address[](1);
        executors[0] = address(0);
        deployment.timelock = new StaticsTimelock(proposers, executors, address(0));

        bytes memory args = abi.encode(
            IPoolManager(config.poolManager),
            address(deployment.timelock),
            config.feeReceiver,
            config.liquidityReceiver,
            config.liquidityAdmin
        );
        (address expectedHook, bytes32 salt) =
            HookMiner.find(create2Deployer, REQUIRED_HOOK_FLAGS, type(StaticsLaunchLiquidityHook).creationCode, args);
        deployment.hook = new StaticsLaunchLiquidityHook{salt: salt}(
            IPoolManager(config.poolManager),
            address(deployment.timelock),
            config.feeReceiver,
            config.liquidityReceiver,
            config.liquidityAdmin
        );
        if (address(deployment.hook) != expectedHook) {
            revert HookAddressMismatch(expectedHook, address(deployment.hook));
        }
        uint160 actualFlags = uint160(address(deployment.hook)) & Hooks.ALL_HOOK_MASK;
        if (actualFlags != REQUIRED_HOOK_FLAGS) revert HookPermissionMismatch(REQUIRED_HOOK_FLAGS, actualFlags);

        (Currency currency0, Currency currency1) = config.weth < config.statics
            ? (Currency.wrap(config.weth), Currency.wrap(config.statics))
            : (Currency.wrap(config.statics), Currency.wrap(config.weth));
        deployment.key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: NATIVE_LP_FEE,
            tickSpacing: config.tickSpacing,
            hooks: IHooks(deployment.hook)
        });
        deployment.poolId = deployment.key.toId();
        deployment.create2Salt = salt;
    }

    function loadRobinhoodConfig() public view returns (Config memory config) {
        string memory v4Manifest = vm.readFile("deployments/robinhood-chain-4663.json");
        string memory genesisManifest = vm.readFile("deployments/robinhood-mainnet-genesis.json");
        uint256 v4ChainId = vm.parseJsonUint(v4Manifest, ".chainId");
        uint256 genesisChainId = vm.parseJsonUint(genesisManifest, ".network.chainId");
        if (v4ChainId != genesisChainId) revert InvalidChain(v4ChainId, genesisChainId);
        if (v4ChainId != ROBINHOOD_MAINNET_CHAIN_ID) revert InvalidChain(ROBINHOOD_MAINNET_CHAIN_ID, v4ChainId);
        int256 configuredTickSpacing = vm.envInt("STATICS_LAUNCH_TICK_SPACING");
        uint256 configuredSqrtPriceX96 = vm.envUint("STATICS_LAUNCH_SQRT_PRICE_X96");
        if (
            configuredTickSpacing < TickMath.MIN_TICK_SPACING || configuredTickSpacing > TickMath.MAX_TICK_SPACING
                || configuredSqrtPriceX96 > type(uint160).max
        ) revert InvalidConfig();

        address treasury = vm.parseJsonAddress(genesisManifest, ".roles.treasury");
        address governance = vm.parseJsonAddress(genesisManifest, ".roles.governance");
        config = Config({
            chainId: v4ChainId,
            poolManager: vm.parseJsonAddress(v4Manifest, ".contracts.poolManager.address"),
            positionManager: vm.parseJsonAddress(v4Manifest, ".contracts.positionManager.address"),
            permit2: vm.parseJsonAddress(v4Manifest, ".contracts.permit2.address"),
            statics: vm.parseJsonAddress(genesisManifest, ".contracts.staticsToken.address"),
            weth: vm.parseJsonAddress(v4Manifest, ".contracts.weth.address"),
            governance: governance,
            feeReceiver: treasury,
            liquidityReceiver: treasury,
            liquidityAdmin: governance,
            tickSpacing: int24(configuredTickSpacing),
            sqrtPriceX96: uint160(configuredSqrtPriceX96),
            poolManagerCodeHash: vm.parseJsonBytes32(v4Manifest, ".contracts.poolManager.runtimeCodeHash"),
            positionManagerCodeHash: vm.parseJsonBytes32(v4Manifest, ".contracts.positionManager.runtimeCodeHash"),
            permit2CodeHash: vm.parseJsonBytes32(v4Manifest, ".contracts.permit2.runtimeCodeHash"),
            staticsCodeHash: vm.parseJsonBytes32(genesisManifest, ".contracts.staticsToken.runtimeCodeHash"),
            wethCodeHash: vm.parseJsonBytes32(v4Manifest, ".contracts.weth.runtimeCodeHash")
        });
    }

    function writeArtifact(string memory path, Config memory config, Deployment memory deployment, address deployer)
        public
    {
        if (bytes(path).length == 0) revert EmptyArtifactPath();
        string memory objectKey = "launchLiquidity";
        vm.serializeUint(objectKey, "chainId", config.chainId);
        vm.serializeAddress(objectKey, "deployer", deployer);
        vm.serializeAddress(objectKey, "timelock", address(deployment.timelock));
        vm.serializeAddress(objectKey, "hook", address(deployment.hook));
        vm.serializeAddress(objectKey, "poolManager", config.poolManager);
        vm.serializeAddress(objectKey, "positionManager", config.positionManager);
        vm.serializeAddress(objectKey, "permit2", config.permit2);
        vm.serializeAddress(objectKey, "statics", config.statics);
        vm.serializeAddress(objectKey, "weth", config.weth);
        vm.serializeAddress(objectKey, "governance", config.governance);
        vm.serializeAddress(objectKey, "feeReceiver", config.feeReceiver);
        vm.serializeAddress(objectKey, "liquidityReceiver", config.liquidityReceiver);
        vm.serializeAddress(objectKey, "liquidityAdmin", config.liquidityAdmin);
        vm.serializeBytes32(objectKey, "poolId", PoolId.unwrap(deployment.poolId));
        vm.serializeBytes32(objectKey, "create2Salt", deployment.create2Salt);
        vm.serializeBytes32(objectKey, "poolManagerRuntimeCodeHash", config.poolManagerCodeHash);
        vm.serializeBytes32(objectKey, "positionManagerRuntimeCodeHash", config.positionManagerCodeHash);
        vm.serializeBytes32(objectKey, "permit2RuntimeCodeHash", config.permit2CodeHash);
        vm.serializeBytes32(objectKey, "staticsRuntimeCodeHash", config.staticsCodeHash);
        vm.serializeBytes32(objectKey, "wethRuntimeCodeHash", config.wethCodeHash);
        vm.serializeBytes32(objectKey, "hookRuntimeCodeHash", address(deployment.hook).codehash);
        vm.serializeUint(objectKey, "hookPermissionMask", REQUIRED_HOOK_FLAGS);
        vm.serializeUint(objectKey, "nativeLpFeePips", NATIVE_LP_FEE);
        vm.serializeUint(objectKey, "inputFeeBps", deployment.hook.INPUT_FEE_BPS());
        vm.serializeUint(objectKey, "outputFeeBps", deployment.hook.OUTPUT_FEE_BPS());
        vm.serializeUint(objectKey, "polShareBps", deployment.hook.POL_SHARE_BPS());
        vm.serializeInt(objectKey, "tickSpacing", config.tickSpacing);
        vm.serializeUint(objectKey, "sqrtPriceX96", config.sqrtPriceX96);
        bytes memory initializeCalldata =
            abi.encodeCall(StaticsLaunchLiquidityHook.registerAndInitialize, (deployment.key, config.sqrtPriceX96));
        string memory json = vm.serializeBytes(objectKey, "registerAndInitializeCalldata", initializeCalldata);
        vm.writeJson(json, path);
    }

    function _validate(Config memory config) private view {
        if (block.chainid != config.chainId) revert InvalidChain(config.chainId, block.chainid);
        if (
            config.governance == address(0) || config.feeReceiver == address(0)
                || config.liquidityReceiver == address(0) || config.liquidityAdmin == address(0)
                || config.statics == config.weth || config.tickSpacing < TickMath.MIN_TICK_SPACING
                || config.tickSpacing > TickMath.MAX_TICK_SPACING || config.sqrtPriceX96 < TickMath.MIN_SQRT_PRICE
                || config.sqrtPriceX96 >= TickMath.MAX_SQRT_PRICE
        ) revert InvalidConfig();
        _validateContract(config.poolManager, config.poolManagerCodeHash);
        _validateContract(config.positionManager, config.positionManagerCodeHash);
        _validateContract(config.permit2, config.permit2CodeHash);
        _validateContract(config.statics, config.staticsCodeHash);
        _validateContract(config.weth, config.wethCodeHash);
        address boundManager = ILaunchPositionManagerBindings(config.positionManager).poolManager();
        if (boundManager != config.poolManager) {
            revert InvalidV4Binding(config.positionManager, config.poolManager, boundManager);
        }
        address boundPermit2 = ILaunchPositionManagerBindings(config.positionManager).permit2();
        if (boundPermit2 != config.permit2) {
            revert InvalidV4Binding(config.positionManager, config.permit2, boundPermit2);
        }
    }

    function _validateContract(address target, bytes32 expectedHash) private view {
        if (target.code.length == 0) revert InvalidV4Contract(target);
        bytes32 actualHash = target.codehash;
        if (expectedHash != bytes32(0) && expectedHash != actualHash) {
            revert InvalidCodeHash(target, expectedHash, actualHash);
        }
    }
}
