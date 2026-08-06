// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Script} from "forge-std/Script.sol";

import {IDiamondLoupe} from "../src/interfaces/IDiamondLoupe.sol";
import {IERC173} from "../src/interfaces/IERC173.sol";
import {IStaticsBasket} from "../src/interfaces/IStaticsBasket.sol";
import {IStaticsBasketAdmin} from "../src/interfaces/IStaticsBasketAdmin.sol";
import {IStaticsBasketLiquidity} from "../src/interfaces/IStaticsBasketLiquidity.sol";
import {IStaticsGlobalRewards} from "../src/interfaces/IStaticsGlobalRewards.sol";
import {IStaticsGovernance} from "../src/interfaces/IStaticsGovernance.sol";
import {IStaticsLending} from "../src/interfaces/IStaticsLending.sol";
import {IStaticsSwapFeeHook} from "../src/interfaces/IStaticsSwapFeeHook.sol";

struct LegacyBasketRetirementConfig {
    uint256 chainId;
    address diamond;
    bytes32 diamondCodeHash;
    address timelock;
    bytes32 timelockCodeHash;
    address guardian;
    address treasury;
    address hook;
    bytes32 hookCodeHash;
    address governanceFacet;
    address basketLiquidityFacet;
    address globalRewardsFacet;
    uint256 basketId;
    address basketToken;
    bytes32 basketTokenCodeHash;
    address[] assets;
    bytes32[] poolIds;
    bytes32 salt;
}

