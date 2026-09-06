// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";

import {LibCustody} from "../../src/libraries/LibCustody.sol";
import {MockERC20, MockOutboundFeeERC20, MockSenderExtraFeeERC20} from "../mocks/MockERC20.sol";

contract MockUnderDebitERC20 is MockERC20 {
    address public affectedSender;
    bool public zeroDebit;

    constructor() MockERC20("Under Debit", "UDEBIT", 18) {}

    function configure(address sender, bool zeroDebit_) external {
        affectedSender = sender;
        zeroDebit = zeroDebit_;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (affectedSender != address(0) && from == affectedSender && to != address(0)) {
            if (!zeroDebit) super._update(from, to, value / 2);
            return;
        }
        super._update(from, to, value);
    }
}

contract CustodyHarness {
    bytes32 private constant ACCOUNT = keccak256("statics.test.custody");

    function fund(address token, uint256 amount) external {
        uint256 received = LibCustody.pullAndReserve(ACCOUNT, token, msg.sender, amount);
        require(received == amount, "incompatible token");
    }

    function push(address token, address receiver, uint256 amount) external returns (uint256 spent, uint256 received) {
        return LibCustody.pushReserved(ACCOUNT, token, receiver, amount, amount);
    }

    function pushAuthorized(address token, address receiver, uint256 amount, uint256 maximumDebit)
        external
        returns (uint256 spent, uint256 received)
    {
        return LibCustody.pushReserved(ACCOUNT, token, receiver, amount, maximumDebit);
    }

    function reserved(address token) external view returns (uint256) {
        return LibCustody.accountReserved(ACCOUNT, token);
    }
}

contract LibCustodyTest is Test {
    address private receiver = makeAddr("receiver");
    CustodyHarness private harness;

    function setUp() public {
        harness = new CustodyHarness();
    }

    function testSelfRecipientRevertsWithoutReleasingReservation() public {
        MockERC20 token = new MockERC20("Token", "TOK", 18);
        _fund(token, 100 ether);

        vm.expectRevert(abi.encodeWithSelector(LibCustody.InvalidTransferReceiver.selector, address(harness)));
        harness.push(address(token), address(harness), 10 ether);

        assertEq(token.balanceOf(address(harness)), 100 ether);
        assertEq(harness.reserved(address(token)), 100 ether);
    }

    function testZeroDebitTransferRevertsWithoutReleasingReservation() public {
        MockUnderDebitERC20 token = new MockUnderDebitERC20();
        _fund(token, 100 ether);
        token.configure(address(harness), true);

        vm.expectRevert(abi.encodeWithSelector(LibCustody.DebitBelowRequested.selector, address(token), 0, 10 ether));
        harness.push(address(token), receiver, 10 ether);

        assertEq(token.balanceOf(address(harness)), 100 ether);
        assertEq(token.balanceOf(receiver), 0);
        assertEq(harness.reserved(address(token)), 100 ether);
    }

    function testPartialDebitTransferRevertsAtomically() public {
        MockUnderDebitERC20 token = new MockUnderDebitERC20();
        _fund(token, 100 ether);
        token.configure(address(harness), false);

        vm.expectRevert(
            abi.encodeWithSelector(LibCustody.DebitBelowRequested.selector, address(token), 5 ether, 10 ether)
        );
        harness.push(address(token), receiver, 10 ether);

        assertEq(token.balanceOf(address(harness)), 100 ether);
        assertEq(token.balanceOf(receiver), 0);
        assertEq(harness.reserved(address(token)), 100 ether);
    }

    function testReceiverTaxUsesSenderDebitAndReleasesExactReservation() public {
        MockOutboundFeeERC20 token = new MockOutboundFeeERC20();
        token.setTaxedSender(address(1));
        _fund(token, 100 ether);
        token.setTaxedSender(address(harness));

        (uint256 spent, uint256 received) = harness.push(address(token), receiver, 10 ether);

        assertEq(spent, 10 ether);
        assertEq(received, 9.9 ether);
        assertEq(token.balanceOf(address(harness)), 90 ether);
        assertEq(harness.reserved(address(token)), 90 ether);
    }

    function testUnusedDebitAuthorizationRemainsReserved() public {
        MockERC20 token = new MockERC20("Token", "TOK", 18);
        _fund(token, 100 ether);

        (uint256 spent, uint256 received) = harness.pushAuthorized(address(token), receiver, 10 ether, 20 ether);

        assertEq(spent, 10 ether);
        assertEq(received, 10 ether);
        assertEq(token.balanceOf(address(harness)), 90 ether);
        assertEq(harness.reserved(address(token)), 90 ether);
    }

    function testSenderExtraDebitReleasesMeasuredReservation() public {
        MockSenderExtraFeeERC20 token = new MockSenderExtraFeeERC20();
        _fund(token, 100 ether);
        token.setTaxedSender(address(harness));

        (uint256 spent, uint256 received) = harness.pushAuthorized(address(token), receiver, 10 ether, 11 ether);

        assertEq(spent, 10.1 ether);
        assertEq(received, 10 ether);
        assertEq(token.balanceOf(address(harness)), 89.9 ether);
        assertEq(harness.reserved(address(token)), 89.9 ether);
    }

    function _fund(MockERC20 token, uint256 amount) private {
        token.mint(address(this), amount);
        token.approve(address(harness), amount);
        harness.fund(address(token), amount);
    }
}
