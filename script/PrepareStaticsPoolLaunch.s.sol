// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IMulticall_v4} from "@uniswap/v4-periphery/src/interfaces/IMulticall_v4.sol";
import {IPoolInitializer_v4} from "@uniswap/v4-periphery/src/interfaces/IPoolInitializer_v4.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {StaticsLaunchLiquidityHook} from "../src/liquidity/StaticsLaunchLiquidityHook.sol";
import {LaunchLiquidityScript} from "./libraries/LaunchLiquidityScript.sol";

/// @notice Prepares registration and first-position calldata for any PoolKey using an existing launch hook.
/// @dev This script never broadcasts. Use one output artifact per pool and generate it immediately before use.
contract PrepareStaticsPoolLaunch is Script {
    using LPFeeLibrary for uint24;
    using PoolIdLibrary for PoolKey;

    struct PoolLaunchConfig {
        uint256 chainId;
        address poolManager;
        address positionManager;
        address hook;
        address statics;
        address pairedToken;
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
    }

    error EmptyArtifactPath();
    error InvalidChain(uint256 expected, uint256 actual);
    error ExpiredDeadline(uint256 deadline, uint256 currentTimestamp);
    error InvalidConfig();
    error InvalidBinding(address target, address expected, address actual);

    function run() external returns (PoolLaunchConfig memory config) {
        string memory deploymentPath =
            vm.envOr("STATICS_LAUNCH_LIQUIDITY_ARTIFACT", string("artifacts/launch-liquidity/robinhood-4663.json"));
        string memory preparedPath =
            vm.envOr("STATICS_POOL_LAUNCH_ARTIFACT", string("artifacts/launch-liquidity/robinhood-4663-pool.json"));
        uint256 deadline = vm.envUint("STATICS_LAUNCH_POSITION_DEADLINE");
        config = loadDeploymentAndEnvironment(deploymentPath);
        validate(config, deadline);
        vm.createDir("artifacts/launch-liquidity", true);
        writeArtifact(preparedPath, deploymentPath, config, deadline);
    }

    function loadDeploymentAndEnvironment(string memory path) public view returns (PoolLaunchConfig memory config) {
        if (bytes(path).length == 0) revert EmptyArtifactPath();
        string memory json = vm.readFile(path);
        config.chainId = vm.parseJsonUint(json, ".chainId");
        config.poolManager = vm.parseJsonAddress(json, ".poolManager");
        config.positionManager = vm.parseJsonAddress(json, ".positionManager");
        config.hook = vm.parseJsonAddress(json, ".hook");
        config.statics = vm.parseJsonAddress(json, ".statics");
        config.pairedToken = vm.envAddress("STATICS_LAUNCH_PAIRED_TOKEN");
        config.positionOwner = vm.envAddress("STATICS_LAUNCH_POSITION_OWNER");
        config.fundingMode = LaunchLiquidityScript.parseFundingMode(vm.envString("STATICS_LAUNCH_FUNDING_MODE"));
        config.nativeLpFee = _toUint24(vm.envUint("STATICS_LAUNCH_NATIVE_LP_FEE"));
        config.tickSpacing = _toInt24(vm.envInt("STATICS_LAUNCH_TICK_SPACING"));
        config.sqrtPriceX96 = _toUint160(vm.envUint("STATICS_LAUNCH_SQRT_PRICE_X96"));
        config.tickLower = _toInt24(vm.envInt("STATICS_LAUNCH_TICK_LOWER"));
        config.tickUpper = _toInt24(vm.envInt("STATICS_LAUNCH_TICK_UPPER"));
        config.amount0Max = _toUint128(vm.envUint("STATICS_LAUNCH_AMOUNT0_MAX"));
        config.amount1Max = _toUint128(vm.envUint("STATICS_LAUNCH_AMOUNT1_MAX"));
        config.liquidity = _loadOrCalculateLiquidity(config);
        config.inputFeeBps = _toUint16(vm.envUint("STATICS_LAUNCH_INPUT_FEE_BPS"));
        config.outputFeeBps = _toUint16(vm.envUint("STATICS_LAUNCH_OUTPUT_FEE_BPS"));
    }

    function validate(PoolLaunchConfig memory config, uint256 deadline) public view {
        if (config.chainId != block.chainid) revert InvalidChain(config.chainId, block.chainid);
        if (deadline < block.timestamp) revert ExpiredDeadline(deadline, block.timestamp);
        if (
            config.poolManager == address(0) || config.positionManager == address(0) || config.hook == address(0)
                || config.statics == address(0) || config.pairedToken == address(0)
                || config.statics == config.pairedToken || config.positionOwner == address(0)
                || config.positionOwner == config.poolManager || config.positionOwner == config.positionManager
                || config.positionOwner == config.hook || config.positionOwner == address(1)
                || config.positionOwner == address(2) || config.tickSpacing < TickMath.MIN_TICK_SPACING
                || config.tickSpacing > TickMath.MAX_TICK_SPACING || config.tickLower >= config.tickUpper
                || config.tickLower % config.tickSpacing != 0 || config.tickUpper % config.tickSpacing != 0
                || config.sqrtPriceX96 < TickMath.MIN_SQRT_PRICE || config.sqrtPriceX96 >= TickMath.MAX_SQRT_PRICE
                || config.liquidity == 0 || config.liquidity > uint128(type(int128).max) || config.inputFeeBps > 1_000
                || config.outputFeeBps > 1_000 || config.nativeLpFee.isDynamicFee() || !config.nativeLpFee.isValid()
        ) revert InvalidConfig();
        if (
            config.poolManager.code.length == 0 || config.positionManager.code.length == 0
                || config.hook.code.length == 0
        ) {
            revert InvalidConfig();
        }
        address boundManager = address(IPositionManager(config.positionManager).poolManager());
        if (boundManager != config.poolManager) {
            revert InvalidBinding(config.positionManager, config.poolManager, boundManager);
        }
        address hookManager = address(StaticsLaunchLiquidityHook(config.hook).poolManager());
        if (hookManager != config.poolManager) revert InvalidBinding(config.hook, config.poolManager, hookManager);
        address hookPositionManager = StaticsLaunchLiquidityHook(config.hook).positionManager();
        if (hookPositionManager != config.positionManager) {
            revert InvalidBinding(config.hook, config.positionManager, hookPositionManager);
        }
        LaunchLiquidityScript.validateFundingPosition(
            config.fundingMode,
            config.statics,
            poolKey(config),
            config.sqrtPriceX96,
            config.tickLower,
            config.tickUpper,
            config.amount0Max,
            config.amount1Max
        );
    }

    function calculateLiquidity(PoolLaunchConfig memory config) public pure returns (uint128) {
        return LaunchLiquidityScript.liquidityForAmounts(
            config.sqrtPriceX96, config.tickLower, config.tickUpper, config.amount0Max, config.amount1Max
        );
    }

    function registrationCalldata(PoolLaunchConfig memory config) public pure returns (bytes memory) {
        return abi.encodeCall(
            StaticsLaunchLiquidityHook.registerPool,
            (poolKey(config), config.sqrtPriceX96, config.inputFeeBps, config.outputFeeBps, config.positionOwner)
        );
    }

    function initializeAndMintCalldata(PoolLaunchConfig memory config, uint256 deadline)
        public
        pure
        returns (bytes memory)
    {
        PoolKey memory key = poolKey(config);
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(IPoolInitializer_v4.initializePool, (key, config.sqrtPriceX96));
        calls[1] = mintOnlyCalldata(config, deadline);
        return abi.encodeCall(IMulticall_v4.multicall, (calls));
    }

    function mintOnlyCalldata(PoolLaunchConfig memory config, uint256 deadline) public pure returns (bytes memory) {
        PoolKey memory key = poolKey(config);
        bytes memory actions =
            abi.encodePacked(bytes1(uint8(Actions.MINT_POSITION)), bytes1(uint8(Actions.SETTLE_PAIR)));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(
            key,
            config.tickLower,
            config.tickUpper,
            config.liquidity,
            config.amount0Max,
            config.amount1Max,
            config.positionOwner,
            bytes("")
        );
        params[1] = abi.encode(key.currency0, key.currency1);
        return abi.encodeCall(IPositionManager.modifyLiquidities, (abi.encode(actions, params), deadline));
    }

    function activationCalldata(PoolLaunchConfig memory config) public pure returns (bytes memory) {
        return abi.encodeCall(StaticsLaunchLiquidityHook.activatePool, (poolKey(config).toId()));
    }

    function poolKey(PoolLaunchConfig memory config) public pure returns (PoolKey memory key) {
        (Currency currency0, Currency currency1) = config.pairedToken < config.statics
            ? (Currency.wrap(config.pairedToken), Currency.wrap(config.statics))
            : (Currency.wrap(config.statics), Currency.wrap(config.pairedToken));
        key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: config.nativeLpFee,
            tickSpacing: config.tickSpacing,
            hooks: IHooks(config.hook)
        });
    }

    function writeArtifact(
        string memory path,
        string memory deploymentPath,
        PoolLaunchConfig memory config,
        uint256 deadline
    ) public {
        if (bytes(path).length == 0 || bytes(deploymentPath).length == 0) {
            revert EmptyArtifactPath();
        }
        PoolKey memory key = poolKey(config);
        string memory objectKey = "preparedPoolLaunch";
        vm.serializeString(objectKey, "deploymentArtifact", deploymentPath);
        vm.serializeUint(objectKey, "chainId", config.chainId);
        vm.serializeAddress(objectKey, "poolManager", config.poolManager);
        vm.serializeAddress(objectKey, "positionManager", config.positionManager);
        vm.serializeAddress(objectKey, "hook", config.hook);
        vm.serializeAddress(objectKey, "statics", config.statics);
        vm.serializeAddress(objectKey, "pairedToken", config.pairedToken);
        vm.serializeAddress(objectKey, "currency0", Currency.unwrap(key.currency0));
        vm.serializeAddress(objectKey, "currency1", Currency.unwrap(key.currency1));
        vm.serializeAddress(objectKey, "positionOwner", config.positionOwner);
        vm.serializeString(objectKey, "fundingMode", LaunchLiquidityScript.fundingModeName(config.fundingMode));
        vm.serializeBytes32(objectKey, "poolId", PoolId.unwrap(key.toId()));
        vm.serializeUint(objectKey, "nativeLpFeePips", config.nativeLpFee);
        vm.serializeInt(objectKey, "tickSpacing", config.tickSpacing);
        vm.serializeUint(objectKey, "sqrtPriceX96", config.sqrtPriceX96);
        vm.serializeInt(objectKey, "tickLower", config.tickLower);
        vm.serializeInt(objectKey, "tickUpper", config.tickUpper);
        vm.serializeUint(objectKey, "liquidity", config.liquidity);
        vm.serializeUint(objectKey, "amount0Max", config.amount0Max);
        vm.serializeUint(objectKey, "amount1Max", config.amount1Max);
        vm.serializeUint(objectKey, "inputFeeBps", config.inputFeeBps);
        vm.serializeUint(objectKey, "outputFeeBps", config.outputFeeBps);
        vm.serializeUint(objectKey, "positionDeadline", deadline);
        vm.serializeBytes(objectKey, "registerPoolCalldata", registrationCalldata(config));
        vm.serializeBytes(objectKey, "initializeAndMintCalldata", initializeAndMintCalldata(config, deadline));
        vm.serializeBytes(objectKey, "mintOnlyCalldata", mintOnlyCalldata(config, deadline));
        string memory json = vm.serializeBytes(objectKey, "activatePoolCalldata", activationCalldata(config));
        vm.writeJson(json, path);
    }

    function _loadOrCalculateLiquidity(PoolLaunchConfig memory config) private view returns (uint128) {
        uint256 configured = vm.envOr("STATICS_LAUNCH_LIQUIDITY", uint256(0));
        if (configured != 0) return _toLiquidity(configured);
        return calculateLiquidity(config);
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

    function _toLiquidity(uint256 value) private pure returns (uint128) {
        if (value > uint128(type(int128).max)) revert InvalidConfig();
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
}
