// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {Test} from "forge-std/Test.sol";

import {
    CoreBootstrapConfig,
    CoreBootstrapDeployment,
    DeployCoreBootstrap
} from "script/dollar/DeployCoreBootstrap.s.sol";
import {CoreGovernanceFacet} from "src/dollar/core/facets/CoreGovernanceFacet.sol";
import {IStaticsDollarCore} from "src/dollar/core/interfaces/IStaticsDollarCore.sol";
import {StaticsDollar} from "src/dollar/StaticsDollar.sol";
import {StaticsDollarRiskShares} from "src/dollar/StaticsDollarRiskShares.sol";
import {IStaticsDollarCoreTypes} from "src/dollar/interfaces/IStaticsDollarCoreTypes.sol";
import {IStaticsDollarGateway} from "src/dollar/interfaces/IStaticsDollarGateway.sol";
import {CanonicalWETH9} from "src/dollar/mocks/CanonicalWETH9.sol";
import {MockETHUSDOracle} from "src/dollar/mocks/MockETHUSDOracle.sol";
import {IDiamondLoupe} from "src/interfaces/IDiamondLoupe.sol";
import {IStaticsCustody} from "src/interfaces/IStaticsCustody.sol";
import {MockUSDC} from "../helpers/MockUSDC.sol";

contract PeggedMintAndRecombineIntegrationTest is Test {
    uint256 internal constant WETH_PROFILE_ID = 1;
    uint256 internal constant SERIES_ID = 1;

    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice");
    address internal receiver = makeAddr("receiver");

    struct AtomicMigrationSetup {
        CoreBootstrapDeployment deployment;
        CanonicalWETH9 weth;
        StaticsDollar dollar;
        StaticsDollarRiskShares risk;
        MockUSDC usdc;
        uint256 peggedProfileId;
        uint256 riskAmount;
        IStaticsDollarGateway.PeggedMintAndRecombineQuote quote;
    }

    function testLaunchLevelAtomicLiabilityMigrationUsesInstalledGatewaySelectors() public {
        vm.warp(1_700_000_000);
        AtomicMigrationSetup memory setup = _launchAtomicMigrationStack();
        _assertGatewaySelectorWiring(setup.deployment.diamond);
        _executeAtomicMigration(setup);
    }

    function _launchAtomicMigrationStack() private returns (AtomicMigrationSetup memory setup) {
        CanonicalWETH9 weth = new CanonicalWETH9();
        MockETHUSDOracle wethOracle = new MockETHUSDOracle(2_500e18, 1 hours);
        CoreBootstrapConfig memory config;
        config.owner = owner;
        config.profileGuardian = owner;
        config.initialOracle = address(wethOracle);
        config.weth = address(weth);
        config.stakingToken = address(weth);
        config.collateralRatioBps = 15_000;
        config.priceBandBps = 15_000;
        config.debtCeiling = type(uint256).max;
        setup.deployment = new DeployCoreBootstrap().deploy(config);
        setup.weth = weth;
        setup.dollar = StaticsDollar(setup.deployment.staticsDollar);
        setup.risk = StaticsDollarRiskShares(setup.deployment.staticsDollarRisk);
        setup.usdc = new MockUSDC();
        MockETHUSDOracle pegOracle = new MockETHUSDOracle(1e18, 1 hours);
        vm.prank(owner);
        setup.peggedProfileId = CoreGovernanceFacet(setup.deployment.core)
            .createPeggedCollateralProfile(
                address(setup.usdc), address(pegOracle), 0.995e18, 1.005e18, 5, 7, 1_000_000e18
            );
        vm.prank(owner);
        CoreGovernanceFacet(setup.deployment.core)
            .setProfileMode(setup.peggedProfileId, IStaticsDollarCoreTypes.ProfileMode.Active);

        vm.deal(alice, 1 ether);
        vm.prank(alice);
        IStaticsDollarGateway(setup.deployment.diamond).depositETH{value: 1 ether}(alice, alice, 0, 0);
        setup.riskAmount = 100e18;
        setup.quote = IStaticsDollarGateway(setup.deployment.diamond)
            .quoteMintPeggedAndRecombine(setup.peggedProfileId, WETH_PROFILE_ID, SERIES_ID, setup.riskAmount);
        setup.usdc.mint(alice, setup.quote.totalPeggedCollateralIn);
        vm.startPrank(alice);
        setup.usdc.approve(setup.deployment.diamond, setup.quote.totalPeggedCollateralIn);
        setup.risk.setApprovalForAll(setup.deployment.diamond, true);
        vm.stopPrank();
    }

    function _assertGatewaySelectorWiring(address diamond) private view {
        address gatewayFacet =
            IDiamondLoupe(diamond).facetAddress(IStaticsDollarGateway.mintPeggedAndRecombine.selector);
        assertTrue(gatewayFacet != address(0));
        assertEq(
            IDiamondLoupe(diamond).facetAddress(IStaticsDollarGateway.quoteMintPeggedAndRecombine.selector),
            gatewayFacet
        );
        assertEq(
            IDiamondLoupe(diamond).facetAddress(IStaticsDollarGateway.mintPeggedAndRecombineWithPermit.selector),
            gatewayFacet
        );
        assertTrue(IERC165(diamond).supportsInterface(type(IStaticsDollarGateway).interfaceId));
    }

    function _executeAtomicMigration(AtomicMigrationSetup memory setup) private {
        IStaticsDollarCore core = IStaticsDollarCore(setup.deployment.core);
        IStaticsDollarGateway gateway = IStaticsDollarGateway(setup.deployment.diamond);
        IStaticsCustody custody = IStaticsCustody(setup.deployment.diamond);
        uint256 supplyBefore = setup.dollar.totalSupply();
        uint256 seniorBefore = core.seniorLiabilities();
        vm.expectEmit(true, true, true, true, setup.deployment.diamond);
        emit IStaticsDollarGateway.PeggedMintedAndRecombined(
            alice,
            receiver,
            setup.peggedProfileId,
            WETH_PROFILE_ID,
            SERIES_ID,
            setup.riskAmount,
            setup.quote.totalPeggedCollateralIn,
            setup.riskAmount,
            setup.quote.volatileCollateralOut
        );
        vm.prank(alice);
        (IStaticsDollarCoreTypes.ExitStatus status,,) = gateway.mintPeggedAndRecombine(
            setup.peggedProfileId,
            WETH_PROFILE_ID,
            SERIES_ID,
            setup.riskAmount,
            setup.quote.totalPeggedCollateralIn,
            setup.quote.volatileCollateralOut,
            receiver
        );

        assertEq(uint8(status), uint8(IStaticsDollarCoreTypes.ExitStatus.Available));
        assertEq(setup.dollar.totalSupply(), supplyBefore);
        assertEq(core.seniorLiabilities(), seniorBefore);
        assertEq(core.collateralProfile(setup.peggedProfileId).seniorOutstanding, setup.riskAmount);
        assertEq(setup.risk.balanceOf(alice, SERIES_ID), 1_566_666_666_666_666_666_666);
        assertEq(setup.weth.balanceOf(receiver), setup.quote.volatileCollateralOut);
        assertEq(setup.dollar.balanceOf(setup.deployment.diamond), custody.globalReservedByToken(address(setup.dollar)));
        assertEq(setup.usdc.balanceOf(setup.deployment.diamond), custody.globalReservedByToken(address(setup.usdc)));
        assertEq(setup.usdc.allowance(setup.deployment.diamond, setup.deployment.core), 0);
    }
}
