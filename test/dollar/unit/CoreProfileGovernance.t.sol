// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

import {
    CoreBootstrapConfig,
    CoreBootstrapDeployment,
    DeployCoreBootstrap
} from "script/dollar/DeployCoreBootstrap.s.sol";
import {CoreGovernanceFacet} from "src/dollar/core/facets/CoreGovernanceFacet.sol";
import {CoreViewFacet} from "src/dollar/core/facets/CoreViewFacet.sol";
import {IStaticsDollarCoreTypes} from "src/dollar/interfaces/IStaticsDollarCoreTypes.sol";
import {CanonicalWETH9} from "src/dollar/mocks/CanonicalWETH9.sol";
import {MockETHUSDOracle} from "src/dollar/mocks/MockETHUSDOracle.sol";
import {LibDiamond} from "src/libraries/LibDiamond.sol";
import {MockUSDC} from "../helpers/MockUSDC.sol";

contract CoreProfileGovernanceTest is Test {
    address internal owner = makeAddr("owner");
    address internal profileGuardian = makeAddr("profileGuardian");

    CanonicalWETH9 internal weth;
    MockETHUSDOracle internal initialOracle;
    CoreBootstrapDeployment internal deployment;
    CoreGovernanceFacet internal governance;
    CoreViewFacet internal viewFacet;

    function setUp() public {
        weth = new CanonicalWETH9();
        initialOracle = new MockETHUSDOracle(2_500e18, 30 days);
        CoreBootstrapConfig memory config;
        config.owner = owner;
        config.profileGuardian = profileGuardian;
        config.initialOracle = address(initialOracle);
        config.weth = address(weth);
        config.riskUri = "ipfs://risk/{id}.json";
        deployment = new DeployCoreBootstrap().deploy(config);
        governance = CoreGovernanceFacet(deployment.core);
        viewFacet = CoreViewFacet(deployment.core);
    }

    function test_ProtocolOwnerCreatesAndActivatesVolatileProfileDirectly() public {
        MockUSDC collateral = new MockUSDC();
        MockETHUSDOracle oracle = new MockETHUSDOracle(25e18, 30 days);

        vm.prank(profileGuardian);
        vm.expectRevert(abi.encodeWithSelector(LibDiamond.NotContractOwner.selector, profileGuardian, owner));
        governance.createCollateralProfile(address(collateral), address(oracle), 15_000, 15_000, 5, 10, 1_000_000e18);

        vm.prank(owner);
        (uint256 profileId, uint256 seriesId) = governance.createCollateralProfile(
            address(collateral), address(oracle), 15_000, 15_000, 5, 10, 1_000_000e18
        );
        IStaticsDollarCoreTypes.StableCollateralProfile memory profile = viewFacet.collateralProfile(profileId);
        assertEq(profileId, 2);
        assertEq(seriesId, 2);
        assertEq(uint256(profile.mode), uint256(IStaticsDollarCoreTypes.ProfileMode.Inactive));
        assertEq(profile.activeSeriesId, seriesId);
        assertEq(viewFacet.collateralTokenProfileId(address(collateral)), profileId);

        vm.prank(owner);
        governance.setProfileMode(profileId, IStaticsDollarCoreTypes.ProfileMode.Active);
        assertEq(
            uint256(viewFacet.collateralProfile(profileId).mode), uint256(IStaticsDollarCoreTypes.ProfileMode.Active)
        );
    }

    function test_GuardianCanPauseAndReduceRiskButCannotRestoreIt() public {
        uint256 pauseMinting = 1;
        vm.startPrank(profileGuardian);
        governance.pauseProfileOperations(1, pauseMinting);
        governance.reduceDebtCeiling(1, 900_000e18);
        governance.enterReduceOnly(1);
        vm.expectRevert(abi.encodeWithSelector(LibDiamond.NotContractOwner.selector, profileGuardian, owner));
        governance.resumeProfileOperations(1, pauseMinting);
        vm.expectRevert(abi.encodeWithSelector(LibDiamond.NotContractOwner.selector, profileGuardian, owner));
        governance.setProfileMode(1, IStaticsDollarCoreTypes.ProfileMode.Active);
        vm.stopPrank();

        assertEq(viewFacet.pausedProfileOperations(1), pauseMinting);
        assertEq(viewFacet.collateralProfile(1).debtCeiling, 900_000e18);
        assertEq(uint256(viewFacet.collateralProfile(1).mode), uint256(IStaticsDollarCoreTypes.ProfileMode.ReduceOnly));

        vm.prank(owner);
        governance.resumeProfileOperations(1, pauseMinting);
        assertEq(viewFacet.pausedProfileOperations(1), 0);
    }

    function test_ProtocolOwnerSetsOracleWithExecutionTimeValidation() public {
        MockETHUSDOracle replacement = new MockETHUSDOracle(2_600e18, 30 days);
        replacement.setInvalidPrice(true);
        vm.prank(owner);
        vm.expectRevert();
        governance.setProfileOracle(1, address(replacement));

        replacement.setInvalidPrice(false);
        replacement.setUpdatedAt(block.timestamp);
        vm.prank(owner);
        governance.setProfileOracle(1, address(replacement));
        assertEq(viewFacet.collateralProfile(1).oracle, address(replacement));
        assertEq(viewFacet.profileOracleRevision(1), 2);
    }

    function test_ProtocolOwnerSetsRiskConfigAndGuardianOnlyReducesCeiling() public {
        CoreGovernanceFacet.ProfileRiskConfig memory risk = CoreGovernanceFacet.ProfileRiskConfig({
            collateralRatioBps: 16_000,
            priceBandBps: 16_000,
            mintFeeBps: 10,
            redemptionFeeBps: 15,
            insuranceTargetBps: 1_000,
            insuranceFeeBps: 100,
            pegMinPriceWad: 0,
            pegMaxPriceWad: 0,
            debtCeiling: 2_000_000e18
        });

        vm.prank(profileGuardian);
        vm.expectRevert(abi.encodeWithSelector(LibDiamond.NotContractOwner.selector, profileGuardian, owner));
        governance.setProfileRiskConfig(1, risk);

        vm.prank(owner);
        governance.setProfileRiskConfig(1, risk);
        IStaticsDollarCoreTypes.StableCollateralProfile memory profile = viewFacet.collateralProfile(1);
        assertEq(profile.collateralRatioBps, 16_000);
        assertEq(profile.mintFeeBps, 10);
        assertEq(profile.debtCeiling, 2_000_000e18);

        vm.prank(profileGuardian);
        governance.reduceDebtCeiling(1, 900_000e18);
        assertEq(viewFacet.collateralProfile(1).debtCeiling, 900_000e18);
    }

    function test_PeggedCreationDoesNotProbeTokenSpecificIssuerControls() public {
        MockUSDC usdc = new MockUSDC();
        MockETHUSDOracle oracle = new MockETHUSDOracle(1e18, 30 days);
        usdc.setRevertIssuerControls(true);
        uint256 nextSeriesId = viewFacet.nextSeriesId();
        vm.prank(owner);
        uint256 profileId = governance.createPeggedCollateralProfile(
            address(usdc), address(oracle), 0.995e18, 1.005e18, 5, 7, 10_000_000e18
        );
        IStaticsDollarCoreTypes.StableCollateralProfile memory profile = viewFacet.collateralProfile(profileId);
        assertEq(uint256(profile.kind), uint256(IStaticsDollarCoreTypes.ProfileKind.Pegged));
        assertEq(uint256(profile.mode), uint256(IStaticsDollarCoreTypes.ProfileMode.Inactive));
        assertEq(profile.decimals, 6);
        assertEq(profile.redemptionFeeBps, 7);
        assertEq(profile.activeSeriesId, 0);
        assertEq(viewFacet.profileSeriesCount(profileId), 0);
        assertEq(viewFacet.nextSeriesId(), nextSeriesId);
    }

    function test_DuplicateCollateralAndRetirementPreconditionsRemainEnforced() public {
        MockETHUSDOracle oracle = new MockETHUSDOracle(2_500e18, 30 days);
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(CoreGovernanceFacet.CollateralTokenAlreadyAssigned.selector, address(weth), 1)
        );
        governance.createCollateralProfile(address(weth), address(oracle), 15_000, 15_000, 0, 0, 1_000e18);

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                CoreGovernanceFacet.InvalidProfileMode.selector, 1, IStaticsDollarCoreTypes.ProfileMode.Retired
            )
        );
        governance.setProfileMode(1, IStaticsDollarCoreTypes.ProfileMode.Retired);

        vm.prank(profileGuardian);
        governance.enterReduceOnly(1);
        vm.prank(owner);
        governance.setProfileMode(1, IStaticsDollarCoreTypes.ProfileMode.Retired);
        assertEq(uint256(viewFacet.collateralProfile(1).mode), uint256(IStaticsDollarCoreTypes.ProfileMode.Retired));
    }
}
