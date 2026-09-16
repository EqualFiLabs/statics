// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {IERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {DeployStaticsPhaseOne, StaticsPhaseOneDeployment} from "../../script/DeployStaticsPhaseOne.s.sol";
import {StakingFacet} from "../../src/dollar/periphery/facets/StakingFacet.sol";
import {IStaticsDollarGateway} from "../../src/dollar/interfaces/IStaticsDollarGateway.sol";
import {IStaticsDollarRiskIncentives} from "../../src/dollar/interfaces/IStaticsDollarRiskIncentives.sol";
import {IStaticsDollarRiskLiquidity} from "../../src/dollar/interfaces/IStaticsDollarRiskLiquidity.sol";
import {IStaticsDollarSeriesMigration} from "../../src/dollar/interfaces/IStaticsDollarSeriesMigration.sol";
import {IERC173} from "../../src/interfaces/IERC173.sol";
import {IDiamondLoupe} from "../../src/interfaces/IDiamondLoupe.sol";
import {IModularPositionNFT} from "../../src/interfaces/IModularPositionNFT.sol";
import {IStaticsBasket} from "../../src/interfaces/IStaticsBasket.sol";
import {IStaticsBasketAdmin} from "../../src/interfaces/IStaticsBasketAdmin.sol";
import {IStaticsBorrowLiquidity} from "../../src/interfaces/IStaticsBorrowLiquidity.sol";
import {IStaticsFlashLoan} from "../../src/interfaces/IStaticsFlashLoan.sol";
import {IStaticsGenesisIntegration} from "../../src/interfaces/IStaticsGenesisIntegration.sol";
import {IStaticsGlobalRewards} from "../../src/interfaces/IStaticsGlobalRewards.sol";
import {IStaticsGovernance} from "../../src/interfaces/IStaticsGovernance.sol";
import {IStaticsMorpho} from "../../src/interfaces/IStaticsMorpho.sol";
import {IStaticsPosition, IStaticsPositionFees} from "../../src/interfaces/IStaticsPosition.sol";
import {IStaticsProtocolPools} from "../../src/interfaces/IStaticsProtocolPools.sol";
import {StaticsTimelock} from "../../src/governance/StaticsTimelock.sol";
import {StaticsLiquidityManager} from "../../src/liquidity/StaticsLiquidityManager.sol";
import {StaticsSwapFeeHook} from "../../src/liquidity/StaticsSwapFeeHook.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

contract PhaseOneV4DependencyMock {}

contract PhaseOnePositionManagerMock {
    address public immutable poolManager;
    address public immutable permit2;

    constructor(address poolManager_, address permit2_) {
        poolManager = poolManager_;
        permit2 = permit2_;
    }
}

