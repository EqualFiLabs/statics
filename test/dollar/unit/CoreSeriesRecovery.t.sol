// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";

import {
    CoreBootstrapConfig,
    CoreBootstrapDeployment,
    DeployCoreBootstrap
} from "script/dollar/DeployCoreBootstrap.s.sol";
import {CoreGovernanceFacet} from "src/dollar/core/facets/CoreGovernanceFacet.sol";
import {CoreHealthFacet} from "src/dollar/core/facets/CoreHealthFacet.sol";
import {CoreInsuranceFacet} from "src/dollar/core/facets/CoreInsuranceFacet.sol";
import {CoreMintFacet} from "src/dollar/core/facets/CoreMintFacet.sol";
import {CoreRecoveryFacet} from "src/dollar/core/facets/CoreRecoveryFacet.sol";
import {CoreTransitionFacet} from "src/dollar/core/facets/CoreTransitionFacet.sol";
import {CoreViewFacet} from "src/dollar/core/facets/CoreViewFacet.sol";
import {LibCoreAccounting} from "src/dollar/core/libraries/LibCoreAccounting.sol";
import {LibDiamond} from "src/libraries/LibDiamond.sol";
import {StaticsDollarRiskShares} from "src/dollar/StaticsDollarRiskShares.sol";
import {StaticsDollar} from "src/dollar/StaticsDollar.sol";
import {IStaticsDollarCoreTypes} from "src/dollar/interfaces/IStaticsDollarCoreTypes.sol";
import {CanonicalWETH9} from "src/dollar/mocks/CanonicalWETH9.sol";
import {MockETHUSDOracle} from "src/dollar/mocks/MockETHUSDOracle.sol";

contract ZeroDecimalRecoveryCollateral is ERC20 {
    constructor() ERC20("Zero Decimal Recovery Collateral", "ZDRC") {}

    function decimals() public pure override returns (uint8) {
        return 0;
    }

    function mint(address receiver, uint256 amount) external {
        _mint(receiver, amount);
    }
}

contract ManagedRecoveryActor is ERC1155Holder {
    function recover(
        CoreRecoveryFacet recoveryFacet,
        uint256 seriesId,
        uint256 shares,
        IStaticsDollarCoreTypes.RecoveryClaimMode mode
    ) external {
        recoveryFacet.recoverExpiredRisk(address(this), seriesId, shares, mode, 0);
    }
}

