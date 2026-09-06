// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {
    CoreBootstrapConfig,
    CoreBootstrapDeployment,
    DeployCoreBootstrap
} from "script/dollar/DeployCoreBootstrap.s.sol";
import {CoreGovernanceFacet} from "src/dollar/core/facets/CoreGovernanceFacet.sol";
import {CoreHealthFacet} from "src/dollar/core/facets/CoreHealthFacet.sol";
import {CoreInsuranceFacet} from "src/dollar/core/facets/CoreInsuranceFacet.sol";
import {CoreMintFacet} from "src/dollar/core/facets/CoreMintFacet.sol";
import {CoreViewFacet} from "src/dollar/core/facets/CoreViewFacet.sol";
import {StaticsDollarRiskShares} from "src/dollar/StaticsDollarRiskShares.sol";
import {StaticsDollar} from "src/dollar/StaticsDollar.sol";
import {IStaticsDollarCoreTypes} from "src/dollar/interfaces/IStaticsDollarCoreTypes.sol";
import {CanonicalWETH9} from "src/dollar/mocks/CanonicalWETH9.sol";
import {MockETHUSDOracle} from "src/dollar/mocks/MockETHUSDOracle.sol";
import {FeeRouterFacet} from "src/dollar/periphery/facets/FeeRouterFacet.sol";
import {IStaticsGlobalRewards} from "src/interfaces/IStaticsGlobalRewards.sol";
import {MockUSDC} from "../helpers/MockUSDC.sol";

contract ReentrantRiskReceiver {
    address internal immutable core;
    bytes4 public observedRevert;

    constructor(address core_) {
        core = core_;
    }

    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external returns (bytes4) {
        try CoreMintFacet(core).depositCollateral(1, 1, 0, 0, address(this), address(this)) {}
        catch (bytes memory reason) {
            if (reason.length >= 4) {
                bytes4 selector;
                assembly {
                    selector := mload(add(reason, 32))
                }
                observedRevert = selector;
            }
        }
        return this.onERC1155Received.selector;
    }
}

