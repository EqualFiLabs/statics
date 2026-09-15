// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {IStaticsBasketCollateral} from "../../../src/interfaces/IStaticsBasketCollateral.sol";
import {IStaticsLending} from "../../../src/interfaces/IStaticsLending.sol";
import {IBlendBasket, RobinhoodBlendBasketForkBase} from "./RobinhoodBlendBasketFork.t.sol";

/// @notice Proves a Statics position can borrow and repay a live Blend share constituent.
contract RobinhoodBlendLendingForkTest is RobinhoodBlendBasketForkBase {
    uint256 private constant POSITION_SHARES = 10 ether;
    uint256 private constant BORROW_SHARES = 5 ether;

    struct BooksSnapshot {
        uint256 vault;
        uint256 basketReserve;
        uint256 globalReserve;
        uint256 treasury;
        uint256 diamondBlend;
        uint256 outerSupply;
        uint256 outerReserve;
        uint256 aliceOuter;
        uint256 bobBlend;
    }

    struct LendingMetrics {
        uint256 positionId;
        uint256 withdrawnShares;
        uint256 mintGas;
        uint256 borrowGas;
        uint256 repayGas;
        uint256 withdrawGas;
    }

    function testStaticsLendsAndRecoversLiveBlendConstituent() public {
        IBlendBasket blend = IBlendBasket(BLEND_AI);
        bytes32 blendBackingBefore = _blendBackingHash(blend);
        BooksSnapshot memory beforePosition = _snapshot();
        LendingMetrics memory metrics = _exerciseLending();

        _assertExited(metrics, beforePosition);
        assertEq(_blendBackingHash(blend), blendBackingBefore);

        emit log("Statics collateral: sBAI; borrowed and repaid asset: live Blend AI shares");
        emit log_named_uint("Blend-backed collateral mint gas", metrics.mintGas);
        emit log_named_uint("Blend constituent borrow gas", metrics.borrowGas);
        emit log_named_uint("Blend constituent repay gas", metrics.repayGas);
        emit log_named_uint("Unlocked sBAI withdrawal gas", metrics.withdrawGas);
    }

    function _exerciseLending() private returns (LendingMetrics memory metrics) {
        (metrics.positionId, metrics.mintGas) = _mintPosition();
        (metrics.withdrawnShares, metrics.borrowGas, metrics.repayGas) = _borrowAndRepay(metrics.positionId);
        uint256 gasBefore = gasleft();
        vm.prank(alice);
        basketCollateral.withdrawBasketCollateral(metrics.positionId, staticsBasketId, metrics.withdrawnShares, alice);
        metrics.withdrawGas = gasBefore - gasleft();
    }

    function _mintPosition() private returns (uint256 positionId, uint256 executionGas) {
        uint256[] memory mintQuote = baskets.quoteMint(staticsBasketId, POSITION_SHARES);
        uint256 gasBefore = gasleft();
        vm.prank(alice);
        uint256[] memory actualInputs;
        (positionId, actualInputs) =
            basketCollateral.createAndMintBasketCollateral(staticsBasketId, POSITION_SHARES, alice, mintQuote);
        executionGas = gasBefore - gasleft();
        assertEq(actualInputs, mintQuote);
        assertEq(IERC721(address(diamond)).ownerOf(positionId), alice);
    }

    function _borrowAndRepay(uint256 positionId)
        private
        returns (uint256 withdrawnShares, uint256 borrowGas, uint256 repayGas)
    {
        IStaticsLending.BorrowQuote memory quoted = lending.quoteBorrow(staticsBasketId, BORROW_SHARES);
        assertEq(quoted.assets.length, 1);
        assertEq(quoted.assets[0], BLEND_AI);
        assertEq(quoted.principals.length, 1);
        assertGt(quoted.principals[0], 0);

        BooksSnapshot memory beforeBorrow = _snapshot();
        uint256 gasBefore = gasleft();
        vm.prank(alice);
        (uint256 loanId, uint256[] memory principals) = lending.borrow(positionId, staticsBasketId, BORROW_SHARES, bob);
        borrowGas = gasBefore - gasleft();
        assertEq(principals, quoted.principals);
        _assertBorrow(positionId, loanId, quoted, beforeBorrow);

        gasBefore = gasleft();
        vm.startPrank(bob);
        assertTrue(IERC20(BLEND_AI).approve(address(diamond), principals[0]));
        lending.repay(loanId);
        vm.stopPrank();
        repayGas = gasBefore - gasleft();
        _assertRepaid(positionId, quoted, beforeBorrow);

        IStaticsBasketCollateral.BasketCollateralPosition memory position =
            basketCollateral.basketCollateralPosition(positionId, staticsBasketId);
        withdrawnShares = position.depositedShares;
    }

    function _assertExited(LendingMetrics memory metrics, BooksSnapshot memory beforePosition) private view {
        IStaticsBasketCollateral.BasketCollateralPosition memory exited =
            basketCollateral.basketCollateralPosition(metrics.positionId, staticsBasketId);
        assertEq(exited.depositedShares, 0);
        assertEq(exited.lockedShares, 0);
        assertEq(custody.globalReservedByToken(staticsBasketToken), beforePosition.outerReserve);
        assertEq(IERC20(staticsBasketToken).balanceOf(alice), beforePosition.aliceOuter + metrics.withdrawnShares);
    }

    function _assertBorrow(
        uint256 positionId,
        uint256 loanId,
        IStaticsLending.BorrowQuote memory quoted,
        BooksSnapshot memory beforeBorrow
    ) private view {
        uint256 principal = quoted.principals[0];
        uint256 feeUnderlying = quoted.feeShares;
        IStaticsLending.LoanView memory current = lending.loan(loanId);
        assertEq(current.positionId, positionId);
        assertEq(current.basketId, staticsBasketId);
        assertEq(current.collateralShares, quoted.collateralShares);
        assertEq(current.feeShares, quoted.feeShares);
        assertEq(current.debtShares, quoted.debtShares);
        assertEq(current.penaltyShares, quoted.penaltyShares);
        assertEq(current.assets[0], BLEND_AI);
        assertEq(current.principals[0], principal);
        assertEq(lending.outstandingPrincipal(staticsBasketId, BLEND_AI), principal);
        assertEq(IERC20(BLEND_AI).balanceOf(bob), beforeBorrow.bobBlend + principal);
        assertEq(baskets.vaultBalance(staticsBasketId, BLEND_AI), beforeBorrow.vault - principal - feeUnderlying);
        assertEq(custody.globalReservedByToken(BLEND_AI), beforeBorrow.globalReserve - principal);
        assertEq(IERC20(BLEND_AI).balanceOf(address(diamond)), beforeBorrow.diamondBlend - principal);
        assertEq(globalRewards.treasuryAccrued(BLEND_AI), beforeBorrow.treasury + feeUnderlying);

        IStaticsBasketCollateral.BasketCollateralPosition memory position =
            basketCollateral.basketCollateralPosition(positionId, staticsBasketId);
        assertEq(position.depositedShares, POSITION_SHARES - quoted.feeShares);
        assertEq(position.lockedShares, quoted.collateralShares);
        assertEq(IERC20(staticsBasketToken).totalSupply(), beforeBorrow.outerSupply - quoted.feeShares);
    }

    function _assertRepaid(
        uint256 positionId,
        IStaticsLending.BorrowQuote memory quoted,
        BooksSnapshot memory beforeBorrow
    ) private view {
        uint256 feeUnderlying = quoted.feeShares;
        assertEq(lending.outstandingPrincipal(staticsBasketId, BLEND_AI), 0);
        assertEq(IERC20(BLEND_AI).balanceOf(bob), beforeBorrow.bobBlend);
        assertEq(baskets.vaultBalance(staticsBasketId, BLEND_AI), beforeBorrow.vault - feeUnderlying);
        assertEq(custody.globalReservedByToken(BLEND_AI), beforeBorrow.globalReserve);
        assertEq(IERC20(BLEND_AI).balanceOf(address(diamond)), beforeBorrow.diamondBlend);
        assertEq(globalRewards.treasuryAccrued(BLEND_AI), beforeBorrow.treasury + feeUnderlying);
        assertEq(
            custody.reservedByAccount(custody.basketCustodyAccount(staticsBasketId), BLEND_AI),
            beforeBorrow.basketReserve - feeUnderlying
        );

        IStaticsBasketCollateral.BasketCollateralPosition memory position =
            basketCollateral.basketCollateralPosition(positionId, staticsBasketId);
        assertEq(position.depositedShares, POSITION_SHARES - quoted.feeShares);
        assertEq(position.lockedShares, 0);
    }

    function _snapshot() private view returns (BooksSnapshot memory snapshot) {
        snapshot.vault = baskets.vaultBalance(staticsBasketId, BLEND_AI);
        snapshot.basketReserve = custody.reservedByAccount(custody.basketCustodyAccount(staticsBasketId), BLEND_AI);
        snapshot.globalReserve = custody.globalReservedByToken(BLEND_AI);
        snapshot.treasury = globalRewards.treasuryAccrued(BLEND_AI);
        snapshot.diamondBlend = IERC20(BLEND_AI).balanceOf(address(diamond));
        snapshot.outerSupply = IERC20(staticsBasketToken).totalSupply();
        snapshot.outerReserve = custody.globalReservedByToken(staticsBasketToken);
        snapshot.aliceOuter = IERC20(staticsBasketToken).balanceOf(alice);
        snapshot.bobBlend = IERC20(BLEND_AI).balanceOf(bob);
    }

    function _blendBackingHash(IBlendBasket blend) private view returns (bytes32 result) {
        address[] memory assets = blend.constituents();
        for (uint256 i; i < assets.length; ++i) {
            result = keccak256(abi.encode(result, assets[i], blend.units(assets[i]), blend.backing(assets[i])));
        }
    }
}
