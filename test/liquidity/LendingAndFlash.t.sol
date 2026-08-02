// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IStaticsFlashLoan} from "../../src/interfaces/IStaticsFlashLoan.sol";
import {IStaticsLending} from "../../src/interfaces/IStaticsLending.sol";
import {IStaticsBasket} from "../../src/interfaces/IStaticsBasket.sol";
import {IStaticsBasketRewards} from "../../src/interfaces/IStaticsBasketRewards.sol";
import {BasketFacet} from "../../src/facets/BasketFacet.sol";
import {LendingFacet} from "../../src/facets/LendingFacet.sol";
import {MockFlashBorrower} from "../mocks/MockFlashBorrower.sol";
import {MockERC20, MockFeeOnTransferERC20} from "../mocks/MockERC20.sol";
import {StaticsTestBase} from "../helpers/StaticsTestBase.sol";

contract LendingAndFlashTest is StaticsTestBase {
    function testOriginationFeeBurnsPositionSharesAndLoanAppliesLtv() public {
        (uint256 basketId, address token) = _createDefaultBasket(0, 0);
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
        assertEq(IERC20(token).totalSupply(), 9.95 ether);
        assertEq(baskets.vaultBalance(basketId, address(assetA)), 10.495 ether);
        assertEq(basketAdmin.protocolRevenue(basketId, address(assetA)), 0.1 ether);
        assertEq(lending.outstandingPrincipal(basketId, address(assetA)), 9.405 ether);

        IStaticsBasketRewards.BasketPositionView memory position = basketRewards.basketPosition(positionId, basketId);
        assertEq(position.eligibleShares, 9.95 ether);
        assertEq(position.lockedShares, 4.95 ether);
    }

    function testRepayRestoresExactPrincipalAndUnlocksPositionCollateral() public {
        (uint256 basketId, address token) = _createDefaultBasket(0, 0);
        uint256 positionId = _mintPositionShares(basketId, alice, 10 ether);
        vm.prank(alice);
        (uint256 loanId, uint256[] memory principals) = lending.borrow(positionId, basketId, 5 ether, alice);

        vm.startPrank(alice);
        assetA.approve(address(diamond), principals[0]);
        assetB.approve(address(diamond), principals[1]);
        lending.repay(loanId);
        vm.stopPrank();

        IStaticsBasketRewards.BasketPositionView memory position = basketRewards.basketPosition(positionId, basketId);
        assertEq(position.eligibleShares, 9.95 ether);
        assertEq(position.lockedShares, 0);
        assertEq(IERC20(token).balanceOf(address(diamond)), 9.95 ether);
        assertEq(lending.outstandingPrincipal(basketId, address(assetA)), 0);
        assertEq(baskets.vaultBalance(basketId, address(assetA)), 19.9 ether);
    }

    function testExtensionChargesStoredUnderlyingPrincipalsAndPreservesBasketState() public {
        (uint256 basketId, address token) = _createDefaultBasket(0, 0);
        uint256 positionId = _mintPositionShares(basketId, alice, 10 ether);
        vm.prank(alice);
        (uint256 loanId,) = lending.borrow(positionId, basketId, 5 ether, alice);

        (address[] memory assets, uint256[] memory quotedFees) = lending.quoteExtension(loanId);
        assetA.mint(alice, quotedFees[0]);
        assetB.mint(alice, quotedFees[1]);
        uint256 supplyBefore = IERC20(token).totalSupply();
        uint256 vaultBefore = baskets.vaultBalance(basketId, address(assetA));
        uint256 eligibleBefore = basketRewards.basketPosition(positionId, basketId).eligibleShares;
        uint256 principalBefore = lending.loan(loanId).principals[0];

        vm.startPrank(alice);
        assetA.approve(address(diamond), quotedFees[0]);
        assetB.approve(address(diamond), quotedFees[1]);
        IStaticsLending.LoanView memory beforeLoan = lending.loan(loanId);
        uint256[] memory received = lending.extend(loanId, quotedFees);
        vm.stopPrank();

        IStaticsLending.LoanView memory afterLoan = lending.loan(loanId);
        assertEq(assets[0], address(assetA));
        assertEq(assets[1], address(assetB));
        assertEq(quotedFees[0], 0.0235125 ether);
        assertEq(quotedFees[1], 0.05878125 ether);
        assertEq(received, quotedFees);
        assertEq(afterLoan.maturity, beforeLoan.maturity + 30 days);
        assertEq(basketAdmin.protocolRevenue(basketId, address(assetA)), 0.1235125 ether);
        assertEq(IERC20(token).totalSupply(), supplyBefore);
        assertEq(baskets.vaultBalance(basketId, address(assetA)), vaultBefore);
        assertEq(basketRewards.basketPosition(positionId, basketId).eligibleShares, eligibleBefore);
        assertEq(lending.loan(loanId).principals[0], principalBefore);
    }

    function testExtensionCreditsMeasuredTaxedReceiptAsRevenue() public {
        MockFeeOnTransferERC20 taxed = new MockFeeOnTransferERC20();
        IStaticsBasket.CreateBasketParams memory params = _defaultParams(1 ether, 0);
        params.assets[0] = address(taxed);
        vm.prank(alice);
        (uint256 basketId,) = baskets.createBasket{value: 1 ether}(params);

        taxed.mint(alice, 100 ether);
        assetB.mint(alice, 100 ether);
        vm.startPrank(alice);
        taxed.approve(address(diamond), type(uint256).max);
        assetB.approve(address(diamond), type(uint256).max);
        uint256[] memory mintInputs = baskets.quoteMint(basketId, 10 ether);
        (uint256 positionId,) = basketRewards.createAndMintBasket(basketId, 10 ether, alice, mintInputs);
        (uint256 loanId,) = lending.borrow(positionId, basketId, 5 ether, alice);
        (, uint256[] memory requiredFees) = lending.quoteExtension(loanId);
        uint256[] memory grossAmounts = new uint256[](2);
        grossAmounts[0] = Math.mulDiv(requiredFees[0], 100, 99, Math.Rounding.Ceil);
        grossAmounts[1] = requiredFees[1] + 1;
        taxed.mint(alice, grossAmounts[0]);
        assetB.mint(alice, grossAmounts[1]);
        uint256 revenueABefore = basketAdmin.protocolRevenue(basketId, address(taxed));
        uint256 revenueBBefore = basketAdmin.protocolRevenue(basketId, address(assetB));
        uint256[] memory received = lending.extend(loanId, grossAmounts);
        vm.stopPrank();

        assertGe(received[0], requiredFees[0]);
        assertEq(received[0], grossAmounts[0] * 99 / 100);
        assertEq(received[1], grossAmounts[1]);
        assertEq(basketAdmin.protocolRevenue(basketId, address(taxed)), revenueABefore + received[0]);
        assertEq(basketAdmin.protocolRevenue(basketId, address(assetB)), revenueBBefore + received[1]);
        assertEq(
            custody.reservedByAccount(custody.basketCustodyAccount(basketId), address(taxed)),
            taxed.balanceOf(address(diamond))
        );
    }

    function testExtensionUnderpaymentRevertsWithoutAdvancingMaturity() public {
        (uint256 basketId,) = _createDefaultBasket(0, 0);
        uint256 positionId = _mintPositionShares(basketId, alice, 10 ether);
        vm.prank(alice);
        (uint256 loanId,) = lending.borrow(positionId, basketId, 5 ether, alice);
        (, uint256[] memory requiredFees) = lending.quoteExtension(loanId);
        uint40 maturityBefore = lending.loan(loanId).maturity;
        uint256 revenueBefore = basketAdmin.protocolRevenue(basketId, address(assetA));
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
        assertEq(basketAdmin.protocolRevenue(basketId, address(assetA)), revenueBefore);
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
        uint256 secondRevenueBefore = basketAdmin.protocolRevenue(secondBasket, address(assetA));
        bytes32 firstAccount = custody.basketCustodyAccount(firstBasket);
        bytes32 secondAccount = custody.basketCustodyAccount(secondBasket);
        uint256 firstReservedBefore = custody.reservedByAccount(firstAccount, address(assetA));
        uint256 secondReservedBefore = custody.reservedByAccount(secondAccount, address(assetA));

        vm.startPrank(alice);
        assetA.approve(address(diamond), fees[0]);
        assetB.approve(address(diamond), fees[1]);
        lending.extend(loanId, fees);
        vm.stopPrank();

        assertEq(basketAdmin.protocolRevenue(firstBasket, address(assetA)), 0.1235125 ether);
        assertEq(basketAdmin.protocolRevenue(secondBasket, address(assetA)), secondRevenueBefore);
        assertEq(custody.reservedByAccount(firstAccount, address(assetA)), firstReservedBefore + fees[0]);
        assertEq(custody.reservedByAccount(secondAccount, address(assetA)), secondReservedBefore);
        assertEq(custody.globalReservedByToken(address(assetA)), assetA.balanceOf(address(diamond)));
    }

    function testPermissionlessRecoveryBurnsCollateralAndIsolatesSurplus() public {
        (uint256 basketId, address token) = _createDefaultBasket(0, 0);
        uint256 positionId = _mintPositionShares(basketId, alice, 10 ether);
        vm.prank(alice);
        (uint256 loanId,) = lending.borrow(positionId, basketId, 10 ether, alice);
        IStaticsLending.LoanView memory opened = lending.loan(loanId);

        vm.warp(uint256(opened.maturity) + 1 hours);
        vm.expectRevert();
        lending.recover(loanId);
        vm.warp(block.timestamp + 1);
        vm.prank(bob);
        lending.recover(loanId);

        assertEq(IERC20(token).totalSupply(), 0);
        assertEq(lending.outstandingPrincipal(basketId, address(assetA)), 0);
        assertEq(basketAdmin.protocolRevenue(basketId, address(assetA)), 0.2 ether);
        assertEq(lending.recoverySurplus(basketId, address(assetA)), 0.99 ether);
        assertEq(basketRewards.basketPosition(positionId, basketId).eligibleShares, 0);
        assertEq(assetA.balanceOf(address(diamond)), 1.19 ether);
        assertEq(custody.reservedByAccount(custody.basketCustodyAccount(basketId), address(assetA)), 1.19 ether);
        assertEq(custody.globalReservedByToken(address(assetA)), 1.19 ether);
    }

    function testFullRecoveryRoutesLowDecimalResidualToRecoverySurplus() public {
        MockERC20 lowDecimal = new MockERC20("Indivisible", "ONE", 0);
        address[] memory assets = new address[](2);
        assets[0] = address(assetA);
        assets[1] = address(lowDecimal);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 1 ether;
        amounts[1] = 1;
        IStaticsBasket.CreateBasketParams memory params = IStaticsBasket.CreateBasketParams({
            name: "Indivisible Basket",
            symbol: "sONE",
            assets: assets,
            bundleAmounts: amounts,
            mintFeeTiers: _singleFeeTier(0),
            redemptionFeeTiers: _singleFeeTier(0),
            flashFeeBps: 0,
            originationFeeBps: 100,
            extensionFeeBps: 0,
            ltvBps: 9_500,
            loanDuration: 30 days
        });
        vm.startPrank(alice);
        (uint256 basketId, address token) = baskets.createBasket{value: 1 ether}(params);
        assetA.mint(alice, 0.5 ether);
        lowDecimal.mint(alice, 1);
        assetA.approve(address(diamond), type(uint256).max);
        lowDecimal.approve(address(diamond), type(uint256).max);
        uint256[] memory mintInputs = baskets.quoteMint(basketId, 0.5 ether);
        (uint256 positionId,) = basketRewards.createAndMintBasket(basketId, 0.5 ether, alice, mintInputs);
        (uint256 loanId,) = lending.borrow(positionId, basketId, 0.5 ether, alice);
        vm.stopPrank();

        IStaticsLending.LoanView memory opened = lending.loan(loanId);
        vm.warp(uint256(opened.maturity) + 1 hours + 1);
        lending.recover(loanId);

        assertEq(IERC20(token).totalSupply(), 0);
        assertEq(baskets.vaultBalance(basketId, address(lowDecimal)), 0);
        assertEq(basketAdmin.protocolRevenue(basketId, address(lowDecimal)), 0);
        assertEq(lending.recoverySurplus(basketId, address(lowDecimal)), 1);
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

        assertEq(basketRewards.basketPosition(positionId, basketId).lockedShares, 6.93 ether);
        vm.startPrank(alice);
        assetA.approve(address(diamond), firstPrincipal[0]);
        assetB.approve(address(diamond), firstPrincipal[1]);
        lending.repay(firstLoan);
        vm.stopPrank();

        assertEq(basketRewards.basketPosition(positionId, basketId).lockedShares, 3.96 ether);
        assertEq(lending.loan(secondLoan).collateralShares, 3.96 ether);
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
        assertEq(basketRewards.basketPosition(positionId, basketId).lockedShares, 3.96 ether);
        assertEq(lending.outstandingPrincipal(basketId, address(assetA)), secondPrincipal[0]);
        assertEq(lending.outstandingPrincipal(basketId, address(assetB)), secondPrincipal[1]);
    }

    function testLockedCollateralContinuesEarningBasketFees() public {
        (uint256 basketId, address token) = _createDefaultBasket(0.1 ether, 0);
        uint256 positionId = _mintPositionShares(basketId, alice, 10 ether);
        vm.prank(alice);
        lending.borrow(positionId, basketId, 5 ether, alice);
        _mintShares(basketId, token, bob, 1 ether);

        (, uint256[] memory pending) = basketRewards.pendingBasketRewards(positionId, basketId);
        assertApproxEqAbs(pending[0], 0.09 ether, 1);
        assertEq(basketRewards.basketPosition(positionId, basketId).lockedShares, 4.95 ether);
    }

    function testBasketMayConfigureLowerLtv() public {
        IStaticsBasket.CreateBasketParams memory params = _defaultParams(0, 0);
        params.originationFeeBps = 0;
        params.ltvBps = 5_000;
        vm.prank(alice);
        (uint256 basketId,) = baskets.createBasket{value: 1 ether}(params);
        (,, address[] memory assets, uint256[] memory principals) = lending.quoteBorrow(basketId, 1 ether);

        assertEq(baskets.basket(basketId).ltvBps, 5_000);
        assertEq(assets[0], address(assetA));
        assertEq(principals[0], 1 ether);
        assertEq(principals[1], 2.5 ether);
    }

    function testBasketCannotConfigureLtvAboveImmutableMaximum() public {
        IStaticsBasket.CreateBasketParams memory params = _defaultParams(0, 0);
        params.ltvBps = 9_501;
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BasketFacet.LtvExceedsMaximum.selector, 9_501));
        baskets.createBasket{value: 1 ether}(params);
    }

    function testRecursiveLoopConvergesBelowTwentyTimesPrincipal() public {
        IStaticsBasket.CreateBasketParams memory params = _defaultParams(0, 0);
        params.originationFeeBps = 0;
        params.extensionFeeBps = 0;
        params.ltvBps = 9_500;
        vm.prank(alice);
        (uint256 basketId,) = baskets.createBasket{value: 1 ether}(params);
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
            basketRewards.mintBasketToPosition(positionId, basketId, nextLayer, maximums);
            debtEquivalentShares += nextLayer;
            totalDeposited += nextLayer;
            layerShares = nextLayer;
        }

        assertLt(totalDeposited, 20 ether);
        assertLt(debtEquivalentShares, 19 ether);
        assertEq(basketRewards.basketPosition(positionId, basketId).eligibleShares, totalDeposited);
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
        assertEq(basketAdmin.protocolRevenue(basketId, assets[0]), 0.0011 ether);
        assertEq(basketLiquidity.liquidityReserve(basketId, assets[0]), 0.0009 ether);
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

    function testFlashCallbackCannotReenterBasketFacet() public {
        (uint256 basketId, address token) = _createDefaultBasket(0, 0);
        _mintShares(basketId, token, alice, 10 ether);
        MockFlashBorrower receiver = new MockFlashBorrower(address(diamond));
        (,, uint256[] memory fees) = flashLoans.quoteFlashLoan(basketId, 1 ether);
        assetA.mint(address(receiver), fees[0]);
        assetB.mint(address(receiver), fees[1]);
        uint256[] memory maximums = baskets.quoteMint(basketId, 1 ether);
        receiver.setReentryData(abi.encodeCall(IStaticsBasket.mint, (basketId, 1 ether, address(receiver), maximums)));

        receiver.execute(basketId, 1 ether, bytes(""));

        assertFalse(receiver.reentrySucceeded());
        assertEq(bytes4(receiver.reentryResult()), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
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
            IERC20(token).balanceOf(address(diamond)), basketRewards.basketPosition(positionId, basketId).eligibleShares
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
            loanDuration: 30 days
        });
        vm.startPrank(alice);
        (uint256 basketId,) = baskets.createBasket{value: 1 ether}(params);
        assetA.mint(alice, 100 ether);
        lowDecimal.mint(alice, 200);
        assetA.approve(address(diamond), type(uint256).max);
        lowDecimal.approve(address(diamond), type(uint256).max);
        uint256[] memory mintInputs = baskets.quoteMint(basketId, 100 ether);
        (uint256 positionId,) = basketRewards.createAndMintBasket(basketId, 100 ether, alice, mintInputs);
        for (uint256 i; i < 100; ++i) {
            (uint256 loanId, uint256[] memory principals) = lending.borrow(positionId, basketId, 1 ether, alice);
            assetA.approve(address(diamond), principals[0]);
            lowDecimal.approve(address(diamond), principals[1]);
            lending.repay(loanId);
        }
        vm.stopPrank();

        assertEq(basketAdmin.protocolRevenue(basketId, address(lowDecimal)), 2);
    }

    function _mintPositionShares(uint256 basketId, address user, uint256 shares) private returns (uint256 positionId) {
        uint256[] memory quote = baskets.quoteMint(basketId, shares);
        _fundAndApprove(user, quote[0], quote[1]);
        vm.prank(user);
        (positionId,) = basketRewards.createAndMintBasket(basketId, shares, user, quote);
    }

    function _mintShares(uint256 basketId, address token, address user, uint256 shares) private {
        uint256[] memory quote = baskets.quoteMint(basketId, shares);
        _fundAndApprove(user, quote[0], quote[1]);
        vm.prank(user);
        baskets.mint(basketId, shares, user, quote);
        assertEq(IERC20(token).balanceOf(user), shares);
    }
}
