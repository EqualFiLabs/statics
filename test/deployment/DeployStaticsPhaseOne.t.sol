// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {IERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
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
import {IStaticsGovernance} from "../../src/interfaces/IStaticsGovernance.sol";
import {IStaticsLending} from "../../src/interfaces/IStaticsLending.sol";
import {IStaticsMorpho} from "../../src/interfaces/IStaticsMorpho.sol";
import {IStaticsPosition, IStaticsPositionFees} from "../../src/interfaces/IStaticsPosition.sol";
import {IStaticsProtocolPools} from "../../src/interfaces/IStaticsProtocolPools.sol";
import {IStaticsProtocolRevenue} from "../../src/interfaces/IStaticsProtocolRevenue.sol";
import {StaticsTimelock} from "../../src/governance/StaticsTimelock.sol";
import {StaticsSwapFeeHook} from "../../src/liquidity/StaticsSwapFeeHook.sol";
import {CanonicalV4Router} from "../helpers/CanonicalPoolTestBase.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

contract PhaseOnePoolManagerMock {}

contract DeployStaticsPhaseOneTest is Test {
    uint256 private constant EXPECTED_PHASE_ONE_FACETS = 14;
    uint256 private constant EXPECTED_PHASE_ONE_SELECTORS = 106;

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
                positionCreationFeeAmount: 0.001 ether
            })
        );
        address diamond = deployment.diamond;

        assertEq(deployment.positionNFT, diamond);
        assertEq(deployment.weth, address(weth));
        assertEq(IERC173(diamond).owner(), address(timelock));
        assertEq(IStaticsGovernance(diamond).guardian(), guardian);
        assertEq(IStaticsBasketAdmin(diamond).treasury(), treasury);
        assertEq(IStaticsProtocolPools(diamond).poolCreationFee(), 0);
        assertEq(IStaticsPositionFees(diamond).positionCreationFee(), 0.001 ether);
        assertEq(IStaticsGlobalRewards(diamond).stakingToken(), address(statics));
        assertEq(IStaticsGlobalRewards(diamond).maxRewardAssetsPerPosition(), 12);
        assertTrue(timelock.hasRole(timelock.PROPOSER_ROLE(), multisig));
        assertTrue(timelock.hasRole(timelock.CANCELLER_ROLE(), guardian));
        assertTrue(timelock.hasRole(timelock.EXECUTOR_ROLE(), address(0)));
        assertFalse(timelock.hasRole(timelock.PROPOSER_ROLE(), guardian));

        _assertManifest(diamond, EXPECTED_PHASE_ONE_FACETS, EXPECTED_PHASE_ONE_SELECTORS);
        assertTrue(IERC165(diamond).supportsInterface(type(IERC721).interfaceId));
        assertTrue(IERC165(diamond).supportsInterface(type(IStaticsGlobalRewards).interfaceId));
        assertTrue(IERC165(diamond).supportsInterface(type(IStaticsPosition).interfaceId));
        assertTrue(IERC165(diamond).supportsInterface(type(IStaticsPositionFees).interfaceId));
        assertTrue(IERC165(diamond).supportsInterface(type(IModularPositionNFT).interfaceId));
        assertTrue(IERC165(diamond).supportsInterface(type(IPositionOwnerIndex).interfaceId));
        assertTrue(IERC165(diamond).supportsInterface(type(IERC5192).interfaceId));
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

    function testPhaseOneDeploysReusableHookWithoutLiquidityManager() public {
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
                positionCreationFeeAmount: 0
            }),
            DeployStaticsPhaseOne.V4Config({
                poolManager: address(poolManager),
                inputFeeBps: 25,
                outputFeeBps: 25,
                poolManagerCodeHash: address(poolManager).codehash
            })
        );

        StaticsSwapFeeHook hook = StaticsSwapFeeHook(payable(deployment.swapFeeHook));
        assertEq(hook.staticsDiamond(), deployment.diamond);
        assertEq(address(hook.poolManager()), address(poolManager));
        assertGt(deployment.permanentLiquidityMath.code.length, 0);

        vm.prank(address(timelock));
        IStaticsBasketLiquidity(deployment.diamond)
            .installCanonicalPoolIntegration(address(poolManager), deployment.swapFeeHook);
        (address configuredPoolManager, address configuredHook, bool installed) =
            IStaticsBasketLiquidity(deployment.diamond).liquidityIntegration();
        assertEq(configuredPoolManager, address(poolManager));
        assertEq(configuredHook, deployment.swapFeeHook);
        assertTrue(installed);

        IDiamondLoupe loupe = IDiamondLoupe(deployment.diamond);
        assertEq(loupe.facetAddress(IStaticsBasketLiquidity.installLiquidityManager.selector), address(0));
        assertEq(loupe.facetAddress(IStaticsProtocolPools.replaceLiquidityManager.selector), address(0));
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

        uint256 creatorRevenue = fixture.revenue.creatorRevenue(fixture.creator, rewardAssets[0])
            + fixture.revenue.creatorRevenue(fixture.creator, rewardAssets[1]);
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
            positionCreationFeeAmount: 0
        });

        vm.expectRevert(DeployStaticsPhaseOne.InvalidConfig.selector);
        deployer.deploy(config);

        config.weth = address(statics);
        config.guardian = address(0);
        vm.expectRevert(DeployStaticsPhaseOne.InvalidConfig.selector);
        deployer.deploy(config);
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
                positionCreationFeeAmount: 0
            })
        );
    }

    function _assertPhaseOneSelectors(address diamond) private view {
        IDiamondLoupe loupe = IDiamondLoupe(diamond);
        assertTrue(loupe.facetAddress(IStaticsGovernance.protocolPoolSwapsBlocked.selector) != address(0));
        assertTrue(loupe.facetAddress(IStaticsPosition.createPosition.selector) != address(0));
        assertTrue(loupe.facetAddress(IStaticsGlobalRewards.createAndStake.selector) != address(0));
        assertTrue(loupe.facetAddress(IStaticsCustody.stakingCustodyAccount.selector) != address(0));
        assertTrue(loupe.facetAddress(IStaticsBasketAdmin.setTreasury.selector) != address(0));
        assertTrue(loupe.facetAddress(IStaticsBasketLiquidity.installCanonicalPoolIntegration.selector) != address(0));
        assertTrue(loupe.facetAddress(IStaticsProtocolPools.createPool.selector) != address(0));
        assertTrue(loupe.facetAddress(IStaticsProtocolPools.setGeneralFeeAllocation.selector) != address(0));
        assertTrue(loupe.facetAddress(IStaticsProtocolRevenue.routeProtocolSwapFees.selector) != address(0));
    }

    function _assertDeferredSelectorsAbsent(address diamond) private view {
        IDiamondLoupe loupe = IDiamondLoupe(diamond);
        assertEq(loupe.facetAddress(IStaticsGovernance.quarantineBasket.selector), address(0));
        assertEq(loupe.facetAddress(IStaticsBasket.createBasket.selector), address(0));
        assertEq(loupe.facetAddress(IStaticsBasket.mint.selector), address(0));
        assertEq(loupe.facetAddress(IStaticsLending.borrow.selector), address(0));
        assertEq(loupe.facetAddress(IStaticsFlashLoan.flashLoan.selector), address(0));
        assertEq(loupe.facetAddress(IStaticsGenesisIntegration.linkGenesis.selector), address(0));
        assertEq(loupe.facetAddress(IStaticsBasketLiquidity.installLiquidityManager.selector), address(0));
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
                positionCreationFeeAmount: 0
            }),
            DeployStaticsPhaseOne.V4Config({
                poolManager: address(fixture.poolManager),
                inputFeeBps: 25,
                outputFeeBps: 25,
                poolManagerCodeHash: address(fixture.poolManager).codehash
            })
        );
        fixture.diamond = deployment.diamond;
        fixture.timelock = address(timelock);
        fixture.hook = StaticsSwapFeeHook(payable(deployment.swapFeeHook));
        fixture.pools = IStaticsProtocolPools(deployment.diamond);
        fixture.rewards = IStaticsGlobalRewards(deployment.diamond);
        fixture.revenue = IStaticsProtocolRevenue(deployment.diamond);
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
