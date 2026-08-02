// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IStaticsFlashLoan} from "../../src/interfaces/IStaticsFlashLoan.sol";
import {IStaticsGlobalRewards} from "../../src/interfaces/IStaticsGlobalRewards.sol";
import {IStaticsLending} from "../../src/interfaces/IStaticsLending.sol";
import {IModularPositionNFT} from "../../src/interfaces/IModularPositionNFT.sol";
import {IStaticsBasket} from "../../src/interfaces/IStaticsBasket.sol";
import {IStaticsBasketCollateral} from "../../src/interfaces/IStaticsBasketCollateral.sol";
import {BasketFacet} from "../../src/facets/BasketFacet.sol";
import {FlashLoanFacet} from "../../src/facets/FlashLoanFacet.sol";
import {LendingFacet} from "../../src/facets/LendingFacet.sol";
import {MockFlashBorrower} from "../mocks/MockFlashBorrower.sol";
import {MockERC20, MockFeeOnTransferERC20, MockOutboundFeeERC20, MockReentrantERC20} from "../mocks/MockERC20.sol";
import {StaticsTestBase} from "../helpers/StaticsTestBase.sol";

contract PositionStateObserver {
    IModularPositionNFT private immutable _positions;
    uint256 public observedNonce;
    uint256 public observedObligations;

    constructor(address positions_) {
        _positions = IModularPositionNFT(positions_);
    }

    function observe(uint256 positionId) external {
        IModularPositionNFT.PositionState memory state = _positions.positionState(positionId);
        observedNonce = state.stateNonce;
        observedObligations = state.unresolvedObligationCount;
    }
}

