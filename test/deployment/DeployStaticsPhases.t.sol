// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {Test} from "forge-std/Test.sol";

import {
    DeployStaticsPhases,
    PhaseFourDeployment,
    PhaseThreeDeployment,
    PhaseTwoDeployment
} from "../../script/DeployStaticsPhases.s.sol";
import {DeployStaticsPhaseOne, StaticsPhaseOneDeployment} from "../../script/DeployStaticsPhaseOne.s.sol";
import {
    CoreBootstrapConfig,
    CoreBootstrapDeployment,
    DeployCoreBootstrap
} from "../../script/dollar/DeployCoreBootstrap.s.sol";
import {StaticsProtocolParts, StaticsProtocolPlan} from "../../script/libraries/StaticsProtocolPlan.sol";
import {IStaticsDollarGateway} from "../../src/dollar/interfaces/IStaticsDollarGateway.sol";
import {CoreViewFacet} from "../../src/dollar/core/facets/CoreViewFacet.sol";
import {StaticsPhaseTwoInit} from "../../src/diamond/StaticsPhaseTwoInit.sol";
import {GlobalRewardsFacet} from "../../src/facets/GlobalRewardsFacet.sol";
import {IDiamondCut} from "../../src/interfaces/IDiamondCut.sol";
import {IDiamondLoupe} from "../../src/interfaces/IDiamondLoupe.sol";
import {IStaticsBasket} from "../../src/interfaces/IStaticsBasket.sol";
import {IStaticsBasketAdmin} from "../../src/interfaces/IStaticsBasketAdmin.sol";
import {IStaticsBasketLiquidity} from "../../src/interfaces/IStaticsBasketLiquidity.sol";
import {IStaticsCustody} from "../../src/interfaces/IStaticsCustody.sol";
import {IStaticsFlashLoan} from "../../src/interfaces/IStaticsFlashLoan.sol";
import {IStaticsGlobalRewards} from "../../src/interfaces/IStaticsGlobalRewards.sol";
import {IStaticsGovernance} from "../../src/interfaces/IStaticsGovernance.sol";
import {IStaticsMorpho} from "../../src/interfaces/IStaticsMorpho.sol";
import {IStaticsPositionPortfolio} from "../../src/interfaces/IStaticsPositionPortfolio.sol";
import {IStaticsPermissionedPools} from "../../src/interfaces/IStaticsPermissionedPools.sol";
import {StaticsTimelock} from "../../src/governance/StaticsTimelock.sol";
import {LibDeploymentPhases} from "../../src/libraries/LibDeploymentPhases.sol";
import {MockETHUSDOracle} from "../../src/dollar/mocks/MockETHUSDOracle.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

contract StagedDependencyMock {}

contract StagedPositionManagerMock {
    address public immutable poolManager;
    address public immutable permit2;

    constructor(address poolManager_, address permit2_) {
        poolManager = poolManager_;
        permit2 = permit2_;
    }
}

contract StagedPermissionedClaimsMock {
    address public immutable poolManager;
    address public immutable permissionedHook;
    address public positionManager;

    constructor(address manager, address hook) {
        poolManager = manager;
        permissionedHook = hook;
    }

    function bindPositionManager(address manager) external {
        require(positionManager == address(0));
        positionManager = manager;
    }
}

contract StagedPermissionedPeripheryMock {
    address public immutable poolManager;
    address public immutable permit2;
    address public immutable permissionedHook;
    address public immutable positionClaims;

    constructor(address manager, address permit, address hook, address claims) {
        poolManager = manager;
        permit2 = permit;
        permissionedHook = hook;
        positionClaims = claims;
    }
}

contract StagedQuoterMock {
    address public immutable poolManager;

    constructor(address manager) {
        poolManager = manager;
    }
}

