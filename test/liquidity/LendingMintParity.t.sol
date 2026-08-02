// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IStaticsBasket} from "../../src/interfaces/IStaticsBasket.sol";
import {IStaticsLending} from "../../src/interfaces/IStaticsLending.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {StaticsTestBase} from "../helpers/StaticsTestBase.sol";

contract LendingMintParityTest is StaticsTestBase {
    function testSingleConstituentMintAndBorrowMatchQuotes() public {
        _assertMintAndBorrowParity(1);
    }

    function testThreeConstituentMintAndBorrowMatchQuotes() public {
        _assertMintAndBorrowParity(3);
    }

    function testSixteenConstituentMintAndBorrowMatchQuotes() public {
        _assertMintAndBorrowParity(16);
    }

    function testFuzzOrdinaryMintAndBorrowMatchQuotes(uint96 rawMintFee, uint96 rawBorrowShares) public {
        uint256 mintFeeShares = bound(uint256(rawMintFee), 0, 1 ether);
        uint256 borrowShares = bound(uint256(rawBorrowShares), 1e12, 10 ether);
        (uint256 basketId,) = _createDefaultBasket(mintFeeShares, 0);
        uint256 mintShares = 20 ether;
        uint256[] memory mintQuote = baskets.quoteMint(basketId, mintShares);
        _fundAndApprove(alice, mintQuote[0], mintQuote[1]);
        vm.prank(alice);
        (uint256 positionId, uint256[] memory actualInputs) =
            basketCollateral.createAndMintBasketCollateral(basketId, mintShares, alice, mintQuote);
        assertEq(actualInputs, mintQuote);

        IStaticsLending.BorrowQuote memory quoted = lending.quoteBorrow(basketId, borrowShares);
        uint256[] memory balancesBefore = _balances(quoted.assets, bob);
        vm.prank(alice);
        (uint256 loanId, uint256[] memory principals) = lending.borrow(positionId, basketId, borrowShares, bob);

        assertEq(principals, quoted.principals);
        IStaticsLending.LoanView memory loan = lending.loan(loanId);
        assertEq(loan.feeShares, quoted.feeShares);
        assertEq(loan.collateralShares, quoted.collateralShares);
        assertEq(loan.debtShares, quoted.debtShares);
        assertEq(loan.penaltyShares, quoted.penaltyShares);
        assertEq(loan.principals, quoted.principals);
        for (uint256 i; i < quoted.assets.length; ++i) {
            assertEq(IERC20(quoted.assets[i]).balanceOf(bob) - balancesBefore[i], quoted.principals[i]);
        }
    }

    function _assertMintAndBorrowParity(uint256 count) private {
        address[] memory assets = new address[](count);
        uint256[] memory bundleAmounts = new uint256[](count);
        for (uint256 i; i < count; ++i) {
            assets[i] = address(new MockERC20("Constituent", "C", 18));
            bundleAmounts[i] = (i + 1) * 0.1 ether;
        }
        IStaticsBasket.CreateBasketParams memory params = IStaticsBasket.CreateBasketParams({
            name: "Parity Basket",
            symbol: "sPAR",
            assets: assets,
            bundleAmounts: bundleAmounts,
            mintFeeTiers: _singleFeeTier(0.2 ether),
            redemptionFeeTiers: new IStaticsBasket.FeeTier[](0),
            flashFeeBps: 0,
            originationFeeBps: 100,
            extensionFeeBps: 25,
            ltvBps: 9_500,
            recoveryPenaltyBps: 500,
            loanDuration: 30 days
        });
        vm.prank(alice);
        (uint256 basketId,) = baskets.createBasket{value: basketAdmin.creationFee()}(params);

        uint256[] memory mintQuote = baskets.quoteMint(basketId, 20 ether);
        vm.startPrank(alice);
        for (uint256 i; i < count; ++i) {
            MockERC20(assets[i]).mint(alice, mintQuote[i]);
            IERC20(assets[i]).approve(address(diamond), type(uint256).max);
        }
        (uint256 positionId, uint256[] memory actualInputs) =
            basketCollateral.createAndMintBasketCollateral(basketId, 20 ether, alice, mintQuote);
        vm.stopPrank();
        assertEq(actualInputs, mintQuote);

        IStaticsLending.BorrowQuote memory quoted = lending.quoteBorrow(basketId, 10 ether);
        uint256[] memory balancesBefore = _balances(assets, bob);
        vm.prank(alice);
        (uint256 loanId, uint256[] memory principals) = lending.borrow(positionId, basketId, 10 ether, bob);
        IStaticsLending.LoanView memory loan = lending.loan(loanId);

        assertEq(principals, quoted.principals);
        assertEq(loan.feeShares, quoted.feeShares);
        assertEq(loan.collateralShares, quoted.collateralShares);
        assertEq(loan.debtShares, quoted.debtShares);
        assertEq(loan.penaltyShares, quoted.penaltyShares);
        assertEq(loan.principals, quoted.principals);
        for (uint256 i; i < count; ++i) {
            assertEq(IERC20(assets[i]).balanceOf(bob) - balancesBefore[i], quoted.principals[i]);
            assertEq(lending.outstandingPrincipal(basketId, assets[i]), quoted.principals[i]);
        }
    }

    function _balances(address[] memory assets, address owner) private view returns (uint256[] memory balances) {
        balances = new uint256[](assets.length);
        for (uint256 i; i < assets.length; ++i) {
            balances[i] = IERC20(assets[i]).balanceOf(owner);
        }
    }
}
