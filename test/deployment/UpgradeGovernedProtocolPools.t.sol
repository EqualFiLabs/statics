// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Test} from "forge-std/Test.sol";

import {DeployStatics} from "../../script/DeployStatics.s.sol";
import {UpgradeGovernedProtocolPools} from "../../script/UpgradeGovernedProtocolPools.s.sol";
import {StaticsDollarStackDeployment} from "../../script/dollar/DeployStaticsDollar.s.sol";
import {StaticsInterfaceInit} from "../../src/diamond/StaticsInterfaceInit.sol";
import {BasketLiquidityFacet} from "../../src/facets/BasketLiquidityFacet.sol";
import {BorrowLiquidityFacet} from "../../src/facets/BorrowLiquidityFacet.sol";
import {LiquidityRewardsFacet} from "../../src/facets/LiquidityRewardsFacet.sol";
import {ProtocolPoolFacet} from "../../src/facets/ProtocolPoolFacet.sol";
import {StaticsTimelock} from "../../src/governance/StaticsTimelock.sol";
import {IDiamondCut} from "../../src/interfaces/IDiamondCut.sol";
import {IDiamondLoupe} from "../../src/interfaces/IDiamondLoupe.sol";
import {IERC173} from "../../src/interfaces/IERC173.sol";
import {IStaticsBasket} from "../../src/interfaces/IStaticsBasket.sol";
import {IStaticsBasketLiquidity} from "../../src/interfaces/IStaticsBasketLiquidity.sol";
import {IStaticsLiquidityManager} from "../../src/interfaces/IStaticsLiquidityManager.sol";
import {IStaticsProtocolPools} from "../../src/interfaces/IStaticsProtocolPools.sol";
import {IStaticsSwapFeeHook} from "../../src/interfaces/IStaticsSwapFeeHook.sol";
import {StaticsSelectors} from "../../src/libraries/StaticsSelectors.sol";
import {StaticsLiquidityManager} from "../../src/liquidity/StaticsLiquidityManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

