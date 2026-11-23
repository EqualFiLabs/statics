// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ConfigureStaticsGenesis, StaticsGenesisHandoffConfig} from "../../../script/ConfigureStaticsGenesis.s.sol";
import {DeployStatics} from "../../../script/DeployStatics.s.sol";
import {StaticsDollarStackDeployment} from "../../../script/dollar/DeployStaticsDollar.s.sol";
import {StaticsGenesisIntegrationInit} from "../../../src/diamond/StaticsGenesisIntegrationInit.sol";
import {GenesisActivationRegistry} from "../../../src/genesis/GenesisActivationRegistry.sol";
import {GenesisLaunchDistributor} from "../../../src/genesis/GenesisLaunchDistributor.sol";
import {StaticsFeeReceiver} from "../../../src/genesis/StaticsFeeReceiver.sol";
import {StaticsGenesisVault} from "../../../src/genesis/StaticsGenesisVault.sol";
import {StaticsGenesis} from "../../../src/tokens/StaticsGenesis.sol";
import {IGenesisTransferTracking} from "../../../src/interfaces/IGenesisTransferTracking.sol";
import {StaticsTimelock} from "../../../src/governance/StaticsTimelock.sol";

interface IRehearsalRouter {
    function bootstrapOperators(uint256 maxCount) external returns (uint256 count, uint256 nextId);
    function finalizeBootstrap() external;
    function totalEffectiveWeight() external view returns (uint256);
    function effectiveWeight(uint256 operatorId) external view returns (uint256);
    function registerRewardAsset(address asset) external;
    function syncOperator(uint256 operatorId) external returns (uint8);
    function syncedTransferNonce(uint256 operatorId) external view returns (uint64);
}

interface IRehearsalGameRevenue {
    function flushOperatorRevenue(uint64 version, address asset, uint256 amount) external returns (uint256);
}

