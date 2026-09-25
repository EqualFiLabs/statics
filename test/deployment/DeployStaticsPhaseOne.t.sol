// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {IERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {DeployStaticsPhaseOne, StaticsPhaseOneDeployment} from "../../script/DeployStaticsPhaseOne.s.sol";
import {StakingFacet} from "../../src/dollar/periphery/facets/StakingFacet.sol";
import {IStaticsDollarGateway} from "../../src/dollar/interfaces/IStaticsDollarGateway.sol";
import {IStaticsDollarRiskIncentives} from "../../src/dollar/interfaces/IStaticsDollarRiskIncentives.sol";
import {IStaticsDollarRiskLiquidity} from "../../src/dollar/interfaces/IStaticsDollarRiskLiquidity.sol";
import {IStaticsDollarSeriesMigration} from "../../src/dollar/interfaces/IStaticsDollarSeriesMigration.sol";
import {BasketLiquidityFacet} from "../../src/facets/BasketLiquidityFacet.sol";
import {IERC173} from "../../src/interfaces/IERC173.sol";
import {IERC5192} from "../../src/interfaces/IERC5192.sol";
import {IDiamondLoupe} from "../../src/interfaces/IDiamondLoupe.sol";
import {IModularPositionNFT} from "../../src/interfaces/IModularPositionNFT.sol";
import {IPositionOwnerIndex} from "../../src/interfaces/IPositionOwnerIndex.sol";
import {IStaticsBasket} from "../../src/interfaces/IStaticsBasket.sol";
import {IStaticsBasketAdmin} from "../../src/interfaces/IStaticsBasketAdmin.sol";
import {IStaticsBasketLiquidity} from "../../src/interfaces/IStaticsBasketLiquidity.sol";
import {IStaticsBorrowLiquidity} from "../../src/interfaces/IStaticsBorrowLiquidity.sol";
import {IStaticsCustody} from "../../src/interfaces/IStaticsCustody.sol";
import {IStaticsFlashLoan} from "../../src/interfaces/IStaticsFlashLoan.sol";
import {IStaticsGenesisIntegration} from "../../src/interfaces/IStaticsGenesisIntegration.sol";
import {IStaticsGlobalRewards} from "../../src/interfaces/IStaticsGlobalRewards.sol";
import {IStaticsGaugeIncentives} from "../../src/interfaces/IStaticsGaugeIncentives.sol";
import {IStaticsGovernance} from "../../src/interfaces/IStaticsGovernance.sol";
import {IStaticsLending} from "../../src/interfaces/IStaticsLending.sol";
import {IStaticsMorpho} from "../../src/interfaces/IStaticsMorpho.sol";
import {IStaticsPosition, IStaticsPositionFees} from "../../src/interfaces/IStaticsPosition.sol";
import {IStaticsProtocolPools} from "../../src/interfaces/IStaticsProtocolPools.sol";
import {IStaticsProtocolRevenue} from "../../src/interfaces/IStaticsProtocolRevenue.sol";
import {IStaticsRangeGauge} from "../../src/interfaces/IStaticsRangeGauge.sol";
import {IStaticsRangeGaugeCallback} from "../../src/interfaces/IStaticsRangeGaugeCallback.sol";
import {IStaticsPermissionedPools} from "../../src/interfaces/IStaticsPermissionedPools.sol";
import {IStaticsRewardPolicy} from "../../src/interfaces/IStaticsRewardPolicy.sol";
import {StaticsTimelock} from "../../src/governance/StaticsTimelock.sol";
import {StaticsPermissionedSwapFeeHook} from "../../src/liquidity/StaticsPermissionedSwapFeeHook.sol";
import {StaticsLiquidityManager} from "../../src/liquidity/StaticsLiquidityManager.sol";
import {StaticsSwapFeeHook} from "../../src/liquidity/StaticsSwapFeeHook.sol";
import {CanonicalV4Router} from "../helpers/CanonicalPoolTestBase.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

contract PhaseOnePoolManagerMock {}

contract PhaseOneDependencyMock {}

contract PhaseOnePositionManagerMock {
    address public immutable poolManager;
    address public immutable permit2;

    constructor(address poolManager_, address permit2_) {
        poolManager = poolManager_;
        permit2 = permit2_;
    }
}

contract PhaseOnePermissionedBindingMock {
    address public immutable poolManager;
    address public immutable permissionedHook;

    constructor(address manager, address hook) {
        poolManager = manager;
        permissionedHook = hook;
    }
}

