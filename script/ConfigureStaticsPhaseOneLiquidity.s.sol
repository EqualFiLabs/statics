// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {IDiamondLoupe} from "../src/interfaces/IDiamondLoupe.sol";
import {IERC173} from "../src/interfaces/IERC173.sol";
import {IStaticsBasketLiquidity} from "../src/interfaces/IStaticsBasketLiquidity.sol";
import {IStaticsProtocolPools} from "../src/interfaces/IStaticsProtocolPools.sol";
import {StaticsSelectors} from "../src/libraries/StaticsSelectors.sol";
import {StaticsPermanentLiquidityMath} from "../src/liquidity/StaticsPermanentLiquidityMath.sol";
import {StaticsSwapFeeHook} from "../src/liquidity/StaticsSwapFeeHook.sol";
import {RobinhoodDeploymentConfig} from "./RobinhoodDeploymentConfig.sol";

struct StaticsPhaseOneLiquidityConfig {
    address poolManager;
    address hook;
    address permanentLiquidityHarvester;
    uint16 inputFeeBps;
    uint16 outputFeeBps;
    bytes32 poolManagerCodeHash;
    bytes32 hookCodeHash;
}

/// @notice Timelock ceremony for installing only the v4 dependencies used by the Phase 1 DEX.
contract ConfigureStaticsPhaseOneLiquidity is Script, RobinhoodDeploymentConfig {
    uint160 private constant REQUIRED_HOOK_FLAGS = Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG
        | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        | Hooks.BEFORE_DONATE_FLAG;

    error InvalidDiamond(address diamond);
    error InvalidTimelock(address timelock);
    error InvalidContract(address target);
    error InvalidCodeHash(address target, bytes32 expected, bytes32 actual);
    error InvalidBinding(address target, address expected, address actual);
    error InvalidPermanentLiquidityHarvester(address harvester);
    error InvalidHookFlags(uint160 expected, uint160 actual);
    error InvalidHookFees(uint256 expectedInput, uint256 actualInput, uint256 expectedOutput, uint256 actualOutput);
    error UnexpectedFacetCount(uint256 expected, uint256 actual);
    error UnexpectedSelectorCount(uint256 expected, uint256 actual);
    error UnexpectedSelector(bytes4 selector, bool expectedInstalled, bool installed);
    error LiquidityAlreadyInstalled();
    error LiquidityInstallationFailed();

    /// @notice Builds the single timelock scheduling call for submission by the governance Safe.
    /// @dev This preparation path never broadcasts and does not require a Safe private key.
    function runPrepare()
        external
        view
        returns (address target, uint256 value, bytes memory data, bytes32 operationId, uint256 delay)
    {
        address diamond = vm.envAddress("STATICS_DIAMOND_ADDRESS");
        bytes32 salt = vm.envBytes32("STATICS_LIQUIDITY_TIMELOCK_SALT");
        StaticsPhaseOneLiquidityConfig memory config = _loadRobinhoodConfig();
        (target, value, data, operationId, delay) = prepare(diamond, config, salt);
        console2.log("TIMELOCK_SCHEDULE_TARGET", target);
        console2.log("TIMELOCK_SCHEDULE_VALUE", value);
        console2.log("TIMELOCK_OPERATION_ID");
        console2.logBytes32(operationId);
        console2.log("TIMELOCK_DELAY", delay);
        console2.log("TIMELOCK_SCHEDULE_CALLDATA");
        console2.logBytes(data);
    }

    function runExecute() external {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address diamond = vm.envAddress("STATICS_DIAMOND_ADDRESS");
        bytes32 salt = vm.envBytes32("STATICS_LIQUIDITY_TIMELOCK_SALT");
        StaticsPhaseOneLiquidityConfig memory config = _loadRobinhoodConfig();

        vm.startBroadcast(privateKey);
        execute(diamond, config, salt);
        vm.stopBroadcast();
    }

    function prepare(address diamond, StaticsPhaseOneLiquidityConfig memory config, bytes32 salt)
        public
        view
        returns (address target, uint256 value, bytes memory data, bytes32 operationId, uint256 delay)
    {
        TimelockController timelock = _validate(diamond, config, false);
        (address[] memory targets, uint256[] memory values, bytes[] memory payloads) = buildBatch(diamond, config);
        delay = timelock.getMinDelay();
        operationId = timelock.hashOperationBatch(targets, values, payloads, bytes32(0), salt);
        target = address(timelock);
        value = 0;
        data = abi.encodeCall(TimelockController.scheduleBatch, (targets, values, payloads, bytes32(0), salt, delay));
    }

    function execute(address diamond, StaticsPhaseOneLiquidityConfig memory config, bytes32 salt) public {
        TimelockController timelock = _validate(diamond, config, false);
        (address[] memory targets, uint256[] memory values, bytes[] memory payloads) = buildBatch(diamond, config);
        timelock.executeBatch(targets, values, payloads, bytes32(0), salt);
        _validate(diamond, config, true);
    }

    function buildBatch(address diamond, StaticsPhaseOneLiquidityConfig memory config)
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
        payloads[1] =
            abi.encodeCall(IStaticsProtocolPools.setPermanentLiquidityHarvester, (config.permanentLiquidityHarvester));
    }

    function _validate(address diamond, StaticsPhaseOneLiquidityConfig memory config, bool requireInstalled)
        private
        view
        returns (TimelockController timelock)
    {
        if (diamond.code.length == 0) revert InvalidDiamond(diamond);
        if (config.permanentLiquidityHarvester == address(0) || config.permanentLiquidityHarvester == diamond) {
            revert InvalidPermanentLiquidityHarvester(config.permanentLiquidityHarvester);
        }
        address owner = IERC173(diamond).owner();
        if (owner.code.length == 0) revert InvalidTimelock(owner);
        timelock = TimelockController(payable(owner));

        _validatePhaseOneSelectors(diamond);
        _validateContract(config.poolManager, config.poolManagerCodeHash);
        _validateContract(config.hook, config.hookCodeHash);

        StaticsSwapFeeHook hook = StaticsSwapFeeHook(payable(config.hook));
        _binding(config.hook, diamond, hook.staticsDiamond());
        _binding(config.hook, config.poolManager, address(hook.poolManager()));
        _validateContract(
            address(hook.permanentLiquidityMath()), keccak256(type(StaticsPermanentLiquidityMath).runtimeCode)
        );
        (uint16 inputFeeBps, uint16 outputFeeBps) = hook.defaultFeeRate();
        if (inputFeeBps != config.inputFeeBps || outputFeeBps != config.outputFeeBps) {
            revert InvalidHookFees(config.inputFeeBps, inputFeeBps, config.outputFeeBps, outputFeeBps);
        }
        uint160 actualFlags = uint160(config.hook) & Hooks.ALL_HOOK_MASK;
        if (actualFlags != REQUIRED_HOOK_FLAGS) revert InvalidHookFlags(REQUIRED_HOOK_FLAGS, actualFlags);

        (address installedPoolManager, address installedHook, bool integrationInstalled) =
            IStaticsBasketLiquidity(diamond).liquidityIntegration();
        address installedHarvester = IStaticsProtocolPools(diamond).permanentLiquidityHarvester();
        if (requireInstalled) {
            if (
                !integrationInstalled || installedPoolManager != config.poolManager || installedHook != config.hook
                    || installedHarvester != config.permanentLiquidityHarvester
            ) revert LiquidityInstallationFailed();
        } else if (integrationInstalled || installedHarvester != address(0)) {
            revert LiquidityAlreadyInstalled();
        }
    }

    function _validatePhaseOneSelectors(address diamond) private view {
        IDiamondLoupe.Facet[] memory facets = IDiamondLoupe(diamond).facets();
        if (facets.length != 14) revert UnexpectedFacetCount(14, facets.length);

        uint256 selectorCount;
        for (uint256 i; i < facets.length; ++i) {
            selectorCount += facets[i].functionSelectors.length;
        }
        if (selectorCount != 106) revert UnexpectedSelectorCount(106, selectorCount);

        bytes4[][] memory selectorSets = _phaseOneSelectorSets();
        for (uint256 i; i < selectorSets.length; ++i) {
            bytes4[] memory selectors = selectorSets[i];
            for (uint256 j; j < selectors.length; ++j) {
                bytes4 selector = selectors[j];
                if (!_containsSelector(facets, selector)) revert UnexpectedSelector(selector, true, false);
            }
        }

        _expectSelector(diamond, IStaticsBasketLiquidity.installLiquidityManager.selector, false);
        _expectSelector(diamond, IStaticsProtocolPools.replaceLiquidityManager.selector, false);
    }

    function _phaseOneSelectorSets() private pure returns (bytes4[][] memory sets) {
        sets = new bytes4[][](14);
        sets[0] = StaticsSelectors.diamondCut();
        sets[1] = StaticsSelectors.diamondLoupe();
        sets[2] = StaticsSelectors.ownership();
        sets[3] = StaticsSelectors.phaseOneGovernance();
        sets[4] = StaticsSelectors.position();
        sets[5] = StaticsSelectors.phaseOneCustody();
        sets[6] = StaticsSelectors.phaseOneTreasuryAdmin();
        sets[7] = StaticsSelectors.phaseOneLiquidityIntegration();
        sets[8] = StaticsSelectors.globalRewards();
        sets[9] = StaticsSelectors.interfaceInit();
        sets[10] = StaticsSelectors.protocolPoolCreation();
        sets[11] = StaticsSelectors.phaseOneProtocolPoolAdmin();
        sets[12] = StaticsSelectors.phaseOneProtocolPoolView();
        sets[13] = StaticsSelectors.phaseOneProtocolRevenue();
    }

    function _containsSelector(IDiamondLoupe.Facet[] memory facets, bytes4 expected) private pure returns (bool) {
        for (uint256 i; i < facets.length; ++i) {
            bytes4[] memory selectors = facets[i].functionSelectors;
            for (uint256 j; j < selectors.length; ++j) {
                if (selectors[j] == expected) return true;
            }
        }
        return false;
    }

    function _expectSelector(address diamond, bytes4 selector, bool expectedInstalled) private view {
        bool installed = IDiamondLoupe(diamond).facetAddress(selector) != address(0);
        if (installed != expectedInstalled) revert UnexpectedSelector(selector, expectedInstalled, installed);
    }

    function _validateContract(address target, bytes32 expectedHash) private view {
        if (target.code.length == 0) revert InvalidContract(target);
        bytes32 actualHash = target.codehash;
        if (expectedHash == bytes32(0) || expectedHash != actualHash) {
            revert InvalidCodeHash(target, expectedHash, actualHash);
        }
    }

    function _binding(address target, address expected, address actual) private pure {
        if (expected != actual) revert InvalidBinding(target, expected, actual);
    }

    function _loadRobinhoodConfig() private view returns (StaticsPhaseOneLiquidityConfig memory config) {
        string memory manifest = vm.readFile(_robinhoodManifestPath(block.chainid));
        uint256 inputFee = vm.parseJsonUint(manifest, ".staticsLiquidityCalibration.inputFeeBps");
        uint256 outputFee = vm.parseJsonUint(manifest, ".staticsLiquidityCalibration.outputFeeBps");
        if (inputFee > type(uint16).max || outputFee > type(uint16).max) {
            revert InvalidHookFees(type(uint16).max, inputFee, type(uint16).max, outputFee);
        }
        config = StaticsPhaseOneLiquidityConfig({
            poolManager: vm.parseJsonAddress(manifest, ".contracts.poolManager.address"),
            hook: vm.envAddress("STATICS_SWAP_FEE_HOOK_ADDRESS"),
            permanentLiquidityHarvester: vm.envAddress("STATICS_PERMANENT_LIQUIDITY_HARVESTER"),
            inputFeeBps: uint16(inputFee),
            outputFeeBps: uint16(outputFee),
            poolManagerCodeHash: vm.parseJsonBytes32(manifest, ".contracts.poolManager.runtimeCodeHash"),
            hookCodeHash: vm.envBytes32("STATICS_SWAP_FEE_HOOK_RUNTIME_CODE_HASH")
        });
    }
}
