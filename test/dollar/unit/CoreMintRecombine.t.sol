// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {
    CoreBootstrapConfig,
    CoreBootstrapDeployment,
    DeployCoreBootstrap
} from "script/dollar/DeployCoreBootstrap.s.sol";
import {CoreGovernanceFacet} from "src/dollar/core/facets/CoreGovernanceFacet.sol";
import {CoreMintFacet} from "src/dollar/core/facets/CoreMintFacet.sol";
import {CoreViewFacet} from "src/dollar/core/facets/CoreViewFacet.sol";
import {LibCoreAccounting} from "src/dollar/core/libraries/LibCoreAccounting.sol";
import {LibSolvencyIndex} from "src/dollar/core/libraries/LibSolvencyIndex.sol";
import {StaticsDollarRiskShares} from "src/dollar/StaticsDollarRiskShares.sol";
import {StaticsDollar} from "src/dollar/StaticsDollar.sol";
import {IStaticsDollarCoreTypes} from "src/dollar/interfaces/IStaticsDollarCoreTypes.sol";
import {CanonicalWETH9} from "src/dollar/mocks/CanonicalWETH9.sol";
import {MockETHUSDOracle} from "src/dollar/mocks/MockETHUSDOracle.sol";

contract OutboundTaxCollateral is ERC20 {
    address public taxedSender;
    uint256 public taxBps;

    constructor() ERC20("Outbound Tax Collateral", "OTC") {}

    function mint(address account, uint256 amount) external {
        _mint(account, amount);
    }

    function setOutboundTax(address sender, uint256 taxBps_) external {
        require(taxBps_ <= 10_000);
        taxedSender = sender;
        taxBps = taxBps_;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from == taxedSender && to != address(0) && taxBps != 0) {
            uint256 tax = value * taxBps / 10_000;
            super._update(from, address(0), tax);
            super._update(from, to, value - tax);
            return;
        }
        super._update(from, to, value);
    }
}