contract DeployStaticsPhaseOneTest is Test {
    uint256 private constant EXPECTED_PHASE_ONE_FACETS = 26;
    uint256 private constant EXPECTED_PHASE_ONE_SELECTORS = 182;

    struct PhaseOneDexFixture {
        address diamond;
        address timelock;
        address creator;
        IPoolManager poolManager;
        StaticsSwapFeeHook hook;
        IStaticsProtocolPools pools;
        IStaticsGlobalRewards rewards;
        IStaticsProtocolRevenue revenue;
        MockERC20 statics;
        MockERC20 assetA;
        MockERC20 assetB;
    }

    function testLaunchInstallsOnlyDexAndGlobalStakingSelectors() public {
        DeployStaticsPhaseOne deployer = new DeployStaticsPhaseOne();
        MockERC20 statics = new MockERC20("Statics", "STATICS", 18);
        MockERC20 weth = new MockERC20("Wrapped Ether", "WETH", 18);
        address multisig = makeAddr("multisig");
        address guardian = makeAddr("guardian");
        address treasury = makeAddr("treasury");

        (StaticsPhaseOneDeployment memory deployment, StaticsTimelock timelock) = deployer.deploy(
            DeployStaticsPhaseOne.Config({
                multisig: multisig,
                guardian: guardian,
                treasury: treasury,
                stakingToken: address(statics),
                weth: address(weth),
                positionCreationFeeAmount: 0.001 ether,
                weeklyGaugeReleaseBps: 400
            })
        );
        address diamond = deployment.diamond;

        assertEq(deployment.positionNFT, diamond);
        assertEq(deployment.weth, address(weth));
        assertTrue(deployment.defaultVenueControllerFactory.code.length != 0);
        assertEq(IERC173(diamond).owner(), address(timelock));
        assertEq(IStaticsGovernance(diamond).guardian(), guardian);
        assertEq(IStaticsBasketAdmin(diamond).treasury(), treasury);
        assertEq(IStaticsProtocolPools(diamond).poolCreationFee(), 0);
        assertEq(IStaticsPositionFees(diamond).positionCreationFee(), 0.001 ether);
        assertEq(IStaticsGlobalRewards(diamond).stakingToken(), address(statics));
        assertEq(IStaticsGlobalRewards(diamond).maxRewardAssetsPerPosition(), 12);
        assertEq(IStaticsRangeGauge(diamond).gaugeRewardDuration(), 7 days);
        assertTrue(IStaticsRangeGauge(diamond).gaugeRewardAssetAllowed(address(statics)));
        IStaticsGaugeIncentives.ReserveView memory reserve = IStaticsGaugeIncentives(diamond).gaugeReserve();
        assertEq(reserve.releaseBps, 400);
        assertEq(reserve.available, 0);
        assertEq(reserve.deferred, 0);
        assertEq(reserve.committed, 0);
        assertTrue(timelock.hasRole(timelock.PROPOSER_ROLE(), multisig));
        assertTrue(timelock.hasRole(timelock.CANCELLER_ROLE(), guardian));
        assertTrue(timelock.hasRole(timelock.EXECUTOR_ROLE(), address(0)));
        assertFalse(timelock.hasRole(timelock.PROPOSER_ROLE(), guardian));

        _assertManifest(diamond, EXPECTED_PHASE_ONE_FACETS, EXPECTED_PHASE_ONE_SELECTORS);
        assertTrue(IERC165(diamond).supportsInterface(type(IERC721).interfaceId));
        assertTrue(IERC165(diamond).supportsInterface(type(IStaticsGlobalRewards).interfaceId));
        assertTrue(IERC165(diamond).supportsInterface(type(IStaticsGaugeIncentives).interfaceId));
        assertTrue(IERC165(diamond).supportsInterface(type(IStaticsPosition).interfaceId));
        assertTrue(IERC165(diamond).supportsInterface(type(IStaticsPositionFees).interfaceId));
        assertTrue(IERC165(diamond).supportsInterface(type(IModularPositionNFT).interfaceId));
        assertTrue(IERC165(diamond).supportsInterface(type(IPositionOwnerIndex).interfaceId));
        assertTrue(IERC165(diamond).supportsInterface(type(IERC5192).interfaceId));
        assertTrue(IERC165(diamond).supportsInterface(type(IStaticsRangeGauge).interfaceId));
        assertFalse(IERC165(diamond).supportsInterface(type(IStaticsGovernance).interfaceId));
        assertFalse(IERC165(diamond).supportsInterface(type(IStaticsBasket).interfaceId));
        assertFalse(IERC165(diamond).supportsInterface(type(IStaticsCustody).interfaceId));
        assertFalse(IERC165(diamond).supportsInterface(type(IStaticsFlashLoan).interfaceId));
        assertFalse(IERC165(diamond).supportsInterface(type(IStaticsGenesisIntegration).interfaceId));
        assertFalse(IERC165(diamond).supportsInterface(type(IStaticsProtocolPools).interfaceId));
        assertFalse(IERC165(diamond).supportsInterface(type(IStaticsProtocolRevenue).interfaceId));
        assertFalse(IERC165(diamond).supportsInterface(type(IStaticsBorrowLiquidity).interfaceId));
        assertFalse(IERC165(diamond).supportsInterface(type(IStaticsMorpho).interfaceId));
        assertFalse(IERC165(diamond).supportsInterface(type(IStaticsDollarGateway).interfaceId));
        assertFalse(IERC165(diamond).supportsInterface(type(IStaticsDollarRiskLiquidity).interfaceId));
        assertFalse(IERC165(diamond).supportsInterface(type(IStaticsDollarRiskIncentives).interfaceId));
        assertFalse(IERC165(diamond).supportsInterface(type(IStaticsDollarSeriesMigration).interfaceId));
        assertFalse(IERC165(diamond).supportsInterface(type(IERC1155Receiver).interfaceId));

        _assertPhaseOneSelectors(diamond);
        _assertDeferredSelectorsAbsent(diamond);
    }

    function testPhaseOneStakingRoundTripUsesInstalledSelectorClosure() public {
        (StaticsPhaseOneDeployment memory deployment,, MockERC20 statics) =
            _deployDefault(makeAddr("multisig"), makeAddr("guardian"));
        IStaticsGlobalRewards rewards = IStaticsGlobalRewards(deployment.diamond);
        IStaticsPosition positions = IStaticsPosition(deployment.diamond);
        address staker = makeAddr("staker");
        address[] memory selected = new address[](1);
        selected[0] = makeAddr("rewardAsset");

        statics.mint(staker, 10 ether);
        vm.startPrank(staker);
        statics.approve(deployment.diamond, 10 ether);
        uint256 positionId = rewards.createAndStake(10 ether, staker, selected);
        rewards.unstake(positionId, 10 ether, staker);
        positions.closePosition(positionId);
        vm.stopPrank();

        assertEq(statics.balanceOf(staker), 10 ether);
        assertEq(rewards.totalStaked(), 0);
        assertFalse(IModularPositionNFT(deployment.diamond).positionState(positionId).exists);
    }

    function testPhaseOnePositionsCloseWithoutMorphoSelectors() public {
        (StaticsPhaseOneDeployment memory deployment,,) = _deployDefault(makeAddr("multisig"), makeAddr("guardian"));
        IStaticsPosition positions = IStaticsPosition(deployment.diamond);
        address positionOwner = makeAddr("positionOwner");

        vm.prank(positionOwner);
        uint256 positionId = positions.createPosition(positionOwner);
        assertTrue(positions.isPositionClosable(positionId));
        vm.prank(positionOwner);
        positions.closePosition(positionId);

        assertFalse(IModularPositionNFT(deployment.diamond).positionState(positionId).exists);
        assertEq(
            IDiamondLoupe(deployment.diamond).facetAddress(IStaticsMorpho.enforceMorphoAccountEmpty.selector),
            address(0)
        );
    }

    function testGuardianMayAlsoBeGovernanceSafe() public {
        address governanceSafe = makeAddr("governanceSafe");
        (StaticsPhaseOneDeployment memory deployment, StaticsTimelock timelock,) =
            _deployDefault(governanceSafe, governanceSafe);

        assertEq(IStaticsGovernance(deployment.diamond).guardian(), governanceSafe);
        assertTrue(timelock.hasRole(timelock.PROPOSER_ROLE(), governanceSafe));
        assertTrue(timelock.hasRole(timelock.CANCELLER_ROLE(), governanceSafe));
    }

    function testPhaseOneDeploysHooksAndBoundLiquidityManager() public {
        DeployStaticsPhaseOne deployer = new DeployStaticsPhaseOne();
        MockERC20 statics = new MockERC20("Statics", "STATICS", 18);
        MockERC20 weth = new MockERC20("Wrapped Ether", "WETH", 18);
        PhaseOnePoolManagerMock poolManager = new PhaseOnePoolManagerMock();

        DeployStaticsPhaseOne.V4Config memory v4 = _v4Config(address(poolManager));
        (StaticsPhaseOneDeployment memory deployment, StaticsTimelock timelock) = deployer.deployWithLiquidity(
            DeployStaticsPhaseOne.Config({
                multisig: makeAddr("multisig"),
                guardian: makeAddr("guardian"),
                treasury: makeAddr("treasury"),
                stakingToken: address(statics),
                weth: address(weth),
                positionCreationFeeAmount: 0,
                weeklyGaugeReleaseBps: 400
            }),
            v4
        );

        StaticsSwapFeeHook hook = StaticsSwapFeeHook(payable(deployment.swapFeeHook));
        assertEq(hook.staticsDiamond(), deployment.diamond);
        assertEq(address(hook.poolManager()), address(poolManager));
        uint160 expectedFlags = Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG
            | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
            | Hooks.BEFORE_DONATE_FLAG;
        assertEq(uint160(address(hook)) & Hooks.ALL_HOOK_MASK, expectedFlags);
        assertGt(deployment.permanentLiquidityMath.code.length, 0);
        StaticsPermissionedSwapFeeHook permissionedHook =
            StaticsPermissionedSwapFeeHook(deployment.permissionedSwapFeeHook);
        assertGt(deployment.permissionedSwapFeeHook.code.length, 0);
        assertEq(permissionedHook.staticsDiamond(), deployment.diamond);
        assertEq(address(permissionedHook.poolManager()), address(poolManager));
        StaticsLiquidityManager liquidityManager = StaticsLiquidityManager(deployment.liquidityManager);
        assertEq(liquidityManager.staticsDiamond(), deployment.diamond);
        assertEq(liquidityManager.poolManager(), address(poolManager));
        assertEq(liquidityManager.positionManager(), v4.positionManager);
        assertEq(liquidityManager.permit2(), v4.permit2);

        vm.prank(address(timelock));
        IStaticsBasketLiquidity(deployment.diamond)
            .installCanonicalPoolIntegration(address(poolManager), deployment.swapFeeHook);
        (address configuredPoolManager, address configuredHook, bool installed) =
            IStaticsBasketLiquidity(deployment.diamond).liquidityIntegration();
        assertEq(configuredPoolManager, address(poolManager));
        assertEq(configuredHook, deployment.swapFeeHook);
        assertTrue(installed);

        IDiamondLoupe loupe = IDiamondLoupe(deployment.diamond);
        assertTrue(loupe.facetAddress(IStaticsBasketLiquidity.installLiquidityManager.selector) != address(0));
        assertTrue(loupe.facetAddress(IStaticsProtocolPools.replaceLiquidityManager.selector) != address(0));
    }

    function testPermissionedInstallRejectsPeripheryBoundToAnotherHook() public {
        DeployStaticsPhaseOne deployer = new DeployStaticsPhaseOne();
        MockERC20 statics = new MockERC20("Statics", "STATICS", 18);
        MockERC20 weth = new MockERC20("Wrapped Ether", "WETH", 18);
        PhaseOnePoolManagerMock poolManager = new PhaseOnePoolManagerMock();
        (StaticsPhaseOneDeployment memory deployment, StaticsTimelock timelock) = deployer.deployWithLiquidity(
            DeployStaticsPhaseOne.Config({
                multisig: makeAddr("multisig"),
                guardian: makeAddr("guardian"),
                treasury: makeAddr("treasury"),
                stakingToken: address(statics),
                weth: address(weth),
                positionCreationFeeAmount: 0,
                weeklyGaugeReleaseBps: 400
            }),
            _v4Config(address(poolManager))
        );
        PhaseOnePermissionedBindingMock wrongPeriphery =
            new PhaseOnePermissionedBindingMock(address(poolManager), makeAddr("wrong-permissioned-hook"));

        vm.startPrank(address(timelock));
        IStaticsBasketLiquidity(deployment.diamond)
            .installCanonicalPoolIntegration(address(poolManager), deployment.swapFeeHook);
        vm.expectRevert(
            abi.encodeWithSelector(
                BasketLiquidityFacet.InvalidIntegrationBinding.selector,
                address(wrongPeriphery),
                deployment.permissionedSwapFeeHook,
                wrongPeriphery.permissionedHook()
            )
        );
        IStaticsBasketLiquidity(deployment.diamond)
            .installPermissionedPoolIntegration(
                deployment.permissionedSwapFeeHook,
                address(wrongPeriphery),
                address(wrongPeriphery),
                address(wrongPeriphery)
            );
        vm.stopPrank();
    }

    function testPhaseOneCreatesAndSwapsGeneralPoolThroughInstalledClosure() public {
        PhaseOneDexFixture memory fixture = _deployPhaseOneDexFixture();
        IStaticsProtocolPools.ProtocolPoolView memory pool = _createPhaseOneGeneralPool(fixture);
        assertEq(uint256(pool.kind), uint256(IStaticsProtocolPools.ProtocolPoolKind.General));
        assertEq(address(pool.key.hooks), address(fixture.hook));

        CanonicalV4Router router = _addPhaseOneLiquidity(fixture.poolManager, pool.key);
        (uint256 positionId, address[] memory rewardAssets) = _stakeForPool(fixture, pool.key);
        vm.warp(block.timestamp + 25 hours);
        vm.roll(block.number + 1);

        address trader = makeAddr("trader");
        _swap(router, pool.key, rewardAssets[0], trader, true);
        _swap(router, pool.key, rewardAssets[1], trader, false);

        uint256 creatorRevenue = fixture.revenue.creatorRevenue(pool.poolId, rewardAssets[0])
            + fixture.revenue.creatorRevenue(pool.poolId, rewardAssets[1]);
        assertGt(creatorRevenue, 0);
        assertGt(fixture.rewards.treasuryAccrued(rewardAssets[0]) + fixture.rewards.treasuryAccrued(rewardAssets[1]), 0);
        vm.prank(makeAddr("staker"));
        uint256[] memory pending = fixture.rewards.pendingRewards(positionId, rewardAssets);
        assertGt(pending[0] + pending[1], 0);
        assertGt(fixture.hook.lockedLiquidity(pool.poolId), 0);
    }

    function testPhaseOneRejectsInvalidDependencies() public {
        DeployStaticsPhaseOne deployer = new DeployStaticsPhaseOne();
        MockERC20 statics = new MockERC20("Statics", "STATICS", 18);
        DeployStaticsPhaseOne.Config memory config = DeployStaticsPhaseOne.Config({
            multisig: makeAddr("multisig"),
            guardian: makeAddr("guardian"),
            treasury: makeAddr("treasury"),
            stakingToken: address(statics),
            weth: address(0),
            positionCreationFeeAmount: 0,
            weeklyGaugeReleaseBps: 400
        });

        vm.expectRevert(DeployStaticsPhaseOne.InvalidConfig.selector);
        deployer.deploy(config);

        config.weth = address(statics);
        config.guardian = address(0);
        vm.expectRevert(DeployStaticsPhaseOne.InvalidConfig.selector);
        deployer.deploy(config);

        config.guardian = makeAddr("guardian");
        config.weeklyGaugeReleaseBps = 1_001;
        vm.expectRevert(DeployStaticsPhaseOne.InvalidConfig.selector);
        deployer.deploy(config);
    }

    function testPhaseOneRejectsCanonicalPositionManagerBindingDrift() public {
        DeployStaticsPhaseOne deployer = new DeployStaticsPhaseOne();
        MockERC20 statics = new MockERC20("Statics", "STATICS", 18);
        MockERC20 weth = new MockERC20("Wrapped Ether", "WETH", 18);
        PhaseOnePoolManagerMock poolManager = new PhaseOnePoolManagerMock();
        PhaseOneDependencyMock permit2 = new PhaseOneDependencyMock();
        PhaseOnePositionManagerMock wrongPoolManager =
            new PhaseOnePositionManagerMock(makeAddr("wrongPoolManager"), address(permit2));
        DeployStaticsPhaseOne.Config memory config = DeployStaticsPhaseOne.Config({
            multisig: makeAddr("multisig"),
            guardian: makeAddr("guardian"),
            treasury: makeAddr("treasury"),
            stakingToken: address(statics),
            weth: address(weth),
            positionCreationFeeAmount: 0,
            weeklyGaugeReleaseBps: 400
        });
        DeployStaticsPhaseOne.V4Config memory v4 = DeployStaticsPhaseOne.V4Config({
            poolManager: address(poolManager),
            positionManager: address(wrongPoolManager),
            permit2: address(permit2),
            inputFeeBps: 25,
            outputFeeBps: 25,
            poolManagerCodeHash: address(poolManager).codehash,
            positionManagerCodeHash: address(wrongPoolManager).codehash,
            permit2CodeHash: address(permit2).codehash
        });

        vm.expectRevert(
            abi.encodeWithSelector(
                DeployStaticsPhaseOne.InvalidV4Binding.selector,
                address(wrongPoolManager),
                address(poolManager),
                wrongPoolManager.poolManager()
            )
        );
        deployer.deployWithLiquidity(config, v4);

        PhaseOneDependencyMock wrongPermit2 = new PhaseOneDependencyMock();
        PhaseOnePositionManagerMock wrongPermitManager =
            new PhaseOnePositionManagerMock(address(poolManager), address(wrongPermit2));
        v4.positionManager = address(wrongPermitManager);
        v4.positionManagerCodeHash = address(wrongPermitManager).codehash;
        vm.expectRevert(
            abi.encodeWithSelector(
                DeployStaticsPhaseOne.InvalidV4Binding.selector,
                address(wrongPermitManager),
                address(permit2),
                address(wrongPermit2)
            )
        );
        deployer.deployWithLiquidity(config, v4);
    }

    function testMainnetLaunchRequiresDeployedGenesisBindings() public {
        vm.chainId(4663);
        DeployStaticsPhaseOne deployer = new DeployStaticsPhaseOne();
        MockERC20 statics = new MockERC20("Statics", "STATICS", 18);
        MockERC20 weth = new MockERC20("Wrapped Ether", "WETH", 18);
        string memory manifest = vm.readFile("deployments/robinhood-mainnet-genesis.json");
        address expectedStatics = vm.parseJsonAddress(manifest, ".contracts.staticsToken.address");

        vm.expectRevert(
            abi.encodeWithSelector(
                DeployStaticsPhaseOne.InvalidGenesisBinding.selector, expectedStatics, address(statics)
            )
        );
        deployer.deploy(
            DeployStaticsPhaseOne.Config({
                multisig: makeAddr("multisig"),
                guardian: makeAddr("guardian"),
                treasury: makeAddr("treasury"),
                stakingToken: address(statics),
                weth: address(weth),
                positionCreationFeeAmount: 0,
                weeklyGaugeReleaseBps: 400
            })
        );
    }

    function _deployDefault(address multisig, address guardian)
        private
        returns (StaticsPhaseOneDeployment memory deployment, StaticsTimelock timelock, MockERC20 statics)
    {
        DeployStaticsPhaseOne deployer = new DeployStaticsPhaseOne();
        statics = new MockERC20("Statics", "STATICS", 18);
        MockERC20 weth = new MockERC20("Wrapped Ether", "WETH", 18);
        (deployment, timelock) = deployer.deploy(
            DeployStaticsPhaseOne.Config({
                multisig: multisig,
                guardian: guardian,
                treasury: makeAddr("treasury"),
                stakingToken: address(statics),
                weth: address(weth),
                positionCreationFeeAmount: 0,
                weeklyGaugeReleaseBps: 400
            })
        );
    }

    function _assertPhaseOneSelectors(address diamond) private view {
        IDiamondLoupe loupe = IDiamondLoupe(diamond);
        assertTrue(loupe.facetAddress(IStaticsGovernance.protocolPoolSwapsBlocked.selector) != address(0));
        assertTrue(loupe.facetAddress(IStaticsRangeGaugeCallback.afterProtocolPoolSwap.selector) != address(0));
        assertTrue(loupe.facetAddress(IStaticsRangeGauge.fundPoolReward.selector) != address(0));
        assertTrue(loupe.facetAddress(IStaticsRangeGauge.setPoolRewardAllocatorShare.selector) != address(0));
        assertTrue(loupe.facetAddress(IStaticsRangeGauge.provideLiquidity.selector) != address(0));
        assertTrue(loupe.facetAddress(IStaticsRangeGauge.exitLiquidity.selector) != address(0));
        assertTrue(loupe.facetAddress(IStaticsRangeGauge.previewLpRewards.selector) != address(0));
        assertTrue(loupe.facetAddress(IStaticsPosition.createPosition.selector) != address(0));
        assertTrue(loupe.facetAddress(IStaticsGlobalRewards.createAndStake.selector) != address(0));
        assertTrue(loupe.facetAddress(IStaticsGaugeIncentives.setGaugeAllocations.selector) != address(0));
        assertTrue(loupe.facetAddress(IStaticsGaugeIncentives.claimGaugeAllocatorRewards.selector) != address(0));
        assertTrue(loupe.facetAddress(IStaticsGaugeIncentives.gaugeReserve.selector) != address(0));
        assertTrue(loupe.facetAddress(IStaticsGaugeIncentives.gaugeAllocatorReward.selector) != address(0));
        assertTrue(loupe.facetAddress(IStaticsCustody.stakingCustodyAccount.selector) != address(0));
        assertTrue(loupe.facetAddress(IStaticsBasketAdmin.setTreasury.selector) != address(0));
        assertTrue(loupe.facetAddress(IStaticsBasketLiquidity.installCanonicalPoolIntegration.selector) != address(0));
        assertTrue(loupe.facetAddress(IStaticsBasketLiquidity.installLiquidityManager.selector) != address(0));
        assertTrue(loupe.facetAddress(IStaticsProtocolPools.createPool.selector) != address(0));
        assertTrue(loupe.facetAddress(IStaticsProtocolPools.setGeneralFeeAllocation.selector) != address(0));
        assertTrue(loupe.facetAddress(IStaticsProtocolRevenue.routeProtocolSwapFees.selector) != address(0));
        assertTrue(loupe.facetAddress(IStaticsRewardPolicy.addRewardRestriction.selector) != address(0));
        assertTrue(loupe.facetAddress(IStaticsPermissionedPools.createPermissionedPool.selector) != address(0));
    }

    function _assertDeferredSelectorsAbsent(address diamond) private view {
        IDiamondLoupe loupe = IDiamondLoupe(diamond);
        assertEq(loupe.facetAddress(IStaticsGovernance.quarantineBasket.selector), address(0));
        assertEq(loupe.facetAddress(IStaticsBasket.createBasket.selector), address(0));
        assertEq(loupe.facetAddress(IStaticsBasket.mint.selector), address(0));
        assertEq(loupe.facetAddress(IStaticsLending.borrow.selector), address(0));
        assertEq(loupe.facetAddress(IStaticsFlashLoan.flashLoan.selector), address(0));
        assertEq(loupe.facetAddress(IStaticsGenesisIntegration.linkGenesis.selector), address(0));
        assertEq(loupe.facetAddress(IStaticsProtocolPools.setBasketFeeAllocation.selector), address(0));
        assertEq(loupe.facetAddress(IStaticsProtocolPools.basketFeeAllocation.selector), address(0));
        assertEq(loupe.facetAddress(IStaticsProtocolRevenue.canAccrueBasketRewards.selector), address(0));
        assertEq(loupe.facetAddress(IStaticsBorrowLiquidity.borrowAndProvideLiquidity.selector), address(0));
        assertEq(loupe.facetAddress(IStaticsMorpho.deployMorphoCollateral.selector), address(0));
        assertEq(loupe.facetAddress(IStaticsDollarGateway.depositETH.selector), address(0));
        assertEq(loupe.facetAddress(IStaticsDollarSeriesMigration.processSeriesTransition.selector), address(0));
        assertEq(loupe.facetAddress(StakingFacet.createAndStakeRiskShares.selector), address(0));
    }

    function _assertManifest(address diamond, uint256 expectedFacets, uint256 expectedSelectors) private view {
        IDiamondLoupe loupe = IDiamondLoupe(diamond);
        address[] memory facets = loupe.facetAddresses();
        assertEq(facets.length, expectedFacets);
        uint256 selectorCount;
        for (uint256 i; i < facets.length; ++i) {
            selectorCount += loupe.facetFunctionSelectors(facets[i]).length;
        }
        assertEq(selectorCount, expectedSelectors);
    }

    function _deployPhaseOneDexFixture() private returns (PhaseOneDexFixture memory fixture) {
        fixture.poolManager =
            IPoolManager(deployCode("out/PoolManager.sol/PoolManager.json", abi.encode(address(this))));
        DeployStaticsPhaseOne deployer = new DeployStaticsPhaseOne();
        fixture.statics = new MockERC20("Statics", "STATICS", 18);
        MockERC20 weth = new MockERC20("Wrapped Ether", "WETH", 18);
        fixture.assetA = new MockERC20("Asset A", "A", 18);
        fixture.assetB = new MockERC20("Asset B", "B", 18);
        fixture.creator = makeAddr("creator");
        (StaticsPhaseOneDeployment memory deployment, StaticsTimelock timelock) = deployer.deployWithLiquidity(
            DeployStaticsPhaseOne.Config({
                multisig: makeAddr("multisig"),
                guardian: makeAddr("guardian"),
                treasury: makeAddr("treasury"),
                stakingToken: address(fixture.statics),
                weth: address(weth),
                positionCreationFeeAmount: 0,
                weeklyGaugeReleaseBps: 400
            }),
            _v4Config(address(fixture.poolManager))
        );
        fixture.diamond = deployment.diamond;
        fixture.timelock = address(timelock);
        fixture.hook = StaticsSwapFeeHook(payable(deployment.swapFeeHook));
        fixture.pools = IStaticsProtocolPools(deployment.diamond);
        fixture.rewards = IStaticsGlobalRewards(deployment.diamond);
        fixture.revenue = IStaticsProtocolRevenue(deployment.diamond);
    }

    function _v4Config(address poolManager) private returns (DeployStaticsPhaseOne.V4Config memory config) {
        PhaseOneDependencyMock permit2 = new PhaseOneDependencyMock();
        PhaseOnePositionManagerMock positionManager = new PhaseOnePositionManagerMock(poolManager, address(permit2));
        config = DeployStaticsPhaseOne.V4Config({
            poolManager: poolManager,
            positionManager: address(positionManager),
            permit2: address(permit2),
            inputFeeBps: 25,
            outputFeeBps: 25,
            poolManagerCodeHash: poolManager.codehash,
            positionManagerCodeHash: address(positionManager).codehash,
            permit2CodeHash: address(permit2).codehash
        });
    }

    function _createPhaseOneGeneralPool(PhaseOneDexFixture memory fixture)
        private
        returns (IStaticsProtocolPools.ProtocolPoolView memory pool)
    {
        vm.startPrank(fixture.timelock);
        IStaticsBasketLiquidity(fixture.diamond)
            .installCanonicalPoolIntegration(address(fixture.poolManager), address(fixture.hook));
        fixture.pools.setPermanentLiquidityHarvester(makeAddr("harvester"));
        IStaticsProtocolPools.CreatePoolParams memory params = IStaticsProtocolPools.CreatePoolParams({
            tokenA: address(fixture.assetA),
            tokenB: address(fixture.assetB),
            lpFee: 3_000,
            tickSpacing: 10,
            sqrtPriceBPerAX96: 1 << 96,
            initialFeeRate: IStaticsProtocolPools.PoolSwapFeeRate({inputFeeBps: 25, outputFeeBps: 25}),
            creator: fixture.creator,
            nonce: 1,
            deadline: block.timestamp + 1 days
        });
        PoolId poolId = fixture.pools.createPool(params, "");
        vm.stopPrank();
        pool = fixture.pools.protocolPool(poolId);
    }

    function _addPhaseOneLiquidity(IPoolManager poolManager, PoolKey memory key)
        private
        returns (CanonicalV4Router router)
    {
        router = new CanonicalV4Router(poolManager);
        address token0 = Currency.unwrap(key.currency0);
        address token1 = Currency.unwrap(key.currency1);
        address lp = makeAddr("lp");
        MockERC20(token0).mint(lp, 100 ether);
        MockERC20(token1).mint(lp, 100 ether);
        vm.startPrank(lp);
        IERC20(token0).approve(address(router), type(uint256).max);
        IERC20(token1).approve(address(router), type(uint256).max);
        router.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(key.tickSpacing),
                tickUpper: TickMath.maxUsableTick(key.tickSpacing),
                liquidityDelta: int256(5 ether),
                salt: bytes32(0)
            })
        );
        vm.stopPrank();
    }

    function _stakeForPool(PhaseOneDexFixture memory fixture, PoolKey memory key)
        private
        returns (uint256 positionId, address[] memory rewardAssets)
    {
        address staker = makeAddr("staker");
        rewardAssets = new address[](2);
        rewardAssets[0] = Currency.unwrap(key.currency0);
        rewardAssets[1] = Currency.unwrap(key.currency1);
        fixture.statics.mint(staker, 10 ether);
        vm.startPrank(staker);
        fixture.statics.approve(fixture.diamond, 10 ether);
        positionId = fixture.rewards.createAndStake(10 ether, staker, rewardAssets);
        vm.stopPrank();
    }

    function _swap(CanonicalV4Router router, PoolKey memory key, address input, address trader, bool zeroForOne)
        private
    {
        MockERC20(input).mint(trader, 0.1 ether);
        vm.startPrank(trader);
        IERC20(input).approve(address(router), type(uint256).max);
        router.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(0.1 ether),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            })
        );
        vm.stopPrank();
    }
}
