// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

import {
    CoreBootstrapConfig,
    CoreBootstrapDeployment,
    DeployCoreBootstrap
} from "script/dollar/DeployCoreBootstrap.s.sol";
import {CoreInit} from "src/dollar/core/CoreInit.sol";
import {StaticsDollarCoreDiamond} from "src/dollar/core/StaticsDollarCoreDiamond.sol";
import {CoreGovernanceFacet} from "src/dollar/core/facets/CoreGovernanceFacet.sol";
import {CoreReceiverFacet} from "src/dollar/core/facets/CoreReceiverFacet.sol";
import {CoreViewFacet} from "src/dollar/core/facets/CoreViewFacet.sol";
import {LibCore} from "src/dollar/core/libraries/LibCore.sol";
import {LibCoreStorage} from "src/dollar/core/libraries/LibCoreStorage.sol";
import {DiamondLoupeFacet} from "src/facets/DiamondLoupeFacet.sol";
import {OwnershipFacet} from "src/facets/OwnershipFacet.sol";
import {IDiamondCut} from "src/interfaces/IDiamondCut.sol";
import {IStaticsBasket} from "src/interfaces/IStaticsBasket.sol";
import {LibDiamond} from "src/libraries/LibDiamond.sol";
import {StaticsDollarRiskShares} from "src/dollar/StaticsDollarRiskShares.sol";
import {StaticsDollar} from "src/dollar/StaticsDollar.sol";
import {IStaticsDollarRiskShares} from "src/dollar/interfaces/IStaticsDollarRiskShares.sol";
import {IStaticsDollar} from "src/dollar/interfaces/IStaticsDollar.sol";
import {CanonicalWETH9} from "src/dollar/mocks/CanonicalWETH9.sol";
import {MockETHUSDOracle} from "src/dollar/mocks/MockETHUSDOracle.sol";
import {StakingFacet} from "src/dollar/periphery/facets/StakingFacet.sol";
import {SequencerAwareMockOracle} from "../helpers/SequencerAwareMockOracle.sol";

contract CoreBootstrapSequencerFeed {}

contract CorePartsHarness is DeployCoreBootstrap {
    function deploy(CoreBootstrapConfig memory) public pure override returns (CoreBootstrapDeployment memory) {
        revert();
    }

    function deploy(CoreBootstrapConfig memory, address) public pure override returns (CoreBootstrapDeployment memory) {
        revert();
    }

    function deployParts() external returns (CoreParts memory) {
        return _deployCoreParts();
    }

    function buildGenesis(CoreParts memory parts) external pure returns (IDiamondCut.FacetCut[] memory) {
        return _coreGenesis(parts);
    }
}

contract CounterfeitStaticsDollar {
    address public immutable pool;

    constructor(address pool_) {
        pool = pool_;
    }

    function coreTokenKind() external pure returns (bytes32) {
        return keccak256("COUNTERFEIT");
    }
}

contract BootstrapWiringMock {
    address public pool;
    address public immutable staticsDollar;
    address public immutable staticsDollarRisk;

    constructor(address pool_, address staticsDollar_, address staticsDollarRisk_) {
        pool = pool_;
        staticsDollar = staticsDollar_;
        staticsDollarRisk = staticsDollarRisk_;
    }

    function setPool(address newPool) external {
        pool = newPool;
    }
}

