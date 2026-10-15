// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {SymTest} from "halmos-cheatcodes/SymTest.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StaticsRestrictedBasketToken} from "../../src/tokens/StaticsRestrictedBasketToken.sol";

/// @dev Minimal unlocked-manager boundary model, not a proof of v4 accounting or hook authentication.
contract RestrictedFormalPoolManager {
    function exttload(bytes32) external pure returns (bytes32) {
        return bytes32(uint256(1));
    }
}

/// @dev Explicit external registry/authorization model. Registry state lives outside
/// the test runner so symbolic callbacks read the same committed model storage.
contract RestrictedFormalProtocol {
    mapping(address => bool) public isBasketDistributor;
    StaticsRestrictedBasketToken public token;

    constructor(IPoolManager manager) {
        token = new StaticsRestrictedBasketToken("Restricted", "R", address(this), 7, manager);
    }

    function setDistributor(address account, bool allowed) external {
        isBasketDistributor[account] = allowed;
    }

    function mint(address account, uint256 amount) external {
        token.mint(account, amount);
    }

    function authorizeProtocolTransfer(address from, address to, uint256 amount) external {
        token.authorizeProtocolTransfer(from, to, amount);
    }

    function authorizePoolSettlement(uint256 inbound, uint256 outbound) external {
        token.authorizePoolSettlement(inbound, outbound);
    }

    function authorizePoolClaim(address receiver, uint256 amount) external {
        token.authorizePoolClaim(receiver, amount);
    }
}

