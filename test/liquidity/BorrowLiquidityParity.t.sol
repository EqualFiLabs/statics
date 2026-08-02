// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IStaticsBasketLiquidity} from "../../src/interfaces/IStaticsBasketLiquidity.sol";
import {IStaticsBasketCollateral} from "../../src/interfaces/IStaticsBasketCollateral.sol";
import {IStaticsBorrowLiquidity} from "../../src/interfaces/IStaticsBorrowLiquidity.sol";
import {IStaticsLending} from "../../src/interfaces/IStaticsLending.sol";
import {BorrowLiquidityTestBase} from "../helpers/BorrowLiquidityTestBase.sol";

contract BorrowLiquidityParityTest is BorrowLiquidityTestBase {
    struct AccountingSnapshot {
        IStaticsLending.LoanView loan;
        uint256 supply;
        uint256 depositedShares;
        uint256 lockedShares;
        uint256[] vaultBalances;
        uint256[] outstandingPrincipal;
    }

    function testSingleAssetCombinedAccountingMatchesSeparateBorrowAndMint() public {
        _assertParity(1, 5 ether);
    }

    function testThreeAssetCombinedAccountingMatchesSeparateBorrowAndMint() public {
        _assertParity(3, 4 ether);
    }

    function _assertParity(uint256 count, uint256 poolLiquidity) private {
        _createReadyBasket(count);
        IStaticsBorrowLiquidity.LiquidityParams[] memory params = _poolParams(poolLiquidity);
        uint256 supplyBefore = IERC20(basketToken).totalSupply();
        uint256 stateSnapshot = vm.snapshotState();

        vm.prank(alice);
        (uint256 combinedLoanId,) =
            borrowLiquidity.borrowAndProvideLiquidity(basketPositionId, basketId, 20 ether, params, bob);
        IStaticsLending.LoanView memory combinedLoan = lending.loan(combinedLoanId);
        uint256 basketShares = IERC20(basketToken).totalSupply() - (supplyBefore - combinedLoan.feeShares);
        AccountingSnapshot memory combined = _accounting(combinedLoanId);

        assertTrue(vm.revertToState(stateSnapshot));
        vm.prank(alice);
        (uint256 separateLoanId,) = lending.borrow(basketPositionId, basketId, 20 ether, bob);
        uint256[] memory mintQuote = baskets.quoteMint(basketId, basketShares);
        vm.startPrank(bob);
        for (uint256 i; i < basketAssets.length; ++i) {
            IERC20(basketAssets[i]).approve(address(diamond), mintQuote[i]);
        }
        baskets.mint(basketId, basketShares, bob, mintQuote);
        vm.stopPrank();
        AccountingSnapshot memory separate = _accounting(separateLoanId);

        assertEq(combined.loan.positionId, separate.loan.positionId);
        assertEq(combined.loan.basketId, separate.loan.basketId);
        assertEq(combined.loan.collateralShares, separate.loan.collateralShares);
        assertEq(combined.loan.feeShares, separate.loan.feeShares);
        assertEq(combined.loan.maturity, separate.loan.maturity);
        assertEq(combined.loan.principals, separate.loan.principals);
        assertEq(combined.supply, separate.supply);
        assertEq(combined.depositedShares, separate.depositedShares);
        assertEq(combined.lockedShares, separate.lockedShares);
        assertEq(combined.vaultBalances, separate.vaultBalances);
        assertEq(combined.outstandingPrincipal, separate.outstandingPrincipal);
    }

    function _accounting(uint256 loanId) private view returns (AccountingSnapshot memory state) {
        state.loan = lending.loan(loanId);
        state.supply = IERC20(basketToken).totalSupply();
        IStaticsBasketCollateral.BasketCollateralPosition memory position =
            basketCollateral.basketCollateralPosition(basketPositionId, basketId);
        state.depositedShares = position.depositedShares;
        state.lockedShares = position.lockedShares;
        uint256 length = basketAssets.length;
        state.vaultBalances = new uint256[](length);
        state.outstandingPrincipal = new uint256[](length);
        for (uint256 i; i < length; ++i) {
            address asset = basketAssets[i];
            state.vaultBalances[i] = baskets.vaultBalance(basketId, asset);
            state.outstandingPrincipal[i] = lending.outstandingPrincipal(basketId, asset);
        }
    }
}
