// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC721Metadata} from "@openzeppelin/contracts/token/ERC721/extensions/IERC721Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IStaticsBasket} from "src/interfaces/IStaticsBasket.sol";
import {IStaticsBasketCollateral} from "src/interfaces/IStaticsBasketCollateral.sol";
import {IStaticsPosition} from "src/interfaces/IStaticsPosition.sol";
import {IStaticsCustody} from "src/interfaces/IStaticsCustody.sol";
import {IDiamondCut} from "src/interfaces/IDiamondCut.sol";
import {LibPosition} from "src/position/LibPosition.sol";
import {PositionNFTFacet} from "src/position/PositionNFTFacet.sol";

import {
    DeployStaticsDollar,
    StaticsDollarLocalConfig,
    StaticsDollarStackDeployment
} from "script/dollar/DeployStaticsDollar.s.sol";
import {StaticsDollarRiskShares} from "src/dollar/StaticsDollarRiskShares.sol";
import {StaticsDollar} from "src/dollar/StaticsDollar.sol";
import {CoreMintFacet} from "src/dollar/core/facets/CoreMintFacet.sol";
import {CoreTransitionFacet} from "src/dollar/core/facets/CoreTransitionFacet.sol";
import {IStaticsDollarCoreTypes} from "src/dollar/interfaces/IStaticsDollarCoreTypes.sol";
import {IStaticsDollarRiskSeriesRewards} from "src/dollar/interfaces/IStaticsDollarRiskSeriesRewards.sol";
import {LibPeriphery} from "src/dollar/periphery/libraries/LibPeriphery.sol";
import {MockETHUSDOracle} from "src/dollar/mocks/MockETHUSDOracle.sol";
import {CanonicalWETH9} from "src/dollar/mocks/CanonicalWETH9.sol";
import {OptInFacet} from "src/dollar/periphery/facets/OptInFacet.sol";
import {PairingVaultFacet} from "src/dollar/periphery/facets/PairingVaultFacet.sol";
import {RewardsFacet} from "src/dollar/periphery/facets/RewardsFacet.sol";
import {StakingFacet} from "src/dollar/periphery/facets/StakingFacet.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";

contract DollarPositionReentrantReceiver is IERC721Receiver {
    address internal immutable DIAMOND;
    bool public reentrySucceeded;
    bytes public reentryResult;

    constructor(address diamond) {
        DIAMOND = diamond;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
        (reentrySucceeded, reentryResult) =
            DIAMOND.call(abi.encodeCall(RewardsFacet.donateStaticsDollarRewards, (uint256(1), uint256(1), uint256(0))));
        return IERC721Receiver.onERC721Received.selector;
    }
}

contract BasketLegLifecycleHarnessFacet {
    function attach(uint256 positionId, uint256 basketId) external {
        LibPosition.enforceAuthorized(positionId, msg.sender);
        LibPosition.activateLeg(positionId, LibPosition.basketLegKey(basketId));
    }

    function detach(uint256 positionId, uint256 basketId) external {
        LibPosition.enforceAuthorized(positionId, msg.sender);
        LibPosition.deactivateLeg(positionId, LibPosition.basketLegKey(basketId));
    }
}

contract PairingReleaseHarness is PairingVaultFacet {
    function proportionalRelease(uint256 reserve, uint256 fill, uint256 availableBefore)
        external
        pure
        returns (uint256)
    {
        return _proportionalRelease(reserve, fill, availableBefore);
    }
}