contract RestrictedBasketSettlementHalmosTest is SymTest, Test {
    StaticsRestrictedBasketToken private token;
    address private manager;
    RestrictedFormalProtocol private protocol;
    address private constant ALICE = address(0xA11CE);
    address private constant BOB = address(0xB0B);

    function setUp() public {
        manager = address(new RestrictedFormalPoolManager());
        protocol = new RestrictedFormalProtocol(IPoolManager(manager));
        token = protocol.token();
        protocol.mint(ALICE, 1 ether);
        protocol.mint(manager, 1 ether);
    }

    function testRepresentativeExactTicket() public {
        this.check_exactTicketIsSingleUse(17);
    }

    function testRepresentativeDirection() public {
        this.check_poolBudgetsAreDirectionalAndConsumable(19, 23);
    }

    function testRepresentativeClaim() public {
        this.check_claimTicketBindsReceiverAndAmount(29);
    }

    function testRepresentativeAuthority() public {
        this.check_onlyProtocolCanGrant(ALICE);
    }

    function check_exactTicketIsSingleUse(uint96 amount) public {
        vm.assume(amount > 0 && amount <= 0.5 ether);
        protocol.authorizeProtocolTransfer(ALICE, address(protocol), amount);
        vm.prank(ALICE);
        (bool mismatch,) = address(token).call(abi.encodeCall(token.transfer, (address(protocol), uint256(amount) + 1)));
        assertFalse(mismatch);
        vm.prank(ALICE);
        assertTrue(token.transfer(address(protocol), amount));
        vm.prank(ALICE);
        (bool replay,) = address(token).call(abi.encodeCall(token.transfer, (address(protocol), uint256(amount))));
        assertFalse(replay);
        assertEq(token.balanceOf(address(protocol)), amount);
        assertEq(token.balanceOf(ALICE), 1 ether - amount);
    }

    function check_poolBudgetsAreDirectionalAndConsumable(uint64 inbound, uint64 outbound) public {
        vm.assume(inbound > 0 && inbound <= 0.5 ether && outbound > 0 && outbound <= 0.5 ether);
        protocol.setDistributor(manager, true);
        protocol.setDistributor(ALICE, true);
        protocol.setDistributor(BOB, true);
        protocol.authorizePoolSettlement(inbound, outbound);
        vm.prank(ALICE);
        assertTrue(token.transfer(manager, inbound));
        vm.prank(ALICE);
        (bool ingressReplay,) = address(token).call(abi.encodeCall(token.transfer, (manager, uint256(1))));
        assertFalse(ingressReplay);
        vm.prank(manager);
        assertTrue(token.transfer(BOB, outbound));
        vm.prank(manager);
        (bool egressReplay,) = address(token).call(abi.encodeCall(token.transfer, (BOB, uint256(1))));
        assertFalse(egressReplay);
        (uint256 remainingIn, uint256 remainingOut) = token.settlementBudgets();
        assertEq(remainingIn + remainingOut, 0);
        assertEq(token.balanceOf(manager), 1 ether + inbound - outbound);
    }

    function check_claimTicketBindsReceiverAndAmount(uint96 amount) public {
        vm.assume(amount > 0 && amount <= 0.5 ether);
        protocol.setDistributor(manager, true);
        protocol.setDistributor(ALICE, true);
        protocol.setDistributor(BOB, true);
        protocol.authorizePoolClaim(BOB, amount);
        vm.prank(manager);
        (bool wrongReceiver,) = address(token).call(abi.encodeCall(token.transfer, (ALICE, uint256(amount))));
        assertFalse(wrongReceiver);
        vm.prank(manager);
        (bool wrongAmount,) = address(token).call(abi.encodeCall(token.transfer, (BOB, uint256(amount) + 1)));
        assertFalse(wrongAmount);
        vm.prank(manager);
        assertTrue(token.transfer(BOB, amount));
        vm.prank(manager);
        (bool replay,) = address(token).call(abi.encodeCall(token.transfer, (BOB, uint256(amount))));
        assertFalse(replay);
        assertEq(token.balanceOf(BOB), amount);
        (uint256 inbound, uint256 outbound) = token.settlementBudgets();
        assertEq(inbound + outbound, 0);
    }

    function testRepresentativeDistributor() public {
        this.check_distributorEndpointsAndAllowances(31);
        this.check_ticketConsumedBeforeDistributor(37);
    }

    function check_distributorEndpointsAndAllowances(uint96 amount) public {
        vm.assume(amount > 0 && amount <= 0.25 ether);
        protocol.setDistributor(BOB, true);
        vm.prank(ALICE);
        assertTrue(token.transfer(BOB, amount));
        vm.prank(BOB);
        assertTrue(token.transfer(ALICE, amount));
        (bool noAllowance,) = address(token).call(abi.encodeCall(token.transferFrom, (ALICE, BOB, uint256(amount))));
        assertFalse(noAllowance);
        vm.prank(ALICE);
        token.approve(address(this), amount);
        assertTrue(token.transferFrom(ALICE, BOB, amount));
        assertEq(token.balanceOf(BOB), amount);
        assertEq(token.allowance(ALICE, address(this)), 0);
    }

    function check_ticketConsumedBeforeDistributor(uint96 amount) public {
        vm.assume(amount > 0 && amount <= 0.25 ether);
        protocol.setDistributor(ALICE, true);
        protocol.authorizeProtocolTransfer(ALICE, address(protocol), amount);
        vm.prank(ALICE);
        assertTrue(token.transfer(address(protocol), amount));
        protocol.setDistributor(ALICE, false);
        vm.prank(ALICE);
        (bool replay,) = address(token).call(abi.encodeCall(token.transfer, (address(protocol), uint256(amount))));
        assertFalse(replay);
    }

    function check_onlyProtocolCanGrant(address caller) public {
        vm.assume(caller != address(protocol));
        vm.prank(caller);
        (bool grant,) =
            address(token).call(abi.encodeCall(token.authorizeProtocolTransfer, (ALICE, address(protocol), uint256(1))));
        assertFalse(grant);
        vm.prank(caller);
        (bool poolGrant,) = address(token).call(abi.encodeCall(token.authorizePoolSettlement, (uint256(1), uint256(1))));
        assertFalse(poolGrant);
        vm.prank(caller);
        (bool claimGrant,) = address(token).call(abi.encodeCall(token.authorizePoolClaim, (BOB, uint256(1))));
        assertFalse(claimGrant);
    }
}
