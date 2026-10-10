// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Metadata} from "@openzeppelin/contracts/token/ERC721/extensions/IERC721Metadata.sol";
import {IERC2981} from "@openzeppelin/contracts/interfaces/IERC2981.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {IDiamondCut} from "../src/interfaces/IDiamondCut.sol";
import {IDiamondLoupe} from "../src/interfaces/IDiamondLoupe.sol";
import {IERC173} from "../src/interfaces/IERC173.sol";
import {IERC5192} from "../src/interfaces/IERC5192.sol";
import {IModularPositionNFT} from "../src/interfaces/IModularPositionNFT.sol";
import {IPositionOwnerIndex} from "../src/interfaces/IPositionOwnerIndex.sol";
import {IStaticsBasketAdmin} from "../src/interfaces/IStaticsBasketAdmin.sol";
import {IStaticsBasketLiquidity} from "../src/interfaces/IStaticsBasketLiquidity.sol";
import {IStaticsGaugeIncentives} from "../src/interfaces/IStaticsGaugeIncentives.sol";
import {IStaticsMarketTape} from "../src/interfaces/IStaticsMarketTape.sol";
import {IStaticsMarketObservations} from "../src/interfaces/IStaticsMarketObservations.sol";
import {IStaticsAggregatedBatchRewards} from "../src/interfaces/IStaticsAggregatedBatchRewards.sol";
import {IStaticsBatchRewards} from "../src/interfaces/IStaticsBatchRewards.sol";
import {IStaticsGlobalRewards} from "../src/interfaces/IStaticsGlobalRewards.sol";
import {IStaticsGovernance} from "../src/interfaces/IStaticsGovernance.sol";
import {IStaticsLiquidityManager} from "../src/interfaces/IStaticsLiquidityManager.sol";
import {IStaticsPermissionedPools} from "../src/interfaces/IStaticsPermissionedPools.sol";
import {IStaticsPermissionedSwapFeeHook} from "../src/interfaces/IStaticsPermissionedSwapFeeHook.sol";
import {IStaticsPosition, IStaticsPositionFees} from "../src/interfaces/IStaticsPosition.sol";
import {IStaticsPositionMarket} from "../src/interfaces/IStaticsPositionMarket.sol";
import {IStaticsRewardSelectionTiming} from "../src/interfaces/IStaticsRewardSelectionTiming.sol";
import {IStaticsPositionRoyalty} from "../src/interfaces/IStaticsPositionRoyalty.sol";
import {IStaticsProtocolPools} from "../src/interfaces/IStaticsProtocolPools.sol";
import {IStaticsRangeGauge} from "../src/interfaces/IStaticsRangeGauge.sol";
import {IStaticsRewardPolicy} from "../src/interfaces/IStaticsRewardPolicy.sol";
import {StaticsTimelock} from "../src/governance/StaticsTimelock.sol";
import {StaticsSelectors} from "../src/libraries/StaticsSelectors.sol";
import {StaticsPermissionedSwapFeeHook} from "../src/liquidity/StaticsPermissionedSwapFeeHook.sol";
import {StaticsSwapFeeHook} from "../src/liquidity/StaticsSwapFeeHook.sol";
import {RobinhoodWethVerifier} from "./libraries/RobinhoodWethVerifier.sol";
import {StaticsPhaseOneVerifier} from "./libraries/StaticsPhaseOneVerifier.sol";
import {RobinhoodDeploymentConfig} from "./RobinhoodDeploymentConfig.sol";

struct StaticsPhaseOneLiquidityConfig {
    address poolManager;
    address positionManager;
    address liquidityManager;
    address hook;
    address permissionedHook;
    address permissionedRouter;
    address permissionedPositionManager;
    address permissionedQuoter;
    address permit2;
    address weth;
    address governanceSafe;
    address guardian;
    address treasury;
    address stakingToken;
    uint256 positionCreationFeeAmount;
    uint256 poolCreationFeeAmount;
    uint16 weeklyGaugeReleaseBps;
    uint16 inputFeeBps;
    uint16 outputFeeBps;
    uint16 revenueMaintenanceTipBps;
    address protocolPolOperator;
    uint256 protocolPolActivationFee;
    bytes32 diamondCodeHash;
    bytes32 poolManagerCodeHash;
    bytes32 positionManagerCodeHash;
    bytes32 liquidityManagerCodeHash;
    bytes32 hookCodeHash;
    bytes32 permissionedHookCodeHash;
    bytes32 permissionedRouterCodeHash;
    bytes32 permissionedPositionManagerCodeHash;
    bytes32 permissionedPositionClaimsCodeHash;
    bytes32 permissionedQuoterCodeHash;
    bytes32 permit2CodeHash;
    bytes32 wethCodeHash;
}

