// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";

import {ConfigureStaticsGenesis, StaticsGenesisHandoffConfig} from "../../script/ConfigureStaticsGenesis.s.sol";
import {DeployStatics} from "../../script/DeployStatics.s.sol";
import {
    PrepareStaticsGenesisUpgrade,
    StaticsGenesisUpgradeParts
} from "../../script/PrepareStaticsGenesisUpgrade.s.sol";
import {StaticsDollarStackDeployment} from "../../script/dollar/DeployStaticsDollar.s.sol";
import {StaticsGenesisIntegrationInit} from "../../src/diamond/StaticsGenesisIntegrationInit.sol";
import {GenesisActivationRegistry} from "../../src/genesis/GenesisActivationRegistry.sol";
import {GenesisLaunchDistributor} from "../../src/genesis/GenesisLaunchDistributor.sol";
import {StaticsFeeReceiver} from "../../src/genesis/StaticsFeeReceiver.sol";
import {StaticsGenesisVault} from "../../src/genesis/StaticsGenesisVault.sol";
import {IDiamondCut} from "../../src/interfaces/IDiamondCut.sol";
import {IDiamondLoupe} from "../../src/interfaces/IDiamondLoupe.sol";
import {IStaticsGenesisIntegration} from "../../src/interfaces/IStaticsGenesisIntegration.sol";
import {GenesisCreditConfig} from "../../src/interfaces/IStaticsGenesisVault.sol";
import {StaticsTimelock} from "../../src/governance/StaticsTimelock.sol";
import {GenesisNFTFacet} from "../../src/facets/GenesisNFTFacet.sol";
import {LibDiamond} from "../../src/libraries/LibDiamond.sol";
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
            address(this),
            address(registry),
            new StaticsGenesisRenderer(new StaticsAvatarSVG()),
            address(timelock),
            treasury,
            "ipfs://statics-genesis/contract.json"
        );
        registry.bindGenesisCollection(address(genesis));
        statics.mint(address(vault), vault.INITIAL_TOKEN_BACKING());
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

        bytes32 salt = keccak256("full Statics Operators handoff");
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

    function testLegacyDiamondUpgradeCompletesUnifiedGovernanceHandoff() public {
        _configureLegacyUpgrade();

        bytes32 salt = keccak256("legacy unified Genesis handoff");
        bytes32 operationId = ceremony.schedule(address(integration), config, salt);
        assertTrue(timelock.isOperationPending(operationId));
        vm.warp(block.timestamp + timelock.getMinDelay());
        ceremony.execute(address(integration), config, salt);

        assertEq(feeReceiver.activeDistributor(), address(integration));
        assertEq(registry.activeConsumer(), address(integration));
        assertEq(genesis.protocol(), address(integration));
        assertTrue(launchDistributor.finalized());
        assertTrue(integration.genesisIntegrationReady());
    }

    function testLegacyDiamondUpgradeCompletesSeparateGovernanceInitialization() public {
        _configureLegacyUpgrade();
        address genesisGovernance = makeAddr("legacyGenesisGovernance");
        _transferGenesisGovernance(genesisGovernance);

        bytes32 salt = keccak256("legacy separate Genesis initialization");
        bytes32 operationId = ceremony.scheduleInitialization(address(integration), config, salt);
        assertTrue(timelock.isOperationPending(operationId));
        vm.warp(block.timestamp + timelock.getMinDelay());
        ceremony.executeInitialization(address(integration), config, salt);

        assertEq(integration.genesisCollection(), address(genesis));
        assertFalse(integration.genesisRecoveryReady());
        assertTrue(
            IDiamondLoupe(address(integration)).facetAddress(IStaticsGenesisIntegration.registerGenesis.selector)
                != address(0)
        );
    }

    function testSeparateGenesisGovernanceRequiresOrderedRoleHandoff() public {
        address genesisGovernance = makeAddr("genesisGovernance");
        _transferGenesisGovernance(genesisGovernance);

        bytes32 salt = keccak256("separate Genesis governance");
        bytes32 operationId = ceremony.scheduleInitialization(address(integration), config, salt);
        assertTrue(timelock.isOperationPending(operationId));
        vm.warp(block.timestamp + timelock.getMinDelay());
        ceremony.executeInitialization(address(integration), config, salt);
        assertEq(integration.genesisCollection(), address(genesis));
        assertFalse(integration.genesisRecoveryReady());

        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(LibDiamond.NotContractOwner.selector, alice, address(timelock)));
        integration.acceptGenesisDistributorRole();
        vm.expectRevert(abi.encodeWithSelector(LibDiamond.NotContractOwner.selector, alice, address(timelock)));
        integration.acceptGenesisConsumerRole();
        vm.stopPrank();

        vm.prank(genesisGovernance);
        registry.proposeConsumer(address(integration));
        vm.prank(address(timelock));
        vm.expectRevert(
            abi.encodeWithSelector(GenesisNFTFacet.GenesisDistributorNotActive.selector, address(launchDistributor))
        );
        integration.acceptGenesisConsumerRole();

        (address[] memory targets,, bytes[] memory payloads) =
            ceremony.buildGenesisDistributorProposal(address(integration), config);
        _executeCalls(genesisGovernance, targets, payloads);
        (targets,, payloads) = ceremony.buildStaticsDistributorAcceptance(address(integration));
        _executeCalls(address(timelock), targets, payloads);
        vm.prank(address(timelock));
        vm.expectRevert(
            abi.encodeWithSelector(
                GenesisNFTFacet.GenesisConsumerPredecessorNotFinalized.selector, address(launchDistributor)
            )
        );
        integration.acceptGenesisConsumerRole();
        (targets,, payloads) = ceremony.buildGenesisConsumerProposal(address(integration), config);
        _executeCalls(genesisGovernance, targets, payloads);
        (targets,, payloads) = ceremony.buildStaticsConsumerAcceptance(address(integration));
        _executeCalls(address(timelock), targets, payloads);
        (targets,, payloads) = ceremony.buildGenesisProtocolBinding(address(integration), config);
        _executeCalls(genesisGovernance, targets, payloads);

        assertTrue(integration.genesisIntegrationReady());
        assertTrue(launchDistributor.finalized());
    }

    function _transferGenesisGovernance(address genesisGovernance) private {
        vm.startPrank(address(timelock));
        feeReceiver.transferOwnership(genesisGovernance);
        registry.transferOwnership(genesisGovernance);
        vault.transferOwnership(genesisGovernance);
        genesis.transferOwnership(genesisGovernance);
        launchDistributor.transferOwnership(genesisGovernance);
        vm.stopPrank();
        vm.startPrank(genesisGovernance);
        feeReceiver.acceptOwnership();
        registry.acceptOwnership();
        vault.acceptOwnership();
        genesis.acceptOwnership();
        launchDistributor.acceptOwnership();
        vm.stopPrank();
    }

    function _configureLegacyUpgrade() private {
        PrepareStaticsGenesisUpgrade preparer = new PrepareStaticsGenesisUpgrade();
        config.upgrade = preparer.deploy();
        config.installUpgrade = true;

        IDiamondCut.FacetCut[] memory planned = preparer.buildCut(config.upgrade);
        uint256 additions;
        for (uint256 i; i < planned.length; ++i) {
            if (planned[i].action == IDiamondCut.FacetCutAction.Add) ++additions;
        }
        IDiamondCut.FacetCut[] memory removal = new IDiamondCut.FacetCut[](additions);
        uint256 removalIndex;
        for (uint256 i; i < planned.length; ++i) {
            if (planned[i].action != IDiamondCut.FacetCutAction.Add) continue;
            removal[removalIndex++] = IDiamondCut.FacetCut({
                facetAddress: address(0),
                action: IDiamondCut.FacetCutAction.Remove,
                functionSelectors: planned[i].functionSelectors
            });
        }
        vm.prank(address(timelock));
        IDiamondCut(address(integration)).diamondCut(removal, address(0), "");
        assertEq(
            IDiamondLoupe(address(integration)).facetAddress(IStaticsGenesisIntegration.registerGenesis.selector),
            address(0)
        );
    }

    function _executeCalls(address caller, address[] memory targets, bytes[] memory payloads) private {
        for (uint256 i; i < targets.length; ++i) {
            vm.prank(caller);
            (bool success,) = targets[i].call(payloads[i]);
            assertTrue(success);
        }
    }

    function _buyGenesis(address owner, uint256 genesisId) private {
        statics.mint(owner, GENESIS_PRICE);
        uint256 requiredNative = vault.quoteGenesisPurchase().requiredNative;
        vm.deal(owner, requiredNative);
        vm.startPrank(owner);
        statics.approve(address(vault), GENESIS_PRICE);
        vault.buyGenesis{value: requiredNative}(genesisId, owner);
        vm.stopPrank();
    }
}
