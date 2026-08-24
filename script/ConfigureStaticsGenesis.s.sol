// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {Script} from "forge-std/Script.sol";

import {StaticsGenesisIntegrationInit} from "../src/diamond/StaticsGenesisIntegrationInit.sol";
import {IGenesisActivationRegistry} from "../src/interfaces/IGenesisActivationRegistry.sol";
import {IDiamondCut} from "../src/interfaces/IDiamondCut.sol";
import {IDiamondLoupe} from "../src/interfaces/IDiamondLoupe.sol";
import {IERC173} from "../src/interfaces/IERC173.sol";
import {IGenesisLaunchDistributor} from "../src/interfaces/IGenesisLaunchDistributor.sol";
import {IStaticsBasketAdmin} from "../src/interfaces/IStaticsBasketAdmin.sol";
import {IStaticsFeeReceiver} from "../src/interfaces/IStaticsFeeReceiver.sol";
import {IStaticsGenesis} from "../src/interfaces/IStaticsGenesis.sol";
import {IStaticsGenesisIntegration} from "../src/interfaces/IStaticsGenesisIntegration.sol";
import {IStaticsGlobalRewards} from "../src/interfaces/IStaticsGlobalRewards.sol";
import {LibGenesisIntegration} from "../src/libraries/LibGenesisIntegration.sol";
import {StaticsGenesisUpgradeCut, StaticsGenesisUpgradeParts} from "./PrepareStaticsGenesisUpgrade.s.sol";

interface IGenesisVaultHandoff {
    function statics() external view returns (address);
    function feeReceiver() external view returns (address);
    function treasury() external view returns (address);
}

interface IGenesisLaunchHandoff {
    function genesisRewardShareBps() external view returns (uint16);
    function finalized() external view returns (bool);
}

struct StaticsGenesisHandoffConfig {
    address initializer;
    address genesis;
    address vault;
    address activationRegistry;
    address feeReceiver;
    address launchDistributor;
    address statics;
    address numeraire;
    uint16 genesisRewardShareBps;
    bool installUpgrade;
    StaticsGenesisUpgradeParts upgrade;
}

