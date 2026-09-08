// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {StaticsLaunchLiquidityHook} from "../src/liquidity/StaticsLaunchLiquidityHook.sol";
import {LaunchLiquidityScript} from "./libraries/LaunchLiquidityScript.sol";

/// @notice Prepares a new independently managed PositionManager position for an initialized launch pool.
/// @dev The current PoolManager price is used when liquidity is calculated from amount caps.
contract PrepareStaticsPositionMint is Script {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    struct PositionMintConfig {
        uint256 chainId;
        address poolManager;
        address positionManager;
        address hook;
        Currency currency0;
        Currency currency1;
        uint24 nativeLpFee;
        int24 tickSpacing;
        uint160 currentSqrtPriceX96;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint128 amount0Max;
        uint128 amount1Max;
        address positionOwner;
    }

    error EmptyArtifactPath();
    error InvalidChain(uint256 expected, uint256 actual);
    error ExpiredDeadline(uint256 deadline, uint256 currentTimestamp);
    error InvalidConfig();
    error InvalidBinding(address target, address expected, address actual);

    function run() external returns (PositionMintConfig memory config) {
        string memory poolArtifact =
            vm.envOr("STATICS_POOL_LAUNCH_ARTIFACT", string("artifacts/launch-liquidity/robinhood-4663-pool.json"));
        string memory preparedPath = vm.envOr(
            "STATICS_POSITION_MINT_ARTIFACT", string("artifacts/launch-liquidity/robinhood-4663-position-mint.json")
        );
        uint256 deadline = vm.envUint("STATICS_POSITION_MINT_DEADLINE");
        config = loadPoolAndEnvironment(poolArtifact);
        validate(config, deadline);
        vm.createDir("artifacts/launch-liquidity", true);
        writeArtifact(preparedPath, poolArtifact, config, deadline);
    }

    function loadPoolAndEnvironment(string memory path) public view returns (PositionMintConfig memory config) {
        if (bytes(path).length == 0) revert EmptyArtifactPath();
        string memory json = vm.readFile(path);
        config.chainId = vm.parseJsonUint(json, ".chainId");
        config.poolManager = vm.parseJsonAddress(json, ".poolManager");
        config.positionManager = vm.parseJsonAddress(json, ".positionManager");
        config.hook = vm.parseJsonAddress(json, ".hook");
        config.currency0 = Currency.wrap(vm.parseJsonAddress(json, ".currency0"));
        config.currency1 = Currency.wrap(vm.parseJsonAddress(json, ".currency1"));
        config.nativeLpFee = _toUint24(vm.parseJsonUint(json, ".nativeLpFeePips"));
        config.tickSpacing = _toInt24(vm.parseJsonInt(json, ".tickSpacing"));
        config.tickLower = _toInt24(vm.envInt("STATICS_POSITION_TICK_LOWER"));
        config.tickUpper = _toInt24(vm.envInt("STATICS_POSITION_TICK_UPPER"));
        config.amount0Max = _toUint128(vm.envUint("STATICS_POSITION_AMOUNT0_MAX"));
        config.amount1Max = _toUint128(vm.envUint("STATICS_POSITION_AMOUNT1_MAX"));
        config.positionOwner = vm.envAddress("STATICS_POSITION_OWNER");
        config.currentSqrtPriceX96 = _currentSqrtPrice(config);
        uint256 configuredLiquidity = vm.envOr("STATICS_POSITION_LIQUIDITY", uint256(0));
        config.liquidity = configuredLiquidity == 0 ? calculateLiquidity(config) : _toLiquidity(configuredLiquidity);
    }

    function validate(PositionMintConfig memory config, uint256 deadline) public view {
        if (config.chainId != block.chainid) revert InvalidChain(config.chainId, block.chainid);
        if (deadline < block.timestamp) revert ExpiredDeadline(deadline, block.timestamp);
        address currency0 = Currency.unwrap(config.currency0);
        address currency1 = Currency.unwrap(config.currency1);
        if (
            config.poolManager == address(0) || config.poolManager.code.length == 0
                || config.positionManager == address(0) || config.positionManager.code.length == 0
                || config.hook == address(0) || config.hook.code.length == 0 || currency0 == address(0)
                || currency1 == address(0) || currency0 >= currency1 || config.tickSpacing < TickMath.MIN_TICK_SPACING
                || config.tickSpacing > TickMath.MAX_TICK_SPACING || config.tickLower >= config.tickUpper
                || config.tickLower % config.tickSpacing != 0 || config.tickUpper % config.tickSpacing != 0
                || config.currentSqrtPriceX96 < TickMath.MIN_SQRT_PRICE
                || config.currentSqrtPriceX96 >= TickMath.MAX_SQRT_PRICE || config.liquidity == 0
                || config.liquidity > uint128(type(int128).max) || (config.amount0Max == 0 && config.amount1Max == 0)
                || config.positionOwner == address(0) || config.positionOwner == config.poolManager
                || config.positionOwner == config.positionManager || config.positionOwner == config.hook
                || config.positionOwner == address(1) || config.positionOwner == address(2)
        ) revert InvalidConfig();
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
        uint160 actualSqrtPriceX96 = _currentSqrtPrice(config);
        if (actualSqrtPriceX96 != config.currentSqrtPriceX96) revert InvalidConfig();
    }

    function calculateLiquidity(PositionMintConfig memory config) public pure returns (uint128) {
        return LaunchLiquidityScript.liquidityForAmounts(
            config.currentSqrtPriceX96, config.tickLower, config.tickUpper, config.amount0Max, config.amount1Max
        );
    }

    function mintCalldata(PositionMintConfig memory config, uint256 deadline) public pure returns (bytes memory) {
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
        params[1] = abi.encode(config.currency0, config.currency1);
        return abi.encodeCall(IPositionManager.modifyLiquidities, (abi.encode(actions, params), deadline));
    }

    function poolKey(PositionMintConfig memory config) public pure returns (PoolKey memory key) {
        key = PoolKey({
            currency0: config.currency0,
            currency1: config.currency1,
            fee: config.nativeLpFee,
            tickSpacing: config.tickSpacing,
            hooks: IHooks(config.hook)
        });
    }

    function writeArtifact(
        string memory path,
        string memory poolArtifact,
        PositionMintConfig memory config,
        uint256 deadline
    ) public {
        if (bytes(path).length == 0 || bytes(poolArtifact).length == 0) {
            revert EmptyArtifactPath();
        }
        PoolKey memory key = poolKey(config);
        string memory objectKey = "preparedPositionMint";
        vm.serializeString(objectKey, "poolArtifact", poolArtifact);
        vm.serializeUint(objectKey, "chainId", config.chainId);
        vm.serializeAddress(objectKey, "poolManager", config.poolManager);
        vm.serializeAddress(objectKey, "positionManager", config.positionManager);
        vm.serializeAddress(objectKey, "hook", config.hook);
        vm.serializeAddress(objectKey, "currency0", Currency.unwrap(config.currency0));
        vm.serializeAddress(objectKey, "currency1", Currency.unwrap(config.currency1));
        vm.serializeBytes32(objectKey, "poolId", PoolId.unwrap(key.toId()));
        vm.serializeUint(objectKey, "nativeLpFeePips", config.nativeLpFee);
        vm.serializeInt(objectKey, "tickSpacing", config.tickSpacing);
        vm.serializeUint(objectKey, "currentSqrtPriceX96", config.currentSqrtPriceX96);
        vm.serializeInt(objectKey, "tickLower", config.tickLower);
        vm.serializeInt(objectKey, "tickUpper", config.tickUpper);
        vm.serializeUint(objectKey, "liquidity", config.liquidity);
        vm.serializeUint(objectKey, "amount0Max", config.amount0Max);
        vm.serializeUint(objectKey, "amount1Max", config.amount1Max);
        vm.serializeAddress(objectKey, "positionOwner", config.positionOwner);
        vm.serializeUint(objectKey, "deadline", deadline);
        string memory json = vm.serializeBytes(objectKey, "mintCalldata", mintCalldata(config, deadline));
        vm.writeJson(json, path);
    }

    function _currentSqrtPrice(PositionMintConfig memory config) private view returns (uint160 sqrtPriceX96) {
        (sqrtPriceX96,,,) = IPoolManager(config.poolManager).getSlot0(poolKey(config).toId());
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

    function _toInt24(int256 value) private pure returns (int24) {
        if (value < type(int24).min || value > type(int24).max) revert InvalidConfig();
        return int24(value);
    }
}
