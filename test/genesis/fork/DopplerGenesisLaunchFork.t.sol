// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {IV4Quoter} from "@uniswap/v4-periphery/src/interfaces/IV4Quoter.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {ActionConstants} from "@uniswap/v4-periphery/src/libraries/ActionConstants.sol";
import {Plan, Planner} from "@uniswap/v4-periphery/test/shared/Planner.sol";
import {
    DeployStaticsGenesis,
    StaticsGenesisDeployment,
    StaticsGenesisDeploymentConfig,
    StaticsGenesisLaunchArtifact,
    StaticsGenesisLaunchCommitments,
    StaticsGenesisMarket
} from "../../../script/DeployStaticsGenesis.s.sol";
import {GenesisActivationRegistry} from "../../../src/genesis/GenesisActivationRegistry.sol";
import {GenesisLaunchDistributor} from "../../../src/genesis/GenesisLaunchDistributor.sol";
import {StaticsFeeReceiver} from "../../../src/genesis/StaticsFeeReceiver.sol";
import {StaticsTreasuryVesting} from "../../../src/genesis/StaticsTreasuryVesting.sol";
import {StaticsDopplerLaunchConfig} from "../../../src/genesis/doppler/StaticsDopplerLaunchConfig.sol";
import {StaticsGenesisVault} from "../../../src/genesis/StaticsGenesisVault.sol";
import {StaticsGenesis} from "../../../src/tokens/StaticsGenesis.sol";
import {MockDopplerToken} from "../../mocks/MockDopplerToken.sol";
import {MockWrappedNative} from "../../mocks/MockWrappedNative.sol";

interface IDopplerFeeShares {
    function getShares(bytes32 poolId, address beneficiary) external view returns (uint256 shares);
    function poolManager() external view returns (IPoolManager);
}

interface IWETH is IERC20 {
    function deposit() external payable;
}

interface IUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

contract DopplerGenesisLaunchForkHarness is DeployStaticsGenesis {
    function buildArtifact(
        StaticsGenesisDeploymentConfig memory config,
        address deployer,
        StaticsFeeReceiver receiver,
        StaticsTreasuryVesting treasuryVesting,
        uint256 expectedLaunchNonce
    ) external view returns (StaticsGenesisLaunchArtifact memory artifact) {
        (bytes32 wethDependencyHash, StaticsDopplerLaunchConfig.RuntimeCodeHashes memory moduleCodeHashes) =
            _dependencyCommitments(config);
        bytes32 currentHash = launchConfigHash(config, wethDependencyHash, moduleCodeHashes);
        StaticsGenesisLaunchCommitments memory commitments = StaticsGenesisLaunchCommitments({
            expectedLaunchNonce: expectedLaunchNonce,
            wethDependencyHash: wethDependencyHash,
            moduleCodeHashes: moduleCodeHashes,
            launchConfigHash: currentHash
        });
        artifact = _buildLaunchArtifact(config, deployer, receiver, treasuryVesting, commitments);
    }

    function _requireApprovedProductionConfig(bytes32) internal pure override {}
}