contract CoreSeriesRecoveryTest is Test {
    address internal owner = makeAddr("owner");
    address internal profileGuardian = makeAddr("profileGuardian");
    address internal alice = makeAddr("alice");
    address internal keeper = makeAddr("keeper");
    address internal executor = makeAddr("executor");

    CanonicalWETH9 internal weth;
    MockETHUSDOracle internal oracle;
    CoreBootstrapDeployment internal deployment;
    CoreMintFacet internal mintFacet;
    CoreTransitionFacet internal transition;
    CoreRecoveryFacet internal recoveryFacet;
    CoreGovernanceFacet internal governance;
    CoreHealthFacet internal healthFacet;
    CoreInsuranceFacet internal insuranceFacet;
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
        config.stakingToken = address(weth);
        config.riskUri = "ipfs://risk/{id}.json";
        deployment = new DeployCoreBootstrap().deploy(config);
        mintFacet = CoreMintFacet(deployment.core);
        transition = CoreTransitionFacet(deployment.core);
        recoveryFacet = CoreRecoveryFacet(deployment.core);
        governance = CoreGovernanceFacet(deployment.core);
        healthFacet = CoreHealthFacet(deployment.core);
        insuranceFacet = CoreInsuranceFacet(deployment.core);
        viewFacet = CoreViewFacet(deployment.core);
        staticsDollar = StaticsDollar(deployment.staticsDollar);
        staticsDollarRisk = StaticsDollarRiskShares(deployment.staticsDollarRisk);
    }

    function test_ReturnedAndExpiredUpsideRecoverySettleEveryAggregateBook() public {
        uint256 minted = _depositWeth(2e18);
        uint256 returned = minted / 2;
        uint256 successorSeriesId = _finalizeUpside(returned);
        assertEq(successorSeriesId, 2);

        IStaticsDollarCoreTypes.RecoveryClaimPreview memory returnedPreview =
            recoveryFacet.previewReturnedRiskClaim(alice, 1, IStaticsDollarCoreTypes.RecoveryClaimMode.ExactUnits);
        if (returnedPreview.collateralIn != 0) _fundAndApproveWeth(alice, returnedPreview.collateralIn);
        uint256 newRiskBefore = staticsDollarRisk.balanceOf(alice, successorSeriesId);
        vm.prank(alice);
        recoveryFacet.claimReturnedRisk(
            1,
            IStaticsDollarCoreTypes.RecoveryClaimMode.ExactUnits,
            returnedPreview.collateralIn,
            returnedPreview.successorPairs,
            returnedPreview.collateralOut,
            alice
        );
        assertEq(staticsDollarRisk.balanceOf(alice, successorSeriesId) - newRiskBefore, returnedPreview.successorPairs);
        assertEq(viewFacet.returnedRiskShares(1, alice), 0);

        IStaticsDollarCoreTypes.SeriesRecoveryState memory recoveryState = viewFacet.seriesRecoveryState(1);
        uint256 seniorClaim = recoveryState.seniorRecoveryOutstanding;
        uint256 aliceWethBefore = weth.balanceOf(alice);
        vm.prank(alice);
        uint256 seniorCollateral = recoveryFacet.redeemRecoverySenior(1, seniorClaim, 0, alice);
        assertEq(weth.balanceOf(alice) - aliceWethBefore, seniorCollateral);

        uint256 expiredShares = staticsDollarRisk.balanceOf(alice, 1);
        vm.prank(alice);
        staticsDollar.transfer(keeper, expiredShares);
        IStaticsDollarCoreTypes.ExpiredRiskRecoveryPreview memory expiredPreview =
            recoveryFacet.previewExpiredRiskRecovery(
                alice, 1, expiredShares, IStaticsDollarCoreTypes.RecoveryClaimMode.NAV
            );
        uint256 keeperWethBefore = weth.balanceOf(keeper);
        uint256 holderSuccessorBefore = staticsDollarRisk.balanceOf(alice, successorSeriesId);
        vm.prank(keeper);
        recoveryFacet.recoverExpiredRisk(
            alice,
            1,
            expiredShares,
            IStaticsDollarCoreTypes.RecoveryClaimMode.NAV,
            expiredPreview.seniorCollateralOut + expiredPreview.keeperBounty
        );

        assertEq(
            weth.balanceOf(keeper) - keeperWethBefore, expiredPreview.seniorCollateralOut + expiredPreview.keeperBounty
        );
        assertEq(
            staticsDollarRisk.balanceOf(alice, successorSeriesId) - holderSuccessorBefore, expiredPreview.holderPairs
        );
        assertEq(staticsDollarRisk.balanceOf(alice, 1), 0);
        assertEq(uint256(viewFacet.riskSeries(1).status), uint256(IStaticsDollarCoreTypes.SeriesStatus.Closed));
        (uint256 remainingShares, uint256 remainingCollateral,,) = viewFacet.expiredRecoveryBook(1);
        assertEq(remainingShares, 0);
        assertEq(remainingCollateral, 0);
        assertEq(staticsDollar.totalSupply(), viewFacet.seniorLiabilities());
        assertEq(weth.balanceOf(deployment.core), viewFacet.totalCollateral(address(weth)));
    }

    function test_TransitionCanCancelAndReturnEscrowCanBeReclaimed() public {
        uint256 minted = _depositWeth(1e18);
        oracle.setPriceWad(4_000e18);
        oracle.setUpdatedAt(block.timestamp);
        transition.startSeriesTransition(1);
        vm.prank(alice);
        staticsDollarRisk.setApprovalForAll(deployment.core, true);
        vm.prank(alice);
        transition.returnRiskShares(1, minted / 3);

        oracle.setPriceWad(2_500e18);
        oracle.setUpdatedAt(block.timestamp);
        transition.cancelSeriesTransition(1);
        uint256 balanceBefore = staticsDollarRisk.balanceOf(alice, 1);
        vm.prank(alice);
        uint256 reclaimed = transition.reclaimReturnedRiskShares(1, alice);
        assertEq(staticsDollarRisk.balanceOf(alice, 1) - balanceBefore, reclaimed);
        assertEq(staticsDollarRisk.balanceOf(alice, 1), minted);
        assertEq(uint256(viewFacet.riskSeries(1).status), uint256(IStaticsDollarCoreTypes.SeriesStatus.Active));
    }

    function test_OracleActivationCancelsPendingTransitionAndIncrementsRevision() public {
        _depositWeth(1e18);
        oracle.setPriceWad(4_000e18);
        oracle.setUpdatedAt(block.timestamp);
        transition.startSeriesTransition(1);
        (address snapshottedOracle, uint256 revision,,) = viewFacet.transitionSnapshot(1);
        assertEq(snapshottedOracle, address(oracle));
        assertEq(revision, 1);

        MockETHUSDOracle replacement = new MockETHUSDOracle(4_000e18, 30 days);
        vm.prank(owner);
        governance.setProfileOracle(1, address(replacement));

        assertEq(uint256(viewFacet.riskSeries(1).status), uint256(IStaticsDollarCoreTypes.SeriesStatus.Active));
        assertEq(uint256(viewFacet.seriesRecoveryState(1).kind), uint256(IStaticsDollarCoreTypes.TransitionKind.None));
        (snapshottedOracle,,,) = viewFacet.transitionSnapshot(1);
        assertEq(snapshottedOracle, address(0));
        assertEq(viewFacet.profileOracleRevision(1), 2);
    }

    function test_RetirementCannotOverwritePendingReturnEscrow() public {
        uint256 minted = _depositWeth(1e18);
        oracle.setPriceWad(4_000e18);
        oracle.setUpdatedAt(block.timestamp);
        transition.startSeriesTransition(1);
        vm.prank(alice);
        staticsDollarRisk.setApprovalForAll(deployment.core, true);
        vm.prank(alice);
        transition.returnRiskShares(1, minted);

        vm.prank(profileGuardian);
        governance.enterReduceOnly(1);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(CoreGovernanceFacet.SeriesTransitionPending.selector, 1, 1));
        governance.setProfileMode(1, IStaticsDollarCoreTypes.ProfileMode.Retired);

        oracle.setPriceWad(2_500e18);
        oracle.setUpdatedAt(block.timestamp);
        transition.cancelSeriesTransition(1);
        vm.prank(alice);
        transition.reclaimReturnedRiskShares(1, alice);
        assertEq(staticsDollarRisk.balanceOf(alice, 1), minted);
    }

    function test_PermissionlessRecoveryRejectsFragmentationButFullRecoveryPaysBounty() public {
        uint256 minted = _depositWeth(1e18);
        _finalizeUpside(0);
        vm.prank(alice);
        staticsDollar.transfer(keeper, minted);

        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(CoreRecoveryFacet.PartialRecoveryNotAllowed.selector, alice, minted / 2, minted)
        );
        recoveryFacet.recoverExpiredRisk(alice, 1, minted / 2, IStaticsDollarCoreTypes.RecoveryClaimMode.NAV, 0);

        IStaticsDollarCoreTypes.ExpiredRiskRecoveryPreview memory preview =
            recoveryFacet.previewExpiredRiskRecovery(alice, 1, minted, IStaticsDollarCoreTypes.RecoveryClaimMode.NAV);
        assertGt(preview.keeperBounty, 0);
        uint256 keeperBefore = weth.balanceOf(keeper);
        vm.prank(keeper);
        recoveryFacet.recoverExpiredRisk(
            alice,
            1,
            minted,
            IStaticsDollarCoreTypes.RecoveryClaimMode.NAV,
            preview.seniorCollateralOut + preview.keeperBounty
        );
        assertEq(weth.balanceOf(keeper) - keeperBefore, preview.seniorCollateralOut + preview.keeperBounty);
    }

    function test_CollateralOnlyRunoffSurvivesPausedIssuanceAndRetirement() public {
        uint256 minted = _depositWeth(1e18);
        _finalizeUpside(minted);
        uint256 currentSeries = _rollActiveUpside(6_500e18);
        assertEq(currentSeries, 3);
        vm.prank(profileGuardian);
        governance.pauseProfileOperations(1, 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LibCoreAccounting.ProfileOperationPaused.selector, 1, 1));
        recoveryFacet.claimReturnedRisk(1, IStaticsDollarCoreTypes.RecoveryClaimMode.NAV, 0, 0, 0, alice);

        vm.prank(profileGuardian);
        governance.enterReduceOnly(1);
        vm.prank(owner);
        governance.setProfileMode(1, IStaticsDollarCoreTypes.ProfileMode.Retired);
        assertEq(uint256(viewFacet.collateralProfile(1).mode), uint256(IStaticsDollarCoreTypes.ProfileMode.Retired));

        IStaticsDollarCoreTypes.RecoveryClaimPreview memory preview =
            recoveryFacet.previewReturnedRiskClaim(alice, 1, IStaticsDollarCoreTypes.RecoveryClaimMode.CollateralOnly);
        uint256 balanceBefore = weth.balanceOf(alice);
        vm.prank(alice);
        recoveryFacet.claimReturnedRisk(
            1, IStaticsDollarCoreTypes.RecoveryClaimMode.CollateralOnly, 0, 0, preview.collateralOut, alice
        );
        assertEq(weth.balanceOf(alice) - balanceBefore, preview.collateralOut);

        IStaticsDollarCoreTypes.SeriesRecoveryState memory state = viewFacet.seriesRecoveryState(1);
        vm.prank(alice);
        recoveryFacet.redeemRecoverySenior(1, state.seniorRecoveryOutstanding, 0, alice);
        assertEq(uint256(viewFacet.riskSeries(1).status), uint256(IStaticsDollarCoreTypes.SeriesStatus.Closed));
        assertEq(staticsDollar.totalSupply(), 0);
        assertEq(viewFacet.totalCollateral(address(weth)), 0);
    }

    function test_HistoricalNavClaimSkipsRetiredSuccessors() public {
        uint256 minted = _depositWeth(1e18);
        uint256 firstSuccessor = _finalizeUpside(minted);
        uint256 currentSeries = _rollActiveUpside(6_500e18);

        IStaticsDollarCoreTypes.RecoveryClaimPreview memory preview =
            recoveryFacet.previewReturnedRiskClaim(alice, 1, IStaticsDollarCoreTypes.RecoveryClaimMode.NAV);
        assertEq(preview.successorSeriesId, currentSeries);
        assertNotEq(preview.successorSeriesId, firstSuccessor);

        vm.prank(alice);
        recoveryFacet.claimReturnedRisk(
            1,
            IStaticsDollarCoreTypes.RecoveryClaimMode.NAV,
            preview.collateralIn,
            preview.successorPairs,
            preview.collateralOut,
            alice
        );
        assertEq(staticsDollarRisk.balanceOf(alice, firstSuccessor), 0);
        assertEq(staticsDollarRisk.balanceOf(alice, currentSeries), preview.successorPairs);
    }

    function test_RecoveryIssuanceCannotExceedReducedDebtCeiling() public {
        uint256 minted = _depositWeth(1e18);
        _finalizeUpside(minted);
        uint256 currentOutstanding = viewFacet.collateralProfile(1).seniorOutstanding;
        vm.prank(profileGuardian);
        governance.reduceDebtCeiling(1, currentOutstanding);

        IStaticsDollarCoreTypes.RecoveryClaimPreview memory preview =
            recoveryFacet.previewReturnedRiskClaim(alice, 1, IStaticsDollarCoreTypes.RecoveryClaimMode.NAV);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                CoreRecoveryFacet.DebtCeilingExceeded.selector,
                1,
                currentOutstanding + preview.successorPairs,
                currentOutstanding
            )
        );
        recoveryFacet.claimReturnedRisk(1, IStaticsDollarCoreTypes.RecoveryClaimMode.NAV, 0, 0, 0, alice);
    }

    function test_RecoveryCollateralExitCannotBypassAnotherProfileImpairment() public {
        uint256 minted = _depositWeth(1e18);
        _finalizeUpside(minted);

        ZeroDecimalRecoveryCollateral collateral = new ZeroDecimalRecoveryCollateral();
        MockETHUSDOracle lowDecimalOracle = new MockETHUSDOracle(10e18, 30 days);
        (uint256 profileId,) = _activateLowDecimalProfile(collateral, lowDecimalOracle);
        collateral.mint(alice, 10_000);
        vm.prank(alice);
        collateral.approve(deployment.core, 10_000);
        IStaticsDollarCoreTypes.DepositPreview memory depositPreview = mintFacet.previewDeposit(profileId, 10_000);
        vm.prank(alice);
        mintFacet.depositCollateral(
            profileId, 10_000, depositPreview.staticsDollarMinted, depositPreview.sharesMinted, alice, alice
        );
        lowDecimalOracle.setPriceWad(1e18);
        lowDecimalOracle.setUpdatedAt(block.timestamp);
        oracle.setUpdatedAt(block.timestamp);

        IStaticsDollarCoreTypes.RecoveryClaimPreview memory preview =
            recoveryFacet.previewReturnedRiskClaim(alice, 1, IStaticsDollarCoreTypes.RecoveryClaimMode.CollateralOnly);
        assertEq(preview.oldShares, minted);
        vm.prank(alice);
        vm.expectPartialRevert(CoreRecoveryFacet.CollateralExitUnavailable.selector);
        recoveryFacet.claimReturnedRisk(
            1, IStaticsDollarCoreTypes.RecoveryClaimMode.CollateralOnly, 0, 0, preview.collateralOut, alice
        );
    }

    function test_DownsideHaircutRunoffCanHealTheImpairedProfile() public {
        uint256 minted = _depositWeth(1e18);
        oracle.setPriceWad(1_600e18);
        oracle.setUpdatedAt(block.timestamp);
        transition.startSeriesTransition(1);
        vm.prank(alice);
        staticsDollarRisk.setApprovalForAll(deployment.core, true);
        vm.prank(alice);
        transition.returnRiskShares(1, minted);
        IStaticsDollarCoreTypes.SeriesRecoveryState memory state = viewFacet.seriesRecoveryState(1);
        vm.warp(state.endsAt);
        oracle.setUpdatedAt(block.timestamp);
        transition.finalizeSeriesTransition(1);

        IStaticsDollarCoreTypes.RecoveryClaimPreview memory juniorPreview =
            recoveryFacet.previewReturnedRiskClaim(alice, 1, IStaticsDollarCoreTypes.RecoveryClaimMode.CollateralOnly);
        assertEq(juniorPreview.collateralOut, 0);
        vm.prank(alice);
        recoveryFacet.claimReturnedRisk(1, IStaticsDollarCoreTypes.RecoveryClaimMode.CollateralOnly, 0, 0, 0, alice);

        IStaticsDollarCoreTypes.ProfileSolvency memory impaired = healthFacet.profileSolvency(1);
        assertFalse(impaired.healthy);
        uint256 collateralBefore = weth.balanceOf(alice);
        vm.prank(alice);
        uint256 haircutOut = recoveryFacet.redeemRecoverySenior(1, minted, 0, alice);
        assertEq(weth.balanceOf(alice) - collateralBefore, haircutOut);
        assertLt(haircutOut * 1_600e18 / 1e18, minted);
        assertTrue(healthFacet.profileSolvency(1).healthy);
        assertEq(staticsDollar.totalSupply(), 0);
        assertEq(uint256(viewFacet.riskSeries(1).status), uint256(IStaticsDollarCoreTypes.SeriesStatus.Closed));
    }

    function test_LowDecimalRecombineThenRecoverySweepsHistoricalBook() public {
        ZeroDecimalRecoveryCollateral collateral = new ZeroDecimalRecoveryCollateral();
        MockETHUSDOracle lowDecimalOracle = new MockETHUSDOracle(10e18, 30 days);
        (uint256 profileId, uint256 seriesId) = _activateLowDecimalProfile(collateral, lowDecimalOracle);
        uint256 collateralAmount = 10;
        collateral.mint(alice, collateralAmount);
        vm.prank(alice);
        collateral.approve(deployment.core, collateralAmount);
        IStaticsDollarCoreTypes.DepositPreview memory depositPreview =
            mintFacet.previewDeposit(profileId, collateralAmount);
        vm.prank(alice);
        (, uint256 minted,) = mintFacet.depositCollateral(
            profileId, collateralAmount, depositPreview.staticsDollarMinted, depositPreview.sharesMinted, alice, alice
        );

        lowDecimalOracle.setPriceWad(16e18);
        lowDecimalOracle.setUpdatedAt(block.timestamp);
        transition.startSeriesTransition(profileId);
        IStaticsDollarCoreTypes.SeriesRecoveryState memory state = viewFacet.seriesRecoveryState(seriesId);
        vm.warp(state.endsAt);
        lowDecimalOracle.setUpdatedAt(block.timestamp);
        transition.finalizeSeriesTransition(seriesId);

        uint256 recombined = minted / 3;
        vm.prank(alice);
        mintFacet.recombine(seriesId, recombined, recombined, 0, alice);
        uint256 remaining = minted - recombined;
        vm.prank(alice);
        staticsDollar.transfer(keeper, remaining);
        vm.prank(keeper);
        recoveryFacet.recoverExpiredRisk(alice, seriesId, remaining, IStaticsDollarCoreTypes.RecoveryClaimMode.NAV, 0);

        _assertHistoricalSeriesClosed(seriesId);
        assertEq(collateral.balanceOf(deployment.core), viewFacet.totalCollateral(address(collateral)));
        assertEq(staticsDollar.totalSupply(), viewFacet.seniorLiabilities());
    }

    function test_LowDecimalRecoveryThenRecombineSweepsHistoricalBook() public {
        ZeroDecimalRecoveryCollateral collateral = new ZeroDecimalRecoveryCollateral();
        MockETHUSDOracle lowDecimalOracle = new MockETHUSDOracle(10e18, 30 days);
        (uint256 profileId, uint256 seriesId) = _activateLowDecimalProfile(collateral, lowDecimalOracle);
        address bob = makeAddr("bob");
        uint256 collateralAmount = 10;
        collateral.mint(alice, collateralAmount);
        vm.prank(alice);
        collateral.approve(deployment.core, collateralAmount);
        IStaticsDollarCoreTypes.DepositPreview memory depositPreview =
            mintFacet.previewDeposit(profileId, collateralAmount);
        vm.prank(alice);
        (, uint256 minted,) = mintFacet.depositCollateral(
            profileId, collateralAmount, depositPreview.staticsDollarMinted, depositPreview.sharesMinted, alice, alice
        );
        uint256 recovered = minted / 3;
        uint256 recombined = minted - recovered;
        vm.prank(alice);
        staticsDollarRisk.safeTransferFrom(alice, bob, seriesId, recombined, "");
        vm.startPrank(alice);
        staticsDollar.transfer(keeper, recovered);
        staticsDollar.transfer(bob, recombined);
        vm.stopPrank();

        lowDecimalOracle.setPriceWad(16e18);
        lowDecimalOracle.setUpdatedAt(block.timestamp);
        transition.startSeriesTransition(profileId);
        IStaticsDollarCoreTypes.SeriesRecoveryState memory state = viewFacet.seriesRecoveryState(seriesId);
        vm.warp(state.endsAt);
        lowDecimalOracle.setUpdatedAt(block.timestamp);
        transition.finalizeSeriesTransition(seriesId);

        vm.prank(keeper);
        recoveryFacet.recoverExpiredRisk(alice, seriesId, recovered, IStaticsDollarCoreTypes.RecoveryClaimMode.NAV, 0);
        vm.prank(bob);
        mintFacet.recombine(seriesId, recombined, recombined, 0, bob);

        _assertHistoricalSeriesClosed(seriesId);
        _assertLowDecimalBooksReconcile(collateral);
    }

    function testFuzz_LowDecimalAlternatingSettlementSweepsHistoricalBook(uint256 rawFirst, uint256 rawSecond) public {
        ZeroDecimalRecoveryCollateral collateral = new ZeroDecimalRecoveryCollateral();
        MockETHUSDOracle lowDecimalOracle = new MockETHUSDOracle(10e18, 30 days);
        (uint256 profileId, uint256 seriesId) = _activateLowDecimalProfile(collateral, lowDecimalOracle);
        LowDecimalSplit memory split = _depositAndSplitLowDecimal(collateral, profileId, seriesId, rawFirst, rawSecond);
        _expireLowDecimalSeries(profileId, seriesId, lowDecimalOracle);

        vm.prank(alice);
        mintFacet.recombine(seriesId, split.first, split.first, 0, alice);
        vm.prank(keeper);
        recoveryFacet.recoverExpiredRisk(split.bob, seriesId, split.second, IStaticsDollarCoreTypes.RecoveryClaimMode.NAV, 0);
        vm.prank(split.carol);
        mintFacet.recombine(seriesId, split.third, split.third, 0, split.carol);

        _assertHistoricalSeriesClosed(seriesId);
        _assertLowDecimalBooksReconcile(collateral);
    }

    struct LowDecimalSplit {
        uint256 first;
        uint256 second;
        uint256 third;
        address bob;
        address carol;
    }

    function _depositAndSplitLowDecimal(
        ZeroDecimalRecoveryCollateral collateral,
        uint256 profileId,
        uint256 seriesId,
        uint256 rawFirst,
        uint256 rawSecond
    ) private returns (LowDecimalSplit memory split) {
        split.bob = makeAddr("alternatingBob");
        split.carol = makeAddr("alternatingCarol");
        uint256 collateralAmount = 10;
        collateral.mint(alice, collateralAmount);
        vm.prank(alice);
        collateral.approve(deployment.core, collateralAmount);
        IStaticsDollarCoreTypes.DepositPreview memory depositPreview =
            mintFacet.previewDeposit(profileId, collateralAmount);
        vm.prank(alice);
        (, uint256 minted,) = mintFacet.depositCollateral(
            profileId, collateralAmount, depositPreview.staticsDollarMinted, depositPreview.sharesMinted, alice, alice
        );

        uint256 minimumSlice = minted / collateralAmount + 1;
        split.first = bound(rawFirst, minimumSlice, minted - 2 * minimumSlice);
        split.second = bound(rawSecond, minimumSlice, minted - split.first - minimumSlice);
        split.third = minted - split.first - split.second;
        vm.startPrank(alice);
        staticsDollarRisk.safeTransferFrom(alice, split.bob, seriesId, split.second, "");
        staticsDollarRisk.safeTransferFrom(alice, split.carol, seriesId, split.third, "");
        staticsDollar.transfer(keeper, split.second);
        staticsDollar.transfer(split.carol, split.third);
        vm.stopPrank();
    }

    function _expireLowDecimalSeries(uint256 profileId, uint256 seriesId, MockETHUSDOracle lowDecimalOracle) private {
        lowDecimalOracle.setPriceWad(16e18);
        lowDecimalOracle.setUpdatedAt(block.timestamp);
        transition.startSeriesTransition(profileId);
        IStaticsDollarCoreTypes.SeriesRecoveryState memory state = viewFacet.seriesRecoveryState(seriesId);
        vm.warp(state.endsAt);
        lowDecimalOracle.setUpdatedAt(block.timestamp);
        transition.finalizeSeriesTransition(seriesId);
    }

    function _assertLowDecimalBooksReconcile(ZeroDecimalRecoveryCollateral collateral) private view {
        assertEq(collateral.balanceOf(deployment.core), viewFacet.totalCollateral(address(collateral)));
        assertEq(staticsDollar.totalSupply(), viewFacet.seniorLiabilities());
    }

    function test_RecombiningExpiredBookDoesNotCloseReturnedRecoveryBuckets() public {
        uint256 minted = _depositWeth(2e18);
        uint256 returned = minted / 2;
        _finalizeUpside(returned);
        uint256 expired = staticsDollarRisk.balanceOf(alice, 1);

        vm.prank(alice);
        mintFacet.recombine(1, expired, expired, 0, alice);
        assertEq(uint256(viewFacet.riskSeries(1).status), uint256(IStaticsDollarCoreTypes.SeriesStatus.Recoverable));
        (uint256 bookShares, uint256 bookCollateral, uint256 bookSenior, uint256 bookBounty) =
            viewFacet.expiredRecoveryBook(1);
        assertEq(bookShares, 0);
        assertEq(bookCollateral, 0);
        assertEq(bookSenior, 0);
        assertEq(bookBounty, 0);

        vm.prank(alice);
        recoveryFacet.claimReturnedRisk(1, IStaticsDollarCoreTypes.RecoveryClaimMode.CollateralOnly, 0, 0, 0, alice);
        IStaticsDollarCoreTypes.SeriesRecoveryState memory state = viewFacet.seriesRecoveryState(1);
        vm.prank(alice);
        recoveryFacet.redeemRecoverySenior(1, state.seniorRecoveryOutstanding, 0, alice);
        _assertHistoricalSeriesClosed(1);
    }

    function test_RetiredSeriesRecombinationClosesBeforeFutureInsuranceDonations() public {
        uint256 minted = _depositWeth(1e18);
        vm.prank(profileGuardian);
        governance.enterReduceOnly(1);
        vm.prank(owner);
        governance.setProfileMode(1, IStaticsDollarCoreTypes.ProfileMode.Retired);

        vm.prank(alice);
        mintFacet.recombine(1, minted, minted, 0, alice);
        _assertHistoricalSeriesClosed(1);

        uint256 donation = 0.1e18;
        _fundAndApproveWeth(alice, donation);
        vm.prank(alice);
        insuranceFacet.topUpInsurance(1, donation);
        assertEq(viewFacet.collateralProfile(1).insuranceReserve, donation);
        assertEq(viewFacet.riskSeries(1).accountedCollateral, 0);
    }

    function test_GovernanceControlsManagedRecoveryHolders() public {
        assertTrue(viewFacet.managedRecoveryHolder(deployment.diamond));
        ManagedRecoveryActor actor = new ManagedRecoveryActor();

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LibDiamond.NotContractOwner.selector, alice, owner));
        governance.setManagedRecoveryHolder(address(actor), true);

        vm.prank(owner);
        governance.setManagedRecoveryHolder(address(actor), true);
        assertTrue(viewFacet.managedRecoveryHolder(address(actor)));

        vm.prank(owner);
        governance.setManagedRecoveryHolder(address(actor), false);
        assertFalse(viewFacet.managedRecoveryHolder(address(actor)));
    }

    function test_RevokingManagedHolderRestoresPermissionlessRecovery() public {
        ManagedRecoveryActor actor = new ManagedRecoveryActor();
        vm.prank(owner);
        governance.setManagedRecoveryHolder(address(actor), true);

        uint256 collateralAmount = 1 ether;
        _fundAndApproveWeth(alice, collateralAmount);
        IStaticsDollarCoreTypes.DepositPreview memory depositPreview = mintFacet.previewDeposit(1, collateralAmount);
        vm.prank(alice);
        (, uint256 minted,) = mintFacet.depositCollateral(
            1, collateralAmount, depositPreview.staticsDollarMinted, depositPreview.sharesMinted, alice, address(actor)
        );
        _finalizeUpside(0);
        vm.prank(alice);
        staticsDollar.transfer(keeper, minted);

        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(CoreRecoveryFacet.Unauthorized.selector, keeper));
        recoveryFacet.recoverExpiredRisk(address(actor), 1, minted, IStaticsDollarCoreTypes.RecoveryClaimMode.NAV, 0);

        vm.prank(owner);
        governance.setManagedRecoveryHolder(address(actor), false);
        vm.prank(keeper);
        recoveryFacet.recoverExpiredRisk(address(actor), 1, minted, IStaticsDollarCoreTypes.RecoveryClaimMode.NAV, 0);

        assertEq(staticsDollarRisk.balanceOf(address(actor), 1), 0);
        assertGt(staticsDollarRisk.balanceOf(address(actor), 2), 0);
    }

    function testFuzz_LowDecimalManagedRecoveryPartitionsPreserveAggregateBooks(uint256 rawFirstClaim) public {
        (ManagedRecoveryActor actor, uint256 seriesId, uint256 minted, ZeroDecimalRecoveryCollateral collateral) =
            _prepareLowDecimalExpiredSeries();

        (uint256 initialShares,, uint256 initialSenior, uint256 initialBounty) = viewFacet.expiredRecoveryBook(seriesId);
        assertEq(initialShares, minted);
        assertGt(initialBounty, 0);
        uint256 firstClaim = 1 + (rawFirstClaim % (minted - 1));
        IStaticsDollarCoreTypes.ExpiredRiskRecoveryPreview memory first = recoveryFacet.previewExpiredRiskRecovery(
            address(actor), seriesId, firstClaim, IStaticsDollarCoreTypes.RecoveryClaimMode.NAV
        );
        actor.recover(recoveryFacet, seriesId, firstClaim, IStaticsDollarCoreTypes.RecoveryClaimMode.NAV);
        uint256 finalClaim = minted - firstClaim;
        IStaticsDollarCoreTypes.ExpiredRiskRecoveryPreview memory finalPreview = recoveryFacet.previewExpiredRiskRecovery(
            address(actor), seriesId, finalClaim, IStaticsDollarCoreTypes.RecoveryClaimMode.NAV
        );
        actor.recover(recoveryFacet, seriesId, finalClaim, IStaticsDollarCoreTypes.RecoveryClaimMode.NAV);

        assertEq(first.seniorCollateralOut + finalPreview.seniorCollateralOut, initialSenior);
        assertEq(first.keeperBounty + finalPreview.keeperBounty, initialBounty);
        _assertExpiredBooksDrained(seriesId);
        assertEq(collateral.balanceOf(deployment.core), viewFacet.totalCollateral(address(collateral)));
    }

    function _prepareLowDecimalExpiredSeries()
        private
        returns (ManagedRecoveryActor actor, uint256 seriesId, uint256 minted, ZeroDecimalRecoveryCollateral collateral)
    {
        collateral = new ZeroDecimalRecoveryCollateral();
        MockETHUSDOracle lowDecimalOracle = new MockETHUSDOracle(10e18, 30 days);
        (uint256 profileId, uint256 activeSeriesId) = _activateLowDecimalProfile(collateral, lowDecimalOracle);
        seriesId = activeSeriesId;
        actor = new ManagedRecoveryActor();
        vm.prank(owner);
        governance.setManagedRecoveryHolder(address(actor), true);

        uint256 collateralAmount = 10_000;
        collateral.mint(alice, collateralAmount);
        vm.prank(alice);
        collateral.approve(deployment.core, collateralAmount);
        IStaticsDollarCoreTypes.DepositPreview memory depositPreview =
            mintFacet.previewDeposit(profileId, collateralAmount);
        vm.prank(alice);
        (, minted,) = mintFacet.depositCollateral(
            profileId,
            collateralAmount,
            depositPreview.staticsDollarMinted,
            depositPreview.sharesMinted,
            address(actor),
            address(actor)
        );

        lowDecimalOracle.setPriceWad(16e18);
        lowDecimalOracle.setUpdatedAt(block.timestamp);
        transition.startSeriesTransition(profileId);
        IStaticsDollarCoreTypes.SeriesRecoveryState memory state = viewFacet.seriesRecoveryState(seriesId);
        vm.warp(state.endsAt);
        lowDecimalOracle.setUpdatedAt(block.timestamp);
        transition.finalizeSeriesTransition(seriesId);
    }

    function _assertExpiredBooksDrained(uint256 seriesId) private view {
        (uint256 remainingShares, uint256 remainingCollateral, uint256 remainingSenior, uint256 remainingBounty) =
            viewFacet.expiredRecoveryBook(seriesId);
        assertEq(remainingShares, 0);
        assertEq(remainingCollateral, 0);
        assertEq(remainingSenior, 0);
        assertEq(remainingBounty, 0);
        assertEq(uint256(viewFacet.riskSeries(seriesId).status), uint256(IStaticsDollarCoreTypes.SeriesStatus.Closed));
        assertEq(staticsDollar.totalSupply(), viewFacet.seniorLiabilities());
    }

    function test_LowDecimalManagedRecoveryFinalClaimKeepsBountyWithinJunior() public {
        testFuzz_LowDecimalManagedRecoveryPartitionsPreserveAggregateBooks(
            5328967045226502584761812994344905040891273999784560440771896930392683650875
        );
    }

    function _depositWeth(uint256 collateralAmount) private returns (uint256 minted) {
        _fundAndApproveWeth(alice, collateralAmount);
        IStaticsDollarCoreTypes.DepositPreview memory preview = mintFacet.previewDeposit(1, collateralAmount);
        vm.prank(alice);
        (, minted,) = mintFacet.depositCollateral(
            1, collateralAmount, preview.staticsDollarMinted, preview.sharesMinted, alice, alice
        );
    }

    function _finalizeUpside(uint256 returnedShares) private returns (uint256 successorSeriesId) {
        oracle.setPriceWad(4_000e18);
        oracle.setUpdatedAt(block.timestamp);
        transition.startSeriesTransition(1);
        if (returnedShares != 0) {
            vm.prank(alice);
            staticsDollarRisk.setApprovalForAll(deployment.core, true);
            vm.prank(alice);
            transition.returnRiskShares(1, returnedShares);
        }
        IStaticsDollarCoreTypes.SeriesRecoveryState memory state = viewFacet.seriesRecoveryState(1);
        vm.warp(state.endsAt);
        oracle.setUpdatedAt(block.timestamp);
        vm.prank(executor);
        successorSeriesId = transition.finalizeSeriesTransition(1);
    }

    function _rollActiveUpside(uint256 priceWad) private returns (uint256 successorSeriesId) {
        uint256 seriesId = viewFacet.collateralProfile(1).activeSeriesId;
        oracle.setPriceWad(priceWad);
        oracle.setUpdatedAt(block.timestamp);
        transition.startSeriesTransition(1);
        IStaticsDollarCoreTypes.SeriesRecoveryState memory state = viewFacet.seriesRecoveryState(seriesId);
        vm.warp(state.endsAt);
        oracle.setUpdatedAt(block.timestamp);
        vm.prank(executor);
        successorSeriesId = transition.finalizeSeriesTransition(seriesId);
    }

    function _fundAndApproveWeth(address account, uint256 amount) private {
        vm.deal(account, account.balance + amount);
        vm.prank(account);
        weth.deposit{value: amount}();
        vm.prank(account);
        weth.approve(deployment.core, type(uint256).max);
    }

    function _activateLowDecimalProfile(ZeroDecimalRecoveryCollateral collateral, MockETHUSDOracle lowDecimalOracle)
        private
        returns (uint256 profileId, uint256 seriesId)
    {
        vm.prank(owner);
        (profileId, seriesId) = governance.createCollateralProfile(
            address(collateral), address(lowDecimalOracle), 15_000, 15_000, 0, 0, type(uint256).max
        );
        vm.prank(owner);
        governance.setProfileMode(profileId, IStaticsDollarCoreTypes.ProfileMode.Active);
    }

    function _assertHistoricalSeriesClosed(uint256 seriesId) private view {
        IStaticsDollarCoreTypes.RiskSeries memory series = viewFacet.riskSeries(seriesId);
        assertEq(uint256(series.status), uint256(IStaticsDollarCoreTypes.SeriesStatus.Closed));
        assertEq(series.seniorOutstanding, 0);
        assertEq(series.riskSharesOutstanding, 0);
        assertEq(series.accountedCollateral, 0);
        (uint256 shares, uint256 collateral, uint256 senior, uint256 bounty) = viewFacet.expiredRecoveryBook(seriesId);
        assertEq(shares, 0);
        assertEq(collateral, 0);
        assertEq(senior, 0);
        assertEq(bounty, 0);
    }
}