contract UpgradeGovernedProtocolPoolsTest is Test {
    UpgradeGovernedProtocolPools private ceremony;
    StaticsTimelock private timelock;
    StaticsDollarStackDeployment private deployment;

    function setUp() public {
        ceremony = new UpgradeGovernedProtocolPools();
        MockERC20 stakingToken = new MockERC20("Statics", "STAT", 18);
        DeployStatics deployer = new DeployStatics();
        (deployment, timelock) = deployer.deployWithLiquidity(
            DeployStatics.Config({
                multisig: address(ceremony),
                guardian: makeAddr("guardian"),
                treasury: makeAddr("treasury"),
                stakingToken: address(stakingToken),
                creationFeeAmount: 0,
                positionCreationFeeAmount: 0
            }),
            _v4Config()
        );

        vm.startPrank(address(timelock));
        IStaticsBasketLiquidity(deployment.diamond)
            .installCanonicalPoolIntegration(deployment.poolManager, deployment.swapFeeHook);
        IStaticsBasketLiquidity(deployment.diamond).installLiquidityManager(deployment.liquidityManager);
        _removeProtocolPoolSurface();
        vm.stopPrank();
        assertFalse(IERC165(deployment.diamond).supportsInterface(type(IStaticsProtocolPools).interfaceId));
    }

    function testTimelockBatchReplacesFacetsAndRotatesManagerAtomically() public {
        UpgradeGovernedProtocolPools.UpgradeContracts memory contracts_ = _replacementContracts();
        bytes32 salt = keccak256("governed protocol pools test");
        address oldManager = deployment.liquidityManager;

        bytes32 operationId = ceremony.schedule(deployment.diamond, contracts_, salt);
        assertTrue(timelock.isOperationPending(operationId));
        vm.expectRevert(
            abi.encodeWithSelector(UpgradeGovernedProtocolPools.UpgradeOperationNotReady.selector, operationId)
        );
        ceremony.execute(deployment.diamond, contracts_, salt);

        vm.warp(block.timestamp + timelock.getMinDelay());
        ceremony.execute(deployment.diamond, contracts_, salt);

        assertTrue(timelock.isOperationDone(operationId));
        assertTrue(IERC165(deployment.diamond).supportsInterface(type(IStaticsProtocolPools).interfaceId));
        (address manager, bool installed) = IStaticsBasketLiquidity(deployment.diamond).liquidityManager();
        assertTrue(installed);
        assertEq(manager, contracts_.liquidityManager);
        ceremony.validateUpgraded(deployment.diamond, contracts_, oldManager);
    }

    function testBatchIsAllOrNothingWhenManagerBindingIsInvalid() public {
        UpgradeGovernedProtocolPools.UpgradeContracts memory contracts_ = _replacementContracts();
        address wrongDiamond = makeAddr("wrongDiamond");
        contracts_.liquidityManager = address(
            new StaticsLiquidityManager(
                wrongDiamond, deployment.positionManager, deployment.poolManager, deployment.permit2
            )
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                UpgradeGovernedProtocolPools.InvalidManagerBinding.selector,
                contracts_.liquidityManager,
                deployment.diamond,
                wrongDiamond
            )
        );
        ceremony.schedule(deployment.diamond, contracts_, keccak256("invalid manager"));

        assertEq(
            IDiamondLoupe(deployment.diamond).facetAddress(IStaticsProtocolPools.protocolPool.selector), address(0)
        );
        (address manager,) = IStaticsBasketLiquidity(deployment.diamond).liquidityManager();
        assertEq(manager, deployment.liquidityManager);
    }

    function _removeProtocolPoolSurface() private {
        IDiamondCut.FacetCut[] memory cut = new IDiamondCut.FacetCut[](1);
        cut[0] = IDiamondCut.FacetCut({
            facetAddress: address(0),
            action: IDiamondCut.FacetCutAction.Remove,
            functionSelectors: StaticsSelectors.protocolPools()
        });
        bytes4[] memory interfaceIds = new bytes4[](1);
        interfaceIds[0] = type(IStaticsProtocolPools).interfaceId;
        bool[] memory supported = new bool[](1);
        IDiamondCut(deployment.diamond)
            .diamondCut(
                cut, deployment.diamond, abi.encodeCall(StaticsInterfaceInit.setInterfaces, (interfaceIds, supported))
            );
    }

    function _replacementContracts() private returns (UpgradeGovernedProtocolPools.UpgradeContracts memory contracts_) {
        contracts_ = UpgradeGovernedProtocolPools.UpgradeContracts({
            basketLiquidityFacet: address(new BasketLiquidityFacet()),
            borrowLiquidityFacet: address(new BorrowLiquidityFacet()),
            liquidityRewardsFacet: address(new LiquidityRewardsFacet()),
            protocolPoolFacet: address(new ProtocolPoolFacet()),
            liquidityManager: address(
                new StaticsLiquidityManager(
                    deployment.diamond, deployment.positionManager, deployment.poolManager, deployment.permit2
                )
            )
        });
    }

    function _v4Config() private returns (DeployStatics.V4Config memory config) {
        IPoolManager poolManager =
            IPoolManager(deployCode("out/PoolManager.sol/PoolManager.json", abi.encode(address(this))));
        IAllowanceTransfer permit2 = IAllowanceTransfer(deployCode("out/Permit2.sol/Permit2.json"));
        IPositionManager positionManager = IPositionManager(
            deployCode(
                "out/PositionManager.sol/PositionManager.json",
                abi.encode(address(poolManager), address(permit2), uint256(100_000), address(0), address(0))
            )
        );
        config = DeployStatics.V4Config({
            poolManager: address(poolManager),
            positionManager: address(positionManager),
            permit2: address(permit2),
            inputFeeBps: 30,
            outputFeeBps: 30,
            poolManagerCodeHash: address(poolManager).codehash,
            positionManagerCodeHash: address(positionManager).codehash,
            permit2CodeHash: address(permit2).codehash
        });
    }
}