/// @notice One governed batch that binds separately launched Genesis infrastructure to the Diamond.
contract ConfigureStaticsGenesis is Script {
    error InvalidDiamond(address diamond);
    error InvalidTimelock(address timelock);
    error InvalidContract(address target);
    error InvalidOwner(address target, address expected, address actual);
    error InvalidBinding(address target, address expected, address actual);
    error InvalidRewardShare(uint256 expected, uint256 actual);
    error InvalidHandoffState();
    error GenesisHandoffFailed();

    event StaticsGenesisHandoffPrepared(
        bytes32 indexed operationId,
        address indexed diamond,
        address indexed timelock,
        address genesis,
        address launchDistributor,
        uint256 delay
    );

    function runDeployInitializer() external returns (address initializer) {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(privateKey);
        initializer = address(new StaticsGenesisIntegrationInit());
        vm.stopBroadcast();
    }

    function runSchedule() external returns (bytes32 operationId) {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address diamond = vm.envAddress("STATICS_DIAMOND_ADDRESS");
        bytes32 salt = vm.envBytes32("STATICS_GENESIS_HANDOFF_TIMELOCK_SALT");
        StaticsGenesisHandoffConfig memory config = _loadConfig();
        vm.startBroadcast(privateKey);
        operationId = schedule(diamond, config, salt);
        vm.stopBroadcast();
    }

    function runScheduleInitialization() external returns (bytes32 operationId) {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address diamond = vm.envAddress("STATICS_DIAMOND_ADDRESS");
        bytes32 salt = vm.envBytes32("STATICS_GENESIS_HANDOFF_TIMELOCK_SALT");
        StaticsGenesisHandoffConfig memory config = _loadConfig();
        vm.startBroadcast(privateKey);
        operationId = scheduleInitialization(diamond, config, salt);
        vm.stopBroadcast();
    }

    function runExecute() external {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address diamond = vm.envAddress("STATICS_DIAMOND_ADDRESS");
        bytes32 salt = vm.envBytes32("STATICS_GENESIS_HANDOFF_TIMELOCK_SALT");
        StaticsGenesisHandoffConfig memory config = _loadConfig();
        vm.startBroadcast(privateKey);
        execute(diamond, config, salt);
        vm.stopBroadcast();
    }

    function runExecuteInitialization() external {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address diamond = vm.envAddress("STATICS_DIAMOND_ADDRESS");
        bytes32 salt = vm.envBytes32("STATICS_GENESIS_HANDOFF_TIMELOCK_SALT");
        StaticsGenesisHandoffConfig memory config = _loadConfig();
        vm.startBroadcast(privateKey);
        executeInitialization(diamond, config, salt);
        vm.stopBroadcast();
    }

    function schedule(address diamond, StaticsGenesisHandoffConfig memory config, bytes32 salt)
        public
        returns (bytes32 operationId)
    {
        TimelockController timelock = _validateBefore(diamond, config, true);
        (address[] memory targets, uint256[] memory values, bytes[] memory payloads) = buildBatch(diamond, config);
        uint256 delay = timelock.getMinDelay();
        timelock.scheduleBatch(targets, values, payloads, bytes32(0), salt, delay);
        operationId = timelock.hashOperationBatch(targets, values, payloads, bytes32(0), salt);
        emit StaticsGenesisHandoffPrepared(
            operationId, diamond, address(timelock), config.genesis, config.launchDistributor, delay
        );
    }

    function execute(address diamond, StaticsGenesisHandoffConfig memory config, bytes32 salt) public {
        TimelockController timelock = _validateBefore(diamond, config, true);
        (address[] memory targets, uint256[] memory values, bytes[] memory payloads) = buildBatch(diamond, config);
        timelock.executeBatch(targets, values, payloads, bytes32(0), salt);
        _validateAfter(diamond, config);
    }

    function scheduleInitialization(address diamond, StaticsGenesisHandoffConfig memory config, bytes32 salt)
        public
        returns (bytes32 operationId)
    {
        TimelockController timelock = _validateBefore(diamond, config, false);
        (address[] memory targets, uint256[] memory values, bytes[] memory payloads) =
            buildInitializationBatch(diamond, config);
        uint256 delay = timelock.getMinDelay();
        timelock.scheduleBatch(targets, values, payloads, bytes32(0), salt, delay);
        operationId = timelock.hashOperationBatch(targets, values, payloads, bytes32(0), salt);
        emit StaticsGenesisHandoffPrepared(
            operationId, diamond, address(timelock), config.genesis, config.launchDistributor, delay
        );
    }

    function executeInitialization(address diamond, StaticsGenesisHandoffConfig memory config, bytes32 salt) public {
        TimelockController timelock = _validateBefore(diamond, config, false);
        (address[] memory targets, uint256[] memory values, bytes[] memory payloads) =
            buildInitializationBatch(diamond, config);
        timelock.executeBatch(targets, values, payloads, bytes32(0), salt);
        IStaticsGenesisIntegration integration = IStaticsGenesisIntegration(diamond);
        if (integration.genesisCollection() != config.genesis || integration.genesisRecoveryReady()) {
            revert GenesisHandoffFailed();
        }
    }

    function buildBatch(address diamond, StaticsGenesisHandoffConfig memory config)
        public
        pure
        returns (address[] memory targets, uint256[] memory values, bytes[] memory payloads)
    {
        targets = new address[](7);
        values = new uint256[](7);
        payloads = new bytes[](7);

        LibGenesisIntegration.InitArgs memory args = LibGenesisIntegration.InitArgs({
            genesis: config.genesis,
            vault: config.vault,
            activationRegistry: config.activationRegistry,
            feeReceiver: config.feeReceiver,
            statics: config.statics,
            numeraire: config.numeraire,
            genesisRewardShareBps: config.genesisRewardShareBps
        });
        IDiamondCut.FacetCut[] memory cut =
            config.installUpgrade ? StaticsGenesisUpgradeCut.build(config.upgrade) : new IDiamondCut.FacetCut[](0);
        targets[0] = diamond;
        payloads[0] = abi.encodeCall(
            IDiamondCut.diamondCut,
            (cut, config.initializer, abi.encodeCall(StaticsGenesisIntegrationInit.initialize, (args)))
        );
        targets[1] = config.feeReceiver;
        payloads[1] = abi.encodeCall(IStaticsFeeReceiver.proposeDistributor, (diamond));
        targets[2] = diamond;
        payloads[2] = abi.encodeCall(IStaticsGenesisIntegration.acceptGenesisDistributorRole, ());
        targets[3] = config.launchDistributor;
        payloads[3] = abi.encodeCall(IGenesisLaunchDistributor.finalizeLaunchRewards, ());
        targets[4] = config.activationRegistry;
        payloads[4] = abi.encodeCall(IGenesisActivationRegistry.proposeConsumer, (diamond));
        targets[5] = diamond;
        payloads[5] = abi.encodeCall(IStaticsGenesisIntegration.acceptGenesisConsumerRole, ());
        targets[6] = config.genesis;
        payloads[6] = abi.encodeCall(IStaticsGenesis.bindProtocol, (diamond));
    }

    function buildInitializationBatch(address diamond, StaticsGenesisHandoffConfig memory config)
        public
        pure
        returns (address[] memory targets, uint256[] memory values, bytes[] memory payloads)
    {
        (address[] memory unifiedTargets, uint256[] memory unifiedValues, bytes[] memory unifiedPayloads) =
            buildBatch(diamond, config);
        targets = new address[](1);
        values = new uint256[](1);
        payloads = new bytes[](1);
        targets[0] = unifiedTargets[0];
        values[0] = unifiedValues[0];
        payloads[0] = unifiedPayloads[0];
    }

    /// @notice First Genesis-governance call after Diamond initialization.
    function buildGenesisDistributorProposal(address diamond, StaticsGenesisHandoffConfig memory config)
        public
        pure
        returns (address[] memory targets, uint256[] memory values, bytes[] memory payloads)
    {
        targets = new address[](1);
        values = new uint256[](1);
        payloads = new bytes[](1);
        targets[0] = config.feeReceiver;
        payloads[0] = abi.encodeCall(IStaticsFeeReceiver.proposeDistributor, (diamond));
    }

    /// @notice Statics-governance call after Genesis governance proposes the Diamond.
    function buildStaticsDistributorAcceptance(address diamond)
        public
        pure
        returns (address[] memory targets, uint256[] memory values, bytes[] memory payloads)
    {
        targets = new address[](1);
        values = new uint256[](1);
        payloads = new bytes[](1);
        targets[0] = diamond;
        payloads[0] = abi.encodeCall(IStaticsGenesisIntegration.acceptGenesisDistributorRole, ());
    }

    /// @notice Genesis-governance calls after the Diamond becomes the active fee distributor.
    function buildGenesisConsumerProposal(address diamond, StaticsGenesisHandoffConfig memory config)
        public
        pure
        returns (address[] memory targets, uint256[] memory values, bytes[] memory payloads)
    {
        targets = new address[](2);
        values = new uint256[](2);
        payloads = new bytes[](2);
        targets[0] = config.launchDistributor;
        payloads[0] = abi.encodeCall(IGenesisLaunchDistributor.finalizeLaunchRewards, ());
        targets[1] = config.activationRegistry;
        payloads[1] = abi.encodeCall(IGenesisActivationRegistry.proposeConsumer, (diamond));
    }

    /// @notice Statics-governance call after Genesis governance proposes the Diamond as consumer.
    function buildStaticsConsumerAcceptance(address diamond)
        public
        pure
        returns (address[] memory targets, uint256[] memory values, bytes[] memory payloads)
    {
        targets = new address[](1);
        values = new uint256[](1);
        payloads = new bytes[](1);
        targets[0] = diamond;
        payloads[0] = abi.encodeCall(IStaticsGenesisIntegration.acceptGenesisConsumerRole, ());
    }

    /// @notice Final Genesis-governance call after both Diamond roles are active.
    function buildGenesisProtocolBinding(address diamond, StaticsGenesisHandoffConfig memory config)
        public
        pure
        returns (address[] memory targets, uint256[] memory values, bytes[] memory payloads)
    {
        targets = new address[](1);
        values = new uint256[](1);
        payloads = new bytes[](1);
        targets[0] = config.genesis;
        payloads[0] = abi.encodeCall(IStaticsGenesis.bindProtocol, (diamond));
    }

    function _validateBefore(address diamond, StaticsGenesisHandoffConfig memory config, bool requireUnifiedGovernance)
        private
        view
        returns (TimelockController timelock)
    {
        if (diamond.code.length == 0) revert InvalidDiamond(diamond);
        address owner = IERC173(diamond).owner();
        if (owner.code.length == 0) revert InvalidTimelock(owner);
        timelock = TimelockController(payable(owner));

        _contract(config.initializer);
        _contract(config.genesis);
        _contract(config.vault);
        _contract(config.activationRegistry);
        _contract(config.feeReceiver);
        _contract(config.launchDistributor);
        _contract(config.statics);
        _contract(config.numeraire);
        address genesisGovernance = IERC173(config.genesis).owner();
        _owner(config.vault, genesisGovernance);
        _owner(config.activationRegistry, genesisGovernance);
        _owner(config.feeReceiver, genesisGovernance);
        _owner(config.launchDistributor, genesisGovernance);
        if (requireUnifiedGovernance && genesisGovernance != owner) {
            revert InvalidOwner(config.genesis, owner, genesisGovernance);
        }

        bool genesisInstalled =
            IDiamondLoupe(diamond).facetAddress(IStaticsGenesisIntegration.registerGenesis.selector) != address(0);
        if (config.installUpgrade) {
            if (genesisInstalled) revert InvalidHandoffState();
            _contract(config.upgrade.globalRewards);
            _contract(config.upgrade.positionNFT);
            _contract(config.upgrade.custody);
            _contract(config.upgrade.genesisNFT);
        } else if (!genesisInstalled) {
            revert InvalidHandoffState();
        }
        if (genesisInstalled && IStaticsGenesisIntegration(diamond).genesisCollection() != address(0)) {
            revert InvalidHandoffState();
        }
        if (IStaticsGenesis(config.genesis).protocol() != address(0)) revert InvalidHandoffState();
        _binding(config.genesis, config.vault, IStaticsGenesis(config.genesis).vault());
        _binding(config.genesis, config.activationRegistry, IStaticsGenesis(config.genesis).activationRegistry());
        IGenesisVaultHandoff vault = IGenesisVaultHandoff(config.vault);
        _binding(config.vault, config.statics, vault.statics());
        _binding(config.vault, config.feeReceiver, vault.feeReceiver());
        address treasury = IStaticsBasketAdmin(diamond).treasury();
        _binding(config.vault, treasury, vault.treasury());
        IStaticsFeeReceiver receiver = IStaticsFeeReceiver(config.feeReceiver);
        _binding(config.feeReceiver, config.statics, receiver.statics());
        _binding(config.feeReceiver, config.numeraire, receiver.numeraire());
        _binding(config.feeReceiver, config.vault, receiver.reserveVault());
        _binding(config.feeReceiver, config.launchDistributor, receiver.activeDistributor());
        IGenesisActivationRegistry registry = IGenesisActivationRegistry(config.activationRegistry);
        _binding(config.activationRegistry, config.genesis, registry.genesisCollection());
        _binding(config.activationRegistry, treasury, registry.treasury());
        _binding(config.activationRegistry, config.launchDistributor, registry.activeConsumer());
        _binding(diamond, config.statics, IStaticsGlobalRewards(diamond).stakingToken());
        uint16 launchShare = IGenesisLaunchHandoff(config.launchDistributor).genesisRewardShareBps();
        if (launchShare != config.genesisRewardShareBps) {
            revert InvalidRewardShare(config.genesisRewardShareBps, launchShare);
        }
        if (IGenesisLaunchHandoff(config.launchDistributor).finalized()) revert InvalidHandoffState();
    }

    function _validateAfter(address diamond, StaticsGenesisHandoffConfig memory config) private view {
        if (IStaticsFeeReceiver(config.feeReceiver).activeDistributor() != diamond) revert GenesisHandoffFailed();
        if (IGenesisActivationRegistry(config.activationRegistry).activeConsumer() != diamond) {
            revert GenesisHandoffFailed();
        }
        if (IStaticsGenesis(config.genesis).protocol() != diamond) revert GenesisHandoffFailed();
        if (!IGenesisLaunchHandoff(config.launchDistributor).finalized()) revert GenesisHandoffFailed();
        IStaticsGenesisIntegration integration = IStaticsGenesisIntegration(diamond);
        if (!integration.genesisRecoveryReady() || !integration.genesisIntegrationReady()) {
            revert GenesisHandoffFailed();
        }
        if (integration.genesisCollection() != config.genesis) revert GenesisHandoffFailed();
        if (integration.genesisRewardShareBps() != config.genesisRewardShareBps) revert GenesisHandoffFailed();
    }

    function _contract(address target) private view {
        if (target == address(0) || target.code.length == 0) revert InvalidContract(target);
    }

    function _owner(address target, address expected) private view {
        address actual = IERC173(target).owner();
        if (actual != expected) revert InvalidOwner(target, expected, actual);
    }

    function _binding(address target, address expected, address actual) private pure {
        if (expected != actual) revert InvalidBinding(target, expected, actual);
    }

    function _loadConfig() private view returns (StaticsGenesisHandoffConfig memory config) {
        uint256 share = vm.envUint("STATICS_GENESIS_REWARD_SHARE_BPS");
        if (share > type(uint16).max) revert InvalidRewardShare(type(uint16).max, share);
        config = StaticsGenesisHandoffConfig({
            initializer: vm.envAddress("STATICS_GENESIS_INTEGRATION_INIT_ADDRESS"),
            genesis: vm.envAddress("STATICS_GENESIS_NFT_ADDRESS"),
            vault: vm.envAddress("STATICS_GENESIS_VAULT_ADDRESS"),
            activationRegistry: vm.envAddress("STATICS_GENESIS_ACTIVATION_REGISTRY_ADDRESS"),
            feeReceiver: vm.envAddress("STATICS_GENESIS_FEE_RECEIVER_ADDRESS"),
            launchDistributor: vm.envAddress("STATICS_GENESIS_DISTRIBUTOR_ADDRESS"),
            statics: vm.envAddress("STAKING_TOKEN"),
            numeraire: vm.envAddress("WETH_ADDRESS"),
            genesisRewardShareBps: uint16(share),
            installUpgrade: vm.envOr("STATICS_GENESIS_INSTALL_UPGRADE", false),
            upgrade: StaticsGenesisUpgradeParts({
                globalRewards: vm.envOr("STATICS_GLOBAL_REWARDS_FACET_ADDRESS", address(0)),
                positionNFT: vm.envOr("STATICS_POSITION_NFT_FACET_ADDRESS", address(0)),
                custody: vm.envOr("STATICS_CUSTODY_FACET_ADDRESS", address(0)),
                genesisNFT: vm.envOr("STATICS_GENESIS_NFT_FACET_ADDRESS", address(0))
            })
        });
    }
}