contract DeployStaticsPhaseOneTest is Test {
    function testLaunchInstallsOnlyPhaseOneBehindTimelock() public {
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
                singleAssetFlashFeeBps: 5
            })
        );
        address diamond = deployment.diamond;

        assertEq(deployment.positionNFT, diamond);
        assertEq(deployment.weth, address(weth));
        assertEq(IERC173(diamond).owner(), address(timelock));
        assertEq(IStaticsGovernance(diamond).guardian(), guardian);
        assertEq(IStaticsBasketAdmin(diamond).treasury(), treasury);
        assertEq(IStaticsBasketAdmin(diamond).creationFee(), 0);
        assertEq(IStaticsProtocolPools(diamond).poolCreationFee(), 0);
        assertEq(IStaticsPositionFees(diamond).positionCreationFee(), 0.001 ether);
        assertEq(IStaticsFlashLoan(diamond).singleAssetFlashFeeBps(), 5);
        assertTrue(timelock.hasRole(timelock.PROPOSER_ROLE(), multisig));
        assertTrue(timelock.hasRole(timelock.CANCELLER_ROLE(), guardian));
        assertTrue(timelock.hasRole(timelock.EXECUTOR_ROLE(), address(0)));
        assertFalse(timelock.hasRole(timelock.PROPOSER_ROLE(), guardian));

        _assertManifest(diamond, 25, 204);
        assertTrue(IERC165(diamond).supportsInterface(type(IStaticsBasket).interfaceId));
        assertTrue(IERC165(diamond).supportsInterface(type(IStaticsGlobalRewards).interfaceId));
        assertTrue(IERC165(diamond).supportsInterface(type(IStaticsFlashLoan).interfaceId));
        assertTrue(IERC165(diamond).supportsInterface(type(IStaticsGenesisIntegration).interfaceId));
        assertFalse(IERC165(diamond).supportsInterface(type(IStaticsBorrowLiquidity).interfaceId));
        assertFalse(IERC165(diamond).supportsInterface(type(IStaticsMorpho).interfaceId));
        assertFalse(IERC165(diamond).supportsInterface(type(IStaticsDollarGateway).interfaceId));
        assertFalse(IERC165(diamond).supportsInterface(type(IStaticsDollarRiskLiquidity).interfaceId));
        assertFalse(IERC165(diamond).supportsInterface(type(IStaticsDollarRiskIncentives).interfaceId));
        assertFalse(IERC165(diamond).supportsInterface(type(IStaticsDollarSeriesMigration).interfaceId));
        assertFalse(IERC165(diamond).supportsInterface(type(IERC1155Receiver).interfaceId));

        IDiamondLoupe loupe = IDiamondLoupe(diamond);
        assertEq(loupe.facetAddress(IStaticsBorrowLiquidity.borrowAndProvideLiquidity.selector), address(0));
        assertEq(loupe.facetAddress(IStaticsMorpho.deployMorphoCollateral.selector), address(0));
        assertEq(loupe.facetAddress(IStaticsDollarGateway.depositETH.selector), address(0));
        assertEq(loupe.facetAddress(IStaticsDollarSeriesMigration.processSeriesTransition.selector), address(0));
        assertEq(loupe.facetAddress(StakingFacet.createAndStakeRiskShares.selector), address(0));
    }

    function testPhaseOnePositionsCloseWithoutMorphoFacets() public {
        (StaticsPhaseOneDeployment memory deployment,) = _deployDefault(makeAddr("multisig"), makeAddr("guardian"));
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
        (StaticsPhaseOneDeployment memory deployment, StaticsTimelock timelock) =
            _deployDefault(governanceSafe, governanceSafe);

        assertEq(IStaticsGovernance(deployment.diamond).guardian(), governanceSafe);
        assertTrue(timelock.hasRole(timelock.PROPOSER_ROLE(), governanceSafe));
        assertTrue(timelock.hasRole(timelock.CANCELLER_ROLE(), governanceSafe));
    }

    function testPhaseOneDeploysCanonicalLiquidityDependencies() public {
        DeployStaticsPhaseOne deployer = new DeployStaticsPhaseOne();
        MockERC20 statics = new MockERC20("Statics", "STATICS", 18);
        MockERC20 weth = new MockERC20("Wrapped Ether", "WETH", 18);
        PhaseOneV4DependencyMock poolManager = new PhaseOneV4DependencyMock();
        PhaseOneV4DependencyMock permit2 = new PhaseOneV4DependencyMock();
        PhaseOnePositionManagerMock positionManager =
            new PhaseOnePositionManagerMock(address(poolManager), address(permit2));

        (StaticsPhaseOneDeployment memory deployment,) = deployer.deployWithLiquidity(
            DeployStaticsPhaseOne.Config({
                multisig: makeAddr("multisig"),
                guardian: makeAddr("guardian"),
                treasury: makeAddr("treasury"),
                stakingToken: address(statics),
                weth: address(weth),
                positionCreationFeeAmount: 0,
                singleAssetFlashFeeBps: 5
            }),
            DeployStaticsPhaseOne.V4Config({
                poolManager: address(poolManager),
                positionManager: address(positionManager),
                permit2: address(permit2),
                inputFeeBps: 25,
                outputFeeBps: 25,
                poolManagerCodeHash: address(poolManager).codehash,
                positionManagerCodeHash: address(positionManager).codehash,
                permit2CodeHash: address(permit2).codehash
            })
        );

        assertEq(StaticsSwapFeeHook(payable(deployment.swapFeeHook)).staticsDiamond(), deployment.diamond);
        assertEq(address(StaticsSwapFeeHook(payable(deployment.swapFeeHook)).poolManager()), address(poolManager));
        assertEq(StaticsLiquidityManager(deployment.liquidityManager).staticsDiamond(), deployment.diamond);
        assertEq(StaticsLiquidityManager(deployment.liquidityManager).positionManager(), address(positionManager));
        assertGt(deployment.permanentLiquidityMath.code.length, 0);
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
            singleAssetFlashFeeBps: 5
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
        returns (StaticsPhaseOneDeployment memory deployment, StaticsTimelock timelock)
    {
        DeployStaticsPhaseOne deployer = new DeployStaticsPhaseOne();
        MockERC20 statics = new MockERC20("Statics", "STATICS", 18);
        MockERC20 weth = new MockERC20("Wrapped Ether", "WETH", 18);
        return deployer.deploy(
            DeployStaticsPhaseOne.Config({
                multisig: multisig,
                guardian: guardian,
                treasury: makeAddr("treasury"),
                stakingToken: address(statics),
                weth: address(weth),
                positionCreationFeeAmount: 0,
                singleAssetFlashFeeBps: 5
            })
        );
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
}
