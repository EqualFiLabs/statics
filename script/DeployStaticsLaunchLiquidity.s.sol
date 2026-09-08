// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Script} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {StaticsTimelock} from "../src/governance/StaticsTimelock.sol";
import {StaticsLaunchFeeClaimRedeemer} from "../src/liquidity/StaticsLaunchFeeClaimRedeemer.sol";
import {StaticsLaunchLiquidityHook} from "../src/liquidity/StaticsLaunchLiquidityHook.sol";
import {LaunchLiquidityScript} from "./libraries/LaunchLiquidityScript.sol";

interface ILaunchPositionManagerBindings {
    function poolManager() external view returns (address);
    function permit2() external view returns (address);
}

/// @notice Deploys the standalone launch fee hook and prepares one externally owned PositionManager launch.
/// @dev The same hook can register additional PoolKeys after deployment.
contract DeployStaticsLaunchLiquidity is Script {
    using LPFeeLibrary for uint24;
    using PoolIdLibrary for PoolKey;

    uint256 public constant ROBINHOOD_MAINNET_CHAIN_ID = 4_663;
    address public constant FOUNDRY_CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    uint160 public constant REQUIRED_HOOK_FLAGS = Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG
        | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;

    struct Config {
        uint256 chainId;
        address poolManager;
        address positionManager;
        address permit2;
        address statics;
        address pairedToken;
        address governance;
        address feeReceiver;
        address positionOwner;
        LaunchLiquidityScript.FundingMode fundingMode;
        uint24 nativeLpFee;
        int24 tickSpacing;
        uint160 sqrtPriceX96;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint128 amount0Max;
        uint128 amount1Max;
        uint16 inputFeeBps;
        uint16 outputFeeBps;
        bytes32 poolManagerCodeHash;
        bytes32 positionManagerCodeHash;
        bytes32 permit2CodeHash;
        bytes32 staticsCodeHash;
        bytes32 pairedTokenCodeHash;
    }

    struct Deployment {
        StaticsTimelock timelock;
        StaticsLaunchLiquidityHook hook;
        StaticsLaunchFeeClaimRedeemer feeClaimRedeemer;
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
        deployment.feeClaimRedeemer = new StaticsLaunchFeeClaimRedeemer(IPoolManager(config.poolManager));

        bytes memory args = abi.encode(
            IPoolManager(config.poolManager),
            IPositionManager(config.positionManager),
            address(deployment.timelock),
            config.feeReceiver
        );
        (address expectedHook, bytes32 salt) =
            HookMiner.find(create2Deployer, REQUIRED_HOOK_FLAGS, type(StaticsLaunchLiquidityHook).creationCode, args);
        deployment.hook = new StaticsLaunchLiquidityHook{salt: salt}(
            IPoolManager(config.poolManager),
            IPositionManager(config.positionManager),
            address(deployment.timelock),
            config.feeReceiver
        );
        if (address(deployment.hook) != expectedHook) {
            revert HookAddressMismatch(expectedHook, address(deployment.hook));
        }
        uint160 actualFlags = uint160(address(deployment.hook)) & Hooks.ALL_HOOK_MASK;
        if (actualFlags != REQUIRED_HOOK_FLAGS) revert HookPermissionMismatch(REQUIRED_HOOK_FLAGS, actualFlags);
        _validatePositionOwner(
            config.positionOwner, address(deployment.hook), address(deployment.feeClaimRedeemer), config
        );

        (Currency currency0, Currency currency1) = config.pairedToken < config.statics
            ? (Currency.wrap(config.pairedToken), Currency.wrap(config.statics))
            : (Currency.wrap(config.statics), Currency.wrap(config.pairedToken));
        deployment.key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: config.nativeLpFee,
            tickSpacing: config.tickSpacing,
            hooks: IHooks(deployment.hook)
        });
        deployment.poolId = deployment.key.toId();
        deployment.create2Salt = salt;
        _validateFunding(config, deployment.key);
    }

    function loadRobinhoodConfig() public view returns (Config memory config) {
        string memory v4Manifest = vm.readFile("deployments/robinhood-chain-4663.json");
        string memory genesisManifest = vm.readFile("deployments/robinhood-mainnet-genesis.json");
        uint256 v4ChainId = vm.parseJsonUint(v4Manifest, ".chainId");
        uint256 genesisChainId = vm.parseJsonUint(genesisManifest, ".network.chainId");
        if (v4ChainId != genesisChainId) revert InvalidChain(v4ChainId, genesisChainId);
        if (v4ChainId != ROBINHOOD_MAINNET_CHAIN_ID) revert InvalidChain(ROBINHOOD_MAINNET_CHAIN_ID, v4ChainId);
        config.chainId = v4ChainId;
        config.poolManager = vm.parseJsonAddress(v4Manifest, ".contracts.poolManager.address");
        config.positionManager = vm.parseJsonAddress(v4Manifest, ".contracts.positionManager.address");
        config.permit2 = vm.parseJsonAddress(v4Manifest, ".contracts.permit2.address");
        config.statics = vm.parseJsonAddress(genesisManifest, ".contracts.staticsToken.address");
        config.governance = vm.parseJsonAddress(genesisManifest, ".roles.governance");
        config.poolManagerCodeHash = vm.parseJsonBytes32(v4Manifest, ".contracts.poolManager.runtimeCodeHash");
        config.positionManagerCodeHash = vm.parseJsonBytes32(v4Manifest, ".contracts.positionManager.runtimeCodeHash");
        config.permit2CodeHash = vm.parseJsonBytes32(v4Manifest, ".contracts.permit2.runtimeCodeHash");
        config.staticsCodeHash = vm.parseJsonBytes32(genesisManifest, ".contracts.staticsToken.runtimeCodeHash");
        return _loadLaunchEnvironment(config);
    }

    function _loadLaunchEnvironment(Config memory config) private view returns (Config memory) {
        config.pairedToken = vm.envAddress("STATICS_LAUNCH_PAIRED_TOKEN");
        config.feeReceiver = vm.envAddress("STATICS_LAUNCH_FEE_RECEIVER");
        config.positionOwner = vm.envAddress("STATICS_LAUNCH_POSITION_OWNER");
        config.fundingMode =
            LaunchLiquidityScript.parseFundingMode(vm.envOr("STATICS_LAUNCH_FUNDING_MODE", string("STATICS_ONLY")));
        config.nativeLpFee = _toUint24(vm.envUint("STATICS_LAUNCH_NATIVE_LP_FEE"));
        config.tickSpacing = _toInt24(vm.envInt("STATICS_LAUNCH_TICK_SPACING"));
        config.sqrtPriceX96 = _toUint160(vm.envUint("STATICS_LAUNCH_SQRT_PRICE_X96"));
        config.tickLower = _toInt24(vm.envInt("STATICS_LAUNCH_TICK_LOWER"));
        config.tickUpper = _toInt24(vm.envInt("STATICS_LAUNCH_TICK_UPPER"));
        config.amount0Max = _toUint128(vm.envUint("STATICS_LAUNCH_AMOUNT0_MAX"));
        config.amount1Max = _toUint128(vm.envUint("STATICS_LAUNCH_AMOUNT1_MAX"));
        uint256 configuredLiquidity = vm.envOr("STATICS_LAUNCH_LIQUIDITY", uint256(0));
        config.liquidity = configuredLiquidity == 0
            ? LaunchLiquidityScript.liquidityForAmounts(
                config.sqrtPriceX96, config.tickLower, config.tickUpper, config.amount0Max, config.amount1Max
            )
            : _toUint128(configuredLiquidity);
        config.inputFeeBps = _toUint16(vm.envUint("STATICS_LAUNCH_INPUT_FEE_BPS"));
        config.outputFeeBps = _toUint16(vm.envUint("STATICS_LAUNCH_OUTPUT_FEE_BPS"));
        config.pairedTokenCodeHash = vm.envOr("STATICS_LAUNCH_PAIRED_TOKEN_CODE_HASH", bytes32(0));
        return config;
    }

    function registrationCalldata(Config memory config, Deployment memory deployment)
        public
        pure
        returns (bytes memory)
    {
        return abi.encodeCall(
            StaticsLaunchLiquidityHook.registerPool,
            (deployment.key, config.sqrtPriceX96, config.inputFeeBps, config.outputFeeBps, config.positionOwner)
        );
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
        vm.serializeAddress(objectKey, "feeClaimRedeemer", address(deployment.feeClaimRedeemer));
        vm.serializeAddress(objectKey, "poolManager", config.poolManager);
        vm.serializeAddress(objectKey, "positionManager", config.positionManager);
        vm.serializeAddress(objectKey, "permit2", config.permit2);
        vm.serializeAddress(objectKey, "statics", config.statics);
        vm.serializeAddress(objectKey, "pairedToken", config.pairedToken);
        vm.serializeAddress(objectKey, "governance", config.governance);
        vm.serializeAddress(objectKey, "feeReceiver", config.feeReceiver);
        vm.serializeAddress(objectKey, "positionOwner", config.positionOwner);
        vm.serializeString(objectKey, "fundingMode", LaunchLiquidityScript.fundingModeName(config.fundingMode));
        vm.serializeBytes32(objectKey, "poolId", PoolId.unwrap(deployment.poolId));
        vm.serializeBytes32(objectKey, "create2Salt", deployment.create2Salt);
        vm.serializeBytes32(objectKey, "poolManagerRuntimeCodeHash", config.poolManagerCodeHash);
        vm.serializeBytes32(objectKey, "positionManagerRuntimeCodeHash", config.positionManagerCodeHash);
        vm.serializeBytes32(objectKey, "permit2RuntimeCodeHash", config.permit2CodeHash);
        vm.serializeBytes32(objectKey, "staticsRuntimeCodeHash", config.staticsCodeHash);
        vm.serializeBytes32(objectKey, "pairedTokenRuntimeCodeHash", config.pairedTokenCodeHash);
        vm.serializeBytes32(objectKey, "hookRuntimeCodeHash", address(deployment.hook).codehash);
        vm.serializeUint(objectKey, "hookPermissionMask", REQUIRED_HOOK_FLAGS);
        vm.serializeUint(objectKey, "nativeLpFeePips", config.nativeLpFee);
        vm.serializeUint(objectKey, "inputFeeBps", config.inputFeeBps);
        vm.serializeUint(objectKey, "outputFeeBps", config.outputFeeBps);
        vm.serializeInt(objectKey, "tickSpacing", config.tickSpacing);
        vm.serializeInt(objectKey, "tickLower", config.tickLower);
        vm.serializeInt(objectKey, "tickUpper", config.tickUpper);
        vm.serializeUint(objectKey, "sqrtPriceX96", config.sqrtPriceX96);
        vm.serializeUint(objectKey, "liquidity", config.liquidity);
        vm.serializeUint(objectKey, "amount0Max", config.amount0Max);
        vm.serializeUint(objectKey, "amount1Max", config.amount1Max);
        string memory json =
            vm.serializeBytes(objectKey, "registerPoolCalldata", registrationCalldata(config, deployment));
        vm.writeJson(json, path);
    }

    function _validate(Config memory config) private view {
        if (block.chainid != config.chainId) revert InvalidChain(config.chainId, block.chainid);
        if (
            config.governance == address(0) || config.feeReceiver == address(0) || config.positionOwner == address(0)
                || config.statics == address(0) || config.pairedToken == address(0)
                || config.statics == config.pairedToken || config.tickSpacing < TickMath.MIN_TICK_SPACING
                || config.tickSpacing > TickMath.MAX_TICK_SPACING || config.sqrtPriceX96 < TickMath.MIN_SQRT_PRICE
                || config.sqrtPriceX96 >= TickMath.MAX_SQRT_PRICE || config.tickLower >= config.tickUpper
                || config.tickLower % config.tickSpacing != 0 || config.tickUpper % config.tickSpacing != 0
                || config.liquidity == 0 || config.liquidity > uint128(type(int128).max) || config.inputFeeBps > 1_000
                || config.outputFeeBps > 1_000 || config.nativeLpFee.isDynamicFee() || !config.nativeLpFee.isValid()
        ) revert InvalidConfig();
        _validatePositionOwner(config.positionOwner, address(0), address(0), config);
        _validateContract(config.poolManager, config.poolManagerCodeHash);
        _validateContract(config.positionManager, config.positionManagerCodeHash);
        _validateContract(config.permit2, config.permit2CodeHash);
        _validateContract(config.statics, config.staticsCodeHash);
        _validateContract(config.pairedToken, config.pairedTokenCodeHash);
        address boundManager = ILaunchPositionManagerBindings(config.positionManager).poolManager();
        if (boundManager != config.poolManager) {
            revert InvalidV4Binding(config.positionManager, config.poolManager, boundManager);
        }
        address boundPermit2 = ILaunchPositionManagerBindings(config.positionManager).permit2();
        if (boundPermit2 != config.permit2) {
            revert InvalidV4Binding(config.positionManager, config.permit2, boundPermit2);
        }
    }

    function _validatePositionOwner(address positionOwner, address hook, address feeClaimRedeemer, Config memory config)
        private
        pure
    {
        if (
            positionOwner == address(0) || positionOwner == config.poolManager
                || positionOwner == config.positionManager || positionOwner == hook || positionOwner == feeClaimRedeemer
                || positionOwner == address(1) || positionOwner == address(2)
        ) revert InvalidConfig();
    }

    function _validateFunding(Config memory config, PoolKey memory key) private pure {
        LaunchLiquidityScript.validateFundingPosition(
            config.fundingMode,
            config.statics,
            key,
            config.sqrtPriceX96,
            config.tickLower,
            config.tickUpper,
            config.amount0Max,
            config.amount1Max
        );
    }

    function _toUint16(uint256 value) private pure returns (uint16) {
        if (value > type(uint16).max) revert InvalidConfig();
        return uint16(value);
    }

    function _toUint24(uint256 value) private pure returns (uint24) {
        if (value > type(uint24).max) revert InvalidConfig();
        return uint24(value);
    }

    function _toUint128(uint256 value) private pure returns (uint128) {
        if (value > type(uint128).max) revert InvalidConfig();
        return uint128(value);
    }

    function _toUint160(uint256 value) private pure returns (uint160) {
        if (value > type(uint160).max) revert InvalidConfig();
        return uint160(value);
    }

    function _toInt24(int256 value) private pure returns (int24) {
        if (value < type(int24).min || value > type(int24).max) revert InvalidConfig();
        return int24(value);
    }

    function _validateContract(address target, bytes32 expectedHash) private view {
        if (target.code.length == 0) revert InvalidV4Contract(target);
        bytes32 actualHash = target.codehash;
        if (expectedHash != bytes32(0) && expectedHash != actualHash) {
            revert InvalidCodeHash(target, expectedHash, actualHash);
        }
    }
}