contract LendingAndFlashTest is StaticsTestBase {
    function testOriginationFeeBurnsPositionSharesAndLoanAppliesLtv() public {
        (uint256 basketId, address token) = _createDefaultBasket(0, 0);
        uint256 launchSupply = IERC20(token).totalSupply();
        uint256 launchVault = baskets.vaultBalance(basketId, address(assetA));
        uint256 positionId = _mintPositionShares(basketId, alice, 10 ether);

        vm.prank(alice);
        (uint256 loanId, uint256[] memory principals) = lending.borrow(positionId, basketId, 5 ether, alice);

        IStaticsLending.LoanView memory opened = lending.loan(loanId);
        assertEq(opened.positionId, positionId);
        assertEq(opened.feeShares, 0.05 ether);
        assertEq(opened.collateralShares, 4.95 ether);
        assertEq(principals[0], 9.405 ether);
        assertEq(principals[1], 23.5125 ether);
        assertEq(IERC20(token).balanceOf(address(diamond)), 9.95 ether);
        assertEq(IERC20(token).totalSupply(), launchSupply + 9.95 ether);
        assertEq(baskets.vaultBalance(basketId, address(assetA)), launchVault + 10.495 ether);
        assertEq(globalRewards.treasuryAccrued(address(assetA)), 0.1 ether);
        assertEq(lending.outstandingPrincipal(basketId, address(assetA)), 9.405 ether);
        IModularPositionNFT.PositionState memory structural =
            IModularPositionNFT(address(diamond)).positionState(positionId);
        assertEq(structural.stateNonce, 3);
        assertEq(structural.unresolvedObligationCount, 1);

        IStaticsBasketCollateral.BasketCollateralPosition memory position =
            basketCollateral.basketCollateralPosition(positionId, basketId);
        assertEq(position.depositedShares, 9.95 ether);
        assertEq(position.lockedShares, 4.95 ether);
    }

    function testRepayRestoresExactPrincipalAndUnlocksPositionCollateral() public {
        (uint256 basketId, address token) = _createDefaultBasket(0, 0);
        uint256 launchVault = baskets.vaultBalance(basketId, address(assetA));
        uint256 positionId = _mintPositionShares(basketId, alice, 10 ether);
        vm.prank(alice);
        (uint256 loanId, uint256[] memory principals) = lending.borrow(positionId, basketId, 5 ether, alice);

        vm.startPrank(alice);
        assetA.approve(address(diamond), principals[0]);
        assetB.approve(address(diamond), principals[1]);
        lending.repay(loanId);
        vm.stopPrank();

        IStaticsBasketCollateral.BasketCollateralPosition memory position =
            basketCollateral.basketCollateralPosition(positionId, basketId);
        assertEq(position.depositedShares, 9.95 ether);
        assertEq(position.lockedShares, 0);
        assertEq(IERC20(token).balanceOf(address(diamond)), 9.95 ether);
        assertEq(lending.outstandingPrincipal(basketId, address(assetA)), 0);
        assertEq(baskets.vaultBalance(basketId, address(assetA)), launchVault + 19.9 ether);
        IModularPositionNFT.PositionState memory structural =
            IModularPositionNFT(address(diamond)).positionState(positionId);
        assertEq(structural.stateNonce, 4);
        assertEq(structural.unresolvedObligationCount, 0);
    }

    function testExtensionChargesStoredUnderlyingPrincipalsAndPreservesBasketState() public {
        (uint256 basketId, address token) = _createDefaultBasket(0, 0);
        uint256 positionId = _mintPositionShares(basketId, alice, 10 ether);
        vm.prank(alice);
        (uint256 loanId,) = lending.borrow(positionId, basketId, 5 ether, alice);
        uint256 structuralNonce = IModularPositionNFT(address(diamond)).positionState(positionId).stateNonce;

        (address[] memory assets, uint256[] memory quotedFees) = lending.quoteExtension(loanId);
        assetA.mint(alice, quotedFees[0]);
        assetB.mint(alice, quotedFees[1]);
        uint256 supplyBefore = IERC20(token).totalSupply();
        uint256 vaultBefore = baskets.vaultBalance(basketId, address(assetA));
        uint256 eligibleBefore = basketCollateral.basketCollateralPosition(positionId, basketId).depositedShares;
        uint256 principalBefore = lending.loan(loanId).principals[0];

        vm.startPrank(alice);
        assetA.approve(address(diamond), quotedFees[0]);
        assetB.approve(address(diamond), quotedFees[1]);
        IStaticsLending.LoanView memory beforeLoan = lending.loan(loanId);
        uint256[] memory received = lending.extend(loanId, quotedFees);
        vm.stopPrank();

        IStaticsLending.LoanView memory afterLoan = lending.loan(loanId);
        assertEq(IModularPositionNFT(address(diamond)).positionState(positionId).stateNonce, structuralNonce);
        assertEq(assets[0], address(assetA));
        assertEq(assets[1], address(assetB));
        assertEq(quotedFees[0], 0.0235125 ether);
        assertEq(quotedFees[1], 0.05878125 ether);
        assertEq(received, quotedFees);
        assertEq(afterLoan.maturity, beforeLoan.maturity + 30 days);
        assertEq(globalRewards.treasuryAccrued(address(assetA)), 0.1235125 ether);
        assertEq(IERC20(token).totalSupply(), supplyBefore);
        assertEq(baskets.vaultBalance(basketId, address(assetA)), vaultBefore);
        assertEq(basketCollateral.basketCollateralPosition(positionId, basketId).depositedShares, eligibleBefore);
        assertEq(lending.loan(loanId).principals[0], principalBefore);
    }

    function testExtensionCreditsMeasuredTaxedReceiptAsRevenue() public {
        MockFeeOnTransferERC20 taxed = new MockFeeOnTransferERC20();
        IStaticsBasket.CreateBasketParams memory params = _defaultParams(1 ether, 0);
        params.assets[0] = address(taxed);
        (uint256 basketId,) = _launchBasketWithMinimalSeed(params, alice, 1 ether);

        taxed.mint(alice, 100 ether);
        assetB.mint(alice, 100 ether);
        vm.startPrank(alice);
        taxed.approve(address(diamond), type(uint256).max);
        assetB.approve(address(diamond), type(uint256).max);
        uint256[] memory mintInputs = baskets.quoteMint(basketId, 10 ether);
        (uint256 positionId,) = basketCollateral.createAndMintBasketCollateral(basketId, 10 ether, alice, mintInputs);
        (uint256 loanId,) = lending.borrow(positionId, basketId, 5 ether, alice);
        (, uint256[] memory requiredFees) = lending.quoteExtension(loanId);
        uint256[] memory grossAmounts = new uint256[](2);
        grossAmounts[0] = Math.mulDiv(requiredFees[0], 100, 99, Math.Rounding.Ceil);
        grossAmounts[1] = requiredFees[1] + 1;
        taxed.mint(alice, grossAmounts[0]);
        assetB.mint(alice, grossAmounts[1]);
        uint256 revenueABefore = globalRewards.treasuryAccrued(address(taxed));
        uint256 revenueBBefore = globalRewards.treasuryAccrued(address(assetB));
        uint256[] memory received = lending.extend(loanId, grossAmounts);
        vm.stopPrank();

        assertGe(received[0], requiredFees[0]);
        assertEq(received[0], grossAmounts[0] * 99 / 100);
        assertEq(received[1], grossAmounts[1]);
        assertEq(globalRewards.treasuryAccrued(address(taxed)), revenueABefore + received[0]);
        assertEq(globalRewards.treasuryAccrued(address(assetB)), revenueBBefore + received[1]);
        assertEq(custody.globalReservedByToken(address(taxed)), taxed.balanceOf(address(diamond)));
    }

    function testExtensionUnderpaymentRevertsWithoutAdvancingMaturity() public {
        (uint256 basketId,) = _createDefaultBasket(0, 0);
        uint256 positionId = _mintPositionShares(basketId, alice, 10 ether);
        vm.prank(alice);
        (uint256 loanId,) = lending.borrow(positionId, basketId, 5 ether, alice);
        (, uint256[] memory requiredFees) = lending.quoteExtension(loanId);
        uint40 maturityBefore = lending.loan(loanId).maturity;
        uint256 revenueBefore = globalRewards.treasuryAccrued(address(assetA));
        requiredFees[0] -= 1;
        assetA.mint(alice, requiredFees[0]);
        assetB.mint(alice, requiredFees[1]);

        vm.startPrank(alice);
        assetA.approve(address(diamond), requiredFees[0]);
        assetB.approve(address(diamond), requiredFees[1]);
        vm.expectRevert();
        lending.extend(loanId, requiredFees);
        vm.stopPrank();

        assertEq(lending.loan(loanId).maturity, maturityBefore);
        assertEq(globalRewards.treasuryAccrued(address(assetA)), revenueBefore);
    }

    function testExtensionRejectsMalformedFeeVector() public {
        (uint256 basketId,) = _createDefaultBasket(0, 0);
        uint256 positionId = _mintPositionShares(basketId, alice, 10 ether);
        vm.prank(alice);
        (uint256 loanId,) = lending.borrow(positionId, basketId, 5 ether, alice);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LendingFacet.InvalidExtensionInputLength.selector, 1, 2));
        lending.extend(loanId, new uint256[](1));
    }

    function testExpiredAndPausedLoansCannotExtend() public {
        (uint256 basketId,) = _createDefaultBasket(0, 0);
        uint256 positionId = _mintPositionShares(basketId, alice, 10 ether);
        vm.prank(alice);
        (uint256 loanId,) = lending.borrow(positionId, basketId, 5 ether, alice);
        (, uint256[] memory fees) = lending.quoteExtension(loanId);

        vm.prank(guardian);
        governance.pause(1 << 2);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LendingFacet.ActionPaused.selector, 1 << 2));
        lending.extend(loanId, fees);

        governance.unpause(1 << 2);
        IStaticsLending.LoanView memory opened = lending.loan(loanId);
        vm.warp(uint256(opened.maturity) + 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LendingFacet.LoanExpired.selector, loanId, opened.maturity));
        lending.extend(loanId, fees);
    }

    function testExtensionRevenueRemainsBasketScopedForSharedAssets() public {
        (uint256 firstBasket,) = _createDefaultBasket(0, 0);
        (uint256 secondBasket, address secondToken) = _createDefaultBasket(0, 0);
        _mintShares(secondBasket, secondToken, bob, 1 ether);
        uint256 positionId = _mintPositionShares(firstBasket, alice, 10 ether);
        vm.prank(alice);
        (uint256 loanId,) = lending.borrow(positionId, firstBasket, 5 ether, alice);
        (, uint256[] memory fees) = lending.quoteExtension(loanId);
        assetA.mint(alice, fees[0]);
        assetB.mint(alice, fees[1]);
        uint256 secondRevenueBefore = globalRewards.treasuryAccrued(address(assetA));
        bytes32 firstAccount = custody.basketCustodyAccount(firstBasket);
        bytes32 secondAccount = custody.basketCustodyAccount(secondBasket);
        uint256 firstReservedBefore = custody.reservedByAccount(firstAccount, address(assetA));
        uint256 secondReservedBefore = custody.reservedByAccount(secondAccount, address(assetA));

        vm.startPrank(alice);
        assetA.approve(address(diamond), fees[0]);
        assetB.approve(address(diamond), fees[1]);
        lending.extend(loanId, fees);
        vm.stopPrank();

        assertEq(globalRewards.treasuryAccrued(address(assetA)), secondRevenueBefore + fees[0]);
        assertEq(custody.reservedByAccount(firstAccount, address(assetA)), firstReservedBefore);
        assertEq(custody.reservedByAccount(secondAccount, address(assetA)), secondReservedBefore);
        assertEq(custody.globalReservedByToken(address(assetA)), assetA.balanceOf(address(diamond)));
    }

    function testRecoveryBurnsDebtPlusPenaltyAndUnlocksLowLtvRemainder() public {
        IStaticsBasket.CreateBasketParams memory params = _defaultParams(0, 0);
        params.originationFeeBps = 0;
        params.ltvBps = 2_000;
        params.recoveryPenaltyBps = 500;
        (uint256 basketId, address token) = _launchBasket(params, alice, 1 ether);
        uint256 launchSupply = IERC20(token).totalSupply();
        uint256 launchVault = baskets.vaultBalance(basketId, address(assetA));
        uint256 launchBasketReserved =
            custody.reservedByAccount(custody.basketCustodyAccount(basketId), address(assetA));
        uint256 positionId = _mintPositionShares(basketId, alice, 100 ether);
        vm.prank(alice);
        (uint256 loanId,) = lending.borrow(positionId, basketId, 100 ether, alice);
        address[] memory rewardAssets = new address[](2);
        rewardAssets[0] = address(assetA);
        rewardAssets[1] = address(assetB);
        stakingAsset.mint(alice, 100 ether);
        vm.startPrank(alice);
        stakingAsset.approve(address(diamond), 100 ether);
        uint256 stakingPositionId = globalRewards.createAndStake(100 ether, alice, rewardAssets);
        vm.stopPrank();

        IStaticsLending.BorrowQuote memory borrowQuote = lending.quoteBorrow(basketId, 100 ether);
        assertEq(borrowQuote.debtShares, 20 ether);
        assertEq(borrowQuote.penaltyShares, 1 ether);
        IStaticsLending.RecoveryQuote memory recoveryQuote = lending.quoteRecovery(loanId);
        assertEq(recoveryQuote.burnShares, 21 ether);
        assertEq(recoveryQuote.unlockedShares, 79 ether);
        assertEq(recoveryQuote.callerAmounts[0], 0.4 ether);
        assertEq(recoveryQuote.protocolAmounts[0], 1.6 ether);

        vm.warp(recoveryQuote.recoverableAt);
        uint256 nonceBeforeFailedRecovery = IModularPositionNFT(address(diamond)).positionState(positionId).stateNonce;
        vm.expectRevert(
            abi.encodeWithSelector(LendingFacet.LoanNotRecoverable.selector, loanId, recoveryQuote.recoverableAt)
        );
        lending.recover(loanId);
        assertEq(IModularPositionNFT(address(diamond)).positionState(positionId).stateNonce, nonceBeforeFailedRecovery);
        vm.warp(block.timestamp + 1);
        vm.prank(bob);
        lending.recover(loanId);

        IStaticsBasketCollateral.BasketCollateralPosition memory position =
            basketCollateral.basketCollateralPosition(positionId, basketId);
        assertEq(position.depositedShares, 79 ether);
        assertEq(position.lockedShares, 0);
        assertEq(IERC20(token).totalSupply(), launchSupply + 79 ether);
        assertEq(IERC20(token).balanceOf(address(diamond)), 79 ether);
        assertEq(assetA.balanceOf(bob), 0.4 ether);
        vm.prank(alice);
        uint256[] memory pending = globalRewards.pendingRewards(stakingPositionId, rewardAssets);
        assertEq(pending[0], 1.44 ether);
        assertEq(globalRewards.treasuryAccrued(address(assetA)), 0.16 ether);
        assertEq(lending.outstandingPrincipal(basketId, address(assetA)), 0);
        assertEq(IModularPositionNFT(address(diamond)).positionState(positionId).unresolvedObligationCount, 0);
        assertEq(baskets.vaultBalance(basketId, address(assetA)), launchVault + 158 ether);
        assertEq(
            custody.reservedByAccount(custody.basketCustodyAccount(basketId), address(assetA)),
            launchBasketReserved + 158 ether
        );
    }

    function testRecoveryAtMaximumLtvLeavesConfiguredResidualCollateral() public {
        IStaticsBasket.CreateBasketParams memory params = _defaultParams(0, 0);
        params.originationFeeBps = 0;
        params.ltvBps = 9_500;
        params.recoveryPenaltyBps = 500;
        (uint256 basketId, address token) = _launchBasket(params, alice, 1 ether);
        uint256 launchSupply = IERC20(token).totalSupply();
        uint256 positionId = _mintPositionShares(basketId, alice, 100 ether);
        vm.prank(alice);
        (uint256 loanId,) = lending.borrow(positionId, basketId, 100 ether, alice);

        IStaticsLending.RecoveryQuote memory quoted = lending.quoteRecovery(loanId);
        assertEq(quoted.burnShares, 99.75 ether);
        assertEq(quoted.unlockedShares, 0.25 ether);
        vm.warp(quoted.recoverableAt + 1);
        lending.recover(loanId);

        IStaticsBasketCollateral.BasketCollateralPosition memory position =
            basketCollateral.basketCollateralPosition(positionId, basketId);
        assertEq(position.depositedShares, 0.25 ether);
        assertEq(position.lockedShares, 0);
        assertEq(IERC20(token).totalSupply(), launchSupply + 0.25 ether);
        assertEq(IERC20(token).balanceOf(address(diamond)), 0.25 ether);
    }

    function testFuzzRecoveryBurnsOnlyDebtAndConfiguredPenalty(
        uint256 rawLtvBps,
        uint256 rawPenaltyBps,
        uint256 rawShares
    ) public {
        uint256 ltvBps = bound(rawLtvBps, 1, 9_500);
        uint256 penaltyBps = bound(rawPenaltyBps, 0, 500);
        uint256 shares = bound(rawShares, 1e12, 100 ether);
        IStaticsBasket.CreateBasketParams memory params = _defaultParams(0, 0);
        params.originationFeeBps = 0;
        params.ltvBps = uint16(ltvBps);
        params.recoveryPenaltyBps = uint16(penaltyBps);
        (uint256 basketId, address token) = _launchBasket(params, alice, 1 ether);
        uint256 launchSupply = IERC20(token).totalSupply();
        uint256 positionId = _mintPositionShares(basketId, alice, shares);

        IStaticsLending.BorrowQuote memory borrowQuote = lending.quoteBorrow(basketId, shares);
        assertEq(borrowQuote.debtShares, Math.mulDiv(shares, ltvBps, 10_000, Math.Rounding.Ceil));
        assertEq(borrowQuote.penaltyShares, Math.mulDiv(borrowQuote.debtShares, penaltyBps, 10_000, Math.Rounding.Ceil));
        vm.prank(alice);
        (uint256 loanId,) = lending.borrow(positionId, basketId, shares, alice);
        IStaticsLending.RecoveryQuote memory recoveryQuote = lending.quoteRecovery(loanId);
        assertEq(recoveryQuote.burnShares, borrowQuote.debtShares + borrowQuote.penaltyShares);
        assertEq(recoveryQuote.unlockedShares, shares - recoveryQuote.burnShares);

        vm.warp(recoveryQuote.recoverableAt + 1);
        lending.recover(loanId);

        IStaticsBasketCollateral.BasketCollateralPosition memory position =
            basketCollateral.basketCollateralPosition(positionId, basketId);
        assertEq(position.depositedShares, recoveryQuote.unlockedShares);
        assertEq(position.lockedShares, 0);
        assertEq(IERC20(token).totalSupply(), launchSupply + recoveryQuote.unlockedShares);
    }

    function testRecoveryPreservesBackingAfterInterveningSupplyChanges() public {
        IStaticsBasket.CreateBasketParams memory params = _defaultParams(0, 0);
        params.originationFeeBps = 0;
        params.ltvBps = 2_000;
        params.recoveryPenaltyBps = 500;
        (uint256 basketId, address token) = _launchBasket(params, alice, 1 ether);
        uint256 launchSupply = IERC20(token).totalSupply();
        uint256 launchVaultA = baskets.vaultBalance(basketId, address(assetA));
        uint256 launchVaultB = baskets.vaultBalance(basketId, address(assetB));
        uint256 positionId = _mintPositionShares(basketId, alice, 100 ether);
        vm.prank(alice);
        (uint256 loanId,) = lending.borrow(positionId, basketId, 100 ether, alice);

        _mintShares(basketId, token, bob, 37 ether);
        vm.startPrank(bob);
        IERC20(token).approve(address(diamond), 11 ether);
        uint256[] memory minimums = new uint256[](2);
        baskets.redeem(basketId, 11 ether, bob, minimums);
        vm.stopPrank();

        IStaticsLending.RecoveryQuote memory recoveryQuote = lending.quoteRecovery(loanId);
        assertEq(recoveryQuote.burnShares, 21 ether);
        assertEq(recoveryQuote.unlockedShares, 79 ether);
        assertEq(recoveryQuote.callerAmounts[0], 0.4 ether);
        assertEq(recoveryQuote.protocolAmounts[0], 1.6 ether);

        vm.warp(recoveryQuote.recoverableAt + 1);
        vm.prank(bob);
        lending.recover(loanId);

        assertEq(IERC20(token).totalSupply(), launchSupply + 105 ether);
        assertEq(baskets.vaultBalance(basketId, address(assetA)), launchVaultA + 210 ether);
        assertEq(baskets.vaultBalance(basketId, address(assetB)), launchVaultB + 525 ether);
        assertEq(lending.outstandingPrincipal(basketId, address(assetA)), 0);
        assertEq(lending.outstandingPrincipal(basketId, address(assetB)), 0);
    }

    function testPositionTransferMovesLoanExtensionAuthority() public {
        (uint256 basketId,) = _createDefaultBasket(0, 0);
        uint256 positionId = _mintPositionShares(basketId, alice, 10 ether);
        vm.prank(alice);
        (uint256 loanId,) = lending.borrow(positionId, basketId, 5 ether, alice);
        vm.prank(alice);
        IERC721(address(diamond)).transferFrom(alice, bob, positionId);

        vm.prank(alice);
        vm.expectRevert();
        lending.extend(loanId, new uint256[](2));

        (, uint256[] memory fees) = lending.quoteExtension(loanId);
        assetA.mint(bob, fees[0]);
        assetB.mint(bob, fees[1]);
        vm.startPrank(bob);
        assetA.approve(address(diamond), fees[0]);
        assetB.approve(address(diamond), fees[1]);
        lending.extend(loanId, fees);
        vm.stopPrank();
        assertEq(lending.loan(loanId).positionId, positionId);
    }

    function testMultipleTranchesLockAndRepayIndependently() public {
        (uint256 basketId,) = _createDefaultBasket(0, 0);
        uint256 positionId = _mintPositionShares(basketId, alice, 10 ether);
        vm.startPrank(alice);
        (uint256 firstLoan, uint256[] memory firstPrincipal) = lending.borrow(positionId, basketId, 3 ether, alice);
        (uint256 secondLoan,) = lending.borrow(positionId, basketId, 4 ether, alice);
        vm.stopPrank();

        IModularPositionNFT.PositionState memory twoLoans =
            IModularPositionNFT(address(diamond)).positionState(positionId);
        assertEq(twoLoans.unresolvedObligationCount, 2);

        assertEq(basketCollateral.basketCollateralPosition(positionId, basketId).lockedShares, 6.93 ether);
        vm.startPrank(alice);
        assetA.approve(address(diamond), firstPrincipal[0]);
        assetB.approve(address(diamond), firstPrincipal[1]);
        lending.repay(firstLoan);
        vm.stopPrank();

        assertEq(basketCollateral.basketCollateralPosition(positionId, basketId).lockedShares, 3.96 ether);
        assertEq(lending.loan(secondLoan).collateralShares, 3.96 ether);
        IModularPositionNFT.PositionState memory oneLoan =
            IModularPositionNFT(address(diamond)).positionState(positionId);
        assertEq(oneLoan.unresolvedObligationCount, 1);
    }

    function testLoanCallbacksObserveLiveObligationUntilRepaymentCompletes() public {
        (uint256 basketId, MockReentrantERC20 reentrant, address token) = _createReentrantFlashBasket();
        _mintReentrantBasketSupply(basketId, token, reentrant, 10 ether);
        uint256 positionId = _mintPositionShares(basketId, alice, 5 ether);
        PositionStateObserver observer = new PositionStateObserver(address(diamond));

        reentrant.setCallback(
            address(diamond), address(observer), abi.encodeCall(PositionStateObserver.observe, (positionId))
        );
        vm.prank(alice);
        (uint256 loanId, uint256[] memory principals) = lending.borrow(positionId, basketId, 1 ether, alice);
        assertEq(observer.observedObligations(), 1);

        reentrant.setCallback(alice, address(observer), abi.encodeCall(PositionStateObserver.observe, (positionId)));
        vm.startPrank(alice);
        reentrant.approve(address(diamond), principals[0]);
        assetB.approve(address(diamond), principals[1]);
        lending.repay(loanId);
        vm.stopPrank();

        assertEq(observer.observedObligations(), 1);
        assertEq(IModularPositionNFT(address(diamond)).positionState(positionId).unresolvedObligationCount, 0);
    }

    function testRecoveryCallbackObservesObligationUntilCleanupCompletes() public {
        (uint256 basketId, MockReentrantERC20 reentrant, address token) = _createReentrantFlashBasket();
        _mintReentrantBasketSupply(basketId, token, reentrant, 10 ether);
        uint256 positionId = _mintPositionShares(basketId, alice, 5 ether);
        vm.prank(alice);
        (uint256 loanId,) = lending.borrow(positionId, basketId, 1 ether, alice);
        PositionStateObserver observer = new PositionStateObserver(address(diamond));
        reentrant.setCallback(
            address(diamond), address(observer), abi.encodeCall(PositionStateObserver.observe, (positionId))
        );

        vm.warp(lending.quoteRecovery(loanId).recoverableAt + 1);
        vm.prank(bob);
        lending.recover(loanId);

        assertEq(observer.observedObligations(), 1);
        assertEq(IModularPositionNFT(address(diamond)).positionState(positionId).unresolvedObligationCount, 0);
    }

    function testRecoveringOneTrancheLeavesSiblingDebtAndCollateralIntact() public {
        (uint256 basketId,) = _createDefaultBasket(0, 0);
        uint256 positionId = _mintPositionShares(basketId, alice, 10 ether);
        vm.startPrank(alice);
        (uint256 firstLoan,) = lending.borrow(positionId, basketId, 3 ether, alice);
        (uint256 secondLoan, uint256[] memory secondPrincipal) = lending.borrow(positionId, basketId, 4 ether, alice);
        vm.stopPrank();

        vm.warp(uint256(lending.loan(firstLoan).maturity) + 1 hours + 1);
        vm.prank(bob);
        lending.recover(firstLoan);

        assertEq(lending.loan(secondLoan).positionId, positionId);
        assertEq(basketCollateral.basketCollateralPosition(positionId, basketId).lockedShares, 3.96 ether);
        assertEq(lending.outstandingPrincipal(basketId, address(assetA)), secondPrincipal[0]);
        assertEq(lending.outstandingPrincipal(basketId, address(assetB)), secondPrincipal[1]);
        assertEq(IModularPositionNFT(address(diamond)).positionState(positionId).unresolvedObligationCount, 1);
    }

    function testLockedCollateralDoesNotCreateBasketSpecificRewards() public {
        (uint256 basketId, address token) = _createDefaultBasket(0.1 ether, 0);
        uint256 launchTreasury = globalRewards.treasuryAccrued(address(assetA));
        uint256 positionId = _mintPositionShares(basketId, alice, 10 ether);
        vm.prank(alice);
        lending.borrow(positionId, basketId, 5 ether, alice);
        _mintShares(basketId, token, bob, 1 ether);

        assertEq(globalRewards.treasuryAccrued(address(assetA)), launchTreasury + 0.5 ether);
        assertEq(basketCollateral.basketCollateralPosition(positionId, basketId).lockedShares, 4.95 ether);
    }

    function testBasketMayConfigureLowerLtv() public {
        IStaticsBasket.CreateBasketParams memory params = _defaultParams(0, 0);
        params.originationFeeBps = 0;
        params.ltvBps = 5_000;
        (uint256 basketId,) = _launchBasket(params, alice, 1 ether);
        IStaticsLending.BorrowQuote memory quoted = lending.quoteBorrow(basketId, 1 ether);

        assertEq(baskets.basket(basketId).ltvBps, 5_000);
        assertEq(quoted.assets[0], address(assetA));
        assertEq(quoted.principals[0], 1 ether);
        assertEq(quoted.principals[1], 2.5 ether);
    }

    function testBasketCannotConfigureLtvAboveImmutableMaximum() public {
        IStaticsBasket.CreateBasketParams memory params = _defaultParams(0, 0);
        params.ltvBps = 9_501;
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BasketFacet.LtvExceedsMaximum.selector, 9_501));
        baskets.createBasket{value: 1 ether}(
            params,
            _defaultPoolLaunchParams(params.assets.length),
            _defaultLaunchMaximums(params.assets.length),
            type(uint256).max
        );
    }

    function testRecursiveLoopConvergesBelowTwentyTimesPrincipal() public {
        IStaticsBasket.CreateBasketParams memory params = _defaultParams(0, 0);
        params.originationFeeBps = 0;
        params.extensionFeeBps = 0;
        params.ltvBps = 9_500;
        (uint256 basketId,) = _launchBasket(params, alice, 1 ether);
        uint256 positionId = _mintPositionShares(basketId, alice, 1 ether);

        uint256 layerShares = 1 ether;
        uint256 totalDeposited = layerShares;
        uint256 debtEquivalentShares;
        for (uint256 i; i < 24; ++i) {
            vm.prank(alice);
            (, uint256[] memory principals) = lending.borrow(positionId, basketId, layerShares, alice);
            uint256 nextLayer = principals[0] / 2;
            assertApproxEqAbs(principals[1], nextLayer * 5, 10);
            uint256[] memory maximums = baskets.quoteMint(basketId, nextLayer);
            vm.prank(alice);
            basketCollateral.mintBasketCollateral(positionId, basketId, nextLayer, maximums);
            debtEquivalentShares += nextLayer;
            totalDeposited += nextLayer;
            layerShares = nextLayer;
        }

        assertLt(totalDeposited, 20 ether);
        assertLt(debtEquivalentShares, 19 ether);
        assertEq(basketCollateral.basketCollateralPosition(positionId, basketId).depositedShares, totalDeposited);
    }

    function testFlashLoanUsesOnlyUnderlyingLiquidityAndRoutesFees() public {
        (uint256 basketId, address token) = _createDefaultBasket(0, 0);
        _mintShares(basketId, token, alice, 10 ether);
        MockFlashBorrower receiver = new MockFlashBorrower(address(diamond));
        (address[] memory assets, uint256[] memory amounts, uint256[] memory fees) =
            flashLoans.quoteFlashLoan(basketId, 2 ether);
        assetA.mint(address(receiver), fees[0]);
        assetB.mint(address(receiver), fees[1]);
        uint256 vaultBefore = baskets.vaultBalance(basketId, assets[0]);

        receiver.execute(basketId, 2 ether, bytes("arb"));

        assertEq(baskets.vaultBalance(basketId, assets[0]), vaultBefore);
        assertEq(amounts[0], 4 ether);
        assertEq(fees[0], 0.002 ether);
        assertEq(globalRewards.treasuryAccrued(assets[0]), fees[0]);
    }

    function testFlashRepaymentCreditsMeasuredDirectionalTaxReceipt() public {
        MockOutboundFeeERC20 taxed = new MockOutboundFeeERC20();
        taxed.setTaxedSender(makeAddr("inactive taxed sender"));
        IStaticsBasket.CreateBasketParams memory params = _defaultParams(0, 0);
        params.assets[0] = address(taxed);
        params.flashFeeBps = 200;
        (uint256 basketId, address token) = _launchBasket(params, alice, basketAdmin.creationFee());
        uint256 launchSupply = IERC20(token).totalSupply();

        uint256[] memory initialMaximums = baskets.quoteMint(basketId, 10 ether);
        taxed.mint(alice, initialMaximums[0]);
        assetB.mint(alice, initialMaximums[1]);
        vm.startPrank(alice);
        taxed.approve(address(diamond), initialMaximums[0]);
        assetB.approve(address(diamond), initialMaximums[1]);
        baskets.mint(basketId, 10 ether, alice, initialMaximums);
        vm.stopPrank();

        MockFlashBorrower receiver = new MockFlashBorrower(address(diamond));
        (address[] memory assets, uint256[] memory amounts, uint256[] memory fees) =
            flashLoans.quoteFlashLoan(basketId, 1 ether);
        taxed.mint(address(receiver), fees[0]);
        assetB.mint(address(receiver), fees[1]);
        taxed.setTaxedSender(address(receiver));
        bytes32 basketAccount = custody.basketCustodyAccount(basketId);
        uint256 vaultBefore = baskets.vaultBalance(basketId, address(taxed));
        uint256 basketReservedBefore = custody.reservedByAccount(basketAccount, address(taxed));
        uint256 globalReservedBefore = custody.globalReservedByToken(address(taxed));
        uint256 treasuryBefore = globalRewards.treasuryAccrued(address(taxed));
        uint256 expectedReceived = amounts[0] + fees[0] - ((amounts[0] + fees[0]) / 100);
        uint256 expectedActualFee = expectedReceived - amounts[0];

        receiver.execute(basketId, 1 ether, bytes("directional repayment tax"));

        assertEq(assets[0], address(taxed));
        assertEq(baskets.vaultBalance(basketId, address(taxed)), vaultBefore);
        assertEq(custody.reservedByAccount(basketAccount, address(taxed)), basketReservedBefore);
        assertEq(globalRewards.treasuryAccrued(address(taxed)) - treasuryBefore, expectedActualFee);
        assertEq(custody.globalReservedByToken(address(taxed)) - globalReservedBefore, expectedActualFee);
        assertGe(taxed.balanceOf(address(diamond)), custody.globalReservedByToken(address(taxed)));
        assertEq(IERC20(token).totalSupply(), launchSupply + 10 ether);
    }

    function testFlashLoanRevertsAtomicallyWhenReceiverDoesNotRepay() public {
        (uint256 basketId, address token) = _createDefaultBasket(0, 0);
        _mintShares(basketId, token, alice, 10 ether);
        MockFlashBorrower receiver = new MockFlashBorrower(address(diamond));
        receiver.setRepay(false);
        uint256 vaultBefore = baskets.vaultBalance(basketId, address(assetA));
        vm.expectRevert();
        receiver.execute(basketId, 1 ether, bytes(""));
        assertEq(baskets.vaultBalance(basketId, address(assetA)), vaultBefore);
    }

    function testFlashCallbackCanMintThroughOrdinaryBasketEntrypoint() public {
        (uint256 basketId, address token) = _createDefaultBasket(0.01 ether, 0);
        _mintShares(basketId, token, alice, 10 ether);
        MockFlashBorrower receiver = new MockFlashBorrower(address(diamond));
        (,, uint256[] memory fees) = flashLoans.quoteFlashLoan(basketId, 1 ether);
        uint256[] memory maximums = baskets.quoteMint(basketId, 1 ether);
        assetA.mint(address(receiver), maximums[0] + fees[0]);
        assetB.mint(address(receiver), maximums[1] + fees[1]);
        receiver.approveProtocol(address(assetA), type(uint256).max);
        receiver.approveProtocol(address(assetB), type(uint256).max);
        receiver.setReentryData(abi.encodeCall(IStaticsBasket.mint, (basketId, 1 ether, address(receiver), maximums)));

        receiver.execute(basketId, 1 ether, bytes(""));

        assertTrue(receiver.reentrySucceeded());
        assertEq(IERC20(token).balanceOf(address(receiver)), 1 ether);
    }

    function testFlashCallbackCanRedeemThroughOrdinaryBasketEntrypoint() public {
        (uint256 basketId, address token) = _createDefaultBasket(0, 0);
        _mintShares(basketId, token, alice, 10 ether);
        MockFlashBorrower receiver = new MockFlashBorrower(address(diamond));
        vm.prank(alice);
        IERC20(token).transfer(address(receiver), 1 ether);
        receiver.setReentryData(
            abi.encodeCall(IStaticsBasket.redeem, (basketId, 1 ether, address(receiver), new uint256[](2)))
        );

        receiver.execute(basketId, 1 ether, bytes(""));

        assertTrue(receiver.reentrySucceeded());
        assertEq(IERC20(token).balanceOf(address(receiver)), 0);
        assertGt(assetA.balanceOf(address(receiver)), 0);
        assertGt(assetB.balanceOf(address(receiver)), 0);
    }

    function testFlashCallbackCannotNestFlashLoan() public {
        (uint256 basketId, address token) = _createDefaultBasket(0, 0);
        _mintShares(basketId, token, alice, 10 ether);
        MockFlashBorrower receiver = new MockFlashBorrower(address(diamond));
        (,, uint256[] memory fees) = flashLoans.quoteFlashLoan(basketId, 1 ether);
        assetA.mint(address(receiver), fees[0]);
        assetB.mint(address(receiver), fees[1]);
        receiver.setReentryData(
            abi.encodeCall(IStaticsFlashLoan.flashLoan, (basketId, 1 ether, address(receiver), bytes("nested")))
        );

        receiver.execute(basketId, 1 ether, bytes("outer"));

        assertFalse(receiver.reentrySucceeded());
        assertEq(bytes4(receiver.reentryResult()), ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
    }

    function testFlashCallbackCannotNestFlashLoanAgainstSiblingBasket() public {
        (uint256 firstBasketId, address firstToken) = _createDefaultBasket(0, 0);
        (uint256 secondBasketId, address secondToken) = _createDefaultBasket(0, 0);
        _mintShares(firstBasketId, firstToken, alice, 10 ether);
        _mintShares(secondBasketId, secondToken, bob, 10 ether);
        MockFlashBorrower receiver = new MockFlashBorrower(address(diamond));
        (,, uint256[] memory fees) = flashLoans.quoteFlashLoan(firstBasketId, 1 ether);
        assetA.mint(address(receiver), fees[0]);
        assetB.mint(address(receiver), fees[1]);
        bytes32 secondAccount = custody.basketCustodyAccount(secondBasketId);
        uint256 secondVaultBefore = baskets.vaultBalance(secondBasketId, address(assetA));
        uint256 secondReservedBefore = custody.reservedByAccount(secondAccount, address(assetA));
        receiver.setReentryData(
            abi.encodeCall(
                IStaticsFlashLoan.flashLoan, (secondBasketId, 1 ether, address(receiver), bytes("nested sibling"))
            )
        );

        receiver.execute(firstBasketId, 1 ether, bytes("outer"));

        assertFalse(receiver.reentrySucceeded());
        assertEq(bytes4(receiver.reentryResult()), ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        assertEq(baskets.vaultBalance(secondBasketId, address(assetA)), secondVaultBefore);
        assertEq(custody.reservedByAccount(secondAccount, address(assetA)), secondReservedBefore);
    }

    function testInvalidFlashCallbackRevertsAllCustodyAndVaultChanges() public {
        (uint256 basketId, address token) = _createDefaultBasket(0, 0);
        _mintShares(basketId, token, alice, 10 ether);
        MockFlashBorrower receiver = new MockFlashBorrower(address(diamond));
        bytes32 account = custody.basketCustodyAccount(basketId);
        uint256 vaultBefore = baskets.vaultBalance(basketId, address(assetA));
        uint256 accountBefore = custody.reservedByAccount(account, address(assetA));
        uint256 globalBefore = custody.globalReservedByToken(address(assetA));
        uint256 balanceBefore = assetA.balanceOf(address(diamond));
        receiver.setCallbackResult(bytes32(uint256(1)));

        vm.expectRevert();
        receiver.execute(basketId, 1 ether, bytes("invalid callback"));

        assertEq(baskets.vaultBalance(basketId, address(assetA)), vaultBefore);
        assertEq(custody.reservedByAccount(account, address(assetA)), accountBefore);
        assertEq(custody.globalReservedByToken(address(assetA)), globalBefore);
        assertEq(assetA.balanceOf(address(diamond)), balanceBefore);
    }

    function testFlashDisbursementTokenHookCannotEnterPersistentValuePath() public {
        (uint256 basketId, MockReentrantERC20 reentrant, address token) = _createReentrantFlashBasket();
        _mintReentrantBasketSupply(basketId, token, reentrant, 10 ether);
        MockFlashBorrower receiver = new MockFlashBorrower(address(diamond));
        (,, uint256[] memory fees) = flashLoans.quoteFlashLoan(basketId, 1 ether);
        reentrant.mint(address(receiver), fees[0]);
        assetB.mint(address(receiver), fees[1]);
        reentrant.setCallback(
            address(diamond),
            address(diamond),
            abi.encodeCall(IStaticsGlobalRewards.distributeTreasuryFees, (address(reentrant)))
        );

        receiver.execute(basketId, 1 ether, bytes("outbound hook"));

        assertFalse(reentrant.reentrySucceeded());
        assertEq(bytes4(reentrant.reentryResult()), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
    }

    function testFlashRepaymentTokenHookCannotEnterPersistentValuePath() public {
        (uint256 basketId, MockReentrantERC20 reentrant, address token) = _createReentrantFlashBasket();
        _mintReentrantBasketSupply(basketId, token, reentrant, 10 ether);
        MockFlashBorrower receiver = new MockFlashBorrower(address(diamond));
        (,, uint256[] memory fees) = flashLoans.quoteFlashLoan(basketId, 1 ether);
        reentrant.mint(address(receiver), fees[0]);
        assetB.mint(address(receiver), fees[1]);
        uint256 treasuryBefore = globalRewards.treasuryAccrued(address(reentrant));
        reentrant.setCallback(
            address(receiver),
            address(diamond),
            abi.encodeCall(IStaticsGlobalRewards.distributeTreasuryFees, (address(reentrant)))
        );

        receiver.execute(basketId, 1 ether, bytes("repayment hook"));

        assertFalse(reentrant.reentrySucceeded());
        assertEq(bytes4(reentrant.reentryResult()), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(globalRewards.treasuryAccrued(address(reentrant)), treasuryBefore + fees[0]);
    }

    function testOutboundTaxCannotReduceFlashPrincipalOrBasketBacking() public {
        MockOutboundFeeERC20 taxed = new MockOutboundFeeERC20();
        IStaticsBasket.CreateBasketParams memory params = _defaultParams(0, 0);
        params.assets[0] = address(taxed);
        params.flashFeeBps = 0;
        (uint256 basketId, address token) = _launchBasket(params, alice, 1 ether);
        uint256 launchSupply = IERC20(token).totalSupply();
        taxed.mint(alice, 21 ether);
        assetB.mint(alice, 50 ether);
        vm.startPrank(alice);
        taxed.approve(address(diamond), type(uint256).max);
        assetB.approve(address(diamond), type(uint256).max);
        baskets.mint(basketId, 10 ether, alice, baskets.quoteMint(basketId, 10 ether));
        vm.stopPrank();
        MockFlashBorrower receiver = new MockFlashBorrower(address(diamond));
        taxed.setTaxedSender(address(diamond));
        bytes32 account = custody.basketCustodyAccount(basketId);
        uint256 vaultBefore = baskets.vaultBalance(basketId, address(taxed));
        uint256 reservedBefore = custody.reservedByAccount(account, address(taxed));
        uint256 diamondBefore = taxed.balanceOf(address(diamond));

        vm.expectPartialRevert(FlashLoanFacet.IncompatibleFlashAsset.selector);
        receiver.execute(basketId, 1 ether, bytes("taxed disbursement"));

        assertEq(baskets.vaultBalance(basketId, address(taxed)), vaultBefore);
        assertEq(custody.reservedByAccount(account, address(taxed)), reservedBefore);
        assertEq(taxed.balanceOf(address(diamond)), diamondBefore);
        assertEq(taxed.balanceOf(address(receiver)), 0);
        assertEq(IERC20(token).totalSupply(), launchSupply + 10 ether);
    }

    function testLiquidityInterfacesAreDiscoverable() public view {
        assertTrue(IERC165(address(diamond)).supportsInterface(type(IStaticsLending).interfaceId));
        assertTrue(IERC165(address(diamond)).supportsInterface(type(IStaticsFlashLoan).interfaceId));
    }

    function testGuardianCanPauseBorrowWithoutBlockingRepay() public {
        (uint256 basketId,) = _createDefaultBasket(0, 0);
        uint256 positionId = _mintPositionShares(basketId, alice, 10 ether);
        vm.prank(guardian);
        governance.pause(1 << 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LendingFacet.ActionPaused.selector, 1 << 1));
        lending.borrow(positionId, basketId, 1 ether, alice);
    }

    function testFuzzBorrowRepayUsesStoredExactPrincipals(uint256 rawSharesIn) public {
        uint256 sharesIn = bound(rawSharesIn, 1e12, 10 ether);
        (uint256 basketId, address token) = _createDefaultBasket(0, 0);
        uint256 positionId = _mintPositionShares(basketId, alice, 20 ether);

        vm.startPrank(alice);
        (uint256 loanId, uint256[] memory principals) = lending.borrow(positionId, basketId, sharesIn, alice);
        assetA.approve(address(diamond), principals[0]);
        assetB.approve(address(diamond), principals[1]);
        lending.repay(loanId);
        vm.stopPrank();

        IStaticsLending.LoanView memory closed;
        vm.expectRevert();
        closed = lending.loan(loanId);
        assertEq(closed.positionId, 0);
        assertEq(lending.outstandingPrincipal(basketId, address(assetA)), 0);
        assertEq(lending.outstandingPrincipal(basketId, address(assetB)), 0);
        assertEq(
            IERC20(token).balanceOf(address(diamond)),
            basketCollateral.basketCollateralPosition(positionId, basketId).depositedShares
        );
    }

    function testFuzzExtensionQuotesStoredPrincipalsWithUpwardRounding(uint256 rawSharesIn) public {
        uint256 sharesIn = bound(rawSharesIn, 1e12, 10 ether);
        (uint256 basketId,) = _createDefaultBasket(0, 0);
        uint256 positionId = _mintPositionShares(basketId, alice, 20 ether);
        vm.prank(alice);
        (uint256 loanId, uint256[] memory principals) = lending.borrow(positionId, basketId, sharesIn, alice);
        (, uint256[] memory fees) = lending.quoteExtension(loanId);

        assertEq(fees[0], Math.mulDiv(principals[0], 25, 10_000, Math.Rounding.Ceil));
        assertEq(fees[1], Math.mulDiv(principals[1], 25, 10_000, Math.Rounding.Ceil));
        assetA.mint(alice, fees[0]);
        assetB.mint(alice, fees[1]);
        vm.startPrank(alice);
        assetA.approve(address(diamond), fees[0]);
        assetB.approve(address(diamond), fees[1]);
        uint256[] memory received = lending.extend(loanId, fees);
        vm.stopPrank();

        assertEq(received, fees);
        assertEq(lending.loan(loanId).principals, principals);
    }

    function testSplitOriginationFeesCarryConstituentRemainders() public {
        MockERC20 lowDecimal = new MockERC20("Low Decimal", "LOW", 0);
        address[] memory assets = new address[](2);
        assets[0] = address(assetA);
        assets[1] = address(lowDecimal);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 1 ether;
        amounts[1] = 2;
        IStaticsBasket.CreateBasketParams memory params = IStaticsBasket.CreateBasketParams({
            name: "Low Decimal Basket",
            symbol: "sLOW",
            assets: assets,
            bundleAmounts: amounts,
            mintFeeTiers: _singleFeeTier(0),
            redemptionFeeTiers: _singleFeeTier(0),
            flashFeeBps: 0,
            originationFeeBps: 100,
            extensionFeeBps: 0,
            ltvBps: 9_500,
            recoveryPenaltyBps: 500,
            loanDuration: 30 days
        });
        (uint256 basketId,) = _launchBasket(params, alice, 1 ether);
        vm.startPrank(alice);
        assetA.mint(alice, 100 ether);
        lowDecimal.mint(alice, 200);
        assetA.approve(address(diamond), type(uint256).max);
        lowDecimal.approve(address(diamond), type(uint256).max);
        uint256[] memory mintInputs = baskets.quoteMint(basketId, 100 ether);
        (uint256 positionId,) = basketCollateral.createAndMintBasketCollateral(basketId, 100 ether, alice, mintInputs);
        for (uint256 i; i < 100; ++i) {
            (uint256 loanId, uint256[] memory principals) = lending.borrow(positionId, basketId, 1 ether, alice);
            assetA.approve(address(diamond), principals[0]);
            lowDecimal.approve(address(diamond), principals[1]);
            lending.repay(loanId);
        }
        vm.stopPrank();

        assertEq(globalRewards.treasuryAccrued(address(lowDecimal)), 2);
    }

    function _mintPositionShares(uint256 basketId, address user, uint256 shares) private returns (uint256 positionId) {
        uint256[] memory quote = baskets.quoteMint(basketId, shares);
        _fundAndApprove(user, quote[0], quote[1]);
        vm.prank(user);
        (positionId,) = basketCollateral.createAndMintBasketCollateral(basketId, shares, user, quote);
    }

    function _createReentrantFlashBasket()
        private
        returns (uint256 basketId, MockReentrantERC20 reentrant, address token)
    {
        reentrant = new MockReentrantERC20();
        IStaticsBasket.CreateBasketParams memory params = _defaultParams(0.01 ether, 0);
        params.assets[0] = address(reentrant);
        (basketId, token) = _launchBasket(params, alice, 1 ether);
    }

    function _mintReentrantBasketSupply(uint256 basketId, address token, MockReentrantERC20 reentrant, uint256 shares)
        private
    {
        uint256[] memory maximums = baskets.quoteMint(basketId, shares);
        reentrant.mint(alice, maximums[0]);
        assetB.mint(alice, maximums[1]);
        vm.startPrank(alice);
        reentrant.approve(address(diamond), type(uint256).max);
        assetB.approve(address(diamond), type(uint256).max);
        baskets.mint(basketId, shares, alice, maximums);
        vm.stopPrank();
        assertEq(IERC20(token).balanceOf(alice), shares);
    }

    function _mintShares(uint256 basketId, address token, address user, uint256 shares) private {
        uint256[] memory quote = baskets.quoteMint(basketId, shares);
        _fundAndApprove(user, quote[0], quote[1]);
        vm.prank(user);
        baskets.mint(basketId, shares, user, quote);
        assertEq(IERC20(token).balanceOf(user), shares);
    }
}