/// @dev Use the compiled artifacts from the Router, Bonanza and Rooms repos. The actual game
/// revenue facets are exercised with seeded settled-revenue buckets, without replaying game rounds.
contract GenesisOperatorRouterForkTest is Test {
    uint256 private constant FORK_BLOCK = 121_060_490;
    bytes32 private constant FORK_HASH = 0xad8931d03858d5d0ce53987338bc2dfcaf03735327b62581cb0f0e50c89d4581;
    string private constant MANIFEST = "./deployments/robinhood-mainnet-genesis.json";
    string private constant ARTIFACTS = "./out/operator-router-integration/";

    function testGenesisHandoffAndGameRevenueThroughRouterV2() public {
        if (!vm.envOr("RUN_OPERATOR_ROUTER_V2_FORK", false)) {
            vm.skip(true);
            return;
        }
        string memory rpc = vm.envString("ROBINHOOD_MAINNET");
        string memory header =
            vm.rpcJson(rpc, "eth_getBlockByHash", string.concat("[\"", vm.toString(FORK_HASH), "\",false]"));
        assertEq(vm.parseJsonBytes32(header, ".hash"), FORK_HASH);
        assertEq(vm.parseJsonUint(header, ".number"), FORK_BLOCK);
        vm.createSelectFork(rpc, FORK_BLOCK);
        assertEq(block.chainid, 4_663);

        StaticsGenesisHandoffConfig memory config = _genesisConfig();
        (address diamond, address authority) = _handoff(config);
        IRehearsalRouter router = IRehearsalRouter(
            _deployArtifact(
                "RouterV2", abi.encode(config.genesis, config.activationRegistry, config.vault, authority, diamond)
            )
        );
        vm.prank(authority);
        IGenesisTransferTracking(diamond).bindGenesisOperatorFeeRouter(address(router));
        vm.warp(block.timestamp + 1);
        uint256 cursor = 1;
        while (cursor <= 5_555) {
            (, cursor) = router.bootstrapOperators(100);
        }
        router.finalizeBootstrap();
        _assertBootstrapWeight(router, config);
        vm.prank(authority);
        router.registerRewardAsset(config.numeraire);

        _verifyVaultLifecycle(router, config);
        _flushGame("RoomsRevenue", "equalfi.rooms.storage.", 4, address(router), config.numeraire, 2 ether);
        assertEq(IERC20(config.numeraire).balanceOf(address(router)), 3 ether);
    }

    function _assertBootstrapWeight(IRehearsalRouter router, StaticsGenesisHandoffConfig memory config) private view {
        StaticsGenesis nft = StaticsGenesis(config.genesis);
        GenesisActivationRegistry registry = GenesisActivationRegistry(config.activationRegistry);
        uint256 total;
        for (uint256 id = 1; id <= 5_555; ++id) {
            uint256 weight = nft.ownerOf(id) == config.vault ? 0 : registry.multiplierBps(id);
            assertEq(router.effectiveWeight(id), weight);
            total += weight;
        }
        assertEq(router.totalEffectiveWeight(), total);
    }

    function _verifyVaultLifecycle(IRehearsalRouter router, StaticsGenesisHandoffConfig memory config) private {
        StaticsGenesisVault vault = StaticsGenesisVault(payable(config.vault));
        uint256 id = 1;
        while (!vault.isVaultInventory(id)) ++id;
        address buyer = makeAddr("operator buyer");
        deal(config.statics, buyer, vault.GENESIS_PRICE());
        uint256 cost = vault.quoteGenesisPurchase().requiredNative;
        vm.deal(buyer, cost);
        vm.startPrank(buyer);
        IERC20(config.statics).approve(address(vault), vault.GENESIS_PRICE());
        vault.buyGenesis{value: cost}(id, buyer);
        vm.stopPrank();
        assertEq(router.syncedTransferNonce(id), 1);
        assertEq(router.effectiveWeight(id), 0);
        vm.warp(block.timestamp + 1);
        router.syncOperator(id);
        uint256 weight = router.totalEffectiveWeight();
        assertEq(router.effectiveWeight(id), 10_000);

        _flushGame("BonanzaRevenue", "statics.lottery.storage.", 5, address(router), config.numeraire, 1 ether);
        vm.cool(address(router));
        vm.startPrank(buyer);
        StaticsGenesis(config.genesis).approve(address(vault), id);
        uint256 gasBefore = gasleft();
        vault.redeemGenesis(id, buyer);
        uint256 gasUsed = gasBefore - gasleft();
        vm.stopPrank();
        emit log_named_uint("vault redeem with one funded Router asset", gasUsed);
        assertLt(gasUsed, 1_000_000);
        assertEq(router.syncedTransferNonce(id), 2);
        assertEq(router.totalEffectiveWeight(), weight - 10_000);
    }

    function _genesisConfig() private view returns (StaticsGenesisHandoffConfig memory config) {
        string memory manifest = vm.readFile(MANIFEST);
        config.genesis = vm.parseJsonAddress(manifest, ".contracts.operatorsNft.address");
        config.vault = vm.parseJsonAddress(manifest, ".contracts.genesisVault.address");
        config.activationRegistry = vm.parseJsonAddress(manifest, ".contracts.activationRegistry.address");
        config.feeReceiver = vm.parseJsonAddress(manifest, ".contracts.feeReceiver.address");
        config.launchDistributor = vm.parseJsonAddress(manifest, ".contracts.launchDistributor.address");
        config.statics = vm.parseJsonAddress(manifest, ".contracts.staticsToken.address");
        config.numeraire = StaticsFeeReceiver(payable(config.feeReceiver)).numeraire();
        config.genesisRewardShareBps = GenesisLaunchDistributor(config.launchDistributor).genesisRewardShareBps();
    }

    function _handoff(StaticsGenesisHandoffConfig memory config) private returns (address diamond, address authority) {
        ConfigureStaticsGenesis ceremony = new ConfigureStaticsGenesis();
        (StaticsDollarStackDeployment memory deployment, StaticsTimelock timelock) = new DeployStatics()
            .deploy(
                DeployStatics.Config({
                    multisig: address(ceremony),
                    guardian: makeAddr("guardian"),
                    treasury: StaticsGenesisVault(payable(config.vault)).treasury(),
                    stakingToken: config.statics,
                    creationFeeAmount: 0,
                    positionCreationFeeAmount: 0,
                    poolCreationFeeAmount: 0,
                    singleAssetFlashFeeBps: 5
                })
            );
        diamond = deployment.diamond;
        authority = address(timelock);
        config.initializer = address(new StaticsGenesisIntegrationInit());
        bytes32 salt = keccak256("Genesis handoff rehearsal");
        ceremony.scheduleInitialization(diamond, config, salt);
        vm.warp(block.timestamp + timelock.getMinDelay());
        ceremony.executeInitialization(diamond, config, salt);

        // Execute the existing split-governance payloads with the forked contract owners.
        (address[] memory targets,, bytes[] memory payloads) = ceremony.buildBatch(diamond, config);
        address[6] memory senders = [
            StaticsFeeReceiver(payable(config.feeReceiver)).owner(),
            authority,
            GenesisLaunchDistributor(config.launchDistributor).owner(),
            GenesisActivationRegistry(config.activationRegistry).owner(),
            authority,
            StaticsGenesis(config.genesis).owner()
        ];
        for (uint256 i; i < senders.length; ++i) {
            vm.prank(senders[i]);
            (bool ok, bytes memory result) = targets[i + 1].call(payloads[i + 1]);
            if (!ok) {
                assembly ("memory-safe") { revert(add(result, 0x20), mload(result)) }
            }
        }
        assertEq(GenesisActivationRegistry(config.activationRegistry).activeConsumer(), diamond);
        assertEq(StaticsGenesis(config.genesis).protocol(), diamond);
        assertEq(IGenesisTransferTracking(diamond).genesisTransferTrackingStartedAt(), block.timestamp);
    }

    function _flushGame(
        string memory artifact,
        string memory namespace,
        uint256 totalOffset,
        address router,
        address asset,
        uint256 amount
    ) private {
        address game = _deployArtifact(artifact, "");
        uint256 integrationSlot = uint256(keccak256(bytes(string.concat(namespace, "integration.v1"))));
        uint256 accountingSlot = uint256(keccak256(bytes(string.concat(namespace, "accounting.v1"))));
        uint256 integration = uint256(keccak256(abi.encode(uint256(1), integrationSlot + 1)));
        bytes32 perVersion = keccak256(abi.encode(uint256(1), accountingSlot + 1));
        bytes32 revenue = keccak256(abi.encode(asset, perVersion));
        uint256 totals = uint256(keccak256(abi.encode(asset, accountingSlot)));
        vm.store(game, bytes32(integrationSlot), bytes32(uint256(1)));
        vm.store(game, bytes32(integration + 1), bytes32(uint256(uint160(router))));
        vm.store(game, bytes32(totals + totalOffset), bytes32(amount));
        vm.store(game, revenue, bytes32(amount));
        vm.store(game, keccak256(bytes(string.concat(namespace, "reentrancy.v1"))), bytes32(uint256(1)));
        deal(asset, game, amount);
        assertEq(IRehearsalGameRevenue(game).flushOperatorRevenue(1, asset, amount), amount);
        assertEq(vm.load(game, revenue), bytes32(0));
        assertEq(IERC20(asset).allowance(game, router), 0);
    }

    function _deployArtifact(string memory name, bytes memory args) private returns (address deployed) {
        bytes memory initcode = abi.encodePacked(
            vm.parseJsonBytes(vm.readFile(string.concat(ARTIFACTS, name, ".json")), ".bytecode.object"), args
        );
        assembly ("memory-safe") {
            deployed := create(0, add(initcode, 0x20), mload(initcode))
        }
        assertTrue(deployed != address(0), name);
    }
}
