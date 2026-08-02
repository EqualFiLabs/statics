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

    function testLaunchLevelAtomicLiabilityMigrationUsesInstalledGatewaySelectors() public {
        vm.warp(1_700_000_000);
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
        CoreBootstrapDeployment memory deployment = new DeployCoreBootstrap().deploy(config);

        IStaticsDollarCore core = IStaticsDollarCore(deployment.core);
        IStaticsDollarGateway gateway = IStaticsDollarGateway(deployment.diamond);
        IStaticsCustody custody = IStaticsCustody(deployment.diamond);
        StaticsDollar dollar = StaticsDollar(deployment.staticsDollar);
        StaticsDollarRiskShares risk = StaticsDollarRiskShares(deployment.staticsDollarRisk);
        MockUSDC usdc = new MockUSDC();
        MockETHUSDOracle pegOracle = new MockETHUSDOracle(1e18, 1 hours);
        vm.prank(owner);
        uint256 peggedProfileId = CoreGovernanceFacet(deployment.core)
            .createPeggedCollateralProfile(address(usdc), address(pegOracle), 0.995e18, 1.005e18, 5, 7, 1_000_000e18);
        vm.prank(owner);
        CoreGovernanceFacet(deployment.core).setProfileMode(peggedProfileId, IStaticsDollarCoreTypes.ProfileMode.Active);

        vm.deal(alice, 1 ether);
        vm.prank(alice);
        gateway.depositETH{value: 1 ether}(alice, alice, 0, 0);
        uint256 riskAmount = 100e18;
        IStaticsDollarGateway.PeggedMintAndRecombineQuote memory quote =
            gateway.quoteMintPeggedAndRecombine(peggedProfileId, WETH_PROFILE_ID, SERIES_ID, riskAmount);
        usdc.mint(alice, quote.totalPeggedCollateralIn);
        vm.startPrank(alice);
        usdc.approve(deployment.diamond, quote.totalPeggedCollateralIn);
        risk.setApprovalForAll(deployment.diamond, true);
        vm.stopPrank();

        address gatewayFacet =
            IDiamondLoupe(deployment.diamond).facetAddress(IStaticsDollarGateway.mintPeggedAndRecombine.selector);
        assertTrue(gatewayFacet != address(0));
        assertEq(
            IDiamondLoupe(deployment.diamond).facetAddress(IStaticsDollarGateway.quoteMintPeggedAndRecombine.selector),
            gatewayFacet
        );
        assertEq(
            IDiamondLoupe(deployment.diamond)
                .facetAddress(IStaticsDollarGateway.mintPeggedAndRecombineWithPermit.selector),
            gatewayFacet
        );
        assertTrue(IERC165(deployment.diamond).supportsInterface(type(IStaticsDollarGateway).interfaceId));

        uint256 supplyBefore = dollar.totalSupply();
        uint256 seniorBefore = core.seniorLiabilities();
        vm.expectEmit(true, true, true, true, deployment.diamond);
        emit IStaticsDollarGateway.PeggedMintedAndRecombined(
            alice,
            receiver,
            peggedProfileId,
            WETH_PROFILE_ID,
            SERIES_ID,
            riskAmount,
            quote.totalPeggedCollateralIn,
            riskAmount,
            quote.volatileCollateralOut
        );
        vm.prank(alice);
        (IStaticsDollarCoreTypes.ExitStatus status,,) = gateway.mintPeggedAndRecombine(
            peggedProfileId,
            WETH_PROFILE_ID,
            SERIES_ID,
            riskAmount,
            quote.totalPeggedCollateralIn,
            quote.volatileCollateralOut,
            receiver
        );

        assertEq(uint8(status), uint8(IStaticsDollarCoreTypes.ExitStatus.Available));
        assertEq(dollar.totalSupply(), supplyBefore);
        assertEq(core.seniorLiabilities(), seniorBefore);
        assertEq(core.collateralProfile(peggedProfileId).seniorOutstanding, riskAmount);
        assertEq(risk.balanceOf(alice, SERIES_ID), 1_566_666_666_666_666_666_666);
        assertEq(weth.balanceOf(receiver), quote.volatileCollateralOut);
        assertEq(dollar.balanceOf(deployment.diamond), custody.globalReservedByToken(address(dollar)));
        assertEq(usdc.balanceOf(deployment.diamond), custody.globalReservedByToken(address(usdc)));
        assertEq(usdc.allowance(deployment.diamond, deployment.core), 0);
    }
}