interface IPermissionedRouterBindings {
    function poolManager() external view returns (address);
    function permit2() external view returns (address);
    function permissionedHook() external view returns (address);
}

interface IPermissionedPositionManagerBindings is IPermissionedRouterBindings {
    function positionClaims() external view returns (address);
    function WETH9() external view returns (address);
}

interface IPermissionedPositionClaimsBindings {
    function poolManager() external view returns (address);
    function positionManager() external view returns (address);
    function permissionedHook() external view returns (address);
}

/// @notice Validates and prepares Phase 1 liquidity installation and governance handoff.
contract ConfigureStaticsPhaseOneLiquidity is Script, RobinhoodDeploymentConfig {
    uint256 private constant LOCAL_CHAIN_ID = 31_337;
    uint256 private constant MAX_WEEKLY_GAUGE_RELEASE_BPS = 1_000;
    uint256 private constant MAX_REVENUE_MAINTENANCE_TIP_BPS = 2_000;
    uint256 private constant DEFAULT_POSITION_ROYALTY_BPS = 500;
    uint160 private constant REQUIRED_HOOK_FLAGS = Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG
        | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        | Hooks.BEFORE_DONATE_FLAG;
    uint160 private constant REQUIRED_PERMISSIONED_HOOK_FLAGS = Hooks.AFTER_INITIALIZE_FLAG
        | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_DONATE_FLAG;
    bytes32 private constant PHASE_STORAGE_POSITION = keccak256("statics.storage.deployment.phases.v1");

    error InvalidDiamond(address diamond);
    error InvalidTimelock(address timelock);
    error InvalidTimelockDelay(uint256 expected, uint256 actual);
    error MissingTimelockRole(bytes32 role, address account);
    error InvalidContract(address target);
    error InvalidCodeHash(address target, bytes32 expected, bytes32 actual);
    error InvalidBinding(address target, address expected, address actual);
    error InvalidHookFlags(uint160 expected, uint160 actual);
    error InvalidHookFees(uint256 expectedInput, uint256 actualInput, uint256 expectedOutput, uint256 actualOutput);
    error InvalidDeploymentPhase(uint256 expected, uint256 actual);
    error InvalidInitializedAddress(bytes32 field, address expected, address actual);
    error InvalidInitializedUint(bytes32 field, uint256 expected, uint256 actual);
    error UnsupportedInterface(bytes4 interfaceId);
    error ConfigurationValueOutOfRange(string field, uint256 value, uint256 maximum);
    error InvalidMaintenanceConfiguration();
    error UnexpectedFacetCount(uint256 expected, uint256 actual);
    error UnexpectedSelectorCount(uint256 expected, uint256 actual);
    error UnexpectedSelector(bytes4 selector, bool expectedInstalled, bool installed);
    error LiquidityAlreadyInstalled();
    error LiquidityInstallationFailed();
    error InvalidLaunchOwner(address expected, address actual);
    error MissingLaunchPools();
    error LaunchPoolMissing(PoolId poolId);

    /// @notice Prints the nine direct Diamond calls for a Safe batch during launch.
    function runPrepareBootstrap() external view {
        address diamond = vm.envAddress("STATICS_DIAMOND_ADDRESS");
        address timelock = vm.envAddress("STATICS_TIMELOCK_ADDRESS");
        StaticsPhaseOneLiquidityConfig memory config = _loadRobinhoodConfig();
        (address[] memory targets, uint256[] memory values, bytes[] memory payloads) =
            prepareBootstrap(diamond, timelock, config);
        for (uint256 i; i < targets.length; ++i) {
            console2.log("SAFE_BATCH_INDEX", i);
            console2.log("SAFE_BATCH_TARGET", targets[i]);
            console2.log("SAFE_BATCH_VALUE", values[i]);
            console2.log("SAFE_BATCH_CALLDATA");
            console2.logBytes(payloads[i]);
        }
    }

    /// @notice Prints the Safe's final ownership transfer after launch pools are live.
    function runPrepareHandoff() external view returns (address target, uint256 value, bytes memory data) {
        address diamond = vm.envAddress("STATICS_DIAMOND_ADDRESS");
        address timelock = vm.envAddress("STATICS_TIMELOCK_ADDRESS");
        StaticsPhaseOneLiquidityConfig memory config = _loadRobinhoodConfig();
        bytes32[] memory publicIds = vm.envBytes32("STATICS_LAUNCH_PUBLIC_POOL_IDS", ",");
        bytes32[] memory permissionedIds = vm.envOr("STATICS_LAUNCH_PERMISSIONED_POOL_IDS", ",", new bytes32[](0));
        (target, value, data) = prepareHandoff(diamond, timelock, config, publicIds, permissionedIds);
        console2.log("SAFE_HANDOFF_TARGET", target);
        console2.log("SAFE_HANDOFF_VALUE", value);
        console2.log("SAFE_HANDOFF_CALLDATA");
        console2.logBytes(data);
    }

    function prepareBootstrap(address diamond, address timelock, StaticsPhaseOneLiquidityConfig memory config)
        public
        view
        returns (address[] memory targets, uint256[] memory values, bytes[] memory payloads)
    {
        _validateBootstrap(diamond, timelock, config, false);
        return buildBatch(diamond, config);
    }

    function prepareHandoff(
        address diamond,
        address timelock,
        StaticsPhaseOneLiquidityConfig memory config,
        bytes32[] memory publicPoolIds,
        bytes32[] memory permissionedPoolIds
    ) public view returns (address target, uint256 value, bytes memory data) {
        _validateBootstrap(diamond, timelock, config, true);
        if (publicPoolIds.length == 0) revert MissingLaunchPools();
        for (uint256 i; i < publicPoolIds.length; ++i) {
            PoolId poolId = PoolId.wrap(publicPoolIds[i]);
            if (!IStaticsProtocolPools(diamond).isProtocolPool(poolId)) revert LaunchPoolMissing(poolId);
        }
        for (uint256 i; i < permissionedPoolIds.length; ++i) {
            PoolId poolId = PoolId.wrap(permissionedPoolIds[i]);
            if (!IStaticsPermissionedPools(diamond).isPermissionedPool(poolId)) revert LaunchPoolMissing(poolId);
        }
        target = diamond;
        value = 0;
        data = abi.encodeCall(IERC173.transferOwnership, (timelock));
    }

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
        targets = new address[](9);
        values = new uint256[](9);
        payloads = new bytes[](9);
        for (uint256 i; i < targets.length; ++i) {
            targets[i] = diamond;
        }
        payloads[0] =
            abi.encodeCall(IStaticsBasketLiquidity.installCanonicalPoolIntegration, (config.poolManager, config.hook));
        payloads[1] = abi.encodeCall(IStaticsBasketLiquidity.installLiquidityManager, (config.liquidityManager));
        payloads[2] = abi.encodeCall(
            IStaticsBasketLiquidity.installPermissionedPoolIntegration,
            (
                config.permissionedHook,
                config.permissionedRouter,
                config.permissionedPositionManager,
                config.permissionedQuoter
            )
        );
        payloads[3] = abi.encodeCall(
            IStaticsPermissionedPools.setPermissionedTrustedPeriphery, (config.permissionedRouter, true)
        );
        payloads[4] = abi.encodeCall(
            IStaticsPermissionedPools.setPermissionedTrustedPeriphery, (config.permissionedPositionManager, true)
        );
        payloads[5] = abi.encodeCall(
            IStaticsPermissionedPools.setPermissionedTrustedPeriphery, (config.permissionedQuoter, true)
        );
        payloads[6] = abi.encodeCall(
            IStaticsProtocolPools.setProtocolPoolMaintenanceConfig,
            (IStaticsProtocolPools.ProtocolPoolMaintenanceConfig({revenueTipBps: config.revenueMaintenanceTipBps}))
        );
        payloads[7] = abi.encodeCall(IStaticsProtocolPools.setProtocolPolOperator, (config.protocolPolOperator));
        payloads[8] =
            abi.encodeCall(IStaticsProtocolPools.setProtocolPolActivationFee, (config.protocolPolActivationFee));
    }

    function _validate(address diamond, StaticsPhaseOneLiquidityConfig memory config, bool requireInstalled)
        private
        view
        returns (TimelockController timelock)
    {
        if (diamond.code.length == 0) revert InvalidDiamond(diamond);
        _validateContract(diamond, config.diamondCodeHash);
        address owner = IERC173(diamond).owner();
        timelock = _validateTimelock(owner, config);

        _validateDependencies(diamond, config);
        _validateInstallState(diamond, config, requireInstalled);
    }

    function _validateBootstrap(
        address diamond,
        address timelockAddress,
        StaticsPhaseOneLiquidityConfig memory config,
        bool requireInstalled
    ) private view {
        if (diamond.code.length == 0) revert InvalidDiamond(diamond);
        _validateContract(diamond, config.diamondCodeHash);
        address owner = IERC173(diamond).owner();
        if (owner != config.governanceSafe) revert InvalidLaunchOwner(config.governanceSafe, owner);
        _validateTimelock(timelockAddress, config);

        _validateDependencies(diamond, config);
        _validateInstallState(diamond, config, requireInstalled);
    }

    function _validateTimelock(address timelockAddress, StaticsPhaseOneLiquidityConfig memory config)
        private
        view
        returns (TimelockController timelock)
    {
        if (timelockAddress.code.length == 0) revert InvalidTimelock(timelockAddress);
        _validateContract(timelockAddress, keccak256(type(StaticsTimelock).runtimeCode));
        timelock = TimelockController(payable(timelockAddress));
        uint256 expectedDelay = _expectedInitialDelay();
        uint256 actualDelay = timelock.getMinDelay();
        if (actualDelay != expectedDelay) revert InvalidTimelockDelay(expectedDelay, actualDelay);
        _validateTimelockRoles(timelock, config.governanceSafe, config.guardian);
    }

    function _validateDependencies(address diamond, StaticsPhaseOneLiquidityConfig memory config) private view {
        _validatePhaseOneSelectors(diamond);
        StaticsPhaseOneVerifier.validateRuntimes(diamond);
        _validateInitializedState(diamond, config);
        _validateContract(config.poolManager, config.poolManagerCodeHash);
        _validateContract(config.positionManager, config.positionManagerCodeHash);
        _validateContract(config.liquidityManager, config.liquidityManagerCodeHash);
        _validateContract(config.hook, config.hookCodeHash);
        _validateContract(config.permissionedHook, config.permissionedHookCodeHash);
        _validateContract(config.permissionedRouter, config.permissionedRouterCodeHash);
        _validateContract(config.permissionedPositionManager, config.permissionedPositionManagerCodeHash);
        _validateContract(config.permissionedQuoter, config.permissionedQuoterCodeHash);
        _validateContract(config.permit2, config.permit2CodeHash);
        _validateContract(config.weth, config.wethCodeHash);
        RobinhoodWethVerifier.validateMainnet(vm, config.weth);

        IPermissionedRouterBindings canonicalPositionManager = IPermissionedRouterBindings(config.positionManager);
        _binding(config.positionManager, config.poolManager, canonicalPositionManager.poolManager());
        _binding(config.positionManager, config.permit2, canonicalPositionManager.permit2());
        _binding(
            config.positionManager, config.weth, IPermissionedPositionManagerBindings(config.positionManager).WETH9()
        );
        IStaticsLiquidityManager liquidityManager = IStaticsLiquidityManager(config.liquidityManager);
        _binding(config.liquidityManager, diamond, liquidityManager.staticsDiamond());
        _binding(config.liquidityManager, config.poolManager, liquidityManager.poolManager());
        _binding(config.liquidityManager, config.positionManager, liquidityManager.positionManager());
        _binding(config.liquidityManager, config.permit2, liquidityManager.permit2());

        StaticsSwapFeeHook hook = StaticsSwapFeeHook(payable(config.hook));
        _binding(config.hook, diamond, hook.staticsDiamond());
        _binding(config.hook, config.weth, hook.weth());
        _binding(config.hook, config.poolManager, address(hook.poolManager()));
        (uint16 inputFeeBps, uint16 outputFeeBps) = hook.defaultFeeRate();
        if (inputFeeBps != config.inputFeeBps || outputFeeBps != config.outputFeeBps) {
            revert InvalidHookFees(config.inputFeeBps, inputFeeBps, config.outputFeeBps, outputFeeBps);
        }
        uint160 actualFlags = uint160(config.hook) & Hooks.ALL_HOOK_MASK;
        if (actualFlags != REQUIRED_HOOK_FLAGS) revert InvalidHookFlags(REQUIRED_HOOK_FLAGS, actualFlags);

        StaticsPermissionedSwapFeeHook permissionedHook = StaticsPermissionedSwapFeeHook(config.permissionedHook);
        _binding(config.permissionedHook, diamond, permissionedHook.staticsDiamond());
        _binding(config.permissionedHook, config.poolManager, address(permissionedHook.poolManager()));
        uint160 actualPermissionedFlags = uint160(config.permissionedHook) & Hooks.ALL_HOOK_MASK;
        if (actualPermissionedFlags != REQUIRED_PERMISSIONED_HOOK_FLAGS) {
            revert InvalidHookFlags(REQUIRED_PERMISSIONED_HOOK_FLAGS, actualPermissionedFlags);
        }
        _validatePeripheryBindings(config);
    }

    function _validateInitializedState(address diamond, StaticsPhaseOneLiquidityConfig memory config) private view {
        uint256 activePhase = uint256(vm.load(diamond, PHASE_STORAGE_POSITION)) & type(uint8).max;
        if (activePhase != 1) revert InvalidDeploymentPhase(1, activePhase);

        _initializedAddress("guardian", config.guardian, IStaticsGovernance(diamond).guardian());
        _initializedAddress("treasury", config.treasury, IStaticsBasketAdmin(diamond).treasury());
        _initializedAddress("stakingToken", config.stakingToken, IStaticsGlobalRewards(diamond).stakingToken());
        _initializedUint(
            "positionCreationFee", config.positionCreationFeeAmount, IStaticsPositionFees(diamond).positionCreationFee()
        );
        _initializedUint(
            "poolCreationFee", config.poolCreationFeeAmount, IStaticsProtocolPools(diamond).poolCreationFee()
        );
        _initializedUint(
            "weeklyGaugeReleaseBps",
            config.weeklyGaugeReleaseBps,
            IStaticsGaugeIncentives(diamond).gaugeReserve().releaseBps
        );
        (address royaltyReceiver, uint16 royaltyBps) = IStaticsPositionRoyalty(diamond).positionRoyalty();
        _initializedAddress("positionRoyaltyReceiver", config.treasury, royaltyReceiver);
        _initializedUint("positionRoyaltyBps", DEFAULT_POSITION_ROYALTY_BPS, royaltyBps);

        _supportedInterface(diamond, type(IERC165).interfaceId);
        _supportedInterface(diamond, type(IDiamondCut).interfaceId);
        _supportedInterface(diamond, type(IDiamondLoupe).interfaceId);
        _supportedInterface(diamond, type(IERC173).interfaceId);
        _supportedInterface(diamond, type(IERC721).interfaceId);
        _supportedInterface(diamond, type(IERC721Metadata).interfaceId);
        _supportedInterface(diamond, type(IERC2981).interfaceId);
        _supportedInterface(diamond, type(IStaticsGlobalRewards).interfaceId);
        _supportedInterface(diamond, type(IStaticsBatchRewards).interfaceId);
        _supportedInterface(diamond, type(IStaticsAggregatedBatchRewards).interfaceId);
        _supportedInterface(diamond, type(IStaticsPosition).interfaceId);
        _supportedInterface(diamond, type(IStaticsPositionFees).interfaceId);
        _supportedInterface(diamond, type(IStaticsPositionRoyalty).interfaceId);
        _supportedInterface(diamond, type(IStaticsPositionMarket).interfaceId);
        _supportedInterface(diamond, type(IStaticsRewardSelectionTiming).interfaceId);
        _supportedInterface(diamond, type(IStaticsRangeGauge).interfaceId);
        _supportedInterface(diamond, type(IStaticsGaugeIncentives).interfaceId);
        _supportedInterface(diamond, type(IStaticsMarketTape).interfaceId);
        _supportedInterface(diamond, type(IStaticsMarketObservations).interfaceId);
        _supportedInterface(diamond, type(IStaticsRewardPolicy).interfaceId);
        _supportedInterface(diamond, type(IStaticsPermissionedPools).interfaceId);
        _supportedInterface(diamond, type(IModularPositionNFT).interfaceId);
        _supportedInterface(diamond, type(IPositionOwnerIndex).interfaceId);
        _supportedInterface(diamond, type(IERC5192).interfaceId);
    }

    function _initializedAddress(bytes32 field, address expected, address actual) private pure {
        if (actual != expected) revert InvalidInitializedAddress(field, expected, actual);
    }

    function _initializedUint(bytes32 field, uint256 expected, uint256 actual) private pure {
        if (actual != expected) revert InvalidInitializedUint(field, expected, actual);
    }

    function _supportedInterface(address diamond, bytes4 interfaceId) private view {
        if (!IERC165(diamond).supportsInterface(interfaceId)) revert UnsupportedInterface(interfaceId);
    }

    function _validateTimelockRoles(TimelockController timelock, address governanceSafe, address guardian)
        private
        view
    {
        bytes32 proposerRole = timelock.PROPOSER_ROLE();
        bytes32 cancellerRole = timelock.CANCELLER_ROLE();
        bytes32 executorRole = timelock.EXECUTOR_ROLE();
        if (!timelock.hasRole(proposerRole, governanceSafe)) {
            revert MissingTimelockRole(proposerRole, governanceSafe);
        }
        if (!timelock.hasRole(cancellerRole, guardian)) {
            revert MissingTimelockRole(cancellerRole, guardian);
        }
        if (!timelock.hasRole(executorRole, address(0))) {
            revert MissingTimelockRole(executorRole, address(0));
        }
    }

    function _validateInstallState(address diamond, StaticsPhaseOneLiquidityConfig memory config, bool requireInstalled)
        private
        view
    {
        _validatePublicInstallState(diamond, config, requireInstalled);
        _validatePermissionedInstallState(diamond, config, requireInstalled);
        _validateProtocolPolInstallState(diamond, config, requireInstalled);
    }

    function _validatePublicInstallState(
        address diamond,
        StaticsPhaseOneLiquidityConfig memory config,
        bool requireInstalled
    ) private view {
        (address installedPoolManager, address installedHook, bool integrationInstalled) =
            IStaticsBasketLiquidity(diamond).liquidityIntegration();
        (address installedLiquidityManager, bool managerInstalled) = IStaticsBasketLiquidity(diamond).liquidityManager();
        if (requireInstalled) {
            if (
                !integrationInstalled || installedPoolManager != config.poolManager || installedHook != config.hook
                    || !managerInstalled || installedLiquidityManager != config.liquidityManager
            ) revert LiquidityInstallationFailed();
        } else if (integrationInstalled || managerInstalled) {
            revert LiquidityAlreadyInstalled();
        }
    }

    function _validatePermissionedInstallState(
        address diamond,
        StaticsPhaseOneLiquidityConfig memory config,
        bool requireInstalled
    ) private view {
        (
            address installedHook,
            address installedRouter,
            address installedPositionManager,
            address installedQuoter,
            bool installed
        ) = IStaticsBasketLiquidity(diamond).permissionedLiquidityIntegration();
        if (!requireInstalled) {
            if (installed) revert LiquidityAlreadyInstalled();
            return;
        }
        IStaticsPermissionedSwapFeeHook hook = IStaticsPermissionedSwapFeeHook(config.permissionedHook);
        if (
            !installed || installedHook != config.permissionedHook || installedRouter != config.permissionedRouter
                || installedPositionManager != config.permissionedPositionManager
                || installedQuoter != config.permissionedQuoter || !hook.trustedPeriphery(config.permissionedRouter)
                || !hook.trustedPeriphery(config.permissionedPositionManager)
                || !hook.trustedPeriphery(config.permissionedQuoter)
        ) revert LiquidityInstallationFailed();
    }

    function _validateProtocolPolInstallState(
        address diamond,
        StaticsPhaseOneLiquidityConfig memory config,
        bool requireInstalled
    ) private view {
        uint16 revenueTipBps = IStaticsProtocolPools(diamond).protocolPoolMaintenanceConfig().revenueTipBps;
        address operator = IStaticsProtocolPools(diamond).protocolPolOperator();
        uint256 activationFee = IStaticsProtocolPools(diamond).protocolPolActivationFee();
        if (requireInstalled) {
            if (
                revenueTipBps != config.revenueMaintenanceTipBps || operator != config.protocolPolOperator
                    || activationFee != config.protocolPolActivationFee
            ) revert LiquidityInstallationFailed();
        } else if (revenueTipBps != 0 || operator != address(0) || activationFee != 0) {
            revert LiquidityAlreadyInstalled();
        }
    }

    function _validatePhaseOneSelectors(address diamond) private view {
        IDiamondLoupe.Facet[] memory facets = IDiamondLoupe(diamond).facets();
        if (facets.length != 32) revert UnexpectedFacetCount(32, facets.length);

        uint256 selectorCount = 0;
        for (uint256 i; i < facets.length; ++i) {
            selectorCount += facets[i].functionSelectors.length;
        }
        if (selectorCount != 226) revert UnexpectedSelectorCount(226, selectorCount);

        bytes4[][] memory selectorSets = _phaseOneSelectorSets();
        for (uint256 i; i < selectorSets.length; ++i) {
            bytes4[] memory selectors = selectorSets[i];
            for (uint256 j; j < selectors.length; ++j) {
                bytes4 selector = selectors[j];
                if (!_containsSelector(facets, selector)) revert UnexpectedSelector(selector, true, false);
            }
        }

        _expectSelector(diamond, IStaticsBasketLiquidity.installLiquidityManager.selector, true);
        _expectSelector(diamond, IStaticsProtocolPools.replaceLiquidityManager.selector, true);
    }

    function _phaseOneSelectorSets() private pure returns (bytes4[][] memory sets) {
        sets = new bytes4[][](32);
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
        sets[12] = StaticsSelectors.protocolPoolMaintenance();
        sets[13] = StaticsSelectors.protocolPol();
        sets[14] = StaticsSelectors.phaseOneProtocolPoolView();
        sets[15] = StaticsSelectors.phaseOneProtocolRevenue();
        sets[16] = StaticsSelectors.rewardPolicy();
        sets[17] = StaticsSelectors.permissionedPoolCreation();
        sets[18] = StaticsSelectors.permissionedPoolAdmin();
        sets[19] = StaticsSelectors.permissionedPoolView();
        sets[20] = StaticsSelectors.rangeGaugeActions();
        sets[21] = StaticsSelectors.rangeGaugePositionIngress();
        sets[22] = StaticsSelectors.rangeGaugePositionManagement();
        sets[23] = StaticsSelectors.rangeGaugeLiveness();
        sets[24] = StaticsSelectors.rangeGaugeViews();
        sets[25] = StaticsSelectors.rangeGaugeCallback();
        sets[26] = StaticsSelectors.gaugeIncentiveActions();
        sets[27] = StaticsSelectors.gaugeIncentiveViews();
        sets[28] = StaticsSelectors.marketTapeViews();
        sets[29] = StaticsSelectors.marketTapeObservations();
        sets[30] = StaticsSelectors.positionMarket();
        sets[31] = StaticsSelectors.batchRewards();
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

    function _expectedInitialDelay() private view returns (uint256) {
        if (block.chainid == ROBINHOOD_TESTNET_CHAIN_ID || block.chainid == LOCAL_CHAIN_ID) return 2 minutes;
        return 24 hours;
    }

    function _loadRobinhoodConfig() private view returns (StaticsPhaseOneLiquidityConfig memory config) {
        string memory manifest = vm.readFile(_robinhoodManifestPath(block.chainid));
        uint256 inputFee = vm.parseJsonUint(manifest, ".staticsLiquidityCalibration.inputFeeBps");
        uint256 outputFee = vm.parseJsonUint(manifest, ".staticsLiquidityCalibration.outputFeeBps");
        uint256 weeklyGaugeReleaseBps = vm.envOr("WEEKLY_GAUGE_RELEASE_BPS", uint256(400));
        uint256 revenueTipBps = vm.envOr("STATICS_REVENUE_MAINTENANCE_TIP_BPS", uint256(500));
        if (inputFee > type(uint16).max || outputFee > type(uint16).max) {
            revert InvalidHookFees(type(uint16).max, inputFee, type(uint16).max, outputFee);
        }
        if (weeklyGaugeReleaseBps > MAX_WEEKLY_GAUGE_RELEASE_BPS) {
            revert ConfigurationValueOutOfRange(
                "WEEKLY_GAUGE_RELEASE_BPS", weeklyGaugeReleaseBps, MAX_WEEKLY_GAUGE_RELEASE_BPS
            );
        }
        if (revenueTipBps > MAX_REVENUE_MAINTENANCE_TIP_BPS) revert InvalidMaintenanceConfiguration();
        string memory wethPath = block.chainid == ROBINHOOD_MAINNET_CHAIN_ID
            ? ".contracts.weth.runtimeCodeHash"
            : ".staticsDollarDependencies.weth.runtimeCodeHash";
        config = StaticsPhaseOneLiquidityConfig({
            poolManager: vm.parseJsonAddress(manifest, ".contracts.poolManager.address"),
            positionManager: vm.parseJsonAddress(manifest, ".contracts.positionManager.address"),
            liquidityManager: vm.envAddress("STATICS_LIQUIDITY_MANAGER_ADDRESS"),
            hook: vm.envAddress("STATICS_SWAP_FEE_HOOK_ADDRESS"),
            permissionedHook: vm.envAddress("STATICS_PERMISSIONED_SWAP_FEE_HOOK_ADDRESS"),
            permissionedRouter: vm.envAddress("STATICS_PERMISSIONED_ROUTER_ADDRESS"),
            permissionedPositionManager: vm.envAddress("STATICS_PERMISSIONED_POSITION_MANAGER_ADDRESS"),
            permissionedQuoter: vm.parseJsonAddress(manifest, ".contracts.quoter.address"),
            permit2: vm.parseJsonAddress(manifest, ".contracts.permit2.address"),
            weth: vm.envAddress("WETH_ADDRESS"),
            governanceSafe: vm.envAddress("MULTISIG"),
            guardian: vm.envAddress("GUARDIAN"),
            treasury: vm.envAddress("TREASURY"),
            stakingToken: vm.envAddress("STAKING_TOKEN"),
            positionCreationFeeAmount: vm.envUint("POSITION_CREATION_FEE_AMOUNT"),
            poolCreationFeeAmount: vm.envUint("POOL_CREATION_FEE_AMOUNT"),
            weeklyGaugeReleaseBps: uint16(weeklyGaugeReleaseBps),
            inputFeeBps: uint16(inputFee),
            outputFeeBps: uint16(outputFee),
            revenueMaintenanceTipBps: uint16(revenueTipBps),
            protocolPolOperator: vm.envAddress("STATICS_POL_OPERATOR"),
            protocolPolActivationFee: vm.envUint("STATICS_POL_ACTIVATION_FEE"),
            diamondCodeHash: vm.envBytes32("STATICS_DIAMOND_RUNTIME_CODE_HASH"),
            poolManagerCodeHash: vm.parseJsonBytes32(manifest, ".contracts.poolManager.runtimeCodeHash"),
            positionManagerCodeHash: vm.parseJsonBytes32(manifest, ".contracts.positionManager.runtimeCodeHash"),
            liquidityManagerCodeHash: vm.envBytes32("STATICS_LIQUIDITY_MANAGER_RUNTIME_CODE_HASH"),
            hookCodeHash: vm.envBytes32("STATICS_SWAP_FEE_HOOK_RUNTIME_CODE_HASH"),
            permissionedHookCodeHash: vm.envBytes32("STATICS_PERMISSIONED_SWAP_FEE_HOOK_RUNTIME_CODE_HASH"),
            permissionedRouterCodeHash: vm.envBytes32("STATICS_PERMISSIONED_ROUTER_RUNTIME_CODE_HASH"),
            permissionedPositionManagerCodeHash: vm.envBytes32(
                "STATICS_PERMISSIONED_POSITION_MANAGER_RUNTIME_CODE_HASH"
            ),
            permissionedPositionClaimsCodeHash: vm.envBytes32("STATICS_PERMISSIONED_POSITION_CLAIMS_RUNTIME_CODE_HASH"),
            permissionedQuoterCodeHash: vm.parseJsonBytes32(manifest, ".contracts.quoter.runtimeCodeHash"),
            permit2CodeHash: vm.parseJsonBytes32(manifest, ".contracts.permit2.runtimeCodeHash"),
            wethCodeHash: vm.parseJsonBytes32(manifest, wethPath)
        });
    }

    function _validatePeripheryBindings(StaticsPhaseOneLiquidityConfig memory config) private view {
        IPermissionedRouterBindings router = IPermissionedRouterBindings(config.permissionedRouter);
        _binding(config.permissionedRouter, config.poolManager, router.poolManager());
        _binding(config.permissionedRouter, config.permit2, router.permit2());
        _binding(config.permissionedRouter, config.permissionedHook, router.permissionedHook());
        IPermissionedPositionManagerBindings positionManager =
            IPermissionedPositionManagerBindings(config.permissionedPositionManager);
        _binding(config.permissionedPositionManager, config.poolManager, positionManager.poolManager());
        _binding(config.permissionedPositionManager, config.permit2, positionManager.permit2());
        _binding(config.permissionedPositionManager, config.permissionedHook, positionManager.permissionedHook());
        _binding(config.permissionedPositionManager, config.weth, positionManager.WETH9());
        address claimsAddress = positionManager.positionClaims();
        _validateContract(claimsAddress, config.permissionedPositionClaimsCodeHash);
        IPermissionedPositionClaimsBindings claims = IPermissionedPositionClaimsBindings(claimsAddress);
        _binding(claimsAddress, config.poolManager, claims.poolManager());
        _binding(claimsAddress, config.permissionedPositionManager, claims.positionManager());
        _binding(claimsAddress, config.permissionedHook, claims.permissionedHook());
        _binding(
            config.permissionedQuoter,
            config.poolManager,
            IPermissionedRouterBindings(config.permissionedQuoter).poolManager()
        );
    }
}