/// @notice Current-network integration proof against official Doppler deployments.
contract DopplerGenesisLaunchForkTest is Test {
    using Planner for Plan;

    bytes1 private constant V4_SWAP_COMMAND = 0x10;
    bytes1 private constant WRAP_ETH_COMMAND = 0x0b;
    bytes1 private constant UNWRAP_WETH_COMMAND = 0x0c;
    string private constant ROBINHOOD_MANIFEST = "deployments/robinhood-chain-4663.json";

    struct RouterExactInputSingleParams {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 amountIn;
        uint128 amountOutMinimum;
        uint256 minHopPriceX36;
        bytes hookData;
    }

    receive() external payable {}

    function testRobinhoodDopplerLaunchEncodingAndWiring() public {
        string memory rpcUrl = vm.envOr("ROBINHOOD_MAINNET", string(""));
        if (bytes(rpcUrl).length == 0) {
            if (vm.envOr("REQUIRE_DOPPLER_FORK_PROOF", false)) fail("ROBINHOOD_MAINNET is required");
            vm.skip(true);
            return;
        }
        string memory manifest = vm.readFile(ROBINHOOD_MANIFEST);
        uint256 forkBlock = vm.parseJsonUint(manifest, ".forkBlock");
        bytes32 forkBlockHash = vm.parseJsonBytes32(manifest, ".forkBlockHash");
        uint256 forkId = vm.createSelectFork(rpcUrl, forkBlock + 1);
        assertEq(blockhash(forkBlock), forkBlockHash, "Robinhood manifest block hash drift");
        vm.rollFork(forkId, forkBlock);
        assertEq(block.chainid, 4_663);
        assertEq(block.number, forkBlock);
        _deployAndAssert();
    }

    function testRobinhoodDopplerLaunchRejectsRuntimeCodeDrift() public {
        string memory rpcUrl = vm.envOr("ROBINHOOD_MAINNET", string(""));
        if (bytes(rpcUrl).length == 0) {
            if (vm.envOr("REQUIRE_DOPPLER_FORK_PROOF", false)) fail("ROBINHOOD_MAINNET is required");
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpcUrl);

        StaticsDopplerLaunchConfig.Modules memory modules = StaticsDopplerLaunchConfig.modules(block.chainid);
        string memory manifest = vm.readFile(ROBINHOOD_MANIFEST);
        bytes32 expectedCodeHash = vm.parseJsonBytes32(manifest, ".contracts.dopplerPoolInitializer.runtimeCodeHash");
        DopplerGenesisLaunchForkHarness deployer = new DopplerGenesisLaunchForkHarness();
        StaticsGenesisDeploymentConfig memory config = _driftConfig(deployer, manifest);
        StaticsGenesisLaunchArtifact memory artifact = _prepareDriftArtifact(deployer, config);
        vm.etch(modules.poolInitializer, hex"60006000fd");

        vm.expectRevert(
            abi.encodeWithSelector(
                DeployStaticsGenesis.InvalidRobinhoodDependencyCodeHash.selector,
                modules.poolInitializer,
                expectedCodeHash,
                modules.poolInitializer.codehash
            )
        );
        deployer.validatePreparedLaunch(artifact);
    }

    function testRobinhoodDopplerLaunchRejectsWethImplementationDrift() public {
        string memory rpcUrl = vm.envOr("ROBINHOOD_MAINNET", string(""));
        if (bytes(rpcUrl).length == 0) {
            if (vm.envOr("REQUIRE_DOPPLER_FORK_PROOF", false)) fail("ROBINHOOD_MAINNET is required");
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpcUrl);

        string memory manifest = vm.readFile(ROBINHOOD_MANIFEST);
        address implementation = vm.parseJsonAddress(manifest, ".contracts.weth.implementation.address");
        bytes32 expectedCodeHash = vm.parseJsonBytes32(manifest, ".contracts.weth.implementation.runtimeCodeHash");
        DopplerGenesisLaunchForkHarness deployer = new DopplerGenesisLaunchForkHarness();
        StaticsGenesisDeploymentConfig memory config = _driftConfig(deployer, manifest);
        StaticsGenesisLaunchArtifact memory artifact = _prepareDriftArtifact(deployer, config);
        vm.etch(implementation, hex"60006000fd");
        vm.expectRevert(
            abi.encodeWithSelector(
                DeployStaticsGenesis.InvalidRobinhoodDependencyCodeHash.selector,
                implementation,
                expectedCodeHash,
                implementation.codehash
            )
        );
        deployer.validatePreparedLaunch(artifact);
    }

    function testRobinhoodDopplerLaunchRejectsWethProxyAdminDrift() public {
        string memory rpcUrl = vm.envOr("ROBINHOOD_MAINNET", string(""));
        if (bytes(rpcUrl).length == 0) {
            if (vm.envOr("REQUIRE_DOPPLER_FORK_PROOF", false)) fail("ROBINHOOD_MAINNET is required");
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpcUrl);

        string memory manifest = vm.readFile(ROBINHOOD_MANIFEST);
        address proxyAdmin = vm.parseJsonAddress(manifest, ".contracts.weth.proxyAdmin.address");
        bytes32 expectedCodeHash = vm.parseJsonBytes32(manifest, ".contracts.weth.proxyAdmin.runtimeCodeHash");
        DopplerGenesisLaunchForkHarness deployer = new DopplerGenesisLaunchForkHarness();
        StaticsGenesisDeploymentConfig memory config = _driftConfig(deployer, manifest);
        StaticsGenesisLaunchArtifact memory artifact = _prepareDriftArtifact(deployer, config);
        vm.etch(proxyAdmin, hex"60006000fd");
        vm.expectRevert(
            abi.encodeWithSelector(
                DeployStaticsGenesis.InvalidRobinhoodDependencyCodeHash.selector,
                proxyAdmin,
                expectedCodeHash,
                proxyAdmin.codehash
            )
        );
        deployer.validatePreparedLaunch(artifact);
    }

    function testRobinhoodDopplerLaunchRejectsWethAuthorityImplementationDrift() public {
        string memory rpcUrl = vm.envOr("ROBINHOOD_MAINNET", string(""));
        if (bytes(rpcUrl).length == 0) {
            if (vm.envOr("REQUIRE_DOPPLER_FORK_PROOF", false)) fail("ROBINHOOD_MAINNET is required");
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpcUrl);

        string memory manifest = vm.readFile(ROBINHOOD_MANIFEST);
        address implementation =
            vm.parseJsonAddress(manifest, ".contracts.weth.proxyAdmin.owner.implementation.address");
        bytes32 expectedCodeHash =
            vm.parseJsonBytes32(manifest, ".contracts.weth.proxyAdmin.owner.implementation.runtimeCodeHash");
        DopplerGenesisLaunchForkHarness deployer = new DopplerGenesisLaunchForkHarness();
        StaticsGenesisDeploymentConfig memory config = _driftConfig(deployer, manifest);
        StaticsGenesisLaunchArtifact memory artifact = _prepareDriftArtifact(deployer, config);
        vm.etch(implementation, hex"60006000fd");
        vm.expectRevert(
            abi.encodeWithSelector(
                DeployStaticsGenesis.InvalidRobinhoodDependencyCodeHash.selector,
                implementation,
                expectedCodeHash,
                implementation.codehash
            )
        );
        deployer.validatePreparedLaunch(artifact);
    }

    function _driftConfig(DeployStaticsGenesis deployer, string memory manifest)
        private
        returns (StaticsGenesisDeploymentConfig memory config)
    {
        config = StaticsGenesisDeploymentConfig({
            governance: makeAddr("driftGovernance"),
            treasury: makeAddr("driftTreasury"),
            numeraire: vm.parseJsonAddress(manifest, ".contracts.weth.address"),
            integrator: address(0),
            modules: StaticsDopplerLaunchConfig.modules(block.chainid),
            salt: keccak256("STATICS_DOPPLER_DRIFT_PROOF"),
            fee: 15_000,
            genesisRewardShareBps: 5_000,
            reserveShareBps: 5_000,
            creditOriginationFee: 0.003 ether,
            creditExtensionFee: 0.003 ether,
            recoveryCallerShareBps: 2_000,
            genesisEpochEnd: block.timestamp + 30 days,
            tokenURI: deployer.staticsTokenURI(),
            contractURI: deployer.staticsGenesisContractURI(),
            externalURLBase: deployer.staticsGenesisExternalURLBase()
        });
    }

    function _prepareDriftArtifact(
        DopplerGenesisLaunchForkHarness deployer,
        StaticsGenesisDeploymentConfig memory config
    ) private returns (StaticsGenesisLaunchArtifact memory artifact) {
        (StaticsFeeReceiver receiver, StaticsTreasuryVesting vesting) = deployer.prepare(config, address(deployer));
        artifact = deployer.buildArtifact(config, address(deployer), receiver, vesting, vm.getNonce(address(deployer)));
    }

    function _deployAndAssert() private {
        StaticsDopplerLaunchConfig.Modules memory modules = StaticsDopplerLaunchConfig.modules(block.chainid);
        _assertCode(modules.airlock);
        _assertCode(modules.tokenFactory);
        _assertCode(modules.governanceFactory);
        _assertCode(modules.poolInitializer);
        _assertCode(modules.noOpMigrator);

        IERC20 weth;
        StaticsGenesisDeployment memory deployment;
        GenesisLaunchDistributor distributor;
        StaticsFeeReceiver receiver;
        StaticsGenesisVault vault;
        address treasury = makeAddr("forkTreasury");

        {
            address governance = makeAddr("forkGovernance");
            if (block.chainid == 4_663) {
                string memory manifest = vm.readFile(ROBINHOOD_MANIFEST);
                weth = IERC20(vm.parseJsonAddress(manifest, ".contracts.weth.address"));
                vm.deal(address(this), 20 ether);
                IWETH(address(weth)).deposit{value: 10 ether}();
            } else {
                MockWrappedNative mockWeth = new MockWrappedNative();
                vm.deal(address(this), 20 ether);
                mockWeth.deposit{value: 10 ether}();
                weth = IERC20(address(mockWeth));
            }
            DopplerGenesisLaunchForkHarness deployer = new DopplerGenesisLaunchForkHarness();
            StaticsGenesisDeploymentConfig memory config = StaticsGenesisDeploymentConfig({
                governance: governance,
                treasury: treasury,
                numeraire: address(weth),
                integrator: address(0),
                modules: modules,
                salt: keccak256(abi.encode("STATICS_DOPPLER_FORK", block.chainid, block.number)),
                fee: 30_000,
                genesisRewardShareBps: 5_000,
                reserveShareBps: 5_000,
                creditOriginationFee: 0.003 ether,
                creditExtensionFee: 0.003 ether,
                recoveryCallerShareBps: 2_000,
                genesisEpochEnd: block.timestamp + 7 days,
                tokenURI: "ipfs://statics/token.json",
                contractURI: deployer.staticsGenesisContractURI(),
                externalURLBase: deployer.staticsGenesisExternalURLBase()
            });

            deployment = _launchBeforeFinalize(deployer, config, weth);
            IERC20 statics = IERC20(deployment.statics);
            StaticsGenesis genesis = StaticsGenesis(deployment.genesis);
            vault = StaticsGenesisVault(deployment.genesisVault);
            StaticsTreasuryVesting vesting = StaticsTreasuryVesting(deployment.treasuryVesting);
            receiver = StaticsFeeReceiver(payable(deployment.feeReceiver));
            GenesisActivationRegistry registry = GenesisActivationRegistry(deployment.activationRegistry);
            distributor = GenesisLaunchDistributor(deployment.genesisDistributor);
            assertEq(genesis.contractURI(), deployer.staticsGenesisContractURI());
            assertEq(genesis.externalURLBase(), deployer.staticsGenesisExternalURLBase());

            assertEq(statics.totalSupply(), 1_000_000_000 ether);
            assertEq(statics.balanceOf(treasury), 0);
            assertGe(statics.balanceOf(address(vesting)), 100_100_000 ether);
            assertEq(vault.tokenBacking(), 99_900_000 ether);
            assertEq(statics.balanceOf(address(vault)), vault.tokenBacking());
            assertEq(genesis.balanceOf(address(vault)), 5_000);
            assertEq(genesis.balanceOf(address(vesting)), 555);
            assertEq(genesis.ownerOf(5_001), address(vesting));
            assertEq(genesis.ownerOf(5_555), address(vesting));
            assertEq(vault.circulatingGenesis(), 555);
            assertEq(vault.requiredBacking(), 99_900_000 ether);
            assertEq(receiver.statics(), deployment.statics);
            assertEq(receiver.poolInitializer(), modules.poolInitializer);
            assertEq(receiver.reserveVault(), address(vault));
            assertEq(receiver.reserveShareBps(), 5_000);
            assertTrue(vault.epochActive());
            assertEq(
                IDopplerFeeShares(modules.poolInitializer).getShares(deployment.poolId, address(receiver)), 0.95 ether
            );
            assertEq(receiver.activeDistributor(), address(distributor));
            assertEq(registry.activeConsumer(), address(distributor));
            assertEq(receiver.pendingOwner(), governance);
            assertTrue(IERC20(deployment.statics).transfer(treasury, 280_000 ether));
        }

        PoolKey memory immediateLaunchKey = _poolKey(deployment.statics, address(weth), modules.poolInitializer, 30_000);
        if (block.chainid == 4_663) {
            _assertNativeRouterRoutes(immediateLaunchKey, deployment.statics, address(weth));
        }

        _buyAndRegisterGenesis(vault, StaticsGenesis(deployment.genesis), distributor, treasury, address(weth));
        PoolKey memory launchKey = _poolKey(deployment.statics, address(weth), modules.poolInitializer, 30_000);
        _swapWethForStatics(launchKey, weth, deployment.statics, modules.poolInitializer, 0.1 ether);
        _assertReserveHarvest(vault, receiver, distributor, weth);
        _assertPostEpochReserveFlows(
            launchKey,
            vault,
            IERC20(deployment.statics),
            StaticsGenesis(deployment.genesis),
            GenesisActivationRegistry(deployment.activationRegistry),
            distributor
        );
    }

    function _launchBeforeFinalize(
        DopplerGenesisLaunchForkHarness deployer,
        StaticsGenesisDeploymentConfig memory config,
        IERC20 weth
    ) private returns (StaticsGenesisDeployment memory deployment) {
        (StaticsFeeReceiver receiver, StaticsTreasuryVesting vesting) = deployer.prepare(config, address(deployer));
        StaticsGenesisLaunchArtifact memory artifact =
            deployer.buildArtifact(config, address(deployer), receiver, vesting, vm.getNonce(address(deployer)));
        // Robinhood's archive RPC rejects historical reads for absent accounts instead of
        // returning empty code. Materialize the predicted account as locally empty so the fork
        // can prove the same CREATE2 precondition without replacing any live dependency state.
        vm.etch(artifact.expectedStatics, bytes(""));
        assertEq(artifact.expectedStatics.code.length, 0);
        deployer.validatePreparedLaunch(artifact);

        StaticsGenesisMarket memory market = deployer.launch(artifact);
        assertEq(market.statics, artifact.expectedStatics);
        assertEq(market.pool, artifact.expectedStatics);
        assertEq(market.poolId, artifact.expectedPoolId);
        assertGt(artifact.expectedStatics.code.length, 0);
        assertEq(receiver.statics(), address(0));
        assertEq(vesting.vestingStart(), 0);

        PoolKey memory key =
            _poolKey(artifact.expectedStatics, address(weth), config.modules.poolInitializer, config.fee);
        uint256 staticsReceived =
            _swapWethForStatics(key, weth, artifact.expectedStatics, config.modules.poolInitializer, 2 ether);
        assertGe(staticsReceived, 280_000 ether, "isolated launch market was not immediately live");

        deployment = deployer.finalize(artifact);
    }

    function _buyAndRegisterGenesis(
        StaticsGenesisVault vault,
        StaticsGenesis genesis,
        GenesisLaunchDistributor distributor,
        address buyer,
        address weth
    ) private {
        // The epoch waives the reserve buy-in but still charges the governed acquisition fee.
        uint256 requiredNative = vault.quoteGenesisPurchase().requiredNative;
        uint256 reserveBefore = vault.reserveETH();
        vm.deal(buyer, buyer.balance + requiredNative);
        vm.startPrank(buyer);
        IERC20(address(vault.statics())).approve(address(vault), vault.GENESIS_PRICE());
        vault.buyGenesis{value: requiredNative}(1, buyer);
        vm.stopPrank();
        assertEq(genesis.ownerOf(1), buyer);
        assertEq(vault.requiredBacking(), 100_080_000 ether);
        assertEq(vault.reserveETH(), reserveBefore + requiredNative);

        vm.prank(buyer);
        distributor.registerGenesis(1);
        assertEq(distributor.pendingGenesis(1, address(vault.statics())), 0);
        assertEq(distributor.pendingGenesis(1, weth), 0);
    }

    function _assertReserveHarvest(
        StaticsGenesisVault vault,
        StaticsFeeReceiver receiver,
        GenesisLaunchDistributor distributor,
        IERC20 weth
    ) private {
        // Harvest routes gross WETH into the reserve (50%) and the distributor remainder (50%).
        uint256 reserveBefore = vault.reserveETH();
        uint256 cumulativeReserveBefore = receiver.cumulativeReserveWeth();
        uint256 cumulativeDistributorBefore = receiver.cumulativeDistributorWeth();
        (, uint256 distributorWeth) = distributor.accrue();
        assertGt(distributorWeth, 0, "standard Doppler fee collection returned no distributor WETH");
        uint256 reserveWeth = receiver.cumulativeReserveWeth() - cumulativeReserveBefore;
        assertGt(reserveWeth, 0, "reserve allocation received no WETH");
        assertEq(receiver.cumulativeDistributorWeth() - cumulativeDistributorBefore, distributorWeth);
        assertEq(
            receiver.cumulativeReserveWeth() + receiver.cumulativeDistributorWeth(),
            receiver.cumulativeHarvested(address(weth))
        );
        assertEq(vault.reserveETH() - reserveBefore, reserveWeth);
        assertEq(address(vault).balance, vault.reserveETH());
        assertGt(distributor.pendingGenesis(1, address(weth)), 0, "registered Genesis earned no launch rewards");
        assertGt(distributor.rewardBook(address(weth)).treasuryClaimable, 0, "treasury earned no launch revenue");

        // Reserve stays dormant during the epoch: redemption/acquisition ignore reserveETH.
        assertTrue(vault.epochActive());
        assertEq(vault.reserveBuyIn(), 0);
        assertEq(vault.reserveRedemptionPayout(), 0);
    }

    function _swapWethForStatics(
        PoolKey memory key,
        IERC20 weth,
        address statics,
        address initializer,
        uint256 amountIn
    ) private returns (uint256 staticsReceived) {
        PoolSwapTest router = new PoolSwapTest(IDopplerFeeShares(initializer).poolManager());
        weth.approve(address(router), amountIn);
        bool zeroForOne = address(weth) < statics;
        uint256 staticsBefore = IERC20(statics).balanceOf(address(this));
        router.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            bytes("")
        );
        staticsReceived = IERC20(statics).balanceOf(address(this)) - staticsBefore;
    }

    /// @dev Proves reserve, activation, credit, transfer, recovery, and reward-accounting transitions.
    function _assertPostEpochReserveFlows(
        PoolKey memory key,
        StaticsGenesisVault vault,
        IERC20 statics,
        StaticsGenesis genesis,
        GenesisActivationRegistry registry,
        GenesisLaunchDistributor distributor
    ) private {
        address treasury = makeAddr("forkTreasury");
        _redeemAndReacquire(vault, statics, genesis, treasury);
        _activateRepayAndTransfer(key, vault, statics, genesis, registry, distributor, treasury);
        _expireAndRecover(vault, statics, genesis, distributor, makeAddr("forkSuccessor"));
    }

    function _redeemAndReacquire(StaticsGenesisVault vault, IERC20 statics, StaticsGenesis genesis, address treasury)
        private
    {
        vm.warp(vault.genesisEpochEnd());
        assertFalse(vault.epochActive());
        uint256 activeReserve = vault.reserveETH();
        assertGt(activeReserve, 0, "reserve did not accumulate during the epoch");
        assertEq(vault.reserveRedemptionPayout(), activeReserve / vault.RESERVE_DENOMINATOR());
        assertEq(
            vault.reserveBuyIn(),
            (activeReserve + vault.RESERVE_BUY_IN_DENOMINATOR() - 1) / vault.RESERVE_BUY_IN_DENOMINATOR()
        );

        uint256 expectedPayout = vault.reserveRedemptionPayout();
        uint256 treasuryEthBefore = treasury.balance;
        vm.startPrank(treasury);
        genesis.approve(address(vault), 1);
        vault.redeemGenesis(1, treasury);
        vm.stopPrank();
        assertEq(statics.balanceOf(treasury), 280_000 ether);
        assertEq(treasury.balance - treasuryEthBefore, expectedPayout);
        assertEq(vault.reserveETH(), activeReserve - expectedPayout);

        uint256 required = vault.reserveBuyIn() + vault.nativeAcquisitionFee();
        vm.deal(treasury, required + 2 * vault.creditOriginationFee() + vault.creditExtensionFee());
        vm.startPrank(treasury);
        statics.approve(address(vault), vault.GENESIS_PRICE());
        vault.buyGenesis{value: required}(1, treasury);
        vm.stopPrank();
        assertEq(genesis.ownerOf(1), treasury);
        assertEq(vault.reserveETH(), activeReserve - expectedPayout + required);
    }

    function _activateRepayAndTransfer(
        PoolKey memory key,
        StaticsGenesisVault vault,
        IERC20 statics,
        StaticsGenesis genesis,
        GenesisActivationRegistry registry,
        GenesisLaunchDistributor distributor,
        address treasury
    ) private {
        uint256 originationFee = vault.creditOriginationFee();
        uint256 extensionFee = vault.creditExtensionFee();
        address owner = makeAddr("forkGenesisOwner");
        vm.deal(owner, 2 * originationFee + extensionFee);
        vm.prank(treasury);
        genesis.transferFrom(treasury, owner, 1);
        vm.prank(treasury);
        statics.transfer(owner, 30_000 ether);

        uint256 supplyBeforeActivation = statics.totalSupply();
        uint256 treasuryBeforeActivation = statics.balanceOf(treasury);
        vm.startPrank(owner);
        statics.approve(address(registry), 30_000 ether);
        registry.activate(1, 2);
        vm.stopPrank();
        assertEq(statics.totalSupply(), supplyBeforeActivation, "activation burned STATICS");
        assertEq(statics.balanceOf(treasury) - treasuryBeforeActivation, 30_000 ether);
        assertEq(registry.multiplierBps(1), 11_500);
        assertEq(distributor.effectiveWeight(1), 11_500);
        _swapWethForStatics(key, IERC20(distributor.numeraire()), address(statics), address(key.hooks), 0.1 ether);
        distributor.accrue();

        vm.prank(owner);
        vault.openGenesisCredit{value: originationFee}(1, 100_000 ether);
        assertEq(vault.totalOutstandingGenesisCredit(), 100_000 ether);
        assertTrue(genesis.locked(1));
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(StaticsGenesis.GenesisLocked.selector, 1));
        genesis.transferFrom(owner, makeAddr("lockedRecipient"), 1);
        vm.startPrank(owner);
        genesis.approve(address(vault), 1);
        vm.expectRevert(abi.encodeWithSelector(StaticsGenesisVault.CreditAlreadyActive.selector, 1));
        vault.redeemGenesis(1, owner);
        uint40 maturityBefore = vault.credit(1).maturity;
        vault.drawGenesisCredit{value: originationFee}(1, 20_000 ether);
        assertEq(vault.credit(1).principal, 120_000 ether);
        assertEq(vault.credit(1).maturity, maturityBefore);
        vault.extendGenesisCredit{value: extensionFee}(1);
        assertEq(vault.credit(1).maturity, maturityBefore + 30 days);
        statics.approve(address(vault), 120_000 ether);
        vault.repayGenesisCredit(1, 120_000 ether);
        vm.stopPrank();
        assertEq(vault.totalOutstandingGenesisCredit(), 0);
        assertFalse(genesis.locked(1));

        _transferAndAssertAccounting(vault, genesis, registry, distributor, owner, makeAddr("forkSuccessor"));
    }

    function _transferAndAssertAccounting(
        StaticsGenesisVault vault,
        StaticsGenesis genesis,
        GenesisActivationRegistry registry,
        GenesisLaunchDistributor distributor,
        address owner,
        address successor
    ) private {
        address rewardAsset = address(vault.statics());
        uint256 previousOwnerPending = distributor.pendingGenesis(1, rewardAsset);
        vm.prank(owner);
        genesis.transferFrom(owner, successor, 1);
        assertEq(genesis.ownerOf(1), successor);
        assertEq(registry.tierOf(1), 0);
        assertEq(distributor.effectiveWeight(1), 10_000);
        assertGe(distributor.ownerClaimable(owner, rewardAsset), previousOwnerPending);

        address pairedRewardAsset = distributor.numeraire();
        uint256 staticsBefore = IERC20(rewardAsset).balanceOf(owner);
        uint256 pairedBefore = IERC20(pairedRewardAsset).balanceOf(owner);
        uint256[] memory noGenesisIds = new uint256[](0);
        vm.prank(owner);
        (uint256 claimedStatics, uint256 claimedPaired) = distributor.claimAllGenesisRewards(noGenesisIds, owner);
        assertGe(claimedStatics, previousOwnerPending);
        assertEq(IERC20(rewardAsset).balanceOf(owner) - staticsBefore, claimedStatics);
        assertEq(IERC20(pairedRewardAsset).balanceOf(owner) - pairedBefore, claimedPaired);
    }

    function _expireAndRecover(
        StaticsGenesisVault vault,
        IERC20 statics,
        StaticsGenesis genesis,
        GenesisLaunchDistributor distributor,
        address successor
    ) private {
        uint256 originationFee = vault.creditOriginationFee();
        uint256 extensionFee = vault.creditExtensionFee();
        uint256 maximumPrincipal = vault.MAX_CREDIT_PRINCIPAL();
        vm.deal(successor, 2 * originationFee + 2 * extensionFee);
        vm.prank(successor);
        vm.expectRevert(
            abi.encodeWithSelector(StaticsGenesisVault.InvalidCreditPrincipal.selector, maximumPrincipal + 1)
        );
        vault.openGenesisCredit{value: originationFee}(1, maximumPrincipal + 1);
        vm.startPrank(successor);
        vault.openGenesisCredit{value: originationFee}(1, 100_000 ether);
        vault.drawGenesisCredit{value: originationFee}(1, 20_000 ether);
        statics.approve(address(vault), 40_000 ether);
        vault.repayGenesisCredit(1, 40_000 ether);
        vault.extendGenesisCredit{value: extensionFee}(1);
        vm.stopPrank();
        assertEq(vault.credit(1).principal, 80_000 ether);
        uint40 expiredMaturity = vault.credit(1).maturity;
        vm.warp(uint256(expiredMaturity) + 1);
        vm.prank(successor);
        vm.expectRevert(abi.encodeWithSelector(StaticsGenesisVault.CreditExpired.selector, 1, expiredMaturity));
        vault.extendGenesisCredit{value: extensionFee}(1);

        address keeper = makeAddr("forkRecoveryKeeper");
        vm.warp(uint256(vault.creditRecoverableAt(1)) + 1);
        uint256 keeperBefore = statics.balanceOf(keeper);
        vm.prank(keeper);
        vault.recoverGenesisCredit(1);
        assertEq(statics.balanceOf(keeper) - keeperBefore, 1_800 ether);
        assertEq(vault.totalOutstandingGenesisCredit(), 0);
        assertEq(genesis.ownerOf(1), address(vault));
        assertFalse(genesis.locked(1));
        assertEq(distributor.effectiveWeight(1), 0);
    }

    function _assertNativeRouterRoutes(PoolKey memory key, address statics, address weth) private {
        string memory manifest = vm.readFile(ROBINHOOD_MANIFEST);
        address router = vm.parseJsonAddress(manifest, ".contracts.universalRouter.address");
        _assertCode(router);
        uint256 staticsReceived = _nativeBuy(key, statics, weth, router);
        _nativeSell(key, statics, weth, router, staticsReceived);
    }

    function _forkQuoter() private view returns (IV4Quoter quoter) {
        string memory manifest = vm.readFile(ROBINHOOD_MANIFEST);
        quoter = IV4Quoter(vm.parseJsonAddress(manifest, ".contracts.quoter.address"));
        _assertCode(address(quoter));
    }

    function _forkPermit2() private view returns (address permit2) {
        string memory manifest = vm.readFile(ROBINHOOD_MANIFEST);
        permit2 = vm.parseJsonAddress(manifest, ".contracts.permit2.address");
        _assertCode(permit2);
    }

    function _exactInSingleCalldata(PoolKey memory key, bool zeroForOne, uint128 amountIn, uint128 minimumOut)
        private
        pure
        returns (bytes memory)
    {
        return abi.encode(
            RouterExactInputSingleParams({
                poolKey: key,
                zeroForOne: zeroForOne,
                amountIn: amountIn,
                amountOutMinimum: minimumOut,
                minHopPriceX36: 0,
                hookData: bytes("")
            })
        );
    }

    function _nativeBuy(PoolKey memory key, address statics, address weth, address router)
        private
        returns (uint256 staticsReceived)
    {
        IV4Quoter quoter = _forkQuoter();
        uint128 buyAmount = 0.01 ether;
        bool buyZeroForOne = weth < statics;
        (uint256 quotedBuy,) = quoter.quoteExactInputSingle(
            IV4Quoter.QuoteExactSingleParams({
                poolKey: key, zeroForOne: buyZeroForOne, exactAmount: buyAmount, hookData: bytes("")
            })
        );
        uint128 minimumBuy = uint128((quotedBuy * 99) / 100);
        uint256 staticsBefore = IERC20(statics).balanceOf(address(this));

        Plan memory buyPlan = Planner.init();
        buyPlan.add(Actions.SWAP_EXACT_IN_SINGLE, _exactInSingleCalldata(key, buyZeroForOne, buyAmount, minimumBuy));
        buyPlan.add(Actions.SETTLE, abi.encode(Currency.wrap(weth), buyAmount, false));
        buyPlan.add(Actions.TAKE_ALL, abi.encode(Currency.wrap(statics), minimumBuy));
        bytes[] memory buyInputs = new bytes[](2);
        buyInputs[0] = abi.encode(ActionConstants.ADDRESS_THIS, buyAmount);
        buyInputs[1] = buyPlan.encode();
        IUniversalRouter(router).execute{value: buyAmount}(
            abi.encodePacked(WRAP_ETH_COMMAND, V4_SWAP_COMMAND), buyInputs, block.timestamp + 1
        );
        staticsReceived = IERC20(statics).balanceOf(address(this)) - staticsBefore;
        assertGe(staticsReceived, minimumBuy, "native buy missed quoted minimum");
    }

    function _nativeSell(PoolKey memory key, address statics, address weth, address router, uint256 staticsReceived)
        private
    {
        address permit2 = _forkPermit2();
        uint128 sellAmount = uint128(staticsReceived / 2);
        IERC20(statics).approve(permit2, type(uint256).max);
        IAllowanceTransfer(permit2).approve(statics, router, type(uint160).max, type(uint48).max);

        uint128 minimumSell;
        {
            bool buyZeroForOne = weth < statics;
            (uint256 quotedSell,) = _forkQuoter()
                .quoteExactInputSingle(
                    IV4Quoter.QuoteExactSingleParams({
                    poolKey: key, zeroForOne: !buyZeroForOne, exactAmount: sellAmount, hookData: bytes("")
                })
                );
            minimumSell = uint128((quotedSell * 99) / 100);
        }
        uint256 ethBefore = address(this).balance;

        Plan memory sellPlan = Planner.init();
        sellPlan.add(
            Actions.SWAP_EXACT_IN_SINGLE, _exactInSingleCalldata(key, !(weth < statics), sellAmount, minimumSell)
        );
        sellPlan.add(Actions.SETTLE_ALL, abi.encode(Currency.wrap(statics), sellAmount));
        sellPlan.add(Actions.TAKE, abi.encode(Currency.wrap(weth), ActionConstants.ADDRESS_THIS, 0));
        bytes[] memory sellInputs = new bytes[](2);
        sellInputs[0] = sellPlan.encode();
        sellInputs[1] = abi.encode(ActionConstants.MSG_SENDER, minimumSell);
        IUniversalRouter(router)
            .execute(abi.encodePacked(V4_SWAP_COMMAND, UNWRAP_WETH_COMMAND), sellInputs, block.timestamp + 1);
        assertGe(address(this).balance - ethBefore, minimumSell, "native sell missed quoted minimum");
    }

    function _poolKey(address statics, address numeraire, address initializer, uint24 fee)
        private
        pure
        returns (PoolKey memory key)
    {
        (address currency0, address currency1) = statics < numeraire ? (statics, numeraire) : (numeraire, statics);
        key = PoolKey({
            currency0: Currency.wrap(currency0),
            currency1: Currency.wrap(currency1),
            fee: fee,
            tickSpacing: 100,
            hooks: IHooks(initializer)
        });
    }

    function _assertCode(address target) private view {
        assertGt(target.code.length, 0, "missing official Doppler module");
    }
}
