// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {
    DeployStaticsDollar,
    StaticsDollarLocalConfig,
    StaticsDollarStackDeployment
} from "script/dollar/DeployStaticsDollar.s.sol";
import {StaticsDollarRiskShares} from "src/dollar/StaticsDollarRiskShares.sol";
import {StaticsDollar} from "src/dollar/StaticsDollar.sol";
import {IStaticsDollarCore} from "src/dollar/core/interfaces/IStaticsDollarCore.sol";
import {IStaticsDollarCoreTypes} from "src/dollar/interfaces/IStaticsDollarCoreTypes.sol";
import {CoreTransitionFacet} from "src/dollar/core/facets/CoreTransitionFacet.sol";
import {CoreGovernanceFacet} from "src/dollar/core/facets/CoreGovernanceFacet.sol";
import {CanonicalWETH9} from "src/dollar/mocks/CanonicalWETH9.sol";
import {MockETHUSDOracle} from "src/dollar/mocks/MockETHUSDOracle.sol";
import {PairingVaultFacet} from "src/dollar/periphery/facets/PairingVaultFacet.sol";
import {StakingFacet} from "src/dollar/periphery/facets/StakingFacet.sol";
import {IStaticsGlobalRewards} from "src/interfaces/IStaticsGlobalRewards.sol";