contract DeployStaticsPhasesTest is Test {
    uint256 private constant PHASE_ONE_SELECTORS = 122;
    uint256 private constant PHASE_TWO_SELECTORS = 218;
    uint256 private constant PHASE_THREE_SELECTORS = 276;
    uint256 private constant PHASE_FOUR_SELECTORS = 303;
    bytes32 private constant PHASE_STORAGE_POSITION = keccak256("statics.storage.deployment.phases.v1");

    struct Fixture {
        DeployStaticsPhases phases;
        StaticsPhaseOneDeployment phaseOne;
        StaticsTimelock timelock;
        MockERC20 statics;
        MockERC20 weth;
        StagedDependencyMock poolManager;
        StagedPositionManagerMock positionManager;
        StagedDependencyMock permit2;
        StagedPermissionedPeripheryMock permissionedRouter;
        StagedPermissionedPeripheryMock permissionedPositionManager;
        StagedPermissionedClaimsMock permissionedPositionClaims;
        StagedQuoterMock permissionedQuoter;
    }

    function testCanonicalPlanPartitionsEverySelectorExactlyOnce() public pure {
        StaticsProtocolParts memory parts;
        IDiamondCut.FacetCut[] memory one = StaticsProtocolPlan.phaseOne(parts);
        IDiamondCut.FacetCut[] memory two = StaticsProtocolPlan.phaseTwo(parts);
        IDiamondCut.FacetCut[] memory three = StaticsProtocolPlan.phaseThree(parts);
        IDiamondCut.FacetCut[] memory four = StaticsProtocolPlan.phaseFour(parts);
        IDiamondCut.FacetCut[] memory complete = StaticsProtocolPlan.cumulative(parts, 4);

        assertEq(StaticsProtocolPlan.selectorCount(one), PHASE_ONE_SELECTORS);
        assertEq(StaticsProtocolPlan.selectorCount(two), PHASE_TWO_SELECTORS - PHASE_ONE_SELECTORS);
        assertEq(StaticsProtocolPlan.selectorCount(three), PHASE_THREE_SELECTORS - PHASE_TWO_SELECTORS);
        assertEq(StaticsProtocolPlan.selectorCount(four), PHASE_FOUR_SELECTORS - PHASE_THREE_SELECTORS);
        assertEq(StaticsProtocolPlan.selectorCount(complete), PHASE_FOUR_SELECTORS);

        bytes4[] memory selectors = _cutSelectors(complete);
        _sort(selectors);
        for (uint256 i = 1; i < selectors.length; ++i) {
            assertNotEq(selectors[i - 1], selectors[i], "selector assigned to multiple phases");
        }
    }

    function testStagedDeploymentReachesFreshDeploymentParity() public {
        Fixture memory fixture = _phaseOneFixture();
        address diamond = fixture.phaseOne.diamond;
        _assertManifest(diamond, 18, PHASE_ONE_SELECTORS);
        assertEq(_activePhase(diamond), 1);

        DeployStaticsPhases.PhaseTwoConfig memory phaseTwoConfig = _phaseTwoConfig(fixture, 0.01 ether);
        PhaseTwoDeployment memory phaseTwo = fixture.phases.deployPhaseTwo(phaseTwoConfig);
        (address[] memory targets, uint256[] memory values, bytes[] memory payloads) =
            fixture.phases.buildPhaseTwoBatch(diamond, phaseTwo, phaseTwoConfig);
        _executeThroughTimelock(fixture.timelock, targets, values, payloads, keccak256("phase two"));

        _assertManifest(diamond, 30, PHASE_TWO_SELECTORS);
        assertEq(_activePhase(diamond), 2);
        assertEq(IStaticsBasketAdmin(diamond).creationFee(), 0.01 ether);
        assertEq(IStaticsFlashLoan(diamond).singleAssetFlashFeeBps(), 5);
        (, bool managerInstalled) = IStaticsBasketLiquidity(diamond).liquidityManager();
        assertTrue(managerInstalled);
        assertTrue(IERC165(diamond).supportsInterface(type(IStaticsGovernance).interfaceId));
        assertTrue(IERC165(diamond).supportsInterface(type(IStaticsBasket).interfaceId));
        assertFalse(IERC165(diamond).supportsInterface(type(IStaticsCustody).interfaceId));
        assertFalse(IERC165(diamond).supportsInterface(type(IStaticsDollarGateway).interfaceId));
        assertFalse(IERC165(diamond).supportsInterface(type(IStaticsPositionPortfolio).interfaceId));
        assertFalse(IERC165(diamond).supportsInterface(type(IStaticsMorpho).interfaceId));

        PhaseThreeDeployment memory phaseThree = fixture.phases
            .deployPhaseThree(_phaseThreeConfig(fixture, diamond, address(new MockETHUSDOracle(2_500e18, 30 days))));
        (targets, values, payloads) = fixture.phases.buildPhaseThreeBatch(diamond, phaseThree);
        _executeThroughTimelock(fixture.timelock, targets, values, payloads, keccak256("phase three"));

        _assertManifest(diamond, 35, PHASE_THREE_SELECTORS);
        assertEq(_activePhase(diamond), 3);
        assertTrue(IERC165(diamond).supportsInterface(type(IStaticsCustody).interfaceId));
        assertTrue(IERC165(diamond).supportsInterface(type(IStaticsDollarGateway).interfaceId));
        assertFalse(IERC165(diamond).supportsInterface(type(IStaticsPositionPortfolio).interfaceId));
        assertFalse(IERC165(diamond).supportsInterface(type(IStaticsMorpho).interfaceId));
        assertEq(IStaticsDollarGateway(diamond).pool(), phaseThree.core);
        assertEq(CoreViewFacet(phaseThree.core).periphery(), diamond);
        assertEq(CoreViewFacet(phaseThree.core).positionNFT(), diamond);

        PhaseFourDeployment memory phaseFour = fixture.phases.deployPhaseFour(diamond);
        (targets, values, payloads) = fixture.phases.buildPhaseFourBatch(diamond, phaseFour);
        _executeThroughTimelock(fixture.timelock, targets, values, payloads, keccak256("phase four"));

        _assertManifest(diamond, 40, PHASE_FOUR_SELECTORS);
        assertEq(_activePhase(diamond), 4);
        assertTrue(IERC165(diamond).supportsInterface(type(IStaticsPositionPortfolio).interfaceId));
        assertTrue(IERC165(diamond).supportsInterface(type(IStaticsMorpho).interfaceId));

        StagedDependencyMock morpho = new StagedDependencyMock();
        MockERC20 usdStx = new MockERC20("Statics Dollar", "USDstx", 18);
        vm.prank(address(fixture.timelock));
        IStaticsMorpho(diamond).initializeMorphoIntegration(address(morpho), address(usdStx), 25);
        assertEq(IStaticsMorpho(diamond).morpho(), address(morpho));
        assertEq(IStaticsMorpho(diamond).morphoUsdStx(), address(usdStx));

        CoreBootstrapDeployment memory fresh = _freshDeployment(fixture);
        _assertSelectorCodehashParity(diamond, fresh.diamond);
        _assertSelectorCodehashParity(phaseThree.core, fresh.core);
        assertEq(IStaticsBasketAdmin(fresh.diamond).creationFee(), IStaticsBasketAdmin(diamond).creationFee());
        assertEq(
            IStaticsFlashLoan(fresh.diamond).singleAssetFlashFeeBps(),
            IStaticsFlashLoan(diamond).singleAssetFlashFeeBps()
        );
    }

    function testPhaseThreeCannotBePreparedBeforePhaseTwo() public {
        Fixture memory fixture = _phaseOneFixture();
        DeployStaticsPhases.PhaseThreeConfig memory config =
            _phaseThreeConfig(fixture, fixture.phaseOne.diamond, address(new MockETHUSDOracle(2_500e18, 30 days)));
        vm.expectRevert(
            abi.encodeWithSelector(
                DeployStaticsPhases.InvalidSelectorManifest.selector, 2, PHASE_TWO_SELECTORS, PHASE_ONE_SELECTORS
            )
        );
        fixture.phases.deployPhaseThree(config);
    }

    function testLaterPhaseRejectsDriftedEarlierFacetRuntime() public {
        Fixture memory fixture = _phaseOneFixture();
        address diamond = fixture.phaseOne.diamond;
        address facet = IDiamondLoupe(diamond).facetAddress(IStaticsGlobalRewards.createAndStake.selector);
        bytes memory driftedRuntime = type(StagedDependencyMock).runtimeCode;
        vm.etch(facet, driftedRuntime);

        DeployStaticsPhases.PhaseTwoConfig memory config = _phaseTwoConfig(fixture, 0);
        vm.expectRevert(
            abi.encodeWithSelector(
                DeployStaticsPhases.InvalidFacet.selector,
                facet,
                keccak256(type(GlobalRewardsFacet).runtimeCode),
                keccak256(driftedRuntime)
            )
        );
        fixture.phases.deployPhaseTwo(config);
    }

    function testLaterPhaseRejectsDriftedPhaseState() public {
        Fixture memory fixture = _phaseOneFixture();
        address diamond = fixture.phaseOne.diamond;
        vm.store(diamond, PHASE_STORAGE_POSITION, bytes32(0));

        vm.expectRevert(abi.encodeWithSelector(DeployStaticsPhases.InvalidDeploymentPhase.selector, 1, 0));
        fixture.phases.deployPhaseTwo(_phaseTwoConfig(fixture, 0));
    }

    function testPhaseInitializerCannotReplay() public {
        Fixture memory fixture = _phaseOneFixture();
        address diamond = fixture.phaseOne.diamond;
        DeployStaticsPhases.PhaseTwoConfig memory config = _phaseTwoConfig(fixture, 0);
        PhaseTwoDeployment memory deployment = fixture.phases.deployPhaseTwo(config);
        (address[] memory targets, uint256[] memory values, bytes[] memory payloads) =
            fixture.phases.buildPhaseTwoBatch(diamond, deployment, config);
        _executeThroughTimelock(fixture.timelock, targets, values, payloads, keccak256("phase two replay"));

        IDiamondCut.FacetCut[] memory empty = new IDiamondCut.FacetCut[](0);
        vm.prank(address(fixture.timelock));
        vm.expectRevert(abi.encodeWithSelector(LibDeploymentPhases.UnexpectedDeploymentPhase.selector, 1, 2));
        IDiamondCut(diamond).diamondCut(empty, deployment.initializer, _initializerData(config));
    }

    function _phaseOneFixture() private returns (Fixture memory fixture) {
        fixture.phases = new DeployStaticsPhases();
        fixture.statics = new MockERC20("Statics", "STATICS", 18);
        fixture.weth = new MockERC20("Wrapped Ether", "WETH", 18);
        fixture.poolManager = new StagedDependencyMock();
        fixture.permit2 = new StagedDependencyMock();
        fixture.positionManager = new StagedPositionManagerMock(address(fixture.poolManager), address(fixture.permit2));
        DeployStaticsPhaseOne phaseOneDeployer = new DeployStaticsPhaseOne();
        (fixture.phaseOne, fixture.timelock) = phaseOneDeployer.deployWithLiquidity(
            DeployStaticsPhaseOne.Config({
                multisig: address(this),
                guardian: makeAddr("guardian"),
                treasury: makeAddr("treasury"),
                stakingToken: address(fixture.statics),
                weth: address(fixture.weth),
                positionCreationFeeAmount: 0
            }),
            DeployStaticsPhaseOne.V4Config({
                poolManager: address(fixture.poolManager),
                inputFeeBps: 25,
                outputFeeBps: 25,
                poolManagerCodeHash: address(fixture.poolManager).codehash
            })
        );
        fixture.permissionedPositionClaims =
            new StagedPermissionedClaimsMock(address(fixture.poolManager), fixture.phaseOne.permissionedSwapFeeHook);
        fixture.permissionedRouter = new StagedPermissionedPeripheryMock(
            address(fixture.poolManager), address(fixture.permit2), fixture.phaseOne.permissionedSwapFeeHook, address(0)
        );
        fixture.permissionedPositionManager = new StagedPermissionedPeripheryMock(
            address(fixture.poolManager),
            address(fixture.permit2),
            fixture.phaseOne.permissionedSwapFeeHook,
            address(fixture.permissionedPositionClaims)
        );
        fixture.permissionedPositionClaims.bindPositionManager(address(fixture.permissionedPositionManager));
        fixture.permissionedQuoter = new StagedQuoterMock(address(fixture.poolManager));
        vm.prank(address(fixture.timelock));
        IStaticsBasketLiquidity(fixture.phaseOne.diamond)
            .installCanonicalPoolIntegration(address(fixture.poolManager), fixture.phaseOne.swapFeeHook);
        vm.startPrank(address(fixture.timelock));
        IStaticsBasketLiquidity(fixture.phaseOne.diamond)
            .installPermissionedPoolIntegration(
                fixture.phaseOne.permissionedSwapFeeHook,
                address(fixture.permissionedRouter),
                address(fixture.permissionedPositionManager),
                address(fixture.permissionedQuoter)
            );
        IStaticsPermissionedPools(fixture.phaseOne.diamond)
            .setPermissionedTrustedPeriphery(address(fixture.permissionedRouter), true);
        IStaticsPermissionedPools(fixture.phaseOne.diamond)
            .setPermissionedTrustedPeriphery(address(fixture.permissionedPositionManager), true);
        IStaticsPermissionedPools(fixture.phaseOne.diamond)
            .setPermissionedTrustedPeriphery(address(fixture.permissionedQuoter), true);
        vm.stopPrank();
    }

    function _phaseThreeConfig(Fixture memory fixture, address diamond, address oracle)
        private
        returns (DeployStaticsPhases.PhaseThreeConfig memory)
    {
        return DeployStaticsPhases.PhaseThreeConfig({
            diamond: diamond,
            core: CoreBootstrapConfig({
                owner: address(fixture.timelock),
                profileGuardian: makeAddr("profileGuardian"),
                treasury: IStaticsBasketAdmin(diamond).treasury(),
                stakingToken: address(fixture.statics),
                creationFeeAmount: 0,
                positionCreationFeeAmount: 0,
                poolCreationFeeAmount: 0,
                singleAssetFlashFeeBps: 0,
                initialOracle: oracle,
                requiredSequencerUptimeFeed: address(0),
                minimumSequencerGracePeriod: 0,
                weth: address(fixture.weth),
                collateralRatioBps: 15_000,
                priceBandBps: 15_000,
                debtCeiling: 1_000_000e18,
                riskUri: "ipfs://statics-dollar/{id}.json"
            }),
            baseBps: 7_000,
            insuranceBps: 3_000,
            redemptionFeeBps: 50,
            redemptionSupplierShareBps: 8_000
        });
    }

    function _phaseTwoConfig(Fixture memory fixture, uint256 creationFeeAmount)
        private
        view
        returns (DeployStaticsPhases.PhaseTwoConfig memory)
    {
        return DeployStaticsPhases.PhaseTwoConfig({
            diamond: fixture.phaseOne.diamond,
            poolManager: address(fixture.poolManager),
            positionManager: address(fixture.positionManager),
            permit2: address(fixture.permit2),
            swapFeeHook: fixture.phaseOne.swapFeeHook,
            permissionedSwapFeeHook: fixture.phaseOne.permissionedSwapFeeHook,
            permissionedRouter: address(fixture.permissionedRouter),
            permissionedPositionManager: address(fixture.permissionedPositionManager),
            permissionedQuoter: address(fixture.permissionedQuoter),
            poolManagerCodeHash: address(fixture.poolManager).codehash,
            positionManagerCodeHash: address(fixture.positionManager).codehash,
            permit2CodeHash: address(fixture.permit2).codehash,
            swapFeeHookCodeHash: fixture.phaseOne.swapFeeHook.codehash,
            permissionedSwapFeeHookCodeHash: fixture.phaseOne.permissionedSwapFeeHook.codehash,
            permissionedRouterCodeHash: address(fixture.permissionedRouter).codehash,
            permissionedPositionManagerCodeHash: address(fixture.permissionedPositionManager).codehash,
            permissionedPositionClaimsCodeHash: address(fixture.permissionedPositionClaims).codehash,
            permissionedQuoterCodeHash: address(fixture.permissionedQuoter).codehash,
            creationFeeAmount: creationFeeAmount,
            singleAssetFlashFeeBps: 5
        });
    }

    function _freshDeployment(Fixture memory fixture) private returns (CoreBootstrapDeployment memory) {
        DeployCoreBootstrap deployer = new DeployCoreBootstrap();
        return deployer.deploy(
            CoreBootstrapConfig({
                owner: address(deployer),
                profileGuardian: makeAddr("freshProfileGuardian"),
                treasury: IStaticsBasketAdmin(fixture.phaseOne.diamond).treasury(),
                stakingToken: address(fixture.statics),
                creationFeeAmount: 0.01 ether,
                positionCreationFeeAmount: 0,
                poolCreationFeeAmount: 0,
                singleAssetFlashFeeBps: 5,
                initialOracle: address(new MockETHUSDOracle(2_500e18, 30 days)),
                requiredSequencerUptimeFeed: address(0),
                minimumSequencerGracePeriod: 0,
                weth: address(fixture.weth),
                collateralRatioBps: 15_000,
                priceBandBps: 15_000,
                debtCeiling: 1_000_000e18,
                riskUri: "ipfs://statics-dollar/{id}.json"
            })
        );
    }

    function _executeThroughTimelock(
        StaticsTimelock timelock,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory payloads,
        bytes32 salt
    ) private {
        timelock.scheduleBatch(targets, values, payloads, bytes32(0), salt, timelock.getMinDelay());
        vm.warp(block.timestamp + timelock.getMinDelay());
        timelock.executeBatch(targets, values, payloads, bytes32(0), salt);
    }

    function _assertSelectorCodehashParity(address staged, address fresh) private view {
        bytes4[] memory stagedSelectors = _diamondSelectors(staged);
        bytes4[] memory freshSelectors = _diamondSelectors(fresh);
        _sort(stagedSelectors);
        _sort(freshSelectors);
        assertEq(stagedSelectors.length, freshSelectors.length);
        for (uint256 i; i < stagedSelectors.length; ++i) {
            assertEq(stagedSelectors[i], freshSelectors[i]);
            assertEq(
                IDiamondLoupe(staged).facetAddress(stagedSelectors[i]).codehash,
                IDiamondLoupe(fresh).facetAddress(freshSelectors[i]).codehash,
                "selector implementation drift"
            );
        }
    }

    function _assertManifest(address diamond, uint256 expectedFacets, uint256 expectedSelectors) private view {
        address[] memory facets = IDiamondLoupe(diamond).facetAddresses();
        assertEq(facets.length, expectedFacets);
        assertEq(_diamondSelectors(diamond).length, expectedSelectors);
    }

    function _activePhase(address diamond) private view returns (uint256) {
        return uint256(vm.load(diamond, PHASE_STORAGE_POSITION)) & type(uint8).max;
    }

    function _initializerData(DeployStaticsPhases.PhaseTwoConfig memory config) private pure returns (bytes memory) {
        return abi.encodeCall(
            StaticsPhaseTwoInit.initialize,
            (StaticsPhaseTwoInit.InitArgs({
                    creationFeeAmount: config.creationFeeAmount, singleAssetFlashFeeBps: config.singleAssetFlashFeeBps
                }))
        );
    }

    function _diamondSelectors(address diamond) private view returns (bytes4[] memory selectors) {
        IDiamondLoupe loupe = IDiamondLoupe(diamond);
        address[] memory facets = loupe.facetAddresses();
        uint256 count;
        for (uint256 i; i < facets.length; ++i) {
            count += loupe.facetFunctionSelectors(facets[i]).length;
        }
        selectors = new bytes4[](count);
        uint256 cursor;
        for (uint256 i; i < facets.length; ++i) {
            bytes4[] memory facetSelectors = loupe.facetFunctionSelectors(facets[i]);
            for (uint256 j; j < facetSelectors.length; ++j) {
                selectors[cursor++] = facetSelectors[j];
            }
        }
    }

    function _cutSelectors(IDiamondCut.FacetCut[] memory cut) private pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](StaticsProtocolPlan.selectorCount(cut));
        uint256 cursor;
        for (uint256 i; i < cut.length; ++i) {
            for (uint256 j; j < cut[i].functionSelectors.length; ++j) {
                selectors[cursor++] = cut[i].functionSelectors[j];
            }
        }
    }

    function _sort(bytes4[] memory selectors) private pure {
        for (uint256 i = 1; i < selectors.length; ++i) {
            bytes4 value = selectors[i];
            uint256 j = i;
            while (j != 0 && uint32(selectors[j - 1]) > uint32(value)) {
                selectors[j] = selectors[j - 1];
                --j;
            }
            selectors[j] = value;
        }
    }
}
