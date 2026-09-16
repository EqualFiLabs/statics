// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {SymTest} from "halmos-cheatcodes/SymTest.sol";

import {FlashCustodyHarness} from "./harness/FlashCustodyHarness.sol";

contract PhaseOneFlashCustodyHalmosTest is SymTest, Test, FlashCustodyHarness {
    function testRepresentativePrincipalCannotBecomeReservationCapacity() public {
        check_flashPrincipalCannotBecomeReservationCapacity(100 ether, 80 ether, 75 ether);
    }

    function testRepresentativeExactRepaymentRestoresBacking() public {
        check_exactRepaymentRestoresBackingAndReservesOnlyFee(100 ether, 80 ether, 75 ether, 0.05 ether);
    }

    function testRepresentativeUnderpaymentReverts() public {
        check_anyUnderpaymentFailsFinalSolvency(100 ether, 80 ether, 75 ether, 0.05 ether);
    }

    function check_flashPrincipalCannotBecomeReservationCapacity(
        uint256 physicalBalance_,
        uint256 reserved_,
        uint256 loan_
    ) public {
        uint256 physical = physicalBalance_;
        uint256 reserved = reserved_;
        uint256 loan = loan_;
        vm.assume(physical <= type(uint96).max);
        vm.assume(reserved <= type(uint96).max && loan <= type(uint96).max);
        vm.assume(physical != 0 && reserved <= physical && loan != 0 && loan <= physical);
        seedCustody(physical, reserved);

        (uint256 spent, uint256 received) = lendAndCheckpoint(loan);
        assertEq(spent, loan);
        assertEq(received, loan);
        uint256 expectedAvailable = physical - reserved > loan ? physical - reserved - loan : 0;
        assertEq(unreserved(), expectedAvailable);

        (bool overReservationSucceeded,) =
            address(this).call(abi.encodeCall(this.reserveDuringCallback, (expectedAvailable + 1)));
        assertFalse(overReservationSucceeded);
        assertEq(globalReserved(), reserved);
        assertEq(callbackReserved(), 0);
    }

    function check_exactRepaymentRestoresBackingAndReservesOnlyFee(
        uint256 physicalBalance_,
        uint256 reserved_,
        uint256 loan_,
        uint256 fee_
    ) public {
        uint256 physical = physicalBalance_;
        uint256 reserved = reserved_;
        uint256 loan = loan_;
        uint256 fee = fee_;
        vm.assume(physical <= type(uint96).max);
        vm.assume(reserved <= type(uint96).max && loan <= type(uint96).max && fee <= type(uint96).max);
        vm.assume(physical != 0 && reserved <= physical && loan != 0 && loan <= physical);
        seedCustody(physical, reserved);
        uint256 startingUnreserved = physical - reserved;

        lendAndCheckpoint(loan);
        restorePhysicalBacking(loan + fee);
        finishFlash(startingUnreserved, fee);
        reserveFee(fee);

        assertEq(physicalBalance(), physical + fee);
        assertEq(globalReserved(), reserved + fee);
        assertEq(feeReserved(), fee);
        assertEq(unreserved(), startingUnreserved);
    }

    function check_anyUnderpaymentFailsFinalSolvency(
        uint256 physicalBalance_,
        uint256 reserved_,
        uint256 loan_,
        uint256 fee_
    ) public {
        uint256 physical = physicalBalance_;
        uint256 reserved = reserved_;
        uint256 loan = loan_;
        uint256 fee = fee_;
        vm.assume(physical <= type(uint96).max);
        vm.assume(reserved <= type(uint96).max && loan <= type(uint96).max && fee <= type(uint96).max);
        vm.assume(physical != 0 && reserved <= physical && loan != 0 && loan <= physical);
        seedCustody(physical, reserved);
        uint256 startingUnreserved = physical - reserved;

        lendAndCheckpoint(loan);
        restorePhysicalBacking(loan + fee - 1);
        (bool success,) = address(this).call(abi.encodeCall(this.finishFlash, (startingUnreserved, fee)));

        assertFalse(success);
        assertEq(globalReserved(), reserved);
        assertEq(feeReserved(), 0);
    }
}
