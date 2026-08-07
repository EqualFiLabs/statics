// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
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
import {IStaticsBasketLiquidity} from "../../src/interfaces/IStaticsBasketLiquidity.sol";
import {IStaticsProtocolPools} from "../../src/interfaces/IStaticsProtocolPools.sol";
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