contract CoreDiamondLifecycleTest is Test {
    address internal owner = makeAddr("owner");
    address internal profileGuardian = makeAddr("profileGuardian");
    address internal alice = makeAddr("alice");
    address internal executor = makeAddr("executor");

    CanonicalWETH9 internal weth;
    MockETHUSDOracle internal wethOracle;
    CoreBootstrapDeployment internal deployment;
    CoreMintFacet internal mintFacet;
    CoreInsuranceFacet internal insuranceFacet;
    CoreGovernanceFacet internal governance;
    CoreHealthFacet internal health;
    CoreViewFacet internal viewFacet;
    StaticsDollar internal staticsDollar;
    StaticsDollarRiskShares internal staticsDollarRisk;

    function setUp() public {
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
        mintFacet = CoreMintFacet(deployment.core);
        insuranceFacet = CoreInsuranceFacet(deployment.core);
        governance = CoreGovernanceFacet(deployment.core);
        health = CoreHealthFacet(deployment.core);
        viewFacet = CoreViewFacet(deployment.core);
        staticsDollar = StaticsDollar(deployment.staticsDollar);
        staticsDollarRisk = StaticsDollarRiskShares(deployment.staticsDollarRisk);
    }

    function test_VolatileDepositTransferAndFullRecombinationPreserveAccounting() public {
        vm.deal(alice, 2e18);
        vm.prank(alice);
        weth.deposit{value: 2e18}();
        vm.prank(alice);
        weth.approve(deployment.core, 2e18);

        IStaticsDollarCoreTypes.DepositPreview memory preview = mintFacet.previewDeposit(1, 1e18);
        vm.prank(alice);
        (uint256 seriesId, uint256 minted, uint256 shares) =
            mintFacet.depositCollateral(1, 1e18, preview.staticsDollarMinted, preview.sharesMinted, alice, alice);

        assertEq(seriesId, 1);
        assertEq(minted, preview.staticsDollarMinted);
        assertEq(shares, minted);
        assertEq(staticsDollar.balanceOf(alice), minted);
        assertEq(staticsDollarRisk.balanceOf(alice, seriesId), shares);
        assertEq(staticsDollar.totalSupply(), viewFacet.seniorLiabilities());
        assertEq(weth.balanceOf(deployment.core), viewFacet.totalCollateral(address(weth)));
        (uint256 activeBooks,) = viewFacet.solvencyIndexMetadata(1);
        assertEq(activeBooks, 1);
        assertTrue(health.profileSolvency(1).healthy);

        address holder = makeAddr("holder");
        vm.prank(alice);
        staticsDollar.transfer(holder, minted);
        vm.prank(alice);
        staticsDollarRisk.safeTransferFrom(alice, holder, seriesId, shares, "");
        IStaticsDollarCoreTypes.RedemptionPreview memory redemption = mintFacet.previewRecombine(seriesId, minted);
        uint256 holderWethBefore = weth.balanceOf(holder);
        vm.prank(holder);
        (IStaticsDollarCoreTypes.ExitStatus status, uint256 collateralOut) =
            mintFacet.recombine(seriesId, minted, shares, redemption.collateralOut, holder);

        assertEq(uint256(status), uint256(IStaticsDollarCoreTypes.ExitStatus.Available));
        assertEq(collateralOut, 1e18);
        assertEq(weth.balanceOf(holder) - holderWethBefore, 1e18);
        assertEq(staticsDollar.totalSupply(), 0);
        assertEq(viewFacet.seniorLiabilities(), 0);
        assertEq(viewFacet.totalCollateral(address(weth)), 0);
        assertEq(weth.balanceOf(deployment.core), 0);
        (activeBooks,) = viewFacet.solvencyIndexMetadata(1);
        assertEq(activeBooks, 0);
    }

    function test_PeggedMintRoutesProtocolRevenueWithoutRiskSeries() public {
        uint256 nextSeriesId = viewFacet.nextSeriesId();
        (uint256 profileId, MockUSDC usdc,) = _activatePeggedProfile();
        uint256 amount = 100e18;
        IStaticsDollarCoreTypes.PeggedMintPreview memory preview = mintFacet.previewPeggedMint(profileId, amount);
        usdc.mint(alice, preview.totalCollateralIn);
        vm.prank(alice);
        usdc.approve(deployment.core, preview.totalCollateralIn);

        vm.prank(alice);
        mintFacet.mintPegged(profileId, amount, preview.totalCollateralIn, alice);
        assertEq(staticsDollar.balanceOf(alice), amount);
        assertEq(staticsDollarRisk.balanceOf(alice, nextSeriesId), 0);
        assertEq(viewFacet.nextSeriesId(), nextSeriesId);
        assertEq(viewFacet.profileSeriesCount(profileId), 0);
        assertEq(usdc.balanceOf(deployment.core), preview.principalCollateral);
        assertEq(usdc.balanceOf(deployment.diamond), preview.feeAmount);
        assertEq(viewFacet.cumulativeFeesPaid(alice, address(usdc)), preview.feeAmount);
        assertEq(FeeRouterFacet(deployment.diamond).pendingInsurance(profileId), 0);
        assertEq(IStaticsGlobalRewards(deployment.diamond).treasuryAccrued(address(usdc)), preview.feeAmount);
    }

    function test_PeggedProfileTopUpAddsDirectlyToRedeemableCollateral() public {
        (uint256 profileId, MockUSDC usdc, MockETHUSDOracle oracle) = _activatePeggedProfile();
        uint256 amount = 100e18;
        IStaticsDollarCoreTypes.PeggedMintPreview memory preview = mintFacet.previewPeggedMint(profileId, amount);
        usdc.mint(alice, preview.totalCollateralIn + 10e6);
        vm.startPrank(alice);
        usdc.approve(deployment.core, type(uint256).max);
        mintFacet.mintPegged(profileId, amount, preview.totalCollateralIn, alice);
        vm.stopPrank();

        oracle.setPriceWad(0.95e18);
        oracle.setUpdatedAt(block.timestamp);
        assertFalse(health.profileSolvency(profileId).healthy);
        health.syncGlobalHealth();

        vm.prank(alice);
        insuranceFacet.topUpInsurance(profileId, 10e6);
        assertTrue(health.profileSolvency(profileId).healthy);
        assertEq(viewFacet.collateralProfile(profileId).insuranceReserve, 0);
        assertEq(viewFacet.collateralProfile(profileId).accountedCollateral, preview.principalCollateral + 10e6);
        assertEq(viewFacet.profileSeriesCount(profileId), 0);
        health.syncGlobalHealth();
        (IStaticsDollarCoreTypes.GlobalHealthPhase phase,,, uint256 recoveryAvailableAt) = health.globalImpairment();
        assertEq(uint256(phase), uint256(IStaticsDollarCoreTypes.GlobalHealthPhase.Recovering));
        assertEq(recoveryAvailableAt, block.timestamp + 48 hours);
    }

    function test_MintReceiverCannotReenterAnotherCoreValuePath() public {
        ReentrantRiskReceiver receiver = new ReentrantRiskReceiver(deployment.core);
        vm.deal(alice, 1e18);
        vm.prank(alice);
        weth.deposit{value: 1e18}();
        vm.prank(alice);
        weth.approve(deployment.core, 1e18);
        IStaticsDollarCoreTypes.DepositPreview memory preview = mintFacet.previewDeposit(1, 1e18);

        vm.prank(alice);
        mintFacet.depositCollateral(
            1, 1e18, preview.staticsDollarMinted, preview.sharesMinted, alice, address(receiver)
        );
        assertEq(receiver.observedRevert(), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(staticsDollarRisk.balanceOf(address(receiver), 1), preview.sharesMinted);
        assertEq(staticsDollar.totalSupply(), viewFacet.seniorLiabilities());
    }

    function test_VolatileFeeKeepsInsuranceAndRoutesRemainderToGlobalRewards() public {
        IStaticsDollarCoreTypes.StableCollateralProfile memory profile = viewFacet.collateralProfile(1);
        CoreGovernanceFacet.ProfileRiskConfig memory risk = CoreGovernanceFacet.ProfileRiskConfig({
            collateralRatioBps: profile.collateralRatioBps,
            priceBandBps: profile.priceBandBps,
            mintFeeBps: 100,
            redemptionFeeBps: profile.redemptionFeeBps,
            insuranceTargetBps: profile.insuranceTargetBps,
            insuranceFeeBps: profile.insuranceFeeBps,
            pegMinPriceWad: profile.pegMinPriceWad,
            pegMaxPriceWad: profile.pegMaxPriceWad,
            debtCeiling: profile.debtCeiling
        });
        vm.prank(owner);
        governance.setProfileRiskConfig(1, risk);

        vm.deal(alice, 3 ether);
        vm.startPrank(alice);
        weth.deposit{value: 3 ether}();
        weth.approve(deployment.diamond, 1 ether);
        address[] memory assets = new address[](1);
        assets[0] = address(weth);
        uint256 positionId = IStaticsGlobalRewards(deployment.diamond).createAndStake(1 ether, alice, assets);
        vm.warp(IStaticsGlobalRewards(deployment.diamond).rewardSelection(positionId, address(weth)).eligibleAt);
        weth.approve(deployment.core, 2 ether);
        IStaticsDollarCoreTypes.DepositPreview memory preview = mintFacet.previewDeposit(1, 1 ether);
        mintFacet.depositCollateral(1, 1 ether, preview.staticsDollarMinted, preview.sharesMinted, alice, alice);
        vm.stopPrank();

        vm.prank(alice);
        uint256[] memory pending = IStaticsGlobalRewards(deployment.diamond).pendingRewards(positionId, assets);
        uint256 insurance = (preview.feeAmount * 30) / 100;
        uint256 globalGross = preview.feeAmount - insurance;
        uint256 stakerReward = (globalGross * 90) / 100;
        assertEq(pending[0], stakerReward);
        assertEq(IStaticsGlobalRewards(deployment.diamond).treasuryAccrued(address(weth)), globalGross - stakerReward);
        assertEq(FeeRouterFacet(deployment.diamond).pendingInsurance(1), insurance);
        assertEq(globalGross + insurance, preview.feeAmount);
    }

    function test_PeggedFeeUsesGlobalNinetyTenSplit() public {
        (uint256 profileId, MockUSDC usdc,) = _activatePeggedProfile();
        vm.deal(alice, 1 ether);
        vm.startPrank(alice);
        weth.deposit{value: 1 ether}();
        weth.approve(deployment.diamond, 1 ether);
        address[] memory assets = new address[](1);
        assets[0] = address(usdc);
        uint256 positionId = IStaticsGlobalRewards(deployment.diamond).createAndStake(1 ether, alice, assets);
        vm.warp(IStaticsGlobalRewards(deployment.diamond).rewardSelection(positionId, address(usdc)).eligibleAt);

        IStaticsDollarCoreTypes.PeggedMintPreview memory preview = mintFacet.previewPeggedMint(profileId, 100e18);
        usdc.mint(alice, preview.totalCollateralIn);
        usdc.approve(deployment.core, preview.totalCollateralIn);
        mintFacet.mintPegged(profileId, 100e18, preview.totalCollateralIn, alice);
        vm.stopPrank();

        vm.prank(alice);
        uint256[] memory pending = IStaticsGlobalRewards(deployment.diamond).pendingRewards(positionId, assets);
        uint256 stakerReward = (preview.feeAmount * 90) / 100;
        assertEq(pending[0], stakerReward);
        assertEq(
            IStaticsGlobalRewards(deployment.diamond).treasuryAccrued(address(usdc)), preview.feeAmount - stakerReward
        );
        assertEq(FeeRouterFacet(deployment.diamond).pendingInsurance(profileId), 0);
    }

    function test_RetirementAtomicallyFlushesPendingInsuranceLikeExplicitRouting() public {
        _setVolatileFees(100, 0);
        vm.deal(alice, 1 ether);
        vm.startPrank(alice);
        weth.deposit{value: 1 ether}();
        weth.approve(deployment.core, 1 ether);
        IStaticsDollarCoreTypes.DepositPreview memory preview = mintFacet.previewDeposit(1, 1 ether);
        mintFacet.depositCollateral(1, 1 ether, preview.staticsDollarMinted, preview.sharesMinted, alice, alice);
        vm.stopPrank();

        FeeRouterFacet router = FeeRouterFacet(deployment.diamond);
        uint256 pending = router.pendingInsurance(1);
        assertGt(pending, 0);
        uint256 state = vm.snapshotState();

        vm.prank(profileGuardian);
        governance.enterReduceOnly(1);
        router.routePendingInsurance(1);
        vm.prank(owner);
        governance.setProfileMode(1, IStaticsDollarCoreTypes.ProfileMode.Retired);
        IStaticsDollarCoreTypes.StableCollateralProfile memory explicitlyRoutedProfile = viewFacet.collateralProfile(1);
        IStaticsDollarCoreTypes.RiskSeries memory explicitlyRoutedSeries = viewFacet.riskSeries(1);
        uint256 explicitlyRoutedCoreBalance = weth.balanceOf(deployment.core);
        uint256 explicitlyRoutedDiamondBalance = weth.balanceOf(deployment.diamond);
        uint256 explicitlyRoutedTreasury = IStaticsGlobalRewards(deployment.diamond).treasuryAccrued(address(weth));

        assertTrue(vm.revertToState(state));
        vm.prank(profileGuardian);
        governance.enterReduceOnly(1);
        vm.prank(owner);
        governance.setProfileMode(1, IStaticsDollarCoreTypes.ProfileMode.Retired);

        IStaticsDollarCoreTypes.StableCollateralProfile memory atomicallyRoutedProfile = viewFacet.collateralProfile(1);
        IStaticsDollarCoreTypes.RiskSeries memory atomicallyRoutedSeries = viewFacet.riskSeries(1);
        assertEq(router.pendingInsurance(1), 0);
        assertEq(atomicallyRoutedProfile.insuranceReserve, explicitlyRoutedProfile.insuranceReserve);
        assertEq(atomicallyRoutedProfile.accountedCollateral, explicitlyRoutedProfile.accountedCollateral);
        assertEq(atomicallyRoutedSeries.accountedCollateral, explicitlyRoutedSeries.accountedCollateral);
        assertEq(uint256(atomicallyRoutedSeries.status), uint256(explicitlyRoutedSeries.status));
        assertEq(weth.balanceOf(deployment.core), explicitlyRoutedCoreBalance);
        assertEq(weth.balanceOf(deployment.diamond), explicitlyRoutedDiamondBalance);
        assertEq(IStaticsGlobalRewards(deployment.diamond).treasuryAccrued(address(weth)), explicitlyRoutedTreasury);
    }

    function test_RetiredRecombinationFeeRoutesDirectlyToGlobalRewards() public {
        _setVolatileFees(0, 100);
        vm.deal(alice, 1 ether);
        vm.startPrank(alice);
        weth.deposit{value: 1 ether}();
        weth.approve(deployment.core, 1 ether);
        IStaticsDollarCoreTypes.DepositPreview memory depositPreview = mintFacet.previewDeposit(1, 1 ether);
        (, uint256 minted,) = mintFacet.depositCollateral(
            1, 1 ether, depositPreview.staticsDollarMinted, depositPreview.sharesMinted, alice, alice
        );
        vm.stopPrank();
        vm.prank(profileGuardian);
        governance.enterReduceOnly(1);
        vm.prank(owner);
        governance.setProfileMode(1, IStaticsDollarCoreTypes.ProfileMode.Retired);

        IStaticsDollarCoreTypes.RedemptionPreview memory redemption = mintFacet.previewRecombine(1, minted);
        uint256 treasuryBefore = IStaticsGlobalRewards(deployment.diamond).treasuryAccrued(address(weth));
        vm.prank(alice);
        mintFacet.recombine(1, minted, minted, redemption.collateralOut, alice);

        assertEq(FeeRouterFacet(deployment.diamond).pendingInsurance(1), 0);
        assertEq(
            IStaticsGlobalRewards(deployment.diamond).treasuryAccrued(address(weth)) - treasuryBefore,
            redemption.feeAmount
        );
    }

    function test_EmptyVolatileProfileRetiresInsuranceIntoGlobalRewards() public {
        uint256 donation = 0.2 ether;
        vm.deal(alice, donation);
        vm.startPrank(alice);
        weth.deposit{value: donation}();
        weth.approve(deployment.core, donation);
        insuranceFacet.topUpInsurance(1, donation);
        vm.stopPrank();

        uint256 treasuryBefore = IStaticsGlobalRewards(deployment.diamond).treasuryAccrued(address(weth));
        vm.prank(profileGuardian);
        governance.enterReduceOnly(1);
        vm.prank(owner);
        governance.setProfileMode(1, IStaticsDollarCoreTypes.ProfileMode.Retired);

        IStaticsDollarCoreTypes.StableCollateralProfile memory retired = viewFacet.collateralProfile(1);
        assertEq(retired.insuranceReserve, 0);
        assertEq(retired.accountedCollateral, 0);
        assertEq(weth.balanceOf(deployment.core), 0);
        assertEq(IStaticsGlobalRewards(deployment.diamond).treasuryAccrued(address(weth)) - treasuryBefore, donation);
    }

    function _setVolatileFees(uint256 mintFeeBps, uint256 redemptionFeeBps) private {
        IStaticsDollarCoreTypes.StableCollateralProfile memory profile = viewFacet.collateralProfile(1);
        CoreGovernanceFacet.ProfileRiskConfig memory risk = CoreGovernanceFacet.ProfileRiskConfig({
            collateralRatioBps: profile.collateralRatioBps,
            priceBandBps: profile.priceBandBps,
            mintFeeBps: mintFeeBps,
            redemptionFeeBps: redemptionFeeBps,
            insuranceTargetBps: profile.insuranceTargetBps,
            insuranceFeeBps: profile.insuranceFeeBps,
            pegMinPriceWad: profile.pegMinPriceWad,
            pegMaxPriceWad: profile.pegMaxPriceWad,
            debtCeiling: profile.debtCeiling
        });
        vm.prank(owner);
        governance.setProfileRiskConfig(1, risk);
    }

    function _activatePeggedProfile() private returns (uint256 profileId, MockUSDC usdc, MockETHUSDOracle oracle) {
        usdc = new MockUSDC();
        oracle = new MockETHUSDOracle(1e18, 30 days);
        vm.prank(owner);
        profileId = governance.createPeggedCollateralProfile(
            address(usdc), address(oracle), 0.995e18, 1.005e18, 5, 7, 10_000_000e18
        );
        vm.prank(owner);
        governance.setProfileMode(profileId, IStaticsDollarCoreTypes.ProfileMode.Active);
    }
}
