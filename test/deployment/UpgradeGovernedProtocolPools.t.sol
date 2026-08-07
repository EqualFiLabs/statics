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

    function testRehearsesUpgradeAndGovernancePoolLaunchAgainstRobinhoodState() public {
        string memory rpcUrl = vm.envOr("ROBINHOOD_TESTNET", string(""));
        if (bytes(rpcUrl).length == 0) {
            if (vm.envOr("REQUIRE_ROBINHOOD_FORK", false)) fail("Robinhood fork required");
            return;
        }
        vm.createSelectFork(rpcUrl, PRE_UPGRADE_FORK_BLOCK);

        address diamond = vm.envAddress("STATICS_DIAMOND_ADDRESS");
        address proposer = vm.envAddress("STATICS_TIMELOCK_PROPOSER");
        StaticsTimelock timelock = StaticsTimelock(payable(IERC173(diamond).owner()));
        UpgradeGovernedProtocolPools ceremony = new UpgradeGovernedProtocolPools();
        UpgradeGovernedProtocolPools.UpgradeContracts memory contracts_ = _replacementContracts(diamond);

        IStaticsBasket.BasketView memory basket = IStaticsBasket(diamond).basket(0);
        bytes32[] memory canonicalStates = new bytes32[](basket.assets.length);
        uint128[] memory lockedLiquidity = new uint128[](basket.assets.length);
        (, address hook,) = IStaticsBasketLiquidity(diamond).liquidityIntegration();
        for (uint256 i; i < basket.assets.length; ++i) {
            IStaticsBasketLiquidity.CanonicalPoolView memory pool =
                IStaticsBasketLiquidity(diamond).canonicalPool(0, basket.assets[i]);
            canonicalStates[i] = keccak256(abi.encode(pool));
            lockedLiquidity[i] = IStaticsSwapFeeHook(hook).lockedLiquidity(pool.poolId);
        }

        bytes32 salt = keccak256("Robinhood governed protocol pools fork rehearsal");
        (address[] memory targets, uint256[] memory values, bytes[] memory payloads) =
            ceremony.buildBatch(diamond, contracts_);
        bytes32 operationId = timelock.hashOperationBatch(targets, values, payloads, bytes32(0), salt);
        uint256 delay = timelock.getMinDelay();
        vm.prank(proposer);
        timelock.scheduleBatch(targets, values, payloads, bytes32(0), salt, delay);
        vm.warp(block.timestamp + delay);
        (address oldManager,) = IStaticsBasketLiquidity(diamond).liquidityManager();
        timelock.executeBatch(targets, values, payloads, bytes32(0), salt);
        ceremony.validateUpgraded(diamond, contracts_, oldManager);
        assertTrue(timelock.isOperationDone(operationId));

        for (uint256 i; i < basket.assets.length; ++i) {
            IStaticsBasketLiquidity.CanonicalPoolView memory pool =
                IStaticsBasketLiquidity(diamond).canonicalPool(0, basket.assets[i]);
            assertEq(keccak256(abi.encode(pool)), canonicalStates[i]);
            assertEq(IStaticsSwapFeeHook(hook).lockedLiquidity(pool.poolId), lockedLiquidity[i]);
            IStaticsProtocolPools.ProtocolPoolView memory normalized =
                IStaticsProtocolPools(diamond).protocolPool(pool.poolId);
            assertEq(uint256(normalized.kind), uint256(IStaticsProtocolPools.ProtocolPoolKind.BasketCanonical));
            assertEq(normalized.basketId, 0);
            assertEq(normalized.basketAsset, basket.assets[i]);
        }

        _launchMockGovernancePool(diamond, proposer, timelock);
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

    function _launchMockGovernancePool(address diamond, address proposer, StaticsTimelock timelock) private {
        MockERC20 tokenA = new MockERC20("Governance Pool A", "GPA", 18);
        MockERC20 tokenB = new MockERC20("Governance Pool B", "GPB", 18);
        uint256 maxA = 10 ether;
        uint256 maxB = 10 ether;
        tokenA.mint(proposer, maxA);
        tokenB.mint(proposer, maxB);
        vm.startPrank(proposer);
        tokenA.approve(diamond, maxA);
        tokenB.approve(diamond, maxB);
        vm.stopPrank();

        IStaticsProtocolPools.CreateGovernancePoolParams memory params = IStaticsProtocolPools.CreateGovernancePoolParams({
            tokenA: address(tokenA),
            tokenB: address(tokenB),
            sqrtPriceBPerAX96: uint160(1 << 96),
            amountAMax: maxA,
            amountBMax: maxB,
            minLiquidity: 1,
            payer: proposer,
            deadline: block.timestamp + 1 days
        });
        (, bytes32 expectedPoolId,, uint128 quotedLiquidity, uint256 amountA, uint256 amountB) = _quote(diamond, params);
        bytes memory payload = abi.encodeCall(IStaticsProtocolPools.createGovernancePool, (params));
        bytes32 salt = keccak256("Robinhood mock governance pool fork launch");
        uint256 delay = timelock.getMinDelay();
        vm.prank(proposer);
        timelock.schedule(diamond, 0, payload, bytes32(0), salt, delay);
        vm.warp(block.timestamp + delay);
        timelock.execute(diamond, 0, payload, bytes32(0), salt);

        IStaticsProtocolPools.ProtocolPoolView memory pool =
            IStaticsProtocolPools(diamond).protocolPool(PoolId.wrap(expectedPoolId));
        assertEq(uint256(pool.kind), uint256(IStaticsProtocolPools.ProtocolPoolKind.Governance));
        assertEq(pool.permanentLiquidity, quotedLiquidity);
        assertEq(tokenA.balanceOf(proposer), maxA - amountA);
        assertEq(tokenB.balanceOf(proposer), maxB - amountB);
        assertEq(tokenA.allowance(proposer, diamond), maxA - amountA);
        assertEq(tokenB.allowance(proposer, diamond), maxB - amountB);
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
        PoolId typedPoolId;
        (key, typedPoolId, sqrtPriceX96, liquidity, amountA, amountB) =
            IStaticsProtocolPools(diamond).quoteGovernancePool(params);
        poolId = PoolId.unwrap(typedPoolId);
    }
}
