// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {Script} from "forge-std/Script.sol";

import {IERC173} from "../src/interfaces/IERC173.sol";
import {IStaticsBasketLiquidity} from "../src/interfaces/IStaticsBasketLiquidity.sol";
import {IStaticsSwapFeeHook} from "../src/interfaces/IStaticsSwapFeeHook.sol";
import {StaticsLiquidityManager} from "../src/liquidity/StaticsLiquidityManager.sol";
import {StaticsSwapFeeHook} from "../src/liquidity/StaticsSwapFeeHook.sol";

interface IConfiguredPositionManager {
    function poolManager() external view returns (address);
    function permit2() external view returns (address);
}

struct StaticsLiquidityConfig {
    address poolManager;
    address positionManager;
    address permit2;
    address hook;
    address manager;
    uint16 inputFeeBps;
    uint16 outputFeeBps;
    bytes32 poolManagerCodeHash;
    bytes32 positionManagerCodeHash;
    bytes32 permit2CodeHash;
}

/// @notice Timelock ceremony for installing immutable Statics v4 dependencies.
contract ConfigureStaticsLiquidity is Script {
    uint160 private constant REQUIRED_HOOK_FLAGS = Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG
        | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
    string private constant ROBINHOOD_MANIFEST = "deployments/robinhood-chain-4663.json";

    error InvalidDiamond(address diamond);
    error InvalidTimelock(address timelock);
    error InvalidContract(address target);
    error InvalidCodeHash(address target, bytes32 expected, bytes32 actual);
    error InvalidBinding(address target, address expected, address actual);
    error InvalidHookFlags(uint160 expected, uint160 actual);
    error InvalidHookFees(uint256 expectedInput, uint256 actualInput, uint256 expectedOutput, uint256 actualOutput);
    error LiquidityAlreadyInstalled();
    error LiquidityInstallationFailed();

    event StaticsLiquidityBatchPrepared(
        bytes32 indexed operationId,
        address indexed diamond,
        address indexed timelock,
        address hook,
        address manager,
        uint256 delay
    );

    function runSchedule() external returns (bytes32 operationId) {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address diamond = vm.envAddress("STATICS_DIAMOND_ADDRESS");
        bytes32 salt = vm.envBytes32("STATICS_LIQUIDITY_TIMELOCK_SALT");
        StaticsLiquidityConfig memory config = _loadRobinhoodConfig();

        vm.startBroadcast(privateKey);
        operationId = schedule(diamond, config, salt);
        vm.stopBroadcast();
    }

    function runExecute() external {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address diamond = vm.envAddress("STATICS_DIAMOND_ADDRESS");
        bytes32 salt = vm.envBytes32("STATICS_LIQUIDITY_TIMELOCK_SALT");
        StaticsLiquidityConfig memory config = _loadRobinhoodConfig();

        vm.startBroadcast(privateKey);
        execute(diamond, config, salt);
        vm.stopBroadcast();
    }

    function schedule(address diamond, StaticsLiquidityConfig memory config, bytes32 salt)
        public
        returns (bytes32 operationId)
    {
        TimelockController timelock = _validate(diamond, config, false);
        (address[] memory targets, uint256[] memory values, bytes[] memory payloads) = buildBatch(diamond, config);
        uint256 delay = timelock.getMinDelay();
        timelock.scheduleBatch(targets, values, payloads, bytes32(0), salt, delay);
        operationId = timelock.hashOperationBatch(targets, values, payloads, bytes32(0), salt);
        emit StaticsLiquidityBatchPrepared(operationId, diamond, address(timelock), config.hook, config.manager, delay);
    }

    function execute(address diamond, StaticsLiquidityConfig memory config, bytes32 salt) public {
        TimelockController timelock = _validate(diamond, config, false);
        (address[] memory targets, uint256[] memory values, bytes[] memory payloads) = buildBatch(diamond, config);
        timelock.executeBatch(targets, values, payloads, bytes32(0), salt);
        _validate(diamond, config, true);
    }

    function buildBatch(address diamond, StaticsLiquidityConfig memory config)
        public
        pure
        returns (address[] memory targets, uint256[] memory values, bytes[] memory payloads)
    {
        targets = new address[](2);
        targets[0] = diamond;
        targets[1] = diamond;
        values = new uint256[](2);
        payloads = new bytes[](2);
        payloads[0] =
            abi.encodeCall(IStaticsBasketLiquidity.installCanonicalPoolIntegration, (config.poolManager, config.hook));
        payloads[1] = abi.encodeCall(IStaticsBasketLiquidity.installLiquidityManager, (config.manager));
    }

    function _validate(address diamond, StaticsLiquidityConfig memory config, bool requireInstalled)
        private
        view
        returns (TimelockController timelock)
    {
        if (diamond.code.length == 0) revert InvalidDiamond(diamond);
        address owner = IERC173(diamond).owner();
        if (owner.code.length == 0) revert InvalidTimelock(owner);
        timelock = TimelockController(payable(owner));

        _validateContract(config.poolManager, config.poolManagerCodeHash);
        _validateContract(config.positionManager, config.positionManagerCodeHash);
        _validateContract(config.permit2, config.permit2CodeHash);
        _validateContract(config.hook, bytes32(0));
        _validateContract(config.manager, bytes32(0));
        _binding(
            config.positionManager, config.poolManager, IConfiguredPositionManager(config.positionManager).poolManager()
        );
        _binding(config.positionManager, config.permit2, IConfiguredPositionManager(config.positionManager).permit2());

        StaticsSwapFeeHook hook = StaticsSwapFeeHook(payable(config.hook));
        _binding(config.hook, diamond, hook.staticsDiamond());
        _binding(config.hook, config.poolManager, address(hook.poolManager()));
        IStaticsSwapFeeHook.FeeConfiguration memory feeConfig = hook.feeConfiguration();
        if (feeConfig.inputFeeBps != config.inputFeeBps || feeConfig.outputFeeBps != config.outputFeeBps) {
            revert InvalidHookFees(
                config.inputFeeBps, feeConfig.inputFeeBps, config.outputFeeBps, feeConfig.outputFeeBps
            );
        }
        uint160 actualFlags = uint160(config.hook) & Hooks.ALL_HOOK_MASK;
        if (actualFlags != REQUIRED_HOOK_FLAGS) revert InvalidHookFlags(REQUIRED_HOOK_FLAGS, actualFlags);

        StaticsLiquidityManager manager = StaticsLiquidityManager(config.manager);
        _binding(config.manager, diamond, manager.staticsDiamond());
        _binding(config.manager, config.poolManager, manager.poolManager());
        _binding(config.manager, config.positionManager, manager.positionManager());
        _binding(config.manager, config.permit2, manager.permit2());

        (address installedPoolManager, address installedHook, bool integrationInstalled) =
            IStaticsBasketLiquidity(diamond).liquidityIntegration();
        (address installedManager, bool managerInstalled) = IStaticsBasketLiquidity(diamond).liquidityManager();
        if (requireInstalled) {
            if (
                !integrationInstalled || !managerInstalled || installedPoolManager != config.poolManager
                    || installedHook != config.hook || installedManager != config.manager
            ) revert LiquidityInstallationFailed();
        } else if (integrationInstalled || managerInstalled) {
            revert LiquidityAlreadyInstalled();
        }
    }

    function _validateContract(address target, bytes32 expectedHash) private view {
        if (target.code.length == 0) revert InvalidContract(target);
        bytes32 actualHash = target.codehash;
        if (expectedHash != bytes32(0) && expectedHash != actualHash) {
            revert InvalidCodeHash(target, expectedHash, actualHash);
        }
    }

    function _binding(address target, address expected, address actual) private pure {
        if (expected != actual) revert InvalidBinding(target, expected, actual);
    }

    function _loadRobinhoodConfig() private view returns (StaticsLiquidityConfig memory config) {
        string memory manifest = vm.readFile(ROBINHOOD_MANIFEST);
        uint256 inputFee = vm.parseJsonUint(manifest, ".staticsLiquidityCalibration.inputFeeBps");
        uint256 outputFee = vm.parseJsonUint(manifest, ".staticsLiquidityCalibration.outputFeeBps");
        if (inputFee > type(uint16).max || outputFee > type(uint16).max) {
            revert InvalidHookFees(type(uint16).max, inputFee, type(uint16).max, outputFee);
        }
        config = StaticsLiquidityConfig({
            poolManager: vm.parseJsonAddress(manifest, ".contracts.poolManager.address"),
            positionManager: vm.parseJsonAddress(manifest, ".contracts.positionManager.address"),
            permit2: vm.parseJsonAddress(manifest, ".contracts.permit2.address"),
            hook: vm.envAddress("STATICS_SWAP_FEE_HOOK_ADDRESS"),
            manager: vm.envAddress("STATICS_LIQUIDITY_MANAGER_ADDRESS"),
            inputFeeBps: uint16(inputFee),
            outputFeeBps: uint16(outputFee),
            poolManagerCodeHash: vm.parseJsonBytes32(manifest, ".contracts.poolManager.runtimeCodeHash"),
            positionManagerCodeHash: vm.parseJsonBytes32(manifest, ".contracts.positionManager.runtimeCodeHash"),
            permit2CodeHash: vm.parseJsonBytes32(manifest, ".contracts.permit2.runtimeCodeHash")
        });
    }
}