contract CoreBootstrapTest is Test {
    address internal owner = makeAddr("owner");
    address internal profileGuardian = makeAddr("profileGuardian");
    address internal user = makeAddr("user");

    function test_FullBootstrapProvesEveryCrossBinding() public {
        CanonicalWETH9 weth = new CanonicalWETH9();
        MockETHUSDOracle oracle = new MockETHUSDOracle(2_500e18, 1 hours);
        DeployCoreBootstrap deployer = new DeployCoreBootstrap();
        CoreBootstrapConfig memory config = _config(address(weth), address(oracle));

        CoreBootstrapDeployment memory deployment = deployer.deploy(config);
        CoreViewFacet core = CoreViewFacet(deployment.core);
        OwnershipFacet ownership = OwnershipFacet(deployment.core);
        DiamondLoupeFacet loupe = DiamondLoupeFacet(deployment.core);
        DiamondLoupeFacet staticsLoupe = DiamondLoupeFacet(deployment.diamond);

        assertEq(StaticsDollar(deployment.staticsDollar).pool(), deployment.core);
        assertEq(StaticsDollarRiskShares(deployment.staticsDollarRisk).pool(), deployment.core);
        assertEq(core.staticsDollar(), deployment.staticsDollar);
        assertEq(core.staticsDollarRisk(), deployment.staticsDollarRisk);
        assertEq(core.initialOracle(), address(oracle));
        assertEq(core.profileGuardian(), profileGuardian);
        assertEq(core.bootstrapAuthority(), address(0));
        assertTrue(core.initialized());
        assertTrue(core.bootstrapFinalized());
        assertEq(core.periphery(), deployment.diamond);
        assertEq(core.positionNFT(), deployment.positionNFT);
        assertEq(deployment.positionNFT, deployment.diamond);
        assertEq(ownership.owner(), owner);
        assertEq(loupe.facetAddresses().length, 11);
        assertEq(staticsLoupe.facetAddresses().length, 25);
        assertTrue(loupe.facetAddress(CoreGovernanceFacet.setManagedRecoveryHolder.selector) != address(0));
        assertEq(loupe.facetAddress(bytes4(keccak256("registerManagedRecoveryHolder()"))), address(0));
        assertEq(IStaticsBasket(deployment.diamond).basketCount(), 0);

        assertEq(StakingFacet(deployment.diamond).pool(), deployment.core);
        assertEq(StakingFacet(deployment.diamond).staticsDollar(), deployment.staticsDollar);
        assertEq(StakingFacet(deployment.diamond).staticsDollarRisk(), deployment.staticsDollarRisk);
        assertEq(StakingFacet(deployment.diamond).positionNFT(), deployment.positionNFT);
    }

    function test_CoreTokenAuthorityAndRiskIngressStayRestricted() public {
        CanonicalWETH9 weth = new CanonicalWETH9();
        MockETHUSDOracle oracle = new MockETHUSDOracle(2_500e18, 1 hours);
        CoreBootstrapDeployment memory deployment =
            new DeployCoreBootstrap().deploy(_config(address(weth), address(oracle)));

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(IStaticsDollar.NotMinter.selector, user));
        StaticsDollar(deployment.staticsDollar).mint(user, 1 ether);
        // Narrow synthetic setup: no issuance facet exists yet, so the test impersonates
        // the wired Core solely to reach the receiver's unsolicited-ingress branch.
        vm.prank(deployment.core);
        StaticsDollarRiskShares(deployment.staticsDollarRisk).mint(user, 1, 1 ether);
        vm.prank(user);
        vm.expectPartialRevert(CoreReceiverFacet.UnexpectedRiskIngress.selector);
        StaticsDollarRiskShares(deployment.staticsDollarRisk).safeTransferFrom(user, deployment.core, 1, 1 ether, "");
        assertEq(StaticsDollarRiskShares(deployment.staticsDollarRisk).balanceOf(user, 1), 1 ether);
    }

    function test_CoreAdministrationFollowsDiamondOwnership() public {
        CanonicalWETH9 weth = new CanonicalWETH9();
        MockETHUSDOracle oracle = new MockETHUSDOracle(2_500e18, 1 hours);
        CoreBootstrapDeployment memory deployment =
            new DeployCoreBootstrap().deploy(_config(address(weth), address(oracle)));
        CoreGovernanceFacet governance = CoreGovernanceFacet(deployment.core);
        address nextOwner = makeAddr("nextOwner");

        vm.prank(owner);
        OwnershipFacet(deployment.core).transferOwnership(nextOwner);
        assertEq(OwnershipFacet(deployment.core).owner(), nextOwner);

        CanonicalWETH9 collateral = new CanonicalWETH9();
        MockETHUSDOracle collateralOracle = new MockETHUSDOracle(2_500e18, 1 hours);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(LibDiamond.NotContractOwner.selector, owner, nextOwner));
        governance.createCollateralProfile(
            address(collateral), address(collateralOracle), 15_000, 15_000, 0, 0, 1_000_000e18
        );

        vm.prank(nextOwner);
        (uint256 profileId,) = governance.createCollateralProfile(
            address(collateral), address(collateralOracle), 15_000, 15_000, 0, 0, 1_000_000e18
        );
        assertEq(profileId, 2);
    }

    function test_InitEnforcesConfiguredSequencerProtection() public {
        CanonicalWETH9 weth = new CanonicalWETH9();
        CoreBootstrapSequencerFeed feed = new CoreBootstrapSequencerFeed();
        MockETHUSDOracle unprotected = new MockETHUSDOracle(2_500e18, 1 hours);
        CoreBootstrapConfig memory invalid = _config(address(weth), address(unprotected));
        invalid.requiredSequencerUptimeFeed = address(feed);
        invalid.minimumSequencerGracePeriod = 1 hours;
        DeployCoreBootstrap invalidDeployer = new DeployCoreBootstrap();
        vm.expectPartialRevert(LibCore.SequencerProtectionRequired.selector);
        invalidDeployer.deploy(invalid);

        SequencerAwareMockOracle protectedOracle = new SequencerAwareMockOracle(2_500e18, address(feed), 1 hours);
        CoreBootstrapConfig memory valid = _config(address(weth), address(protectedOracle));
        valid.requiredSequencerUptimeFeed = address(feed);
        valid.minimumSequencerGracePeriod = 1 hours;
        CoreBootstrapDeployment memory deployment = new DeployCoreBootstrap().deploy(valid);
        assertEq(CoreViewFacet(deployment.core).requiredSequencerUptimeFeed(), address(feed));
        assertEq(CoreViewFacet(deployment.core).minimumSequencerGracePeriod(), 1 hours);
    }

    function test_IncompleteBootstrapRejectsUnauthorizedAndMisboundFinalization() public {
        CorePartsHarness harness = new CorePartsHarness();
        MockETHUSDOracle oracle = new MockETHUSDOracle(2_500e18, 1 hours);
        (address core, address staticsDollar, address staticsDollarRisk) = _deployUnfinalized(harness, address(oracle));
        CoreViewFacet viewFacet = CoreViewFacet(core);
        assertFalse(viewFacet.bootstrapFinalized());
        assertEq(viewFacet.bootstrapAuthority(), address(this));

        BootstrapWiringMock wiring = new BootstrapWiringMock(makeAddr("wrongCore"), staticsDollar, staticsDollarRisk);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(LibCoreStorage.Unauthorized.selector, user));
        CoreGovernanceFacet(core).finalizeBootstrap(address(wiring));

        vm.expectPartialRevert(CoreGovernanceFacet.InvalidPeripheryWiring.selector);
        CoreGovernanceFacet(core).finalizeBootstrap(address(wiring));
        wiring.setPool(core);
        CoreGovernanceFacet(core).finalizeBootstrap(address(wiring));
        assertTrue(viewFacet.bootstrapFinalized());
        assertEq(viewFacet.bootstrapAuthority(), address(0));
    }

    function test_InitRejectsEoaCounterfeitAndMisboundTokens() public {
        CorePartsHarness harness = new CorePartsHarness();
        MockETHUSDOracle oracle = new MockETHUSDOracle(2_500e18, 1 hours);
        CanonicalWETH9 collateral = new CanonicalWETH9();

        DeployCoreBootstrap.CoreParts memory eoaParts = harness.deployParts();
        IDiamondCut.FacetCut[] memory eoaGenesis = harness.buildGenesis(eoaParts);
        address predictedEoaCore = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        StaticsDollarRiskShares eoaRisk = new StaticsDollarRiskShares(predictedEoaCore, "");
        CoreInit.InitArgs memory eoaArgs =
            _initArgs(makeAddr("eoaToken"), address(eoaRisk), address(oracle), address(collateral));
        vm.expectRevert(abi.encodeWithSelector(LibCore.ContractExpected.selector, eoaArgs.staticsDollar));
        new StaticsDollarCoreDiamond(owner, eoaGenesis, eoaParts.init, abi.encodeCall(CoreInit.init, (eoaArgs)));

        DeployCoreBootstrap.CoreParts memory counterfeitParts = harness.deployParts();
        IDiamondCut.FacetCut[] memory counterfeitGenesis = harness.buildGenesis(counterfeitParts);
        address predictedCounterfeitCore = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 2);
        CounterfeitStaticsDollar counterfeit = new CounterfeitStaticsDollar(predictedCounterfeitCore);
        StaticsDollarRiskShares counterfeitRisk = new StaticsDollarRiskShares(predictedCounterfeitCore, "");
        CoreInit.InitArgs memory counterfeitArgs =
            _initArgs(address(counterfeit), address(counterfeitRisk), address(oracle), address(collateral));
        vm.expectPartialRevert(CoreInit.InvalidTokenKind.selector);
        new StaticsDollarCoreDiamond(
            owner, counterfeitGenesis, counterfeitParts.init, abi.encodeCall(CoreInit.init, (counterfeitArgs))
        );

        DeployCoreBootstrap.CoreParts memory misboundParts = harness.deployParts();
        IDiamondCut.FacetCut[] memory misboundGenesis = harness.buildGenesis(misboundParts);
        address predictedMisboundCore = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 2);
        StaticsDollar misboundStaticsDollar = new StaticsDollar(makeAddr("wrongPool"));
        StaticsDollarRiskShares misboundRisk = new StaticsDollarRiskShares(predictedMisboundCore, "");
        CoreInit.InitArgs memory misboundArgs =
            _initArgs(address(misboundStaticsDollar), address(misboundRisk), address(oracle), address(collateral));
        vm.expectPartialRevert(CoreInit.InvalidTokenPool.selector);
        new StaticsDollarCoreDiamond(
            owner, misboundGenesis, misboundParts.init, abi.encodeCall(CoreInit.init, (misboundArgs))
        );
    }

    function _config(address weth, address oracle) internal view returns (CoreBootstrapConfig memory config) {
        config.owner = owner;
        config.profileGuardian = profileGuardian;
        config.initialOracle = oracle;
        config.weth = weth;
        config.partnerRecipient = address(0);
        config.riskUri = "ipfs://risk/{id}.json";
    }

    function _deployUnfinalized(CorePartsHarness harness, address oracle)
        internal
        returns (address core, address staticsDollar, address staticsDollarRisk)
    {
        DeployCoreBootstrap.CoreParts memory parts = harness.deployParts();
        IDiamondCut.FacetCut[] memory genesis = harness.buildGenesis(parts);
        CanonicalWETH9 collateral = new CanonicalWETH9();
        address predictedCore = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 2);
        staticsDollar = address(new StaticsDollar(predictedCore));
        staticsDollarRisk = address(new StaticsDollarRiskShares(predictedCore, ""));
        CoreInit.InitArgs memory args = _initArgs(staticsDollar, staticsDollarRisk, oracle, address(collateral));
        core = address(new StaticsDollarCoreDiamond(owner, genesis, parts.init, abi.encodeCall(CoreInit.init, (args))));
        assertEq(core, predictedCore);
    }

    function _initArgs(address staticsDollar, address staticsDollarRisk, address oracle, address collateral)
        internal
        view
        returns (CoreInit.InitArgs memory args)
    {
        args = CoreInit.InitArgs({
            staticsDollar: staticsDollar,
            staticsDollarRisk: staticsDollarRisk,
            initialOracle: oracle,
            requiredSequencerUptimeFeed: address(0),
            minimumSequencerGracePeriod: 0,
            profileGuardian: profileGuardian,
            initialCollateralToken: collateral,
            collateralRatioBps: 15_000,
            priceBandBps: 15_000,
            debtCeiling: 1_000_000e18
        });
    }
}