contract PeripherySecurityRegressionTest is Test, IERC1155Receiver {
    uint256 internal constant PROFILE_ID = 1;
    uint256 internal constant SERIES_ID = 1;

    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal redeemer = makeAddr("redeemer");

    StaticsDollarStackDeployment internal deployment;
    IStaticsDollarCore internal core;
    CoreTransitionFacet internal transition;
    StaticsDollar internal staticsDollar;
    StaticsDollarRiskShares internal staticsDollarRisk;
    CanonicalWETH9 internal weth;
    MockETHUSDOracle internal oracle;
    StakingFacet internal staking;
    PairingVaultFacet internal vault;
    IERC20 internal statics;

    function setUp() public {
        vm.warp(30 days);
        StaticsDollarLocalConfig memory config;
        config.owner = owner;
        config.profileGuardian = owner;
        config.deployMockWeth = true;
        config.deployMockOracle = true;
        config.mockOraclePriceWad = 2_500e18;
        config.riskUri = "ipfs://risk/{id}.json";
        config.partnerRecipient = address(0);
        deployment = new DeployStaticsDollar().deployLocal(config);
        core = IStaticsDollarCore(deployment.core);
        transition = CoreTransitionFacet(deployment.core);
        staticsDollar = StaticsDollar(deployment.staticsDollar);
        staticsDollarRisk = StaticsDollarRiskShares(deployment.staticsDollarRisk);
        weth = CanonicalWETH9(payable(deployment.weth));
        oracle = MockETHUSDOracle(deployment.oracle);
        staking = StakingFacet(deployment.diamond);
        vault = PairingVaultFacet(deployment.diamond);
        statics = IERC20(deployment.staticsToken);
        vm.prank(owner);
        statics.transfer(alice, 1_000 ether);
    }

    function test_PermissionlessFundingReservesCanonicalRiskIncentivesWithoutLiquidity() public {
        (uint256 dollars,) = _deposit(alice, 1 ether);
        vm.deal(alice, alice.balance + 1 ether);
        vm.startPrank(alice);
        weth.deposit{value: 1 ether}();
        weth.approve(deployment.diamond, 1 ether);
        staticsDollar.approve(deployment.diamond, dollars);
        statics.approve(deployment.diamond, 100 ether);

        assertEq(staking.fundRiskCollateralIncentives(SERIES_ID, 1 ether), 1 ether);
        assertEq(staking.fundRiskDollarIncentives(SERIES_ID, dollars), dollars);
        assertEq(staking.fundRiskStaticsIncentives(SERIES_ID, 100 ether), 100 ether);
        vm.stopPrank();

        StakingFacet.RiskIncentiveView memory incentives = staking.riskIncentives(SERIES_ID);
        assertEq(incentives.collateralToken, address(weth));
        assertEq(incentives.staticsToken, address(statics));
        assertEq(incentives.collateralReserve, 1 ether);
        assertEq(incentives.staticsDollarReserve, dollars);
        assertEq(incentives.staticsReserve, 100 ether);
        assertFalse(incentives.finalized);
        assertEq(staking.totalRiskLiquidity(SERIES_ID), 0);
        assertEq(staking.reservedBalance(address(weth)), 1 ether);
        assertEq(staking.reservedBalance(address(staticsDollar)), dollars);
        assertEq(staking.reservedBalance(address(statics)), 100 ether);
    }

    function test_RiskFundingRejectsTransitioningSeries() public {
        oracle.setPriceWad(4_000e18);
        transition.startSeriesTransition(PROFILE_ID);

        vm.expectRevert(abi.encodeWithSelector(StakingFacet.SeriesNotIncentiveEligible.selector, SERIES_ID));
        staking.fundRiskStaticsIncentives(SERIES_ID, 1 ether);
    }

    function test_RiskFundingRemainsAvailableInReduceOnlyMode() public {
        vm.prank(owner);
        CoreGovernanceFacet(deployment.core).enterReduceOnly(PROFILE_ID);

        vm.startPrank(alice);
        statics.approve(deployment.diamond, 1 ether);
        assertEq(staking.fundRiskStaticsIncentives(SERIES_ID, 1 ether), 1 ether);
        vm.stopPrank();
    }

    function test_UnusedIncentivesRollToCurrentHealthySuccessorWithoutRiskLiquidity() public {
        vm.startPrank(alice);
        statics.approve(deployment.diamond, 100 ether);
        staking.fundRiskStaticsIncentives(SERIES_ID, 100 ether);
        vm.stopPrank();

        oracle.setPriceWad(4_000e18);
        transition.startSeriesTransition(PROFILE_ID);
        vm.warp(block.timestamp + transition.SERIES_TRANSITION_DELAY());
        uint256 successorSeriesId = transition.finalizeSeriesTransition(SERIES_ID);

        (uint256 destinationSeriesId, bool routedGlobal) = staking.finalizeRiskIncentives(SERIES_ID);
        assertEq(destinationSeriesId, successorSeriesId);
        assertFalse(routedGlobal);

        StakingFacet.RiskIncentiveView memory oldIncentives = staking.riskIncentives(SERIES_ID);
        assertTrue(oldIncentives.finalized);
        assertFalse(oldIncentives.routedGlobal);
        assertEq(oldIncentives.destinationSeriesId, successorSeriesId);
        assertEq(oldIncentives.staticsReserve, 0);
        assertEq(staking.riskIncentives(successorSeriesId).staticsReserve, 100 ether);
        assertEq(staking.reservedBalance(address(statics)), 100 ether);

        (uint256 repeatedDestination, bool repeatedGlobal) = staking.finalizeRiskIncentives(SERIES_ID);
        assertEq(repeatedDestination, successorSeriesId);
        assertFalse(repeatedGlobal);
        assertEq(staking.riskIncentives(successorSeriesId).staticsReserve, 100 ether);
    }

    function test_CancelledTransitionKeepsOriginalIncentiveCampaignOpen() public {
        vm.startPrank(alice);
        statics.approve(deployment.diamond, 10 ether);
        staking.fundRiskStaticsIncentives(SERIES_ID, 10 ether);
        vm.stopPrank();

        oracle.setPriceWad(4_000e18);
        transition.startSeriesTransition(PROFILE_ID);
        oracle.setPriceWad(2_500e18);
        transition.cancelSeriesTransition(SERIES_ID);

        vm.expectRevert(abi.encodeWithSelector(StakingFacet.SeriesIncentivesNotFinalizable.selector, SERIES_ID));
        staking.finalizeRiskIncentives(SERIES_ID);
        StakingFacet.RiskIncentiveView memory incentives = staking.riskIncentives(SERIES_ID);
        assertFalse(incentives.finalized);
        assertEq(incentives.staticsReserve, 10 ether);
    }

    function test_PermanentRetirementRoutesUnusedIncentivesToGlobalStaticsLedger() public {
        (uint256 dollars,) = _deposit(alice, 1 ether);
        vm.deal(alice, alice.balance + 0.5 ether);
        vm.startPrank(alice);
        weth.deposit{value: 0.5 ether}();
        weth.approve(deployment.diamond, 0.5 ether);
        staticsDollar.approve(deployment.diamond, dollars);
        statics.approve(deployment.diamond, 25 ether);
        staking.fundRiskCollateralIncentives(SERIES_ID, 0.5 ether);
        staking.fundRiskDollarIncentives(SERIES_ID, dollars);
        staking.fundRiskStaticsIncentives(SERIES_ID, 25 ether);
        vm.stopPrank();

        vm.startPrank(owner);
        CoreGovernanceFacet(deployment.core).enterReduceOnly(PROFILE_ID);
        CoreGovernanceFacet(deployment.core).setProfileMode(PROFILE_ID, IStaticsDollarCoreTypes.ProfileMode.Retired);
        vm.stopPrank();

        (uint256 destinationSeriesId, bool routedGlobal) = staking.finalizeRiskIncentives(SERIES_ID);
        assertEq(destinationSeriesId, 0);
        assertTrue(routedGlobal);
        StakingFacet.RiskIncentiveView memory incentives = staking.riskIncentives(SERIES_ID);
        assertTrue(incentives.finalized);
        assertTrue(incentives.routedGlobal);
        assertEq(incentives.collateralReserve, 0);
        assertEq(incentives.staticsDollarReserve, 0);
        assertEq(incentives.staticsReserve, 0);
        assertEq(staking.reservedBalance(address(weth)), 0);
        assertEq(staking.reservedBalance(address(staticsDollar)), 0);
        assertEq(staking.reservedBalance(address(statics)), 0);

        IStaticsGlobalRewards rewards = IStaticsGlobalRewards(deployment.diamond);
        assertEq(rewards.treasuryAccrued(address(weth)), 0.5 ether);
        assertEq(rewards.treasuryAccrued(address(staticsDollar)), dollars);
        assertEq(rewards.treasuryAccrued(address(statics)), 25 ether);
    }

    function test_RiskSharesAreImmediatelyConsumableAndUnconsumedSharesWithdraw() public {
        (, uint256 shares) = _deposit(alice, 1 ether);
        uint256 amount = shares / 2;
        uint256 positionId = _createAndStake(alice, amount);

        assertEq(staking.riskLiquidity(positionId, SERIES_ID).effectiveShares, amount);
        assertEq(staking.totalRiskLiquidity(SERIES_ID), amount);

        vm.prank(alice);
        uint256 withdrawn = staking.unstakeRiskShares(positionId, SERIES_ID, amount, alice);

        assertEq(withdrawn, amount);
        assertEq(staking.totalRiskLiquidity(SERIES_ID), 0);
        assertEq(staticsDollarRisk.balanceOf(alice, SERIES_ID), shares);
    }

    function test_PairingConsumptionCreatesTheOnlyRiskProceeds() public {
        (, uint256 aliceShares) = _deposit(alice, 1 ether);
        (uint256 redeemerDollar,) = _deposit(redeemer, 1 ether);
        uint256 supplied = aliceShares / 2;
        uint256 fill = supplied / 2;
        uint256 positionId = _createAndStake(alice, supplied);

        StakingFacet.RiskLiquidityView memory beforeFill = staking.riskLiquidity(positionId, SERIES_ID);
        assertEq(beforeFill.claimableCollateral, 0);
        assertEq(beforeFill.claimableStaticsDollar, 0);

        PairingVaultFacet.RedeemPreview memory preview = vault.previewRedeem(SERIES_ID, fill);
        IStaticsDollarCoreTypes.StableCollateralProfile memory profileBefore = core.collateralProfile(PROFILE_ID);
        vm.startPrank(redeemer);
        staticsDollar.approve(deployment.diamond, redeemerDollar);
        (, uint256 filled,) = vault.redeem(SERIES_ID, fill, fill, 0, block.timestamp, redeemer);
        vm.stopPrank();

        assertEq(filled, fill);
        StakingFacet.RiskLiquidityView memory afterFill = staking.riskLiquidity(positionId, SERIES_ID);
        assertApproxEqAbs(afterFill.effectiveShares, supplied - fill, 1);
        assertApproxEqAbs(afterFill.claimableCollateral, preview.collateralToRiskSuppliers, 1);
        assertEq(afterFill.claimableStaticsDollar, 0);
        assertEq(
            core.collateralProfile(PROFILE_ID).insuranceReserve - profileBefore.insuranceReserve,
            preview.collateralToInsurance
        );

        uint256 beforeClaim = weth.balanceOf(bob);
        vm.prank(alice);
        (uint256 collateralClaimed, uint256 dollarClaimed, uint256 staticsClaimed) =
            staking.claimRiskProceeds(positionId, SERIES_ID, bob);
        assertApproxEqAbs(collateralClaimed, preview.collateralToRiskSuppliers, 1);
        assertEq(dollarClaimed, 0);
        assertEq(staticsClaimed, 0);
        assertEq(weth.balanceOf(bob) - beforeClaim, collateralClaimed);
    }

    function test_PairingConsumptionReleasesCanonicalRiskIncentivesProportionally() public {
        (uint256 aliceDollars, uint256 aliceShares) = _deposit(alice, 1 ether);
        (uint256 redeemerDollars,) = _deposit(redeemer, 1 ether);
        uint256 supplied = aliceShares / 2;
        uint256 fill = supplied / 2;
        uint256 positionId = _createAndStake(alice, supplied);
        uint256 collateralFunding = 0.2 ether;
        uint256 dollarFunding = aliceDollars / 4;
        uint256 staticsFunding = 40 ether;

        vm.deal(alice, alice.balance + collateralFunding);
        vm.startPrank(alice);
        weth.deposit{value: collateralFunding}();
        weth.approve(deployment.diamond, collateralFunding);
        staticsDollar.approve(deployment.diamond, dollarFunding);
        statics.approve(deployment.diamond, staticsFunding);
        staking.fundRiskCollateralIncentives(SERIES_ID, collateralFunding);
        staking.fundRiskDollarIncentives(SERIES_ID, dollarFunding);
        staking.fundRiskStaticsIncentives(SERIES_ID, staticsFunding);
        vm.stopPrank();

        PairingVaultFacet.RedeemPreview memory preview = vault.previewRedeem(SERIES_ID, fill);
        vm.startPrank(redeemer);
        staticsDollar.approve(deployment.diamond, redeemerDollars);
        vault.redeem(SERIES_ID, fill, fill, 0, block.timestamp, redeemer);
        vm.stopPrank();

        uint256 releasedCollateral = Math.mulDiv(collateralFunding, fill, supplied);
        uint256 releasedDollar = Math.mulDiv(dollarFunding, fill, supplied);
        uint256 releasedStatics = Math.mulDiv(staticsFunding, fill, supplied);
        StakingFacet.RiskIncentiveView memory incentives = staking.riskIncentives(SERIES_ID);
        assertEq(incentives.collateralReserve, collateralFunding - releasedCollateral);
        assertEq(incentives.staticsDollarReserve, dollarFunding - releasedDollar);
        assertEq(incentives.staticsReserve, staticsFunding - releasedStatics);

        StakingFacet.RiskLiquidityView memory position = staking.riskLiquidity(positionId, SERIES_ID);
        assertApproxEqAbs(position.claimableCollateral, preview.collateralToRiskSuppliers + releasedCollateral, 2);
        assertApproxEqAbs(position.claimableStaticsDollar, releasedDollar, 1);
        assertApproxEqAbs(position.claimableStatics, releasedStatics, 1);

        uint256 collateralBefore = weth.balanceOf(bob);
        uint256 dollarBefore = staticsDollar.balanceOf(bob);
        uint256 staticsBefore = statics.balanceOf(bob);
        vm.prank(alice);
        (uint256 collateralClaimed, uint256 dollarClaimed, uint256 staticsClaimed) =
            staking.claimRiskProceeds(positionId, SERIES_ID, bob);
        assertEq(weth.balanceOf(bob) - collateralBefore, collateralClaimed);
        assertEq(staticsDollar.balanceOf(bob) - dollarBefore, dollarClaimed);
        assertEq(statics.balanceOf(bob) - staticsBefore, staticsClaimed);
    }

    function test_LaterSupplierCannotClaimEarlierPairingProceeds() public {
        (, uint256 aliceShares) = _deposit(alice, 1 ether);
        (, uint256 bobShares) = _deposit(bob, 1 ether);
        (uint256 redeemerDollar,) = _deposit(redeemer, 1 ether);
        uint256 alicePosition = _createAndStake(alice, aliceShares / 2);
        uint256 firstFill = aliceShares / 8;

        vm.startPrank(alice);
        statics.approve(deployment.diamond, 40 ether);
        staking.fundRiskStaticsIncentives(SERIES_ID, 40 ether);
        vm.stopPrank();

        vm.startPrank(redeemer);
        staticsDollar.approve(deployment.diamond, redeemerDollar);
        vault.redeem(SERIES_ID, firstFill, firstFill, 0, block.timestamp, redeemer);
        vm.stopPrank();
        uint256 aliceEarlierProceeds = staking.riskLiquidity(alicePosition, SERIES_ID).claimableCollateral;
        uint256 aliceEarlierStatics = staking.riskLiquidity(alicePosition, SERIES_ID).claimableStatics;
        assertGt(aliceEarlierProceeds, 0);
        assertGt(aliceEarlierStatics, 0);

        uint256 bobPosition = _createAndStake(bob, bobShares / 2);
        assertEq(staking.riskLiquidity(bobPosition, SERIES_ID).claimableCollateral, 0);
        assertEq(staking.riskLiquidity(bobPosition, SERIES_ID).claimableStatics, 0);

        uint256 secondFill = bobShares / 8;
        vm.prank(redeemer);
        vault.redeem(SERIES_ID, secondFill, secondFill, 0, block.timestamp, redeemer);

        assertGt(staking.riskLiquidity(bobPosition, SERIES_ID).claimableCollateral, 0);
        assertGt(staking.riskLiquidity(bobPosition, SERIES_ID).claimableStatics, 0);
        assertGt(staking.riskLiquidity(alicePosition, SERIES_ID).claimableCollateral, aliceEarlierProceeds);
        assertGt(staking.riskLiquidity(alicePosition, SERIES_ID).claimableStatics, aliceEarlierStatics);
    }

    function test_FullConsumptionRollsEpochAndAcceptsFreshLiquidity() public {
        (, uint256 aliceShares) = _deposit(alice, 1 ether);
        (uint256 redeemerDollar,) = _deposit(redeemer, 1 ether);
        uint256 supplied = aliceShares / 2;
        uint256 alicePosition = _createAndStake(alice, supplied);

        vm.startPrank(alice);
        statics.approve(deployment.diamond, 10 ether);
        staking.fundRiskStaticsIncentives(SERIES_ID, 10 ether);
        vm.stopPrank();

        vm.startPrank(redeemer);
        staticsDollar.approve(deployment.diamond, redeemerDollar);
        vault.redeem(SERIES_ID, supplied, supplied, 0, block.timestamp, redeemer);
        vm.stopPrank();
        assertEq(staking.totalRiskLiquidity(SERIES_ID), 0);
        StakingFacet.RiskIncentiveView memory incentives = staking.riskIncentives(SERIES_ID);
        assertEq(incentives.collateralReserve, 0);
        assertEq(incentives.staticsDollarReserve, 0);
        assertEq(incentives.staticsReserve, 0);
        assertEq(staking.riskLiquidity(alicePosition, SERIES_ID).effectiveShares, 0);

        (, uint256 bobShares) = _deposit(bob, 1 ether);
        uint256 bobPosition = _createAndStake(bob, bobShares / 2);
        assertEq(staking.riskLiquidity(bobPosition, SERIES_ID).effectiveShares, bobShares / 2);
        assertEq(staking.riskLiquidity(alicePosition, SERIES_ID).claimableStaticsDollar, 0);
    }

    function test_ZeroEffectiveLiquidityCanCloseWithoutStrandingRemainingShares() public {
        (, uint256 aliceShares) = _deposit(alice, 1 ether);
        (, uint256 bobShares) = _deposit(bob, 1 ether);
        (uint256 redeemerDollar,) = _deposit(redeemer, 1 ether);
        uint256 bobSupply = 1e12;
        assertGe(aliceShares, 1);
        assertGe(bobShares, bobSupply);

        uint256 alicePosition = _createAndStake(alice, 1);
        uint256 bobPosition = _createAndStake(bob, bobSupply);

        vm.startPrank(redeemer);
        staticsDollar.approve(deployment.diamond, redeemerDollar);
        vault.redeem(SERIES_ID, bobSupply, bobSupply, 0, block.timestamp, redeemer);
        vm.stopPrank();

        assertEq(staking.riskLiquidity(alicePosition, SERIES_ID).effectiveShares, 0);
        vm.prank(alice);
        staking.closeRiskLiquidity(alicePosition, SERIES_ID);
        assertFalse(staking.riskLiquidity(alicePosition, SERIES_ID).exists);

        assertEq(staking.riskLiquidity(bobPosition, SERIES_ID).effectiveShares, 1);
        vm.prank(bob);
        assertEq(staking.unstakeRiskShares(bobPosition, SERIES_ID, 1, bob), 1);
    }

    function test_UnmatchedRiskTransfersAreRejected() public {
        (, uint256 shares) = _deposit(alice, 1 ether);
        vm.startPrank(alice);
        vm.expectPartialRevert(StakingFacet.UnexpectedRiskIngress.selector);
        staticsDollarRisk.safeTransferFrom(alice, deployment.diamond, SERIES_ID, shares, "");

        uint256[] memory ids = new uint256[](1);
        uint256[] memory amounts = new uint256[](1);
        ids[0] = SERIES_ID;
        amounts[0] = shares;
        vm.expectRevert(StakingFacet.RiskBatchIngressUnsupported.selector);
        staticsDollarRisk.safeBatchTransferFrom(alice, deployment.diamond, ids, amounts, "");
        vm.stopPrank();
    }

    function test_SuppliedRiskSharesRemainSuppliedThroughSeriesRecovery() public {
        (, uint256 shares) = _deposit(alice, 3 ether);
        uint256 supplied = shares / 2;
        uint256 positionId = _createAndStake(alice, supplied);
        vm.startPrank(alice);
        statics.approve(deployment.diamond, 10 ether);
        staking.fundRiskStaticsIncentives(SERIES_ID, 10 ether);
        vm.stopPrank();

        oracle.setPriceWad(4_000e18);
        transition.startSeriesTransition(PROFILE_ID);
        staking.processSeriesTransition(SERIES_ID);
        vm.warp(block.timestamp + transition.SERIES_TRANSITION_DELAY());
        transition.finalizeSeriesTransition(SERIES_ID);
        (uint256 successorSeriesId,) = staking.processSeriesTransition(SERIES_ID);
        assertEq(staking.riskIncentives(successorSeriesId).staticsReserve, 10 ether);

        vm.prank(alice);
        (, uint256 successorPrincipal) = staking.settleSeriesMigration(positionId, SERIES_ID);

        assertGt(successorSeriesId, SERIES_ID);
        assertGt(successorPrincipal, 0);
        assertEq(staking.riskLiquidity(positionId, SERIES_ID).effectiveShares, 0);
        assertEq(staking.riskLiquidity(positionId, successorSeriesId).effectiveShares, successorPrincipal);
        assertEq(staking.totalRiskLiquidity(successorSeriesId), successorPrincipal);
        assertEq(staticsDollarRisk.balanceOf(deployment.diamond, successorSeriesId), successorPrincipal);
        assertEq(staking.riskLiquidity(positionId, SERIES_ID).claimableStaticsDollar, successorPrincipal);
    }

    function _deposit(address account, uint256 collateralAmount) internal returns (uint256 dollars, uint256 shares) {
        vm.deal(account, collateralAmount);
        vm.startPrank(account);
        weth.deposit{value: collateralAmount}();
        weth.approve(deployment.core, collateralAmount);
        (, dollars, shares) = core.depositCollateral(PROFILE_ID, collateralAmount, 0, 0, account, account);
        vm.stopPrank();
    }

    function _createAndStake(address account, uint256 amount) internal returns (uint256 positionId) {
        vm.startPrank(account);
        staticsDollarRisk.setApprovalForAll(deployment.diamond, true);
        positionId = staking.createAndStakeRiskShares(SERIES_ID, amount, account);
        vm.stopPrank();
    }

    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC1155Receiver.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return IERC1155Receiver.onERC1155BatchReceived.selector;
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IERC1155Receiver).interfaceId;
    }
}