/// @notice Quarantines and atomically retires one legacy genesis basket through its existing timelock.
contract RetireLegacyGenesisBasket is Script {
    bytes32 private constant PREDECESSOR = bytes32(0);

    error InvalidConfiguration();
    error InvalidChain(uint256 expected, uint256 actual);
    error InvalidContract(address target);
    error InvalidCodeHash(address target, bytes32 expected, bytes32 actual);
    error InvalidBinding(address target, address expected, address actual);
    error InvalidFacet(bytes4 selector, address expected, address actual);
    error InvalidOperator(address expected, address actual);
    error MissingTimelockRole(bytes32 role, address operator);
    error BasketDefinitionMismatch(uint256 basketId);
    error InvalidBasketStatus(
        uint256 basketId, IStaticsBasket.BasketStatus expected, IStaticsBasket.BasketStatus actual
    );
    error OutstandingPrincipal(uint256 basketId, address asset, uint256 principal);
    error PoolAlreadyRetired(uint256 basketId, address asset);
    error PoolNotRetired(uint256 basketId, address asset);
    error PoolBindingMismatch(uint256 basketId, address asset, bytes32 expectedPoolId, bytes32 actualPoolId);
    error NoLockedProtocolLiquidity(uint256 basketId, address asset);
    error LockedProtocolLiquidityRemaining(bytes32 poolId, uint256 liquidity);
    error PendingProtocolLiquidityRemaining(bytes32 poolId, address currency, uint256 amount);
    error TreasuryFeesRemaining(address asset, uint256 amount);
    error OperationNotReady(bytes32 operationId);

    event LegacyBasketQuarantined(address indexed diamond, uint256 indexed basketId, address indexed guardian);
    event LegacyBasketRetirementScheduled(
        bytes32 indexed operationId,
        address indexed diamond,
        address indexed timelock,
        uint256 basketId,
        uint256 poolCount,
        uint256 delay
    );
    event LegacyBasketRetirementValidated(
        bytes32 indexed operationId, address indexed diamond, uint256 indexed basketId, uint256 basketTokenSupply
    );

    function runQuarantine() external {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        LegacyBasketRetirementConfig memory config = loadConfig(vm.envString("STATICS_LEGACY_RETIREMENT_CONFIG"));
        address operator = vm.addr(privateKey);
        if (operator != config.guardian) revert InvalidOperator(config.guardian, operator);
        validateReadyToQuarantine(config);

        vm.startBroadcast(privateKey);
        IStaticsGovernance(config.diamond).quarantineBasket(config.basketId);
        vm.stopBroadcast();

        _validateStatus(config, IStaticsBasket.BasketStatus.Quarantined);
        emit LegacyBasketQuarantined(config.diamond, config.basketId, operator);
    }

    function runSchedule() external returns (bytes32 operationId) {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        LegacyBasketRetirementConfig memory config = loadConfig(vm.envString("STATICS_LEGACY_RETIREMENT_CONFIG"));
        TimelockController timelock = _timelock(config);
        address operator = vm.addr(privateKey);
        bytes32 proposerRole = timelock.PROPOSER_ROLE();
        if (!timelock.hasRole(proposerRole, operator)) revert MissingTimelockRole(proposerRole, operator);
        validateReadyToSchedule(config);
        (address[] memory targets, uint256[] memory values, bytes[] memory payloads) = buildBatch(config);
        uint256 delay = timelock.getMinDelay();

        vm.startBroadcast(privateKey);
        timelock.scheduleBatch(targets, values, payloads, PREDECESSOR, config.salt, delay);
        vm.stopBroadcast();

        operationId = timelock.hashOperationBatch(targets, values, payloads, PREDECESSOR, config.salt);
        emit LegacyBasketRetirementScheduled(
            operationId, config.diamond, config.timelock, config.basketId, config.assets.length, delay
        );
    }

    function runExecute() external returns (bytes32 operationId) {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        LegacyBasketRetirementConfig memory config = loadConfig(vm.envString("STATICS_LEGACY_RETIREMENT_CONFIG"));
        TimelockController timelock = _timelock(config);
        address operator = vm.addr(privateKey);
        bytes32 executorRole = timelock.EXECUTOR_ROLE();
        if (!timelock.hasRole(executorRole, address(0)) && !timelock.hasRole(executorRole, operator)) {
            revert MissingTimelockRole(executorRole, operator);
        }
        validateReadyToSchedule(config);
        (address[] memory targets, uint256[] memory values, bytes[] memory payloads) = buildBatch(config);
        operationId = timelock.hashOperationBatch(targets, values, payloads, PREDECESSOR, config.salt);
        if (!timelock.isOperationReady(operationId)) revert OperationNotReady(operationId);

        vm.startBroadcast(privateKey);
        timelock.executeBatch(targets, values, payloads, PREDECESSOR, config.salt);
        vm.stopBroadcast();

        validateRetired(config);
        emit LegacyBasketRetirementValidated(
            operationId, config.diamond, config.basketId, IERC20(config.basketToken).totalSupply()
        );
    }

    function validateReadyToQuarantine(LegacyBasketRetirementConfig memory config) public view {
        _validatePreRetirement(config, IStaticsBasket.BasketStatus.Active);
    }

    function validateReadyToSchedule(LegacyBasketRetirementConfig memory config) public view {
        _validatePreRetirement(config, IStaticsBasket.BasketStatus.Quarantined);
    }

    function validateRetired(LegacyBasketRetirementConfig memory config) public view {
        _validateIdentity(config);
        _validateStatus(config, IStaticsBasket.BasketStatus.ExitOnly);
        IStaticsBasketLiquidity liquidity = IStaticsBasketLiquidity(config.diamond);
        IStaticsGlobalRewards rewards = IStaticsGlobalRewards(config.diamond);
        IStaticsLending lending = IStaticsLending(config.diamond);
        IStaticsSwapFeeHook hook = IStaticsSwapFeeHook(config.hook);
        for (uint256 i; i < config.assets.length; ++i) {
            address asset = config.assets[i];
            uint256 principal = lending.outstandingPrincipal(config.basketId, asset);
            if (principal != 0) revert OutstandingPrincipal(config.basketId, asset, principal);
            if (!liquidity.basketLiquidityUnwound(config.basketId, asset)) {
                revert PoolNotRetired(config.basketId, asset);
            }
            PoolId poolId = PoolId.wrap(config.poolIds[i]);
            if (!hook.poolDecommissioned(poolId)) revert PoolNotRetired(config.basketId, asset);
            uint256 locked = hook.lockedLiquidity(poolId);
            if (locked != 0) revert LockedProtocolLiquidityRemaining(config.poolIds[i], locked);
            IStaticsBasketLiquidity.CanonicalPoolView memory pool = liquidity.canonicalPool(config.basketId, asset);
            _validateNoPending(hook, poolId, pool.currency0);
            _validateNoPending(hook, poolId, pool.currency1);
            uint256 accrued = rewards.treasuryAccrued(asset);
            if (accrued != 0) revert TreasuryFeesRemaining(asset, accrued);
        }
    }

    function buildBatch(LegacyBasketRetirementConfig memory config)
        public
        pure
        returns (address[] memory targets, uint256[] memory values, bytes[] memory payloads)
    {
        uint256 poolCount = config.assets.length;
        if (config.diamond == address(0) || poolCount == 0 || poolCount != config.poolIds.length) {
            revert InvalidConfiguration();
        }
        uint256 callCount = 1 + (2 * poolCount);
        targets = new address[](callCount);
        values = new uint256[](callCount);
        payloads = new bytes[](callCount);
        for (uint256 i; i < callCount; ++i) {
            targets[i] = config.diamond;
        }
        payloads[0] = abi.encodeCall(IStaticsGovernance.decommissionBasket, (config.basketId));
        for (uint256 i; i < poolCount; ++i) {
            payloads[1 + i] =
                abi.encodeCall(IStaticsBasketLiquidity.unwindBasketLiquidity, (config.basketId, config.assets[i]));
            payloads[1 + poolCount + i] =
                abi.encodeCall(IStaticsGlobalRewards.distributeTreasuryFees, (config.assets[i]));
        }
    }

    function operationId(LegacyBasketRetirementConfig memory config) public view returns (bytes32) {
        (address[] memory targets, uint256[] memory values, bytes[] memory payloads) = buildBatch(config);
        return _timelock(config).hashOperationBatch(targets, values, payloads, PREDECESSOR, config.salt);
    }

    function loadConfig(string memory path) public view returns (LegacyBasketRetirementConfig memory config) {
        string memory json = vm.readFile(path);
        config.chainId = vm.parseJsonUint(json, ".network.chainId");
        config.diamond = vm.parseJsonAddress(json, ".retirement.diamond");
        config.diamondCodeHash = vm.parseJsonBytes32(json, ".retirement.diamondRuntimeCodeHash");
        config.timelock = vm.parseJsonAddress(json, ".retirement.timelock");
        config.timelockCodeHash = vm.parseJsonBytes32(json, ".retirement.timelockRuntimeCodeHash");
        config.guardian = vm.parseJsonAddress(json, ".retirement.guardian");
        config.treasury = vm.parseJsonAddress(json, ".retirement.treasury");
        config.hook = vm.parseJsonAddress(json, ".retirement.hook");
        config.hookCodeHash = vm.parseJsonBytes32(json, ".retirement.hookRuntimeCodeHash");
        config.governanceFacet = vm.parseJsonAddress(json, ".retirement.governanceFacet");
        config.basketLiquidityFacet = vm.parseJsonAddress(json, ".retirement.basketLiquidityFacet");
        config.globalRewardsFacet = vm.parseJsonAddress(json, ".retirement.globalRewardsFacet");
        config.basketId = vm.parseJsonUint(json, ".retirement.basketId");
        config.basketToken = vm.parseJsonAddress(json, ".retirement.basketToken");
        config.basketTokenCodeHash = vm.parseJsonBytes32(json, ".retirement.basketTokenRuntimeCodeHash");
        config.assets = vm.parseJsonAddressArray(json, ".retirement.assets");
        config.poolIds = abi.decode(vm.parseJson(json, ".retirement.poolIds"), (bytes32[]));
        config.salt = vm.parseJsonBytes32(json, ".retirement.salt");
        if (config.assets.length == 0 || config.assets.length != config.poolIds.length) revert InvalidConfiguration();
    }

    function _validatePreRetirement(
        LegacyBasketRetirementConfig memory config,
        IStaticsBasket.BasketStatus expectedStatus
    ) private view {
        _validateIdentity(config);
        _validateStatus(config, expectedStatus);
        IStaticsBasketLiquidity liquidity = IStaticsBasketLiquidity(config.diamond);
        IStaticsLending lending = IStaticsLending(config.diamond);
        IStaticsSwapFeeHook hook = IStaticsSwapFeeHook(config.hook);
        for (uint256 i; i < config.assets.length; ++i) {
            address asset = config.assets[i];
            uint256 principal = lending.outstandingPrincipal(config.basketId, asset);
            if (principal != 0) revert OutstandingPrincipal(config.basketId, asset, principal);
            PoolId poolId = PoolId.wrap(config.poolIds[i]);
            if (liquidity.basketLiquidityUnwound(config.basketId, asset) || hook.poolDecommissioned(poolId)) {
                revert PoolAlreadyRetired(config.basketId, asset);
            }
            if (hook.lockedLiquidity(poolId) == 0) revert NoLockedProtocolLiquidity(config.basketId, asset);
        }
    }

    function _validateIdentity(LegacyBasketRetirementConfig memory config) private view {
        if (block.chainid != config.chainId) revert InvalidChain(config.chainId, block.chainid);
        _validateContract(config.diamond, config.diamondCodeHash);
        _validateContract(config.timelock, config.timelockCodeHash);
        _validateContract(config.hook, config.hookCodeHash);
        _validateContract(config.basketToken, config.basketTokenCodeHash);
        _validateBinding(config.diamond, config.timelock, IERC173(config.diamond).owner());
        _validateBinding(config.diamond, config.guardian, IStaticsGovernance(config.diamond).guardian());
        _validateBinding(config.diamond, config.treasury, IStaticsBasketAdmin(config.diamond).treasury());
        (address poolManager, address installedHook, bool installed) =
            IStaticsBasketLiquidity(config.diamond).liquidityIntegration();
        if (!installed || poolManager == address(0)) revert InvalidConfiguration();
        _validateBinding(config.diamond, config.hook, installedHook);
        _validateBinding(config.hook, config.diamond, IStaticsSwapFeeHook(config.hook).staticsDiamond());
        _validateFacet(config, IStaticsGovernance.quarantineBasket.selector, config.governanceFacet);
        _validateFacet(config, IStaticsGovernance.decommissionBasket.selector, config.governanceFacet);
        _validateFacet(config, IStaticsBasketLiquidity.unwindBasketLiquidity.selector, config.basketLiquidityFacet);
        _validateFacet(config, IStaticsGlobalRewards.distributeTreasuryFees.selector, config.globalRewardsFacet);

        IStaticsBasket.BasketView memory basket = IStaticsBasket(config.diamond).basket(config.basketId);
        if (basket.token != config.basketToken || basket.assets.length != config.assets.length) {
            revert BasketDefinitionMismatch(config.basketId);
        }
        IStaticsBasketLiquidity liquidity = IStaticsBasketLiquidity(config.diamond);
        for (uint256 i; i < config.assets.length; ++i) {
            address asset = config.assets[i];
            if (basket.assets[i] != asset) revert BasketDefinitionMismatch(config.basketId);
            IStaticsBasketLiquidity.CanonicalPoolView memory pool = liquidity.canonicalPool(config.basketId, asset);
            bytes32 actualPoolId = PoolId.unwrap(pool.poolId);
            if (actualPoolId != config.poolIds[i]) {
                revert PoolBindingMismatch(config.basketId, asset, config.poolIds[i], actualPoolId);
            }
            if (pool.basketToken != config.basketToken || pool.asset != asset || pool.hook != config.hook) {
                revert BasketDefinitionMismatch(config.basketId);
            }
        }
    }

    function _timelock(LegacyBasketRetirementConfig memory config) private view returns (TimelockController timelock) {
        _validateContract(config.timelock, config.timelockCodeHash);
        timelock = TimelockController(payable(config.timelock));
    }

    function _validateStatus(LegacyBasketRetirementConfig memory config, IStaticsBasket.BasketStatus expected)
        private
        view
    {
        IStaticsBasket.BasketStatus actual = IStaticsBasket(config.diamond).basketStatus(config.basketId);
        if (actual != expected) revert InvalidBasketStatus(config.basketId, expected, actual);
    }

    function _validateContract(address target, bytes32 expectedHash) private view {
        if (target.code.length == 0) revert InvalidContract(target);
        bytes32 actualHash = target.codehash;
        if (actualHash != expectedHash) revert InvalidCodeHash(target, expectedHash, actualHash);
    }

    function _validateBinding(address target, address expected, address actual) private pure {
        if (expected != actual) revert InvalidBinding(target, expected, actual);
    }

    function _validateFacet(LegacyBasketRetirementConfig memory config, bytes4 selector, address expected)
        private
        view
    {
        address actual = IDiamondLoupe(config.diamond).facetAddress(selector);
        if (actual != expected) revert InvalidFacet(selector, expected, actual);
    }

    function _validateNoPending(IStaticsSwapFeeHook hook, PoolId poolId, address currency) private view {
        uint256 pending = hook.pendingPermanentLiquidity(poolId, Currency.wrap(currency));
        if (pending != 0) revert PendingProtocolLiquidityRemaining(PoolId.unwrap(poolId), currency, pending);
    }
}
