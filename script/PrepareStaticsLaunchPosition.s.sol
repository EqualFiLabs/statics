// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IMulticall_v4} from "@uniswap/v4-periphery/src/interfaces/IMulticall_v4.sol";
import {IPoolInitializer_v4} from "@uniswap/v4-periphery/src/interfaces/IPoolInitializer_v4.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {StaticsLaunchLiquidityHook} from "../src/liquidity/StaticsLaunchLiquidityHook.sol";
import {LaunchLiquidityScript} from "./libraries/LaunchLiquidityScript.sol";

/// @notice Builds fresh launch-position calldata from a checked-in deployment artifact.
/// @dev This script never broadcasts. Generate calldata immediately before the position transaction.
contract PrepareStaticsLaunchPosition is Script {
    using PoolIdLibrary for PoolKey;

    struct LaunchConfig {
        uint256 chainId;
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
    }

    error EmptyArtifactPath();
    error InvalidChain(uint256 expected, uint256 actual);
    error ExpiredDeadline(uint256 deadline, uint256 currentTimestamp);
    error InvalidArtifact();

    function run() external returns (LaunchConfig memory config) {
        string memory deploymentPath =
            vm.envOr("STATICS_LAUNCH_LIQUIDITY_ARTIFACT", string("artifacts/launch-liquidity/robinhood-4663.json"));
        string memory preparedPath = vm.envOr(
            "STATICS_LAUNCH_POSITION_ARTIFACT", string("artifacts/launch-liquidity/robinhood-4663-position.json")
        );
        uint256 deadline = vm.envUint("STATICS_LAUNCH_POSITION_DEADLINE");
        config = loadArtifact(deploymentPath);
        validate(config, deadline);
        vm.createDir("artifacts/launch-liquidity", true);
        writeArtifact(preparedPath, deploymentPath, config, deadline);
    }

    function loadArtifact(string memory path) public view returns (LaunchConfig memory config) {
        if (bytes(path).length == 0) revert EmptyArtifactPath();
        string memory json = vm.readFile(path);
        config.chainId = vm.parseJsonUint(json, ".chainId");
        config.positionManager = vm.parseJsonAddress(json, ".positionManager");
        config.hook = vm.parseJsonAddress(json, ".hook");
        config.statics = vm.parseJsonAddress(json, ".statics");
        config.pairedToken = vm.parseJsonAddress(json, ".pairedToken");
        config.positionOwner = vm.parseJsonAddress(json, ".positionOwner");
        config.fundingMode = vm.keyExistsJson(json, ".fundingMode")
            ? LaunchLiquidityScript.parseFundingMode(vm.parseJsonString(json, ".fundingMode"))
            : LaunchLiquidityScript.FundingMode.StaticsOnly;
        config.nativeLpFee = _toUint24(vm.parseJsonUint(json, ".nativeLpFeePips"));
        config.tickSpacing = _toInt24(vm.parseJsonInt(json, ".tickSpacing"));
        config.sqrtPriceX96 = _toUint160(vm.parseJsonUint(json, ".sqrtPriceX96"));
        config.tickLower = _toInt24(vm.parseJsonInt(json, ".tickLower"));
        config.tickUpper = _toInt24(vm.parseJsonInt(json, ".tickUpper"));
        config.liquidity = _toLiquidity(vm.parseJsonUint(json, ".liquidity"));
        config.amount0Max = _toUint128(vm.parseJsonUint(json, ".amount0Max"));
        config.amount1Max = _toUint128(vm.parseJsonUint(json, ".amount1Max"));
    }

    function validate(LaunchConfig memory config, uint256 deadline) public view {
        if (config.chainId != block.chainid) revert InvalidChain(config.chainId, block.chainid);
        if (deadline < block.timestamp) revert ExpiredDeadline(deadline, block.timestamp);
        if (
            config.positionManager == address(0) || config.hook == address(0) || config.statics == address(0)
                || config.pairedToken == address(0) || config.statics == config.pairedToken
                || config.positionOwner == address(0) || config.liquidity == 0
        ) revert InvalidArtifact();
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

    function initializeAndMintCalldata(LaunchConfig memory config, uint256 deadline)
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

    function mintOnlyCalldata(LaunchConfig memory config, uint256 deadline) public pure returns (bytes memory) {
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

    function activationCalldata(LaunchConfig memory config) public pure returns (bytes memory) {
        return abi.encodeCall(StaticsLaunchLiquidityHook.activatePool, (poolKey(config).toId()));
    }

    function poolKey(LaunchConfig memory config) public pure returns (PoolKey memory key) {
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
        LaunchConfig memory config,
        uint256 deadline
    ) public {
        if (bytes(path).length == 0 || bytes(deploymentPath).length == 0) {
            revert EmptyArtifactPath();
        }
        PoolId poolId = poolKey(config).toId();
        string memory objectKey = "preparedLaunchPosition";
        vm.serializeString(objectKey, "deploymentArtifact", deploymentPath);
        vm.serializeUint(objectKey, "chainId", config.chainId);
        vm.serializeAddress(objectKey, "positionManager", config.positionManager);
        vm.serializeAddress(objectKey, "hook", config.hook);
        vm.serializeAddress(objectKey, "positionOwner", config.positionOwner);
        vm.serializeString(objectKey, "fundingMode", LaunchLiquidityScript.fundingModeName(config.fundingMode));
        vm.serializeBytes32(objectKey, "poolId", PoolId.unwrap(poolId));
        vm.serializeUint(objectKey, "positionDeadline", deadline);
        vm.serializeBytes(objectKey, "initializeAndMintCalldata", initializeAndMintCalldata(config, deadline));
        vm.serializeBytes(objectKey, "mintOnlyCalldata", mintOnlyCalldata(config, deadline));
        string memory json = vm.serializeBytes(objectKey, "activatePoolCalldata", activationCalldata(config));
        vm.writeJson(json, path);
    }

    function _toUint24(uint256 value) private pure returns (uint24) {
        if (value > type(uint24).max) revert InvalidArtifact();
        return uint24(value);
    }

    function _toUint128(uint256 value) private pure returns (uint128) {
        if (value > type(uint128).max) revert InvalidArtifact();
        return uint128(value);
    }

    function _toLiquidity(uint256 value) private pure returns (uint128) {
        if (value > uint128(type(int128).max)) revert InvalidArtifact();
        return uint128(value);
    }

    function _toUint160(uint256 value) private pure returns (uint160) {
        if (value > type(uint160).max) revert InvalidArtifact();
        return uint160(value);
    }

    function _toInt24(int256 value) private pure returns (int24) {
        if (value < type(int24).min || value > type(int24).max) revert InvalidArtifact();
        return int24(value);
    }
}
