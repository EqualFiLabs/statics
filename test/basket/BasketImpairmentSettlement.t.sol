// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IStaticsLending} from "../../src/interfaces/IStaticsLending.sol";
import {IStaticsBasketLiquidity} from "../../src/interfaces/IStaticsBasketLiquidity.sol";
import {IStaticsProtocolPools} from "../../src/interfaces/IStaticsProtocolPools.sol";
import {LendingFacet} from "../../src/facets/LendingFacet.sol";
import {LibCustody} from "../../src/libraries/LibCustody.sol";
import {BasketImpairmentTestBase} from "../helpers/BasketImpairmentTestBase.sol";

contract BasketImpairmentSettlementTest is BasketImpairmentTestBase {
    function _borrow() private returns (uint256 position, uint256 loanId) {
        vm.startPrank(alice);
        IERC20(token).approve(address(diamond), 10 ether);
        position = basketCollateral.createAndDepositBasketCollateral(id, 10 ether, alice);
        (loanId,) = lending.borrow(position, id, 4 ether, alice);
        vm.stopPrank();
    }

    function testRepaymentWritesOffOnlyImpairedPrincipalAndAllowsExit() public {
        (uint256 position, uint256 loanId) = _borrow();
        IStaticsLending.LoanView memory loan = lending.loan(loanId);
        uint256 residual = baskets.vaultBalance(id, address(bad));
        uint256 reserved = custody.globalReservedByToken(address(bad));
        uint256 healthyBefore = assetA.balanceOf(alice);
        _impair();
        vm.expectEmit(true, true, true, true, address(diamond));
        emit IStaticsLending.LoanImpairedPrincipalWrittenOff(loanId, id, address(bad), loan.principals[1]);
        vm.prank(alice);
        lending.repay(loanId);
        assertEq(healthyBefore - assetA.balanceOf(alice), loan.principals[0]);
        assertEq(lending.outstandingPrincipal(id, address(assetA)), 0);
        assertEq(lending.outstandingPrincipal(id, address(bad)), 0);
        assertEq(baskets.vaultBalance(id, address(bad)), residual);
        assertEq(custody.globalReservedByToken(address(bad)), reserved);
        assertEq(basketCollateral.basketCollateralPosition(position, id).lockedShares, 0);
        uint256 shares = basketCollateral.basketCollateralPosition(position, id).depositedShares;
        vm.prank(alice);
        impairment.redeemImpairedBasketCollateral(position, id, shares, alice, new uint256[](2));
        assertEq(basketCollateral.basketCollateralPosition(position, id).depositedShares, 0);
    }

    function testMissingHealthyRepaymentRollsBackWriteOffAndLocks() public {
        (uint256 position, uint256 loanId) = _borrow();
        IStaticsLending.LoanView memory loan = lending.loan(loanId);
        _impair();
        vm.startPrank(alice);
        assetA.approve(address(diamond), loan.principals[0] - 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector,
                address(diamond),
                loan.principals[0] - 1,
                loan.principals[0]
            )
        );
        lending.repay(loanId);
        vm.stopPrank();
        assertEq(lending.outstandingPrincipal(id, address(bad)), loan.principals[1]);
        assertEq(basketCollateral.basketCollateralPosition(position, id).lockedShares, loan.collateralShares);
    }

    function testLaterRepaymentFailureRollsBackEarlierPrincipalWriteOff() public {
        (uint256 position, uint256 loanId) = _borrow();
        IStaticsLending.LoanView memory loan = lending.loan(loanId);
        uint256 vault = baskets.vaultBalance(id, address(assetA));
        uint256 reserved = custody.globalReservedByToken(address(assetA));
        // Asset zero is written off before asset one's allowance failure.
        impairment.markBasketAssetImpaired(id, address(assetA));
        vm.startPrank(alice);
        bad.approve(address(diamond), loan.principals[1] - 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector,
                address(diamond),
                loan.principals[1] - 1,
                loan.principals[1]
            )
        );
        lending.repay(loanId);
        vm.stopPrank();
        IStaticsLending.LoanView memory unchanged = lending.loan(loanId);
        assertEq(unchanged.principals, loan.principals);
        assertEq(lending.outstandingPrincipal(id, address(assetA)), loan.principals[0]);
        assertEq(lending.outstandingPrincipal(id, address(bad)), loan.principals[1]);
        assertEq(baskets.vaultBalance(id, address(assetA)), vault);
        assertEq(custody.globalReservedByToken(address(assetA)), reserved);
        assertEq(basketCollateral.basketCollateralPosition(position, id).lockedShares, loan.collateralShares);
        vm.prank(alice);
        bad.approve(address(diamond), loan.principals[1]);
        vm.prank(alice);
        lending.repay(loanId);
        assertEq(lending.outstandingPrincipal(id, address(assetA)), 0);
        assertEq(basketCollateral.basketCollateralPosition(position, id).lockedShares, 0);
    }

    function testRecoveryPreservesTimingAndHealthyPenaltyWithoutImpairedCalls() public {
        (uint256 position, uint256 loanId) = _borrow();
        IStaticsLending.LoanView memory loan = lending.loan(loanId);
        uint256 residual = baskets.vaultBalance(id, address(bad));
        uint256 reserved = custody.globalReservedByToken(address(bad));
        IStaticsLending.RecoveryQuote memory original = lending.quoteRecovery(loanId);
        _impair();
        IStaticsLending.RecoveryQuote memory quote = lending.quoteRecovery(loanId);
        assertEq(quote.callerAmounts[0], original.callerAmounts[0]);
        assertEq(quote.protocolAmounts[0], original.protocolAmounts[0]);
        assertEq(quote.callerAmounts[1], 0);
        assertEq(quote.protocolAmounts[1], 0);
        vm.expectRevert(abi.encodeWithSelector(LendingFacet.LoanNotRecoverable.selector, loanId, quote.recoverableAt));
        lending.recover(loanId);
        vm.warp(quote.recoverableAt + 1);
        uint256 supply = IERC20(token).totalSupply();
        uint256 beforeHealthy = assetA.balanceOf(bob);
        vm.prank(bob);
        lending.recover(loanId);
        assertEq(assetA.balanceOf(bob) - beforeHealthy, quote.callerAmounts[0]);
        assertEq(IERC20(token).totalSupply(), supply - quote.burnShares);
        assertEq(lending.outstandingPrincipal(id, address(bad)), 0);
        assertEq(lending.outstandingPrincipal(id, address(assetA)), 0);
        assertEq(baskets.vaultBalance(id, address(bad)), residual);
        assertEq(custody.globalReservedByToken(address(bad)), reserved);
        assertEq(basketCollateral.basketCollateralPosition(position, id).lockedShares, 0);
        assertEq(
            basketCollateral.basketCollateralPosition(position, id).depositedShares,
            10 ether - loan.feeShares - quote.burnShares
        );
    }

    function testAllImpairedLoanCanCloseWithoutTokenTransfers() public {
        (uint256 position, uint256 loanId) = _borrow();
        _impair();
        impairment.markBasketAssetImpaired(id, address(assetA));
        vm.prank(bob);
        lending.repay(loanId);
        assertEq(lending.outstandingPrincipal(id, address(assetA)), 0);
        assertEq(lending.outstandingPrincipal(id, address(bad)), 0);
        assertEq(basketCollateral.basketCollateralPosition(position, id).lockedShares, 0);
    }

    function testClosingOneLoanPreservesOtherLoanPrincipal() public {
        (, uint256 first) = _borrow();
        IStaticsLending.LoanView memory loan = lending.loan(first);
        _mintTestShares(id, 10 ether);
        (, uint256 second) = _borrow();
        _impair();
        vm.prank(alice);
        lending.repay(first);
        assertEq(lending.outstandingPrincipal(id, address(assetA)), loan.principals[0]);
        assertEq(lending.outstandingPrincipal(id, address(bad)), loan.principals[1]);
        assertEq(lending.loan(second).principals[1], loan.principals[1]);
    }

    function testHealthyPoolUnwindBurnsPolWithoutTouchingImpairedBacking() public {
        IStaticsBasketLiquidity.CanonicalPoolView memory pool = basketLiquidity.canonicalPool(id, address(assetA));
        IStaticsProtocolPools protocol = IStaticsProtocolPools(address(diamond));
        uint256[] memory positions = protocol.protocolPolPositionIds(pool.poolId);
        assertEq(positions.length, 1);
        uint256 residual = baskets.vaultBalance(id, address(bad));
        uint256 reserved = custody.globalReservedByToken(address(bad));
        uint256 badTreasury = globalRewards.treasuryAccrued(address(bad));
        uint256 supply = IERC20(token).totalSupply();
        _impair();
        protocol.closeProtocolPolPosition(positions[0], 0, 0, block.timestamp + 1 days);
        vm.prank(bob);
        basketLiquidity.unwindBasketLiquidity(id, address(assetA));
        assertLt(IERC20(token).totalSupply(), supply);
        assertEq(baskets.vaultBalance(id, address(bad)), residual);
        assertEq(custody.globalReservedByToken(address(bad)), reserved);
        assertEq(custody.reservedByAccount(LibCustody.basketAccount(id), address(bad)), residual);
        assertEq(globalRewards.treasuryAccrued(address(bad)), badTreasury);
    }
}
