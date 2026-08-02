// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

import {
    CoreBootstrapConfig,
    CoreBootstrapDeployment,
    DeployCoreBootstrap
} from "script/dollar/DeployCoreBootstrap.s.sol";
import {StaticsDollar} from "src/dollar/StaticsDollar.sol";
import {StaticsDollarRiskShares} from "src/dollar/StaticsDollarRiskShares.sol";
import {CoreGovernanceFacet} from "src/dollar/core/facets/CoreGovernanceFacet.sol";
import {CoreHealthFacet} from "src/dollar/core/facets/CoreHealthFacet.sol";
import {CoreMintFacet} from "src/dollar/core/facets/CoreMintFacet.sol";
import {CoreRecoveryFacet} from "src/dollar/core/facets/CoreRecoveryFacet.sol";
import {CoreTransitionFacet} from "src/dollar/core/facets/CoreTransitionFacet.sol";
import {CoreViewFacet} from "src/dollar/core/facets/CoreViewFacet.sol";
import {IStaticsDollarCoreTypes} from "src/dollar/interfaces/IStaticsDollarCoreTypes.sol";
import {CanonicalWETH9} from "src/dollar/mocks/CanonicalWETH9.sol";
import {MockETHUSDOracle} from "src/dollar/mocks/MockETHUSDOracle.sol";
import {FeeRouterFacet} from "src/dollar/periphery/facets/FeeRouterFacet.sol";
import {IStaticsGlobalRewards} from "src/interfaces/IStaticsGlobalRewards.sol";
import {MockUSDC} from "../helpers/MockUSDC.sol";

