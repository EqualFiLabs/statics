// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {Script} from "forge-std/Script.sol";

import {IERC173} from "../src/interfaces/IERC173.sol";
import {IStaticsBasket} from "../src/interfaces/IStaticsBasket.sol";
import {IStaticsBasketLiquidity} from "../src/interfaces/IStaticsBasketLiquidity.sol";

struct GenesisBasketActivationConfig {
    uint256 basketId;
    address[] assets;
}

/// @notice Checkpoint and activate every canonical pool belonging to the genesis basket.
contract ActivateGenesisBasket is Script {
    error InvalidDiamond(address diamond);
    error InvalidTimelock(address timelock);
    error InvalidActivationConfiguration();
    error BasketDefinitionMismatch(uint256 basketId);
    error PoolNotWarming(uint256 basketId, address asset, IStaticsBasketLiquidity.CanonicalPoolStatus status);
    error PoolStillWarming(uint256 basketId, address asset, uint256 readyAt);
    error OracleHistoryUnavailable(uint256 basketId, address asset, uint256 observationCardinality);
    error PoolNotActive(uint256 basketId, address asset);

    event GenesisPoolCheckpointed(
        uint256 indexed basketId, address indexed asset, bool observationStored, uint256 observationCardinality
    );
    event GenesisActivationBatchPrepared(
        bytes32 indexed operationId,
        address indexed diamond,
        address indexed timelock,
        uint256 basketId,
        uint256 poolCount,
        uint256 delay
    );
    event GenesisBasketActivationValidated(uint256 indexed basketId, uint256 poolCount);

    function runCheckpoint() external {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address diamond = vm.envAddress("STATICS_DIAMOND_ADDRESS");
        GenesisBasketActivationConfig memory config = loadConfig(vm.envString("STATICS_GENESIS_BASKET_CONFIG"));

        vm.startBroadcast(privateKey);
        checkpoint(diamond, config);
        vm.stopBroadcast();
    }

    function runSchedule() external returns (bytes32 operationId) {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address diamond = vm.envAddress("STATICS_DIAMOND_ADDRESS");
        bytes32 salt = vm.envBytes32("STATICS_GENESIS_ACTIVATION_SALT");
        GenesisBasketActivationConfig memory config = loadConfig(vm.envString("STATICS_GENESIS_BASKET_CONFIG"));

        vm.startBroadcast(privateKey);
        operationId = schedule(diamond, config, salt);
        vm.stopBroadcast();
    }

    function runExecute() external {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address diamond = vm.envAddress("STATICS_DIAMOND_ADDRESS");
        bytes32 salt = vm.envBytes32("STATICS_GENESIS_ACTIVATION_SALT");
        GenesisBasketActivationConfig memory config = loadConfig(vm.envString("STATICS_GENESIS_BASKET_CONFIG"));

        vm.startBroadcast(privateKey);
        execute(diamond, config, salt);
        vm.stopBroadcast();
    }

    function checkpoint(address diamond, GenesisBasketActivationConfig memory config) public {
        _validateWarming(diamond, config, false);
        IStaticsBasketLiquidity liquidity = IStaticsBasketLiquidity(diamond);
        for (uint256 i; i < config.assets.length; ++i) {
            address asset = config.assets[i];
            bool observationStored = liquidity.checkpointCanonicalPool(config.basketId, asset);
            IStaticsBasketLiquidity.CanonicalPoolView memory pool = liquidity.canonicalPool(config.basketId, asset);
            emit GenesisPoolCheckpointed(config.basketId, asset, observationStored, pool.observationCardinality);
        }
        _validateWarming(diamond, config, true);
    }

    function schedule(address diamond, GenesisBasketActivationConfig memory config, bytes32 salt)
        public
        returns (bytes32 operationId)
    {
        TimelockController timelock = _validateWarming(diamond, config, true);
        (address[] memory targets, uint256[] memory values, bytes[] memory payloads) = buildBatch(diamond, config);
        uint256 delay = timelock.getMinDelay();
        timelock.scheduleBatch(targets, values, payloads, bytes32(0), salt, delay);
        operationId = timelock.hashOperationBatch(targets, values, payloads, bytes32(0), salt);
        emit GenesisActivationBatchPrepared(
            operationId, diamond, address(timelock), config.basketId, config.assets.length, delay
        );
    }

    function execute(address diamond, GenesisBasketActivationConfig memory config, bytes32 salt) public {
        TimelockController timelock = _validateWarming(diamond, config, true);
        (address[] memory targets, uint256[] memory values, bytes[] memory payloads) = buildBatch(diamond, config);
        timelock.executeBatch(targets, values, payloads, bytes32(0), salt);
        validate(diamond, config);
    }

    function validate(address diamond, GenesisBasketActivationConfig memory config) public {
        _validateDefinition(diamond, config);
        IStaticsBasketLiquidity liquidity = IStaticsBasketLiquidity(diamond);
        for (uint256 i; i < config.assets.length; ++i) {
            address asset = config.assets[i];
            IStaticsBasketLiquidity.CanonicalPoolView memory pool = liquidity.canonicalPool(config.basketId, asset);
            if (pool.status != IStaticsBasketLiquidity.CanonicalPoolStatus.Active || pool.activatedAt == 0) {
                revert PoolNotActive(config.basketId, asset);
            }
        }
        emit GenesisBasketActivationValidated(config.basketId, config.assets.length);
    }

    function buildBatch(address diamond, GenesisBasketActivationConfig memory config)
        public
        pure
        returns (address[] memory targets, uint256[] memory values, bytes[] memory payloads)
    {
        if (diamond == address(0) || config.assets.length == 0) {
            revert InvalidActivationConfiguration();
        }
        uint256 poolCount = config.assets.length;
        targets = new address[](poolCount);
        values = new uint256[](poolCount);
        payloads = new bytes[](poolCount);
        for (uint256 i; i < poolCount; ++i) {
            targets[i] = diamond;
            payloads[i] =
                abi.encodeCall(IStaticsBasketLiquidity.activateCanonicalPool, (config.basketId, config.assets[i]));
        }
    }

    function loadConfig(string memory path) public view returns (GenesisBasketActivationConfig memory config) {
        string memory json = vm.readFile(path);
        config.basketId = vm.parseJsonUint(json, ".expectedBasketId");
        config.assets = vm.parseJsonAddressArray(json, ".assets");
        if (config.assets.length == 0) revert InvalidActivationConfiguration();
    }

    function _validateWarming(address diamond, GenesisBasketActivationConfig memory config, bool requireOracle)
        private
        view
        returns (TimelockController timelock)
    {
        timelock = _validateDefinition(diamond, config);
        IStaticsBasketLiquidity liquidity = IStaticsBasketLiquidity(diamond);
        (,, uint40 warmup,,) = liquidity.liquiditySafetyParameters();
        for (uint256 i; i < config.assets.length; ++i) {
            address asset = config.assets[i];
            IStaticsBasketLiquidity.CanonicalPoolView memory pool = liquidity.canonicalPool(config.basketId, asset);
            if (pool.status != IStaticsBasketLiquidity.CanonicalPoolStatus.Warming) {
                revert PoolNotWarming(config.basketId, asset, pool.status);
            }
            uint256 readyAt = uint256(pool.initializedAt) + warmup;
            if (block.timestamp < readyAt) revert PoolStillWarming(config.basketId, asset, readyAt);
            if (requireOracle && (pool.observationCardinality < 2 || !pool.referenceAvailable)) {
                revert OracleHistoryUnavailable(config.basketId, asset, pool.observationCardinality);
            }
        }
    }

    function _validateDefinition(address diamond, GenesisBasketActivationConfig memory config)
        private
        view
        returns (TimelockController timelock)
    {
        if (diamond.code.length == 0) revert InvalidDiamond(diamond);
        if (config.assets.length == 0) revert InvalidActivationConfiguration();

        address owner = IERC173(diamond).owner();
        if (owner.code.length == 0) revert InvalidTimelock(owner);
        timelock = TimelockController(payable(owner));

        IStaticsBasket.BasketView memory basket = IStaticsBasket(diamond).basket(config.basketId);
        if (basket.assets.length != config.assets.length) {
            revert BasketDefinitionMismatch(config.basketId);
        }
        for (uint256 i; i < config.assets.length; ++i) {
            if (basket.assets[i] != config.assets[i]) {
                revert BasketDefinitionMismatch(config.basketId);
            }
        }
    }
}
