// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";

import {ConfigureStaticsGenesis, StaticsGenesisHandoffConfig} from "../../script/ConfigureStaticsGenesis.s.sol";
import {DeployStatics} from "../../script/DeployStatics.s.sol";
import {StaticsGenesisUpgradeParts} from "../../script/PrepareStaticsGenesisUpgrade.s.sol";
import {StaticsDollarStackDeployment} from "../../script/dollar/DeployStaticsDollar.s.sol";
import {StaticsGenesisIntegrationInit} from "../../src/diamond/StaticsGenesisIntegrationInit.sol";
import {GenesisActivationRegistry} from "../../src/genesis/GenesisActivationRegistry.sol";
import {GenesisLaunchDistributor} from "../../src/genesis/GenesisLaunchDistributor.sol";
import {StaticsFeeReceiver} from "../../src/genesis/StaticsFeeReceiver.sol";
import {StaticsGenesisVault} from "../../src/genesis/StaticsGenesisVault.sol";
import {IStaticsGenesisIntegration} from "../../src/interfaces/IStaticsGenesisIntegration.sol";
import {GenesisCreditConfig} from "../../src/interfaces/IStaticsGenesisVault.sol";
import {StaticsTimelock} from "../../src/governance/StaticsTimelock.sol";
import {StaticsAvatarSVG} from "../../src/metadata/StaticsAvatarSVG.sol";
import {StaticsGenesisRenderer} from "../../src/metadata/StaticsGenesisRenderer.sol";
import {StaticsGenesis} from "../../src/tokens/StaticsGenesis.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

contract GenesisHandoffFeeSource {
    address public statics;
    address public numeraire;
    address public beneficiary;

    function configure(address statics_, address numeraire_, address beneficiary_) external {
        statics = statics_;
        numeraire = numeraire_;
        beneficiary = beneficiary_;
    }

    function collectFees(bytes32) external pure returns (uint128 fees0, uint128 fees1) {
        return (0, 0);
    }

    function getShares(bytes32, address account) external view returns (uint256) {
        return account == beneficiary ? 0.95 ether : 0;
    }

    function getPoolKey(bytes32)
        external
        view
        returns (address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks)
    {
        (currency0, currency1) = statics < numeraire ? (statics, numeraire) : (numeraire, statics);
        return (currency0, currency1, 30_000, 100, address(this));
    }
}

