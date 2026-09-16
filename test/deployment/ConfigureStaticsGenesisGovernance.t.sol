// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Test} from "forge-std/Test.sol";

import {
    ConfigureStaticsGenesisGovernance,
    GenesisGovernanceMigrationConfig,
    IGenesisOwnable2Step
} from "../../script/ConfigureStaticsGenesisGovernance.s.sol";
import {StaticsTimelock} from "../../src/governance/StaticsTimelock.sol";

contract GenesisGovernanceSafeMock {
    error CallFailed(address target, bytes reason);

    function executeBatch(address[] memory targets, uint256[] memory values, bytes[] memory payloads) external payable {
        for (uint256 i; i < targets.length; ++i) {
            (bool success, bytes memory reason) = targets[i].call{value: values[i]}(payloads[i]);
            if (!success) revert CallFailed(targets[i], reason);
        }
    }
}

contract GenesisOwnable2StepMock is Ownable2Step {
    constructor(address initialOwner) Ownable(initialOwner) {}
}

contract ConfigureStaticsGenesisGovernanceTest is Test {
    ConfigureStaticsGenesisGovernance private migration;
    GenesisGovernanceSafeMock private governanceSafe;
    StaticsTimelock private timelock;
    GenesisGovernanceMigrationConfig private config;

    function setUp() public {
        migration = new ConfigureStaticsGenesisGovernance();
        governanceSafe = new GenesisGovernanceSafeMock();
        address[] memory proposers = new address[](1);
        proposers[0] = address(governanceSafe);
        address[] memory executors = new address[](1);
        executors[0] = address(0);
        address[] memory cancellers = new address[](1);
        cancellers[0] = makeAddr("guardian");
        timelock = new StaticsTimelock(proposers, executors, cancellers, address(0));

        config.governanceSafe = address(governanceSafe);
        config.timelock = address(timelock);
        for (uint256 i; i < config.targets.length; ++i) {
            GenesisOwnable2StepMock target = new GenesisOwnable2StepMock(address(governanceSafe));
            config.targets[i] = address(target);
            config.runtimeCodeHashes[i] = address(target).codehash;
        }
    }

    function testSafeProposalSchedulesAtomicTimelockedAcceptance() public {
        bytes32 salt = keccak256("migrate Genesis governance");
        (address[] memory targets, uint256[] memory values, bytes[] memory payloads, bytes32 operationId) =
            migration.buildSafeProposal(config, salt);

        assertEq(targets.length, 6);
        assertEq(targets[5], address(timelock));
        governanceSafe.executeBatch(targets, values, payloads);

        assertTrue(timelock.isOperationPending(operationId));
        for (uint256 i; i < config.targets.length; ++i) {
            IGenesisOwnable2Step target = IGenesisOwnable2Step(config.targets[i]);
            assertEq(target.owner(), address(governanceSafe));
            assertEq(target.pendingOwner(), address(timelock));
        }

        vm.warp(block.timestamp + timelock.getMinDelay());
        migration.executeAcceptance(config, salt);

        assertTrue(timelock.isOperationDone(operationId));
        for (uint256 i; i < config.targets.length; ++i) {
            IGenesisOwnable2Step target = IGenesisOwnable2Step(config.targets[i]);
            assertEq(target.owner(), address(timelock));
            assertEq(target.pendingOwner(), address(0));
        }
    }

    function testAcceptanceCannotExecuteBeforeDelay() public {
        bytes32 salt = keccak256("wait for governance delay");
        (address[] memory targets, uint256[] memory values, bytes[] memory payloads,) =
            migration.buildSafeProposal(config, salt);
        governanceSafe.executeBatch(targets, values, payloads);

        vm.expectRevert();
        migration.executeAcceptance(config, salt);
    }

    function testProposalRejectsUnexpectedCodeHash() public {
        config.runtimeCodeHashes[2] = keccak256("unexpected runtime");

        vm.expectRevert(
            abi.encodeWithSelector(
                ConfigureStaticsGenesisGovernance.InvalidCodeHash.selector,
                config.targets[2],
                config.runtimeCodeHashes[2],
                config.targets[2].codehash
            )
        );
        migration.buildSafeProposal(config, keccak256("invalid code"));
    }

    function testProposalRejectsPartiallyStartedOwnershipTransfer() public {
        vm.prank(address(governanceSafe));
        IGenesisOwnable2Step(config.targets[0]).transferOwnership(address(timelock));

        vm.expectRevert(
            abi.encodeWithSelector(
                ConfigureStaticsGenesisGovernance.InvalidPendingOwner.selector,
                config.targets[0],
                address(0),
                address(timelock)
            )
        );
        migration.buildSafeProposal(config, keccak256("partial migration"));
    }

    function testProposalRejectsDuplicateTarget() public {
        config.targets[4] = config.targets[0];
        config.runtimeCodeHashes[4] = config.runtimeCodeHashes[0];

        vm.expectRevert(
            abi.encodeWithSelector(ConfigureStaticsGenesisGovernance.DuplicateTarget.selector, config.targets[0])
        );
        migration.buildSafeProposal(config, keccak256("duplicate target"));
    }
}