contract PeggedRedemptionLifecycleTest is Test {
    address internal owner = makeAddr("owner");
    address internal profileGuardian = makeAddr("profileGuardian");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    CanonicalWETH9 internal weth;
    MockETHUSDOracle internal wethOracle;
    CoreBootstrapDeployment internal deployment;
    CoreGovernanceFacet internal governance;
    CoreHealthFacet internal health;
    CoreMintFacet internal mintFacet;
    CoreRecoveryFacet internal recovery;
    CoreTransitionFacet internal transition;
    CoreViewFacet internal viewFacet;
    StaticsDollar internal staticsDollar;
    StaticsDollarRiskShares internal staticsDollarRisk;
    MockUSDC internal usdc;
    MockETHUSDOracle internal usdcOracle;
    uint256 internal profileId;

    function setUp() public {
        vm.warp(30 days);
        weth = new CanonicalWETH9();
        wethOracle = new MockETHUSDOracle(2_500e18, 30 days);
        CoreBootstrapConfig memory config;
        config.owner = owner;
        config.profileGuardian = profileGuardian;
        config.initialOracle = address(wethOracle);
        config.weth = address(weth);
        config.stakingToken = address(weth);
        config.riskUri = "ipfs://risk/{id}.json";
        deployment = new DeployCoreBootstrap().deploy(config);
        governance = CoreGovernanceFacet(deployment.core);
        health = CoreHealthFacet(deployment.core);
        mintFacet = CoreMintFacet(deployment.core);
        recovery = CoreRecoveryFacet(deployment.core);
        transition = CoreTransitionFacet(deployment.core);
        viewFacet = CoreViewFacet(deployment.core);
        staticsDollar = StaticsDollar(deployment.staticsDollar);
        staticsDollarRisk = StaticsDollarRiskShares(deployment.staticsDollarRisk);

        usdc = new MockUSDC();
        usdcOracle = new MockETHUSDOracle(1e18, 30 days);
        vm.prank(owner);
        profileId = governance.createPeggedCollateralProfile(
            address(usdc), address(usdcOracle), 0.995e18, 1.005e18, 5, 7, 10_000_000e18
        );
        vm.prank(owner);
        governance.setProfileMode(profileId, IStaticsDollarCoreTypes.ProfileMode.Active);
    }

    function test_FungibleDollarPartiallyAndFinallyRedeemsPeggedBacking() public {
        IStaticsDollarCoreTypes.PeggedMintPreview memory mintPreview = _mintPegged(alice, 100e18);
        vm.prank(alice);
        staticsDollar.transfer(bob, 40e18);

        IStaticsDollarCoreTypes.PeggedRedemptionPreview memory bobPreview =
            mintFacet.previewPeggedRedemption(profileId, 40e18);
        uint256 bobBefore = usdc.balanceOf(bob);
        vm.prank(bob);
        (IStaticsDollarCoreTypes.ExitStatus status, uint256 collateralOut) =
            mintFacet.redeemPegged(profileId, 40e18, bobPreview.collateralOut, bob);
        assertEq(uint256(status), uint256(IStaticsDollarCoreTypes.ExitStatus.Available));
        assertEq(collateralOut, bobPreview.collateralOut);
        assertEq(usdc.balanceOf(bob) - bobBefore, bobPreview.collateralOut);

        IStaticsDollarCoreTypes.PeggedRedemptionPreview memory finalPreview =
            mintFacet.previewPeggedRedemption(profileId, 60e18);
        vm.prank(alice);
        mintFacet.redeemPegged(profileId, 60e18, finalPreview.collateralOut, alice);

        IStaticsDollarCoreTypes.StableCollateralProfile memory profile = viewFacet.collateralProfile(profileId);
        assertEq(profile.accountedCollateral, 0);
        assertEq(profile.seniorOutstanding, 0);
        assertEq(viewFacet.seniorLiabilities(), 0);
        assertEq(staticsDollar.totalSupply(), 0);
        assertEq(usdc.balanceOf(deployment.core), 0);
        assertEq(
            IStaticsGlobalRewards(deployment.diamond).treasuryAccrued(address(usdc)),
            mintPreview.feeAmount + bobPreview.feeAmount + finalPreview.feeAmount
        );
    }

    function test_RedemptionAllowsReduceOnlyAndRetired() public {
        _mintPegged(alice, 100e18);
        vm.prank(profileGuardian);
        governance.enterReduceOnly(profileId);
        vm.prank(alice);
        mintFacet.redeemPegged(profileId, 40e18, 0, alice);

        vm.prank(owner);
        governance.setProfileMode(profileId, IStaticsDollarCoreTypes.ProfileMode.Retired);
        vm.prank(alice);
        mintFacet.redeemPegged(profileId, 60e18, 0, alice);
        assertEq(staticsDollar.balanceOf(alice), 0);
        assertEq(viewFacet.collateralProfile(profileId).accountedCollateral, 0);
    }

    function test_DownsideCancellationStartsFreshHealthyWindow() public {
        _mintPegged(alice, 100e18);
        wethOracle.setPriceWad(1_600e18);
        wethOracle.setUpdatedAt(block.timestamp);
        transition.startSeriesTransition(1);

        (IStaticsDollarCoreTypes.ExitStatus status,,,) = health.peggedRedemptionStatus();
        assertEq(uint256(status), uint256(IStaticsDollarCoreTypes.ExitStatus.DownsideTransition));
        uint256 dollarBefore = staticsDollar.balanceOf(alice);
        vm.prank(alice);
        (status,) = mintFacet.redeemPegged(profileId, 100e18, 0, alice);
        assertEq(uint256(status), uint256(IStaticsDollarCoreTypes.ExitStatus.DownsideTransition));
        assertEq(staticsDollar.balanceOf(alice), dollarBefore);

        wethOracle.setPriceWad(2_500e18);
        wethOracle.setUpdatedAt(block.timestamp);
        transition.cancelSeriesTransition(1);
        uint256 recoveryAvailableAt;
        (status,,, recoveryAvailableAt) = health.checkpointPeggedRedemption();
        assertEq(uint256(status), uint256(IStaticsDollarCoreTypes.ExitStatus.Recovering));
        assertEq(recoveryAvailableAt, block.timestamp + 48 hours);

        vm.warp(recoveryAvailableAt);
        _refreshOracles();
        (status,,,) = health.checkpointPeggedRedemption();
        assertEq(uint256(status), uint256(IStaticsDollarCoreTypes.ExitStatus.Available));
        vm.prank(alice);
        mintFacet.redeemPegged(profileId, 100e18, 0, alice);
        assertEq(staticsDollar.balanceOf(alice), 0);
    }

    function test_FinalizedDownsideStaysClosedUntilHistoricalBookResolves() public {
        uint256 volatileMinted = _depositWeth(alice, 1e18);
        _mintPegged(alice, 100e18);
        wethOracle.setPriceWad(1_600e18);
        wethOracle.setUpdatedAt(block.timestamp);
        transition.startSeriesTransition(1);
        vm.prank(alice);
        staticsDollarRisk.setApprovalForAll(deployment.core, true);
        vm.prank(alice);
        transition.returnRiskShares(1, volatileMinted);
        IStaticsDollarCoreTypes.SeriesRecoveryState memory state = viewFacet.seriesRecoveryState(1);
        vm.warp(state.endsAt);
        _refreshOracles();
        transition.finalizeSeriesTransition(1);

        vm.prank(alice);
        (IStaticsDollarCoreTypes.ExitStatus status,) = mintFacet.redeemPegged(profileId, 100e18, 0, alice);
        assertEq(uint256(status), uint256(IStaticsDollarCoreTypes.ExitStatus.Impaired));
        assertEq(staticsDollar.balanceOf(alice), volatileMinted + 100e18);

        IStaticsDollarCoreTypes.RecoveryClaimPreview memory junior =
            recovery.previewReturnedRiskClaim(alice, 1, IStaticsDollarCoreTypes.RecoveryClaimMode.CollateralOnly);
        vm.prank(alice);
        recovery.claimReturnedRisk(
            1, IStaticsDollarCoreTypes.RecoveryClaimMode.CollateralOnly, 0, 0, junior.collateralOut, alice
        );
        state = viewFacet.seriesRecoveryState(1);
        vm.prank(alice);
        recovery.redeemRecoverySenior(1, state.seniorRecoveryOutstanding, 0, alice);
        assertTrue(health.profileSolvency(1).healthy);
        assertEq(uint256(viewFacet.riskSeries(1).status), uint256(IStaticsDollarCoreTypes.SeriesStatus.Closed));

        uint256 recoveryAvailableAt;
        (status,,, recoveryAvailableAt) = health.checkpointPeggedRedemption();
        assertEq(uint256(status), uint256(IStaticsDollarCoreTypes.ExitStatus.Recovering));
        vm.warp(recoveryAvailableAt);
        _refreshOracles();
        (status,,,) = health.checkpointPeggedRedemption();
        assertEq(uint256(status), uint256(IStaticsDollarCoreTypes.ExitStatus.Available));
        vm.prank(alice);
        mintFacet.redeemPegged(profileId, 100e18, 0, alice);
        assertEq(staticsDollar.totalSupply(), 0);
    }

    function test_RecoveryTimerResetsOnOracleFailure() public {
        _mintPegged(alice, 100e18);
        wethOracle.setPriceWad(1_600e18);
        wethOracle.setUpdatedAt(block.timestamp);
        transition.startSeriesTransition(1);
        wethOracle.setPriceWad(2_500e18);
        wethOracle.setUpdatedAt(block.timestamp);
        transition.cancelSeriesTransition(1);

        (IStaticsDollarCoreTypes.ExitStatus status,,, uint256 firstAvailableAt) =
            health.checkpointPeggedRedemption();
        assertEq(uint256(status), uint256(IStaticsDollarCoreTypes.ExitStatus.Recovering));
        vm.warp(block.timestamp + 24 hours);
        usdcOracle.setInvalidPrice(true);
        (status,,,) = health.checkpointPeggedRedemption();
        assertEq(uint256(status), uint256(IStaticsDollarCoreTypes.ExitStatus.HealthUnavailable));

        usdcOracle.setInvalidPrice(false);
        _refreshOracles();
        uint256 restartedAvailableAt;
        (status,,, restartedAvailableAt) = health.checkpointPeggedRedemption();
        assertEq(uint256(status), uint256(IStaticsDollarCoreTypes.ExitStatus.Recovering));
        assertGt(restartedAvailableAt, firstAvailableAt);
        assertEq(restartedAvailableAt, block.timestamp + 48 hours);
    }

    function test_MultipleDownsideTransitionsMustAllResolve() public {
        CanonicalWETH9 secondCollateral = new CanonicalWETH9();
        MockETHUSDOracle secondOracle = new MockETHUSDOracle(100e18, 30 days);
        vm.prank(owner);
        (uint256 secondProfile,) = governance.createCollateralProfile(
            address(secondCollateral), address(secondOracle), 15_000, 15_000, 0, 0, 1_000_000e18
        );
        vm.prank(owner);
        governance.setProfileMode(secondProfile, IStaticsDollarCoreTypes.ProfileMode.Active);

        wethOracle.setPriceWad(1_600e18);
        wethOracle.setUpdatedAt(block.timestamp);
        secondOracle.setPriceWad(60e18);
        secondOracle.setUpdatedAt(block.timestamp);
        transition.startSeriesTransition(1);
        transition.startSeriesTransition(secondProfile);

        wethOracle.setPriceWad(2_500e18);
        wethOracle.setUpdatedAt(block.timestamp);
        transition.cancelSeriesTransition(1);
        (IStaticsDollarCoreTypes.ExitStatus status,,,) = health.peggedRedemptionStatus();
        assertEq(uint256(status), uint256(IStaticsDollarCoreTypes.ExitStatus.DownsideTransition));

        secondOracle.setPriceWad(100e18);
        secondOracle.setUpdatedAt(block.timestamp);
        transition.cancelSeriesTransition(2);
        (status,,,) = health.checkpointPeggedRedemption();
        assertEq(uint256(status), uint256(IStaticsDollarCoreTypes.ExitStatus.Recovering));
    }

    function test_CustodyShortfallBlocksPeggedRedemption() public {
        _mintPegged(alice, 100e18);
        // Deliberately corrupt physical custody to exercise an otherwise unreachable
        // shortfall branch; the mint and redemption paths use real transfers above.
        vm.prank(deployment.core);
        usdc.transfer(makeAddr("sink"), 1e6);
        (IStaticsDollarCoreTypes.ExitStatus status, uint256 bitmap,,) = health.checkpointPeggedRedemption();
        assertEq(uint256(status), uint256(IStaticsDollarCoreTypes.ExitStatus.Impaired));
        assertEq(bitmap, uint256(1) << profileId);
    }

    function testFuzz_PartialRedemptionConservesProfileBacking(uint96 rawAmount) public {
        IStaticsDollarCoreTypes.PeggedMintPreview memory mintPreview = _mintPegged(alice, 1_000e18);
        uint256 amount = bound(uint256(rawAmount), 1e18, 999e18);
        IStaticsDollarCoreTypes.PeggedRedemptionPreview memory preview =
            mintFacet.previewPeggedRedemption(profileId, amount);
        vm.prank(alice);
        mintFacet.redeemPegged(profileId, amount, preview.collateralOut, alice);

        IStaticsDollarCoreTypes.StableCollateralProfile memory profile = viewFacet.collateralProfile(profileId);
        assertEq(profile.seniorOutstanding, 1_000e18 - amount);
        assertEq(profile.accountedCollateral, mintPreview.principalCollateral - preview.grossCollateral);
        assertEq(usdc.balanceOf(deployment.core), profile.accountedCollateral);
        assertEq(staticsDollar.totalSupply(), viewFacet.seniorLiabilities());
    }

    function _mintPegged(address receiver, uint256 amount)
        private
        returns (IStaticsDollarCoreTypes.PeggedMintPreview memory preview)
    {
        preview = mintFacet.previewPeggedMint(profileId, amount);
        usdc.mint(receiver, preview.totalCollateralIn);
        vm.startPrank(receiver);
        usdc.approve(deployment.core, preview.totalCollateralIn);
        mintFacet.mintPegged(profileId, amount, preview.totalCollateralIn, receiver);
        vm.stopPrank();
    }

    function _depositWeth(address receiver, uint256 collateralAmount) private returns (uint256 minted) {
        vm.deal(receiver, receiver.balance + collateralAmount);
        vm.prank(receiver);
        weth.deposit{value: collateralAmount}();
        vm.prank(receiver);
        weth.approve(deployment.core, collateralAmount);
        IStaticsDollarCoreTypes.DepositPreview memory preview = mintFacet.previewDeposit(1, collateralAmount);
        vm.prank(receiver);
        (, minted,) = mintFacet.depositCollateral(
            1, collateralAmount, preview.staticsDollarMinted, preview.sharesMinted, receiver, receiver
        );
    }

    function _refreshOracles() private {
        wethOracle.setUpdatedAt(block.timestamp);
        usdcOracle.setUpdatedAt(block.timestamp);
    }
}