contract CoreMintRecombineTest is Test {
    address internal owner = makeAddr("owner");
    address internal profileGuardian = makeAddr("profileGuardian");
    address internal alice = makeAddr("alice");
    address internal executor = makeAddr("executor");

    CanonicalWETH9 internal weth;
    MockETHUSDOracle internal oracle;
    CoreBootstrapDeployment internal deployment;
    CoreMintFacet internal mintFacet;
    CoreGovernanceFacet internal governance;
    CoreViewFacet internal viewFacet;
    StaticsDollar internal staticsDollar;
    StaticsDollarRiskShares internal staticsDollarRisk;

    function setUp() public {
        weth = new CanonicalWETH9();
        oracle = new MockETHUSDOracle(2_500e18, 30 days);
        CoreBootstrapConfig memory config;
        config.owner = owner;
        config.profileGuardian = profileGuardian;
        config.initialOracle = address(oracle);
        config.weth = address(weth);
        config.riskUri = "ipfs://risk/{id}.json";
        deployment = new DeployCoreBootstrap().deploy(config);
        mintFacet = CoreMintFacet(deployment.core);
        governance = CoreGovernanceFacet(deployment.core);
        viewFacet = CoreViewFacet(deployment.core);
        staticsDollar = StaticsDollar(deployment.staticsDollar);
        staticsDollarRisk = StaticsDollarRiskShares(deployment.staticsDollarRisk);
    }

    function test_MinimumOutputsPauseAndDebtCeilingFailBeforeCustodyMoves() public {
        _fundWeth(alice, 1e18);
        IStaticsDollarCoreTypes.DepositPreview memory preview = mintFacet.previewDeposit(1, 1e18);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                CoreMintFacet.OutputBelowMinimum.selector, preview.staticsDollarMinted, preview.staticsDollarMinted + 1
            )
        );
        mintFacet.depositCollateral(1, 1e18, preview.staticsDollarMinted + 1, 0, alice, alice);
        assertEq(weth.balanceOf(deployment.core), 0);

        vm.prank(profileGuardian);
        governance.pauseProfileOperations(1, 1);
        vm.expectRevert(abi.encodeWithSelector(LibCoreAccounting.ProfileOperationPaused.selector, 1, 1));
        mintFacet.previewDeposit(1, 1e18);

        vm.prank(owner);
        governance.resumeProfileOperations(1, 1);
        vm.prank(profileGuardian);
        governance.reduceDebtCeiling(1, 1e18);
        vm.expectPartialRevert(CoreMintFacet.DebtCeilingExceeded.selector);
        mintFacet.previewDeposit(1, 1e18);
        assertEq(weth.balanceOf(deployment.core), 0);
    }

    function test_TransitionBoundaryAndReduceOnlyPreserveSafeExit() public {
        _fundWeth(alice, 1e18);
        IStaticsDollarCoreTypes.RiskSeries memory series = viewFacet.riskSeries(1);
        uint256 downside = viewFacet.seriesDownsideTriggerPriceWad(1);
        oracle.setPriceWad(downside);
        oracle.setUpdatedAt(block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(CoreMintFacet.TransitionRequired.selector, 1, 1, downside));
        mintFacet.previewDeposit(1, 1e18);

        oracle.setPriceWad(series.startPriceWad);
        oracle.setUpdatedAt(block.timestamp);
        IStaticsDollarCoreTypes.DepositPreview memory preview = mintFacet.previewDeposit(1, 1e18);
        vm.prank(alice);
        mintFacet.depositCollateral(1, 1e18, preview.staticsDollarMinted, preview.sharesMinted, alice, alice);
        vm.prank(profileGuardian);
        governance.enterReduceOnly(1);
        vm.expectRevert(
            abi.encodeWithSelector(
                CoreMintFacet.InvalidProfileMode.selector, 1, IStaticsDollarCoreTypes.ProfileMode.ReduceOnly
            )
        );
        mintFacet.previewDeposit(1, 1e18);

        uint256 balanceBefore = weth.balanceOf(alice);
        vm.prank(alice);
        mintFacet.recombine(1, preview.staticsDollarMinted, preview.sharesMinted, 0, alice);
        assertEq(staticsDollar.balanceOf(alice), 0);
        assertEq(staticsDollarRisk.balanceOf(alice, 1), 0);
        assertEq(weth.balanceOf(alice) - balanceBefore, 1e18);
        assertEq(weth.balanceOf(deployment.core), 0);
    }

    function test_OutboundTaxCannotShortchangeReceiverOrCorruptAccounting() public {
        OutboundTaxCollateral collateral = new OutboundTaxCollateral();
        MockETHUSDOracle collateralOracle = new MockETHUSDOracle(1e18, 30 days);
        uint256 profileId = _activateVolatileProfile(address(collateral), address(collateralOracle));
        uint256 amount = 100e18;
        collateral.mint(alice, amount);
        collateral.setOutboundTax(deployment.core, 100);
        vm.prank(alice);
        collateral.approve(deployment.core, amount);
        IStaticsDollarCoreTypes.DepositPreview memory preview = mintFacet.previewDeposit(profileId, amount);
        vm.prank(alice);
        mintFacet.depositCollateral(profileId, amount, preview.staticsDollarMinted, preview.sharesMinted, alice, alice);

        IStaticsDollarCoreTypes.RedemptionPreview memory redemption =
            mintFacet.previewRecombine(2, preview.staticsDollarMinted);
        vm.prank(alice);
        vm.expectPartialRevert(LibCoreAccounting.InvalidCollateralAmount.selector);
        mintFacet.recombine(2, preview.staticsDollarMinted, preview.sharesMinted, redemption.collateralOut, alice);

        assertEq(staticsDollar.balanceOf(alice), preview.staticsDollarMinted);
        assertEq(staticsDollarRisk.balanceOf(alice, 2), preview.sharesMinted);
        assertEq(collateral.balanceOf(deployment.core), amount);
        assertEq(viewFacet.totalCollateral(address(collateral)), amount);
        assertEq(viewFacet.riskSeries(2).seniorOutstanding, preview.staticsDollarMinted);
    }

    function test_InboundTaxCannotCreateUnbackedSupply() public {
        OutboundTaxCollateral collateral = new OutboundTaxCollateral();
        MockETHUSDOracle collateralOracle = new MockETHUSDOracle(1e18, 30 days);
        uint256 profileId = _activateVolatileProfile(address(collateral), address(collateralOracle));
        uint256 amount = 100e18;
        collateral.mint(alice, amount);
        collateral.setOutboundTax(alice, 100);
        vm.prank(alice);
        collateral.approve(deployment.core, amount);
        IStaticsDollarCoreTypes.DepositPreview memory preview = mintFacet.previewDeposit(profileId, amount);

        vm.prank(alice);
        vm.expectPartialRevert(LibCoreAccounting.InvalidCollateralAmount.selector);
        mintFacet.depositCollateral(profileId, amount, preview.staticsDollarMinted, preview.sharesMinted, alice, alice);
        assertEq(staticsDollar.totalSupply(), 0);
        assertEq(staticsDollarRisk.balanceOf(alice, 2), 0);
        assertEq(collateral.balanceOf(deployment.core), 0);
        assertEq(viewFacet.totalCollateral(address(collateral)), 0);
    }

    function test_IndependentCoreDeploymentsProduceIdenticalAccounting() public {
        CanonicalWETH9 referenceWeth = new CanonicalWETH9();
        MockETHUSDOracle referenceOracle = new MockETHUSDOracle(2_500e18, 30 days);
        CoreBootstrapConfig memory config;
        config.owner = owner;
        config.profileGuardian = profileGuardian;
        config.weth = address(referenceWeth);
        config.initialOracle = address(referenceOracle);
        config.collateralRatioBps = 15_000;
        config.priceBandBps = 15_000;
        config.debtCeiling = 1_000_000e18;
        config.riskUri = "ipfs://risk/{id}.json";
        CoreBootstrapDeployment memory baseline = new DeployCoreBootstrap().deploy(config);
        CoreMintFacet referenceMint = CoreMintFacet(baseline.core);
        CoreViewFacet referenceView = CoreViewFacet(baseline.core);

        uint256 collateralAmount = 2e18;
        IStaticsDollarCoreTypes.DepositPreview memory corePreview = mintFacet.previewDeposit(1, collateralAmount);
        IStaticsDollarCoreTypes.DepositPreview memory referencePreview =
            referenceMint.previewDeposit(1, collateralAmount);
        assertEq(abi.encode(corePreview), abi.encode(referencePreview));

        _fundWeth(alice, collateralAmount);
        vm.prank(alice);
        mintFacet.depositCollateral(
            1, collateralAmount, corePreview.staticsDollarMinted, corePreview.sharesMinted, alice, alice
        );
        vm.deal(alice, collateralAmount);
        vm.prank(alice);
        referenceWeth.deposit{value: collateralAmount}();
        vm.prank(alice);
        referenceWeth.approve(baseline.core, collateralAmount);
        vm.prank(alice);
        referenceMint.depositCollateral(
            1, collateralAmount, referencePreview.staticsDollarMinted, referencePreview.sharesMinted, alice, alice
        );

        IStaticsDollarCoreTypes.RiskSeries memory coreSeries = viewFacet.riskSeries(1);
        IStaticsDollarCoreTypes.RiskSeries memory referenceSeries = referenceView.riskSeries(1);
        assertEq(coreSeries.seniorOutstanding, referenceSeries.seniorOutstanding);
        assertEq(coreSeries.riskSharesOutstanding, referenceSeries.riskSharesOutstanding);
        assertEq(coreSeries.accountedCollateral, referenceSeries.accountedCollateral);
        uint256 redeemed = corePreview.staticsDollarMinted / 3;
        IStaticsDollarCoreTypes.RedemptionPreview memory coreRedemption = mintFacet.previewRecombine(1, redeemed);
        IStaticsDollarCoreTypes.RedemptionPreview memory referenceRedemption =
            referenceMint.previewRecombine(1, redeemed);
        assertEq(coreRedemption.staticsDollarBurned, referenceRedemption.staticsDollarBurned);
        assertEq(coreRedemption.sharesBurned, referenceRedemption.sharesBurned);
        assertEq(coreRedemption.collateralOut, referenceRedemption.collateralOut);
        assertEq(coreRedemption.feeAmount, referenceRedemption.feeAmount);
        assertEq(coreRedemption.collateralRatioBpsAfter, referenceRedemption.collateralRatioBpsAfter);
    }

    function testFuzz_PartialRecombineMaintainsSupplyCustodyAndIndex(uint96 collateralSeed, uint96 redeemSeed) public {
        uint256 collateralAmount = bound(uint256(collateralSeed), 1e12, 10e18);
        _fundWeth(alice, collateralAmount);
        IStaticsDollarCoreTypes.DepositPreview memory preview = mintFacet.previewDeposit(1, collateralAmount);
        vm.prank(alice);
        mintFacet.depositCollateral(
            1, collateralAmount, preview.staticsDollarMinted, preview.sharesMinted, alice, alice
        );

        uint256 redeemed = bound(uint256(redeemSeed), 1e12, preview.staticsDollarMinted);
        IStaticsDollarCoreTypes.RedemptionPreview memory redemption = mintFacet.previewRecombine(1, redeemed);
        vm.prank(alice);
        mintFacet.recombine(1, redeemed, redeemed, redemption.collateralOut, alice);

        IStaticsDollarCoreTypes.RiskSeries memory series = viewFacet.riskSeries(1);
        IStaticsDollarCoreTypes.StableCollateralProfile memory profile = viewFacet.collateralProfile(1);
        uint256 remaining = preview.staticsDollarMinted - redeemed;
        assertEq(staticsDollar.totalSupply(), remaining);
        assertEq(viewFacet.seniorLiabilities(), remaining);
        assertEq(profile.seniorOutstanding, remaining);
        assertEq(series.seniorOutstanding, remaining);
        assertEq(series.riskSharesOutstanding, remaining);
        assertEq(staticsDollarRisk.balanceOf(alice, 1), remaining);
        assertEq(weth.balanceOf(deployment.core), series.accountedCollateral);
        assertEq(profile.accountedCollateral, series.accountedCollateral);
        assertEq(viewFacet.totalCollateral(address(weth)), series.accountedCollateral);
        LibSolvencyIndex.BookContribution memory contribution =
            viewFacet.solvencyBookContribution(1, bytes32(uint256(1)));
        assertEq(contribution.exists, remaining != 0);
        assertEq(contribution.liabilityWad, remaining);
        assertEq(contribution.collateralWad, series.accountedCollateral);
    }

    function _fundWeth(address account, uint256 amount) private {
        vm.deal(account, amount);
        vm.prank(account);
        weth.deposit{value: amount}();
        vm.prank(account);
        weth.approve(deployment.core, amount);
    }

    function _activateVolatileProfile(address collateral, address collateralOracle)
        private
        returns (uint256 profileId)
    {
        vm.prank(owner);
        (profileId,) =
            governance.createCollateralProfile(collateral, collateralOracle, 15_000, 15_000, 0, 0, 1_000_000e18);
        vm.prank(owner);
        governance.setProfileMode(profileId, IStaticsDollarCoreTypes.ProfileMode.Active);
    }
}