contract ConfigureStaticsGenesisTest is Test {
    uint256 private constant GENESIS_PRICE = 180_000 ether;
    uint16 private constant REWARD_SHARE_BPS = 5_000;
    bytes32 private constant POOL_ID = keccak256("GENESIS_HANDOFF");

    ConfigureStaticsGenesis private ceremony;
    MockERC20 private statics;
    StaticsTimelock private timelock;
    StaticsFeeReceiver private feeReceiver;
    GenesisActivationRegistry private registry;
    StaticsGenesisVault private vault;
    StaticsGenesis private genesis;
    GenesisLaunchDistributor private launchDistributor;
    IStaticsGenesisIntegration private integration;
    StaticsGenesisHandoffConfig private config;
    address private alice;
    address private bob;
    uint256 private epochEnd;

    function setUp() public {
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        ceremony = new ConfigureStaticsGenesis();
        statics = new MockERC20("Statics", "STATICS", 18);
        DeployStatics deployer = new DeployStatics();
        DeployStatics.Config memory protocolConfig = DeployStatics.Config({
            multisig: address(ceremony),
            guardian: makeAddr("guardian"),
            treasury: makeAddr("treasury"),
            stakingToken: address(statics),
            creationFeeAmount: 0,
            positionCreationFeeAmount: 0,
            poolCreationFeeAmount: 0
        });
        (StaticsDollarStackDeployment memory deployment, StaticsTimelock deployedTimelock) =
            deployer.deploy(protocolConfig);
        timelock = deployedTimelock;
        integration = IStaticsGenesisIntegration(deployment.diamond);

        GenesisHandoffFeeSource feeSource = new GenesisHandoffFeeSource();
        feeReceiver = new StaticsFeeReceiver(address(feeSource), deployment.weth, address(timelock));
        feeSource.configure(address(statics), deployment.weth, address(feeReceiver));
        vm.prank(address(timelock));
        feeReceiver.bindMarket(address(statics), POOL_ID);

        address treasury = protocolConfig.treasury;
        registry = new GenesisActivationRegistry(statics, address(this), address(timelock), treasury);
        epochEnd = block.timestamp + 7 days;
        GenesisCreditConfig memory creditConfig = GenesisCreditConfig({
            feeReceiver: address(feeReceiver),
            treasury: treasury,
            originationFee: 0,
            extensionFee: 0,
            recoveryCallerShareBps: 2_000
        });
        vault = new StaticsGenesisVault(statics, address(this), address(timelock), epochEnd, creditConfig);
        genesis = new StaticsGenesis(
            address(vault),
            address(registry),
            new StaticsGenesisRenderer(new StaticsAvatarSVG()),
            address(timelock),
            treasury,
            "ipfs://statics-genesis/contract.json",
            "https://statics.finance/genesis/"
        );
        registry.bindGenesisCollection(address(genesis));
        vault.finalizeGenesisCollection(address(genesis));
        vm.prank(address(timelock));
        feeReceiver.bindReserveVault(address(vault));

        launchDistributor =
            new GenesisLaunchDistributor(feeReceiver, genesis, registry, treasury, address(timelock), REWARD_SHARE_BPS);
        vm.prank(address(timelock));
        feeReceiver.proposeDistributor(address(launchDistributor));
        vm.prank(address(timelock));
        launchDistributor.acceptFeeReceiverRole();
        vm.prank(address(timelock));
        registry.proposeConsumer(address(launchDistributor));
        vm.prank(address(timelock));
        launchDistributor.acceptActivationConsumer();

        config = StaticsGenesisHandoffConfig({
            initializer: address(new StaticsGenesisIntegrationInit()),
            genesis: address(genesis),
            vault: address(vault),
            activationRegistry: address(registry),
            feeReceiver: address(feeReceiver),
            launchDistributor: address(launchDistributor),
            statics: address(statics),
            numeraire: deployment.weth,
            genesisRewardShareBps: REWARD_SHARE_BPS,
            installUpgrade: false,
            upgrade: StaticsGenesisUpgradeParts({
                globalRewards: address(0), positionNFT: address(0), custody: address(0), genesisNFT: address(0)
            })
        });

        _buyGenesis(alice, 1);
        _buyGenesis(bob, 2);
    }

    function testHandoffMigratesPendingRecoveryAndActivatesPermanentIntegration() public {
        vm.prank(alice);
        launchDistributor.registerGenesis(1);
        vm.warp(epochEnd);
        vm.prank(alice);
        vault.openGenesisCredit(1, 100_000 ether);
        vm.warp(uint256(vault.creditRecoverableAt(1)) + 1);
        vm.prank(bob);
        vault.recoverGenesisCredit(1);
        uint256 pendingRecovery = launchDistributor.pendingGenesisRecovery();
        assertGt(pendingRecovery, 0);

        bytes32 salt = keccak256("full Statics Genesis handoff");
        bytes32 operationId = ceremony.schedule(address(integration), config, salt);
        assertTrue(timelock.isOperationPending(operationId));
        vm.warp(block.timestamp + timelock.getMinDelay());
        ceremony.execute(address(integration), config, salt);

        assertEq(feeReceiver.activeDistributor(), address(integration));
        assertEq(registry.activeConsumer(), address(integration));
        assertEq(genesis.protocol(), address(integration));
        assertTrue(launchDistributor.finalized());
        assertEq(launchDistributor.pendingGenesisRecovery(), 0);
        assertEq(integration.pendingGenesisRecovery(), pendingRecovery);
        assertTrue(integration.genesisIntegrationReady());

        vm.prank(bob);
        integration.registerGenesis(2);
        assertTrue(integration.genesisRegistered(2));
        assertEq(integration.genesisEffectiveWeight(2), 10_000);
    }

    function testBatchUsesExplicitInitializationAndOrderedRoleHandoff() public view {
        (address[] memory targets, uint256[] memory values, bytes[] memory payloads) =
            ceremony.buildBatch(address(integration), config);
        assertEq(targets.length, 7);
        assertEq(values.length, 7);
        assertEq(payloads.length, 7);
        assertEq(targets[0], address(integration));
        assertEq(targets[1], address(feeReceiver));
        assertEq(targets[2], address(integration));
        assertEq(targets[3], address(launchDistributor));
        assertEq(targets[4], address(registry));
        assertEq(targets[5], address(integration));
        assertEq(targets[6], address(genesis));
    }

    function _buyGenesis(address owner, uint256 genesisId) private {
        statics.mint(owner, GENESIS_PRICE);
        vm.startPrank(owner);
        statics.approve(address(vault), GENESIS_PRICE);
        vault.buyGenesis(genesisId, owner);
        vm.stopPrank();
    }
}
