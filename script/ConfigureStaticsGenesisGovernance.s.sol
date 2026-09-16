// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {Script} from "forge-std/Script.sol";

import {RobinhoodDeploymentConfig} from "./RobinhoodDeploymentConfig.sol";

interface IGenesisOwnable2Step {
    function owner() external view returns (address);
    function pendingOwner() external view returns (address);
    function transferOwnership(address newOwner) external;
    function acceptOwnership() external;
}

struct GenesisGovernanceMigrationConfig {
    address governanceSafe;
    address timelock;
    address[5] targets;
    bytes32[5] runtimeCodeHashes;
}

/// @notice Builds and verifies the Safe/timelock ceremony that moves the five mutable
/// Genesis launch contracts from the launch Safe to the Phase 1 timelock.
/// @dev `run` is read-only and never broadcasts or signs a Safe transaction.
contract ConfigureStaticsGenesisGovernance is Script, RobinhoodDeploymentConfig {
    uint256 private constant TARGET_COUNT = 5;

    error InvalidChain(uint256 expected, uint256 actual);
    error InvalidGovernanceSafe(address governanceSafe);
    error InvalidTimelock(address timelock);
    error InvalidTarget(address target);
    error DuplicateTarget(address target);
    error InvalidCodeHash(address target, bytes32 expected, bytes32 actual);
    error InvalidOwner(address target, address expected, address actual);
    error InvalidPendingOwner(address target, address expected, address actual);
    error TimelockNotConfigured(address timelock, address proposer);

    function run()
        external
        view
        returns (address[] memory targets, uint256[] memory values, bytes[] memory payloads, bytes32 operationId)
    {
        GenesisGovernanceMigrationConfig memory config = _loadRobinhoodConfig();
        bytes32 salt = vm.envBytes32("GENESIS_MIGRATION_TIMELOCK_SALT");
        return buildSafeProposal(config, salt);
    }

    function runExecute() external {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        GenesisGovernanceMigrationConfig memory config = _loadRobinhoodConfig();
        bytes32 salt = vm.envBytes32("GENESIS_MIGRATION_TIMELOCK_SALT");

        vm.startBroadcast(privateKey);
        executeAcceptance(config, salt);
        vm.stopBroadcast();
    }

    /// @notice Returns the six calls that must be submitted atomically through the governance Safe:
    /// five ownership transfers followed by scheduling their timelocked acceptances.
    function buildSafeProposal(GenesisGovernanceMigrationConfig memory config, bytes32 salt)
        public
        view
        returns (address[] memory targets, uint256[] memory values, bytes[] memory payloads, bytes32 operationId)
    {
        TimelockController timelock = _validateConfig(config);
        _validateOwnership(config, config.governanceSafe, address(0));
        (address[] memory acceptanceTargets, uint256[] memory acceptanceValues, bytes[] memory acceptancePayloads) =
            buildAcceptanceBatch(config);
        uint256 delay = timelock.getMinDelay();

        targets = new address[](TARGET_COUNT + 1);
        values = new uint256[](TARGET_COUNT + 1);
        payloads = new bytes[](TARGET_COUNT + 1);
        for (uint256 i; i < TARGET_COUNT; ++i) {
            targets[i] = config.targets[i];
            payloads[i] = abi.encodeCall(IGenesisOwnable2Step.transferOwnership, (config.timelock));
        }
        targets[TARGET_COUNT] = config.timelock;
        payloads[TARGET_COUNT] = abi.encodeCall(
            TimelockController.scheduleBatch,
            (acceptanceTargets, acceptanceValues, acceptancePayloads, bytes32(0), salt, delay)
        );
        operationId =
            timelock.hashOperationBatch(acceptanceTargets, acceptanceValues, acceptancePayloads, bytes32(0), salt);
    }

    function buildAcceptanceBatch(GenesisGovernanceMigrationConfig memory config)
        public
        pure
        returns (address[] memory targets, uint256[] memory values, bytes[] memory payloads)
    {
        targets = new address[](TARGET_COUNT);
        values = new uint256[](TARGET_COUNT);
        payloads = new bytes[](TARGET_COUNT);
        for (uint256 i; i < TARGET_COUNT; ++i) {
            targets[i] = config.targets[i];
            payloads[i] = abi.encodeCall(IGenesisOwnable2Step.acceptOwnership, ());
        }
    }

    function executeAcceptance(GenesisGovernanceMigrationConfig memory config, bytes32 salt) public {
        TimelockController timelock = _validateConfig(config);
        _validateOwnership(config, config.governanceSafe, config.timelock);
        (address[] memory targets, uint256[] memory values, bytes[] memory payloads) = buildAcceptanceBatch(config);
        timelock.executeBatch(targets, values, payloads, bytes32(0), salt);
        _validateOwnership(config, config.timelock, address(0));
    }

    function _validateConfig(GenesisGovernanceMigrationConfig memory config)
        private
        view
        returns (TimelockController timelock)
    {
        if (config.governanceSafe == address(0) || config.governanceSafe.code.length == 0) {
            revert InvalidGovernanceSafe(config.governanceSafe);
        }
        if (config.timelock == address(0) || config.timelock.code.length == 0) {
            revert InvalidTimelock(config.timelock);
        }
        timelock = TimelockController(payable(config.timelock));
        if (
            timelock.getMinDelay() == 0 || !timelock.hasRole(timelock.PROPOSER_ROLE(), config.governanceSafe)
                || !timelock.hasRole(timelock.EXECUTOR_ROLE(), address(0))
        ) revert TimelockNotConfigured(config.timelock, config.governanceSafe);

        for (uint256 i; i < TARGET_COUNT; ++i) {
            address target = config.targets[i];
            if (
                target == address(0) || target == config.governanceSafe || target == config.timelock
                    || target.code.length == 0
            ) revert InvalidTarget(target);
            for (uint256 j; j < i; ++j) {
                if (config.targets[j] == target) revert DuplicateTarget(target);
            }
            bytes32 expectedHash = config.runtimeCodeHashes[i];
            bytes32 actualHash = target.codehash;
            if (expectedHash == bytes32(0) || actualHash != expectedHash) {
                revert InvalidCodeHash(target, expectedHash, actualHash);
            }
        }
    }

    function _validateOwnership(
        GenesisGovernanceMigrationConfig memory config,
        address expectedOwner,
        address expectedPendingOwner
    ) private view {
        for (uint256 i; i < TARGET_COUNT; ++i) {
            IGenesisOwnable2Step target = IGenesisOwnable2Step(config.targets[i]);
            address actualOwner = target.owner();
            if (actualOwner != expectedOwner) {
                revert InvalidOwner(config.targets[i], expectedOwner, actualOwner);
            }
            address actualPendingOwner = target.pendingOwner();
            if (actualPendingOwner != expectedPendingOwner) {
                revert InvalidPendingOwner(config.targets[i], expectedPendingOwner, actualPendingOwner);
            }
        }
    }

    function _loadRobinhoodConfig() private view returns (GenesisGovernanceMigrationConfig memory config) {
        string memory manifest = vm.readFile("deployments/robinhood-mainnet-genesis.json");
        uint256 expectedChainId = vm.parseJsonUint(manifest, ".network.chainId");
        if (block.chainid != expectedChainId) revert InvalidChain(expectedChainId, block.chainid);

        config.governanceSafe = vm.parseJsonAddress(manifest, ".roles.governance");
        config.timelock = vm.envAddress("STATICS_TIMELOCK_ADDRESS");
        config.targets[0] = vm.parseJsonAddress(manifest, ".contracts.feeReceiver.address");
        config.targets[1] = vm.parseJsonAddress(manifest, ".contracts.activationRegistry.address");
        config.targets[2] = vm.parseJsonAddress(manifest, ".contracts.genesisVault.address");
        config.targets[3] = vm.parseJsonAddress(manifest, ".contracts.operatorsNft.address");
        config.targets[4] = vm.parseJsonAddress(manifest, ".contracts.launchDistributor.address");
        config.runtimeCodeHashes[0] = vm.parseJsonBytes32(manifest, ".contracts.feeReceiver.runtimeCodeHash");
        config.runtimeCodeHashes[1] = vm.parseJsonBytes32(manifest, ".contracts.activationRegistry.runtimeCodeHash");
        config.runtimeCodeHashes[2] = vm.parseJsonBytes32(manifest, ".contracts.genesisVault.runtimeCodeHash");
        config.runtimeCodeHashes[3] = vm.parseJsonBytes32(manifest, ".contracts.operatorsNft.runtimeCodeHash");
        config.runtimeCodeHashes[4] = vm.parseJsonBytes32(manifest, ".contracts.launchDistributor.runtimeCodeHash");
    }
}