contract RobinhoodGovernedProtocolPoolsUpgradeForkTest is Test {
    uint256 private constant PRE_UPGRADE_FORK_BLOCK = 97_818_311;

    struct UpgradeRehearsal {
        address diamond;
        address proposer;
        StaticsTimelock timelock;
        UpgradeGovernedProtocolPools ceremony;
        UpgradeGovernedProtocolPools.UpgradeContracts contracts;
        IStaticsBasket.BasketView basket;
        bytes32[] canonicalStates;
        uint128[] lockedLiquidity;
        address hook;
    }

    function testRehearsesUpgradeAndGovernancePoolLaunchAgainstRobinhoodState() public {
        string memory rpcUrl = vm.envOr("ROBINHOOD_TESTNET", string(""));
        if (bytes(rpcUrl).length == 0) {
            if (vm.envOr("REQUIRE_ROBINHOOD_FORK", false)) fail("Robinhood fork required");
            return;
        }
        vm.createSelectFork(rpcUrl, PRE_UPGRADE_FORK_BLOCK);

        UpgradeRehearsal memory rehearsal = _snapshotPreUpgradeState();
        _executeUpgrade(rehearsal);
        _assertCanonicalPoolsPreserved(rehearsal);
        _launchMockGovernancePool(rehearsal.diamond, rehearsal.proposer, rehearsal.timelock);
    }

    function _snapshotPreUpgradeState() private returns (UpgradeRehearsal memory rehearsal) {
        rehearsal.diamond = vm.envAddress("STATICS_DIAMOND_ADDRESS");
        rehearsal.proposer = vm.envAddress("STATICS_TIMELOCK_PROPOSER");
        rehearsal.timelock = StaticsTimelock(payable(IERC173(rehearsal.diamond).owner()));
        rehearsal.ceremony = new UpgradeGovernedProtocolPools();
        rehearsal.contracts = _replacementContracts(rehearsal.diamond);

        rehearsal.basket = IStaticsBasket(rehearsal.diamond).basket(0);
        uint256 assetCount = rehearsal.basket.assets.length;
        rehearsal.canonicalStates = new bytes32[](assetCount);
        rehearsal.lockedLiquidity = new uint128[](assetCount);
        (, rehearsal.hook,) = IStaticsBasketLiquidity(rehearsal.diamond).liquidityIntegration();
        for (uint256 i; i < assetCount; ++i) {
            IStaticsBasketLiquidity.CanonicalPoolView memory pool =
                IStaticsBasketLiquidity(rehearsal.diamond).canonicalPool(0, rehearsal.basket.assets[i]);
            rehearsal.canonicalStates[i] = keccak256(abi.encode(pool));
            rehearsal.lockedLiquidity[i] = IStaticsSwapFeeHook(rehearsal.hook).lockedLiquidity(pool.poolId);
        }
    }

    function _executeUpgrade(UpgradeRehearsal memory rehearsal) private {
        bytes32 salt = keccak256("Robinhood governed protocol pools fork rehearsal");
        (address[] memory targets, uint256[] memory values, bytes[] memory payloads) =
            rehearsal.ceremony.buildBatch(rehearsal.diamond, rehearsal.contracts);
        bytes32 operationId =
            rehearsal.timelock.hashOperationBatch(targets, values, payloads, bytes32(0), salt);
        uint256 delay = rehearsal.timelock.getMinDelay();
        vm.prank(rehearsal.proposer);
        rehearsal.timelock.scheduleBatch(targets, values, payloads, bytes32(0), salt, delay);
        vm.warp(block.timestamp + delay);
        (address oldManager,) = IStaticsBasketLiquidity(rehearsal.diamond).liquidityManager();
        rehearsal.timelock.executeBatch(targets, values, payloads, bytes32(0), salt);
        rehearsal.ceremony.validateUpgraded(rehearsal.diamond, rehearsal.contracts, oldManager);
        assertTrue(rehearsal.timelock.isOperationDone(operationId));
    }

    function _assertCanonicalPoolsPreserved(UpgradeRehearsal memory rehearsal) private view {
        for (uint256 i; i < rehearsal.basket.assets.length; ++i) {
            IStaticsBasketLiquidity.CanonicalPoolView memory pool =
                IStaticsBasketLiquidity(rehearsal.diamond).canonicalPool(0, rehearsal.basket.assets[i]);
            assertEq(keccak256(abi.encode(pool)), rehearsal.canonicalStates[i]);
            assertEq(IStaticsSwapFeeHook(rehearsal.hook).lockedLiquidity(pool.poolId), rehearsal.lockedLiquidity[i]);
            IStaticsProtocolPools.ProtocolPoolView memory normalized =
                IStaticsProtocolPools(rehearsal.diamond).protocolPool(pool.poolId);
            assertEq(uint256(normalized.kind), uint256(IStaticsProtocolPools.ProtocolPoolKind.BasketCanonical));
            assertEq(normalized.basketId, 0);
            assertEq(normalized.basketAsset, rehearsal.basket.assets[i]);
        }
    }

    function _replacementContracts(address diamond)
        private
        returns (UpgradeGovernedProtocolPools.UpgradeContracts memory contracts_)
    {
        (address poolManager,,) = IStaticsBasketLiquidity(diamond).liquidityIntegration();
        (address oldManager,) = IStaticsBasketLiquidity(diamond).liquidityManager();
        IStaticsLiquidityManager oldBinding = IStaticsLiquidityManager(oldManager);
        contracts_ = UpgradeGovernedProtocolPools.UpgradeContracts({
            basketLiquidityFacet: address(new BasketLiquidityFacet()),
            borrowLiquidityFacet: address(new BorrowLiquidityFacet()),
            liquidityRewardsFacet: address(new LiquidityRewardsFacet()),
            protocolPoolFacet: address(new ProtocolPoolFacet()),
            liquidityManager: address(
                new StaticsLiquidityManager(diamond, oldBinding.positionManager(), poolManager, oldBinding.permit2())
            )
        });
    }

    struct MockPoolLaunch {
        MockERC20 tokenA;
        MockERC20 tokenB;
        uint256 maxA;
        uint256 maxB;
        uint256 amountA;
        uint256 amountB;
        uint128 quotedLiquidity;
        bytes32 poolId;
    }

    function _launchMockGovernancePool(address diamond, address proposer, StaticsTimelock timelock) private {
        MockPoolLaunch memory launch = _scheduleMockPool(diamond, proposer, timelock);
        _assertMockPool(diamond, proposer, launch);
    }

    function _scheduleMockPool(address diamond, address proposer, StaticsTimelock timelock)
        private
        returns (MockPoolLaunch memory launch)
    {
        launch.tokenA = new MockERC20("Governance Pool A", "GPA", 18);
        launch.tokenB = new MockERC20("Governance Pool B", "GPB", 18);
        launch.maxA = 10 ether;
        launch.maxB = 10 ether;
        launch.tokenA.mint(proposer, launch.maxA);
        launch.tokenB.mint(proposer, launch.maxB);
        vm.startPrank(proposer);
        launch.tokenA.approve(diamond, launch.maxA);
        launch.tokenB.approve(diamond, launch.maxB);
        vm.stopPrank();

        IStaticsProtocolPools.CreateGovernancePoolParams memory params = IStaticsProtocolPools.CreateGovernancePoolParams({
            tokenA: address(launch.tokenA),
            tokenB: address(launch.tokenB),
            sqrtPriceBPerAX96: uint160(1 << 96),
            amountAMax: launch.maxA,
            amountBMax: launch.maxB,
            minLiquidity: 1,
            payer: proposer,
            deadline: block.timestamp + 1 days
        });
        (, launch.poolId,, launch.quotedLiquidity, launch.amountA, launch.amountB) = _quote(diamond, params);
        bytes memory payload = abi.encodeCall(IStaticsProtocolPools.createGovernancePool, (params));
        bytes32 salt = keccak256("Robinhood mock governance pool fork launch");
        uint256 delay = timelock.getMinDelay();
        vm.prank(proposer);
        timelock.schedule(diamond, 0, payload, bytes32(0), salt, delay);
        vm.warp(block.timestamp + delay);
        timelock.execute(diamond, 0, payload, bytes32(0), salt);
    }

    function _assertMockPool(address diamond, address proposer, MockPoolLaunch memory launch) private view {
        IStaticsProtocolPools.ProtocolPoolView memory pool =
            IStaticsProtocolPools(diamond).protocolPool(PoolId.wrap(launch.poolId));
        assertEq(uint256(pool.kind), uint256(IStaticsProtocolPools.ProtocolPoolKind.Governance));
        assertEq(pool.permanentLiquidity, launch.quotedLiquidity);
        assertEq(launch.tokenA.balanceOf(proposer), launch.maxA - launch.amountA);
        assertEq(launch.tokenB.balanceOf(proposer), launch.maxB - launch.amountB);
        assertEq(launch.tokenA.allowance(proposer, diamond), launch.maxA - launch.amountA);
        assertEq(launch.tokenB.allowance(proposer, diamond), launch.maxB - launch.amountB);
    }

    function _quote(address diamond, IStaticsProtocolPools.CreateGovernancePoolParams memory params)
        private
        view
        returns (
            PoolKey memory key,
            bytes32 poolId,
            uint160 sqrtPriceX96,
            uint128 liquidity,
            uint256 amountA,
            uint256 amountB
        )
    {
        IStaticsProtocolPools.GovernancePoolQuote memory quote =
            IStaticsProtocolPools(diamond).quoteGovernancePool(params);
        key = quote.key;
        poolId = PoolId.unwrap(quote.poolId);
        sqrtPriceX96 = quote.sqrtPriceX96;
        liquidity = quote.liquidity;
        amountA = quote.amountA;
        amountB = quote.amountB;
    }
}