contract PeripherySecurityRegressionTest is Test {
    uint256 internal constant PROFILE_ID = 1;
    uint256 internal constant SERIES_ID = 1;

    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal redeemer = makeAddr("redeemer");

    StaticsDollarStackDeployment internal deployment;
    CoreMintFacet internal coreMint;
    CoreTransitionFacet internal transition;
    StaticsDollar internal staticsDollar;
    StaticsDollarRiskShares internal staticsDollarRisk;
    CanonicalWETH9 internal weth;
    MockETHUSDOracle internal oracle;
    StakingFacet internal staking;
    OptInFacet internal optIn;
    PairingVaultFacet internal vault;
    RewardsFacet internal rewards;
    IStaticsCustody internal custody;

    function setUp() public {
        vm.warp(30 days);
        StaticsDollarLocalConfig memory config;
        config.owner = owner;
        config.profileGuardian = owner;
        config.deployMockWeth = true;
        config.deployMockOracle = true;
        config.mockOraclePriceWad = 2_500e18;
        config.riskUri = "ipfs://risk/{id}.json";
        deployment = new DeployStaticsDollar().deployLocal(config);
        coreMint = CoreMintFacet(deployment.core);
        transition = CoreTransitionFacet(deployment.core);
        staticsDollar = StaticsDollar(deployment.staticsDollar);
        staticsDollarRisk = StaticsDollarRiskShares(deployment.staticsDollarRisk);
        weth = CanonicalWETH9(payable(deployment.weth));
        oracle = MockETHUSDOracle(deployment.oracle);
        staking = StakingFacet(deployment.diamond);
        optIn = OptInFacet(deployment.diamond);
        vault = PairingVaultFacet(deployment.diamond);
        rewards = RewardsFacet(deployment.diamond);
        custody = IStaticsCustody(deployment.diamond);
    }

    function test_UnmatchedSingleAndBatchRiskTransfersAreRejected() public {
        _deposit(alice, 1 ether);
        vm.startPrank(alice);
        vm.expectPartialRevert(StakingFacet.UnexpectedRiskIngress.selector);
        staticsDollarRisk.safeTransferFrom(alice, deployment.diamond, SERIES_ID, 1 ether, "");

        uint256[] memory ids = new uint256[](1);
        uint256[] memory amounts = new uint256[](1);
        ids[0] = SERIES_ID;
        amounts[0] = 1 ether;
        vm.expectRevert(StakingFacet.RiskBatchIngressUnsupported.selector);
        staticsDollarRisk.safeBatchTransferFrom(alice, deployment.diamond, ids, amounts, "");
        vm.stopPrank();

        assertEq(staticsDollarRisk.balanceOf(deployment.diamond, SERIES_ID), 0);
    }

    function test_OptInScaleCannotRoundToZeroWhileStoredClaimsRemain() public {
        _deposit(alice, 3 ether);
        uint256 positionId = _createAndStake(alice, 1 ether);
        vm.prank(alice);
        optIn.optIn(positionId, SERIES_ID, 1 ether);

        vm.startPrank(alice);
        staticsDollar.approve(deployment.diamond, type(uint256).max);
        vault.redeem(SERIES_ID, 1 ether - 1, 1 ether - 1, 0, type(uint256).max, alice);
        staking.stake(positionId, SERIES_ID, 1 ether);
        optIn.optIn(positionId, SERIES_ID, 1 ether);
        uint256 custodyBefore = staticsDollarRisk.balanceOf(deployment.diamond, SERIES_ID);
        vm.expectPartialRevert(LibPeriphery.OptInScaleExhausted.selector);
        vault.redeem(SERIES_ID, 1 ether, 1 ether, 0, type(uint256).max, alice);
        vm.stopPrank();

        assertGt(optIn.optInScaleRay(SERIES_ID), 0);
        assertEq(staticsDollarRisk.balanceOf(deployment.diamond, SERIES_ID), custodyBefore);
    }

    function test_TooSmallScaledOptInRevertsWithoutChangingCustodyOrAccounting() public {
        _deposit(alice, 3 ether);
        uint256 positionId = _createAndStake(alice, 1 ether);
        vm.prank(alice);
        optIn.optIn(positionId, SERIES_ID, 1 ether);

        vm.startPrank(alice);
        staticsDollar.approve(deployment.diamond, type(uint256).max);
        vault.redeem(SERIES_ID, 0.4 ether, 0.4 ether, 0, type(uint256).max, alice);
        staking.stake(positionId, SERIES_ID, 1);
        vm.stopPrank();

        LibPeriphery.PositionLeg memory beforeLeg = staking.leg(positionId, SERIES_ID);
        uint256 beforeCustody = staticsDollarRisk.balanceOf(deployment.diamond, SERIES_ID);
        uint256 beforeOptInTotal = optIn.optInTotal(SERIES_ID);
        uint256 beforeScale = optIn.optInScaleRay(SERIES_ID);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(OptInFacet.OptInAmountTooSmall.selector, uint256(1)));
        optIn.optIn(positionId, SERIES_ID, 1);

        LibPeriphery.PositionLeg memory afterLeg = staking.leg(positionId, SERIES_ID);
        assertEq(afterLeg.pendingPrincipal, beforeLeg.pendingPrincipal);
        assertEq(afterLeg.eligiblePrincipal, beforeLeg.eligiblePrincipal);
        assertEq(afterLeg.optInStored, beforeLeg.optInStored);
        assertEq(staticsDollarRisk.balanceOf(deployment.diamond, SERIES_ID), beforeCustody);
        assertEq(optIn.optInTotal(SERIES_ID), beforeOptInTotal);
        assertEq(optIn.optInScaleRay(SERIES_ID), beforeScale);
    }

    function test_PositionRoundingCannotExceedCustodyOrLockMigration() public {
        _deposit(alice, 3 ether);
        _deposit(bob, 3 ether);
        _deposit(redeemer, 3 ether);

        uint256 honestPosition = _createAndStake(bob, 10 ether);
        vm.prank(bob);
        optIn.optIn(honestPosition, SERIES_ID, 10 ether);

        vm.startPrank(redeemer);
        staticsDollar.approve(deployment.diamond, type(uint256).max);
        vault.redeem(SERIES_ID, 3 ether, 3 ether, 0, type(uint256).max, redeemer);
        vm.stopPrank();

        uint256 attackerAmount = 1_667_000_000_000_000_002;
        uint256[3] memory attackerPositions;
        for (uint256 i; i < attackerPositions.length; ++i) {
            attackerPositions[i] = _createAndStake(alice, attackerAmount);
            vm.prank(alice);
            optIn.optIn(attackerPositions[i], SERIES_ID, attackerAmount);
        }

        vm.prank(redeemer);
        vault.redeem(SERIES_ID, 1_679_999_999_999_999_004, 1_679_999_999_999_999_004, 0, type(uint256).max, redeemer);

        uint256 physical = staticsDollarRisk.balanceOf(deployment.diamond, SERIES_ID);
        uint256 summedClaims = optIn.optInBalanceOf(honestPosition, SERIES_ID);
        for (uint256 i; i < attackerPositions.length; ++i) {
            summedClaims += optIn.optInBalanceOf(attackerPositions[i], SERIES_ID);
        }
        assertLe(summedClaims, physical);

        _finalizeUpsideTransition();
        for (uint256 i; i < attackerPositions.length; ++i) {
            vm.prank(alice);
            staking.settleSeriesMigration(attackerPositions[i], SERIES_ID);
        }
        vm.prank(bob);
        staking.settleSeriesMigration(honestPosition, SERIES_ID);

        assertEq(staking.seriesMigration(SERIES_ID).remainingOldPrincipal, 0);
        assertEq(staking.leg(honestPosition, SERIES_ID).optInStored, 0);
    }

    function test_RetiredRewardReserveIsSnapshottedBeforeAnyLegMigrates() public {
        _deposit(alice, 3 ether);
        _deposit(bob, 3 ether);
        uint256 alicePosition = _createAndStake(alice, 100 ether);
        uint256 bobPosition = _createAndStake(bob, 100 ether);
        vm.warp(block.timestamp + 24 hours);
        staking.activateLeg(alicePosition, SERIES_ID);
        staking.activateLeg(bobPosition, SERIES_ID);

        vm.startPrank(alice);
        staticsDollar.approve(deployment.diamond, 200 ether);
        rewards.donateStaticsDollarRewards(SERIES_ID, 0, 200 ether);
        vm.stopPrank();

        _finalizeUpsideTransition();
        (, uint256 aliceRewards) = rewards.pendingSeriesRewards(alicePosition, SERIES_ID);
        (, uint256 bobRewards) = rewards.pendingSeriesRewards(bobPosition, SERIES_ID);
        assertEq(aliceRewards, 100 ether);
        assertEq(bobRewards, 100 ether);
    }

    function test_FullTransferredPositionLifecycleSettlesAndWithdrawsAgainstCore() public {
        _deposit(alice, 3 ether);
        uint256 positionId = _createAndStake(alice, 100 ether);
        IStaticsPosition positions = IStaticsPosition(deployment.diamond);
        assertEq(positions.activeLegCount(positionId), 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(PositionNFTFacet.PositionHasActiveLegs.selector, positionId, 1));
        positions.closePosition(positionId);
        vm.warp(block.timestamp + 24 hours);
        staking.activateLeg(positionId, SERIES_ID);

        vm.prank(alice);
        IERC721(deployment.positionNFT).transferFrom(alice, bob, positionId);
        vm.prank(bob);
        optIn.optIn(positionId, SERIES_ID, 50 ether);

        vm.startPrank(alice);
        staticsDollar.approve(deployment.diamond, type(uint256).max);
        rewards.donateStaticsDollarRewards(SERIES_ID, 10 ether, 0);
        vault.redeem(SERIES_ID, 10 ether, 10 ether, 0, type(uint256).max, alice);
        vm.stopPrank();

        _finalizeUpsideTransition();
        vm.prank(bob);
        (uint256 successorSeriesId,) = staking.settleSeriesMigration(positionId, SERIES_ID);
        assertEq(positions.activeLegCount(positionId), 2);

        (uint256 collateralReward, uint256 staticsDollarReward) = rewards.pendingSeriesRewards(positionId, SERIES_ID);
        assertGt(collateralReward, 0);
        assertGt(staticsDollarReward, 0);
        vm.prank(bob);
        rewards.claimSeriesRewards(positionId, SERIES_ID, bob);
        vm.prank(bob);
        staking.closeLeg(positionId, SERIES_ID);
        assertEq(positions.activeLegCount(positionId), 1);

        uint256 successorOptIn = optIn.optInBalanceOf(positionId, successorSeriesId);
        if (successorOptIn != 0) {
            vm.prank(bob);
            optIn.optOut(positionId, successorSeriesId, successorOptIn, bob);
        }
        LibPeriphery.PositionLeg memory successorLeg = staking.leg(positionId, successorSeriesId);
        uint256 successorBase = successorLeg.pendingPrincipal + successorLeg.eligiblePrincipal;
        if (successorBase != 0) {
            vm.prank(bob);
            staking.withdrawLeg(positionId, successorSeriesId, successorBase, bob);
        }
        vm.prank(bob);
        staking.closeLeg(positionId, successorSeriesId);
        assertEq(positions.activeLegCount(positionId), 0);
        vm.prank(bob);
        positions.closePosition(positionId);

        assertEq(IERC721(deployment.positionNFT).balanceOf(bob), 0);
        assertGt(staticsDollarRisk.balanceOf(bob, successorSeriesId), 0);
    }

    function test_PositionTransferMovesDollarLegAndAccruedRewardsWithoutRewrite() public {
        _deposit(alice, 3 ether);
        uint256 positionId = _createAndStake(alice, 100 ether);
        vm.warp(block.timestamp + 24 hours);
        staking.activateLeg(positionId, SERIES_ID);

        vm.startPrank(alice);
        staticsDollar.approve(deployment.diamond, 10 ether);
        rewards.donateStaticsDollarRewards(SERIES_ID, 10 ether, 0);
        vm.stopPrank();
        LibPeriphery.PositionLeg memory legBefore = staking.leg(positionId, SERIES_ID);
        (uint256 collateralBefore, uint256 dollarBefore) = rewards.pendingSeriesRewards(positionId, SERIES_ID);

        vm.prank(alice);
        IERC721(deployment.diamond).transferFrom(alice, bob, positionId);

        LibPeriphery.PositionLeg memory legAfter = staking.leg(positionId, SERIES_ID);
        (uint256 collateralAfter, uint256 dollarAfter) = rewards.pendingSeriesRewards(positionId, SERIES_ID);
        assertEq(IERC721(deployment.diamond).ownerOf(positionId), bob);
        assertEq(keccak256(abi.encode(legAfter)), keccak256(abi.encode(legBefore)));
        assertEq(collateralAfter, collateralBefore);
        assertEq(dollarAfter, dollarBefore);

        vm.prank(bob);
        rewards.claimSeriesRewards(positionId, SERIES_ID, bob);
        assertEq(staticsDollar.balanceOf(bob), 10 ether);
    }

    function test_DollarLegClosureLeavesIndependentBasketLegAttached() public {
        _deposit(alice, 1 ether);
        uint256 positionId = _createAndStake(alice, 1 ether);
        BasketLegLifecycleHarnessFacet harness = _installBasketLegHarness();

        // Narrow structural harness: basket position deposits land in the next slice;
        // this exercises the shared cross-module leg counter without faking value movement.
        vm.prank(alice);
        harness.attach(positionId, 7);
        assertEq(IStaticsPosition(deployment.diamond).activeLegCount(positionId), 2);

        vm.startPrank(alice);
        staking.withdrawLeg(positionId, SERIES_ID, 1 ether, alice);
        staking.closeLeg(positionId, SERIES_ID);
        vm.expectRevert(abi.encodeWithSelector(PositionNFTFacet.PositionHasActiveLegs.selector, positionId, 1));
        IStaticsPosition(deployment.diamond).closePosition(positionId);
        harness.detach(positionId, 7);
        IStaticsPosition(deployment.diamond).closePosition(positionId);
        vm.stopPrank();

        assertEq(IERC721(deployment.diamond).balanceOf(alice), 0);
    }

    function test_StaticsDiamondIsThePositionNFT() public view {
        assertEq(deployment.positionNFT, deployment.diamond);
        assertEq(staking.positionNFT(), deployment.diamond);
        assertEq(IERC721Metadata(deployment.positionNFT).name(), "Statics Position");
        assertEq(IERC721Metadata(deployment.positionNFT).symbol(), "etPOS");
        assertTrue(IERC165(deployment.diamond).supportsInterface(type(IStaticsCustody).interfaceId));
    }

    function test_DollarRewardsUseSharedPhysicalReservations() public {
        _deposit(alice, 3 ether);
        uint256 positionId = _createAndStake(alice, 100 ether);
        vm.warp(block.timestamp + 24 hours);
        staking.activateLeg(positionId, SERIES_ID);

        vm.startPrank(alice);
        staticsDollar.approve(deployment.diamond, 10 ether);
        rewards.donateStaticsDollarRewards(SERIES_ID, 10 ether, 0);
        vm.stopPrank();

        bytes32 dollarAccount = custody.dollarCustodyAccount();
        assertEq(rewards.reservedBalance(address(staticsDollar)), 10 ether);
        assertEq(custody.reservedByAccount(dollarAccount, address(staticsDollar)), 10 ether);
        assertEq(custody.globalReservedByToken(address(staticsDollar)), 10 ether);

        uint256 bobBefore = staticsDollar.balanceOf(bob);
        vm.prank(alice);
        rewards.claimSeriesRewards(positionId, SERIES_ID, bob);
        assertEq(staticsDollar.balanceOf(bob) - bobBefore, 10 ether);
        assertEq(rewards.reservedBalance(address(staticsDollar)), 0);
        assertEq(custody.reservedByAccount(dollarAccount, address(staticsDollar)), 0);
        assertEq(custody.globalReservedByToken(address(staticsDollar)), 0);
    }

    function test_BasketAndDollarRewardsRemainIndependentOnOnePosition() public {
        _deposit(alice, 3 ether);
        uint256 positionId = _createAndStake(alice, 100 ether);
        vm.warp(block.timestamp + LibPeriphery.REWARD_GATE);
        vm.prank(alice);
        staking.activateLeg(positionId, SERIES_ID);

        MockERC20 basketAsset = new MockERC20("Basket Asset", "BASK", 18);
        address[] memory assets = new address[](1);
        assets[0] = address(basketAsset);
        uint256[] memory bundleAmounts = new uint256[](1);
        bundleAmounts[0] = 1 ether;
        IStaticsBasket.FeeTier[] memory mintFeeTiers = new IStaticsBasket.FeeTier[](1);
        mintFeeTiers[0] = IStaticsBasket.FeeTier({minActionShares: 0, feeShares: 0.1 ether});
        IStaticsBasket.CreateBasketParams memory params = IStaticsBasket.CreateBasketParams({
            name: "Combined Position Basket",
            symbol: "sCOMBO",
            assets: assets,
            bundleAmounts: bundleAmounts,
            mintFeeTiers: mintFeeTiers,
            redemptionFeeTiers: new IStaticsBasket.FeeTier[](0),
            flashFeeBps: 0,
            originationFeeBps: 0,
            extensionFeeBps: 0,
            ltvBps: 9_500,
            loanDuration: 30 days
        });
        IStaticsBasket basket = IStaticsBasket(deployment.diamond);
        IStaticsBasketCollateral basketCollateral = IStaticsBasketCollateral(deployment.diamond);
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (uint256 basketId,) = basket.createBasket{value: 1 ether}(params);

        uint256[] memory quote = basket.quoteMint(basketId, 10 ether);
        basketAsset.mint(alice, quote[0]);
        vm.startPrank(alice);
        basketAsset.approve(deployment.diamond, type(uint256).max);
        basketCollateral.mintBasketCollateral(positionId, basketId, 10 ether, quote);
        staticsDollar.approve(deployment.diamond, 10 ether);
        rewards.donateStaticsDollarRewards(SERIES_ID, 10 ether, 0);
        vm.stopPrank();

        quote = basket.quoteMint(basketId, 10 ether);
        basketAsset.mint(bob, quote[0]);
        vm.startPrank(bob);
        basketAsset.approve(deployment.diamond, type(uint256).max);
        basket.mint(basketId, 10 ether, bob, quote);
        vm.stopPrank();

        (, uint256 dollarBefore) = rewards.pendingSeriesRewards(positionId, SERIES_ID);
        assertEq(dollarBefore, 10 ether);

        vm.prank(alice);
        rewards.claimSeriesRewards(positionId, SERIES_ID, alice);
        assertEq(basketCollateral.basketCollateralPosition(positionId, basketId).depositedShares, 10 ether);
    }

    function test_DollarSafeMintCallbackCannotCrossTheSharedExecutionLock() public {
        _deposit(alice, 3 ether);
        DollarPositionReentrantReceiver receiver = new DollarPositionReentrantReceiver(deployment.diamond);

        vm.startPrank(alice);
        staticsDollarRisk.setApprovalForAll(deployment.diamond, true);
        uint256 positionId = staking.createAndStake(SERIES_ID, 100 ether, address(receiver));
        vm.stopPrank();

        assertEq(IERC721(deployment.diamond).ownerOf(positionId), address(receiver));
        assertFalse(receiver.reentrySucceeded());
        assertEq(bytes4(receiver.reentryResult()), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
    }

    function test_RedeemToEthAcceptsConfiguredWethIngress() public {
        _deposit(alice, 1 ether);
        _deposit(redeemer, 1 ether);
        uint256 positionId = _createAndStake(alice, 1 ether);
        vm.prank(alice);
        optIn.optIn(positionId, SERIES_ID, 1 ether);
        IStaticsDollarCoreTypes.RedemptionPreview memory corePreview = coreMint.previewRecombine(SERIES_ID, 1 ether);
        PairingVaultFacet.RedeemPreview memory pairingPreview = vault.previewRedeem(SERIES_ID, 1 ether);

        vm.startPrank(redeemer);
        staticsDollar.approve(deployment.diamond, 1 ether);
        uint256 receiverBefore = bob.balance;
        (, uint256 redeemed, uint256 ethOut) = vault.redeemToETH(SERIES_ID, 1 ether, 1 ether, 0, block.timestamp, bob);
        vm.stopPrank();

        assertEq(redeemed, 1 ether);
        assertEq(pairingPreview.grossCollateral, corePreview.collateralOut + corePreview.feeAmount);
        assertEq(
            pairingPreview.collateralToRedeemer + pairingPreview.collateralToStakers
                + pairingPreview.collateralToInsurance,
            pairingPreview.grossCollateral
        );
        assertEq(ethOut, pairingPreview.collateralToRedeemer);
        assertEq(bob.balance - receiverBefore, ethOut);
        assertEq(deployment.diamond.balance, 0);
    }

    function test_PairingFillsReleaseBothReservesAndSweepFinalDust() public {
        _deposit(alice, 3 ether);
        _deposit(redeemer, 1 ether);
        uint256 positionId = _createAndStake(alice, 100 ether);
        vm.prank(alice);
        optIn.optIn(positionId, SERIES_ID, 100 ether);

        vm.deal(alice, 7 ether);
        vm.startPrank(alice);
        weth.deposit{value: 7 ether}();
        weth.approve(deployment.diamond, 7 ether);
        staticsDollar.approve(deployment.diamond, 11 ether);
        rewards.donateCollateralRewards(SERIES_ID, 0, 7 ether);
        rewards.donateStaticsDollarRewards(SERIES_ID, 0, 11 ether);
        vm.stopPrank();

        PairingVaultFacet.RedeemPreview memory firstPreview = vault.previewRedeem(SERIES_ID, 30 ether);
        vm.startPrank(redeemer);
        staticsDollar.approve(deployment.diamond, type(uint256).max);
        vault.redeem(SERIES_ID, 30 ether, 30 ether, 0, type(uint256).max, redeemer);
        vm.stopPrank();

        IStaticsDollarRiskSeriesRewards.SeriesRewardState memory state = rewards.seriesRewardState(SERIES_ID);
        assertEq(state.optInEffectivePrincipal, 70 ether);
        assertEq(state.collateralOptInReserve, 4.9 ether);
        assertEq(state.staticsDollarOptInReserve, 7.7 ether);

        (uint256 firstCollateralReward, uint256 firstDollarReward) = rewards.pendingSeriesRewards(positionId, SERIES_ID);
        assertApproxEqAbs(firstCollateralReward, 2.1 ether + firstPreview.collateralToStakers, 1);
        assertEq(firstDollarReward, 3.3 ether);

        PairingVaultFacet.RedeemPreview memory finalPreview = vault.previewRedeem(SERIES_ID, 70 ether);
        vm.prank(redeemer);
        vault.redeem(SERIES_ID, 70 ether, 70 ether, 0, type(uint256).max, redeemer);

        state = rewards.seriesRewardState(SERIES_ID);
        assertEq(state.optInEffectivePrincipal, 0);
        assertEq(state.collateralOptInReserve, 0);
        assertEq(state.staticsDollarOptInReserve, 0);

        (uint256 collateralReward, uint256 dollarReward) = rewards.pendingSeriesRewards(positionId, SERIES_ID);
        assertApproxEqAbs(
            collateralReward, 7 ether + firstPreview.collateralToStakers + finalPreview.collateralToStakers, 1
        );
        assertEq(dollarReward, 11 ether);

        bytes32 dollarAccount = custody.dollarCustodyAccount();
        assertEq(rewards.reservedBalance(address(weth)), collateralReward);
        assertEq(rewards.reservedBalance(address(staticsDollar)), dollarReward);
        assertEq(custody.reservedByAccount(dollarAccount, address(weth)), collateralReward);
        assertEq(custody.reservedByAccount(dollarAccount, address(staticsDollar)), dollarReward);
        assertEq(custody.globalReservedByToken(address(weth)), collateralReward);
        assertEq(custody.globalReservedByToken(address(staticsDollar)), dollarReward);

        uint256 bobWethBefore = weth.balanceOf(bob);
        uint256 bobDollarBefore = staticsDollar.balanceOf(bob);
        vm.prank(alice);
        rewards.claimSeriesRewards(positionId, SERIES_ID, bob);
        assertEq(weth.balanceOf(bob) - bobWethBefore, collateralReward);
        assertEq(staticsDollar.balanceOf(bob) - bobDollarBefore, dollarReward);
        assertEq(custody.globalReservedByToken(address(weth)), 0);
        assertEq(custody.globalReservedByToken(address(staticsDollar)), 0);
    }

    function testFuzz_ProportionalReleaseConservesReserve(uint256 rawReserve, uint256 rawAvailable, uint256 rawFill)
        public
    {
        uint256 reserve = bound(rawReserve, 0, type(uint128).max);
        uint256 available = bound(rawAvailable, 1, type(uint128).max);
        uint256 fill = bound(rawFill, 1, available);
        PairingReleaseHarness harness = new PairingReleaseHarness();

        uint256 released = harness.proportionalRelease(reserve, fill, available);

        assertLe(released, reserve);
        if (fill == available) {
            assertEq(released, reserve);
        } else {
            assertEq(released, Math.mulDiv(reserve, fill, available));
            assertEq(reserve - released, reserve - Math.mulDiv(reserve, fill, available));
        }
    }

    function _deposit(address account, uint256 collateralAmount) internal returns (uint256 pairs) {
        vm.deal(account, collateralAmount);
        vm.startPrank(account);
        weth.deposit{value: collateralAmount}();
        weth.approve(deployment.core, collateralAmount);
        (, pairs,) = coreMint.depositCollateral(PROFILE_ID, collateralAmount, 0, 0, account, account);
        vm.stopPrank();
    }

    function _createAndStake(address account, uint256 amount) internal returns (uint256 positionId) {
        vm.startPrank(account);
        staticsDollarRisk.setApprovalForAll(deployment.diamond, true);
        positionId = staking.createAndStake(SERIES_ID, amount, account);
        vm.stopPrank();
    }

    function _installBasketLegHarness() internal returns (BasketLegLifecycleHarnessFacet harness) {
        harness = new BasketLegLifecycleHarnessFacet();
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = BasketLegLifecycleHarnessFacet.attach.selector;
        selectors[1] = BasketLegLifecycleHarnessFacet.detach.selector;
        IDiamondCut.FacetCut[] memory cut = new IDiamondCut.FacetCut[](1);
        cut[0] = IDiamondCut.FacetCut({
            facetAddress: address(harness), action: IDiamondCut.FacetCutAction.Add, functionSelectors: selectors
        });
        vm.prank(owner);
        IDiamondCut(deployment.diamond).diamondCut(cut, address(0), "");
        harness = BasketLegLifecycleHarnessFacet(deployment.diamond);
    }

    function _finalizeUpsideTransition() internal {
        oracle.setPriceWad(4_000e18);
        transition.startSeriesTransition(PROFILE_ID);
        staking.processSeriesTransition(SERIES_ID);
        vm.warp(block.timestamp + transition.SERIES_TRANSITION_DELAY());
        transition.finalizeSeriesTransition(SERIES_ID);
        staking.processSeriesTransition(SERIES_ID);
    }
}
