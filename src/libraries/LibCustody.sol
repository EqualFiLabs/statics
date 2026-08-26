// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

library LibCustody {
    using SafeERC20 for IERC20;

    bytes32 internal constant CUSTODY_STORAGE_POSITION = keccak256("statics.custody.storage.v1");
    bytes32 internal constant DOLLAR_ACCOUNT = keccak256("statics.custody.account.dollar");
    bytes32 internal constant FEE_ACCOUNT = keccak256("statics.custody.account.fees");
    bytes32 internal constant STAKING_ACCOUNT = keccak256("statics.custody.account.staking");
    bytes32 internal constant GENESIS_REWARD_ACCOUNT = keccak256("statics.custody.account.genesis.rewards");
    bytes32 internal constant BASKET_ACCOUNT_DOMAIN = keccak256("statics.custody.account.basket");

    struct CustodyStorage {
        mapping(address token => uint256 amount) globalReservedByToken;
        mapping(bytes32 account => mapping(address token => uint256 amount)) reservedByAccount;
    }

    event CustodyReserved(bytes32 indexed account, address indexed token, uint256 amount);
    event CustodyReleased(bytes32 indexed account, address indexed token, uint256 amount);

    error InsufficientUnreserved(address token, uint256 requested, uint256 available);
    error InsufficientAccountReservation(bytes32 account, address token, uint256 requested, uint256 available);
    error BalanceDecreasedDuringPull(address token, uint256 beforeBalance, uint256 afterBalance);
    error DebitExceedsAuthorization(address token, uint256 spent, uint256 maximum);
    error GlobalReservationShortfall(address token, uint256 reserved, uint256 balance);

    function custodyStorage() internal pure returns (CustodyStorage storage cs) {
        bytes32 position = CUSTODY_STORAGE_POSITION;
        assembly ("memory-safe") {
            cs.slot := position
        }
    }

    function dollarAccount() internal pure returns (bytes32) {
        return DOLLAR_ACCOUNT;
    }

    function basketAccount(uint256 basketId) internal pure returns (bytes32) {
        return keccak256(abi.encode(BASKET_ACCOUNT_DOMAIN, basketId));
    }

    function feeAccount() internal pure returns (bytes32) {
        return FEE_ACCOUNT;
    }

    function stakingAccount() internal pure returns (bytes32) {
        return STAKING_ACCOUNT;
    }

    function genesisRewardAccount() internal pure returns (bytes32) {
        return GENESIS_REWARD_ACCOUNT;
    }

    function globalReserved(address token) internal view returns (uint256) {
        return custodyStorage().globalReservedByToken[token];
    }

    function accountReserved(bytes32 account, address token) internal view returns (uint256) {
        return custodyStorage().reservedByAccount[account][token];
    }

    function unreservedBalance(address token) internal view returns (uint256 available) {
        uint256 balance = IERC20(token).balanceOf(address(this));
        uint256 reserved = globalReserved(token);
        return balance > reserved ? balance - reserved : 0;
    }

    function reserve(bytes32 account, address token, uint256 amount) internal {
        if (amount == 0) return;
        CustodyStorage storage cs = custodyStorage();
        uint256 balance = IERC20(token).balanceOf(address(this));
        uint256 globallyReserved = cs.globalReservedByToken[token];
        uint256 available = balance > globallyReserved ? balance - globallyReserved : 0;
        if (amount > available) revert InsufficientUnreserved(token, amount, available);
        cs.globalReservedByToken[token] = globallyReserved + amount;
        cs.reservedByAccount[account][token] += amount;
        emit CustodyReserved(account, token, amount);
    }

    function release(bytes32 account, address token, uint256 amount) internal {
        if (amount == 0) return;
        CustodyStorage storage cs = custodyStorage();
        uint256 local = cs.reservedByAccount[account][token];
        if (amount > local) revert InsufficientAccountReservation(account, token, amount, local);
        cs.reservedByAccount[account][token] = local - amount;
        cs.globalReservedByToken[token] -= amount;
        emit CustodyReleased(account, token, amount);
    }

    function moveReservation(bytes32 from, bytes32 to, address token, uint256 amount) internal {
        if (amount == 0 || from == to) return;
        CustodyStorage storage cs = custodyStorage();
        uint256 available = cs.reservedByAccount[from][token];
        if (amount > available) revert InsufficientAccountReservation(from, token, amount, available);
        cs.reservedByAccount[from][token] = available - amount;
        cs.reservedByAccount[to][token] += amount;
        emit CustodyReleased(from, token, amount);
        emit CustodyReserved(to, token, amount);
    }

    function pull(address token, address from, uint256 amount) internal returns (uint256 received) {
        uint256 beforeBalance = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(from, address(this), amount);
        uint256 afterBalance = IERC20(token).balanceOf(address(this));
        if (afterBalance < beforeBalance) revert BalanceDecreasedDuringPull(token, beforeBalance, afterBalance);
        return afterBalance - beforeBalance;
    }

    function pullAndReserve(bytes32 account, address token, address from, uint256 amount)
        internal
        returns (uint256 received)
    {
        received = pull(token, from, amount);
        reserve(account, token, received);
    }

    function pushReserved(bytes32 account, address token, address receiver, uint256 amount, uint256 maximumDebit)
        internal
        returns (uint256 spent, uint256 received)
    {
        uint256 local = accountReserved(account, token);
        if (maximumDebit > local) {
            revert InsufficientAccountReservation(account, token, maximumDebit, local);
        }

        release(account, token, maximumDebit);
        (spent, received) = _pushMeasured(token, receiver, amount);
        if (spent > maximumDebit) revert DebitExceedsAuthorization(token, spent, maximumDebit);
        _enforceGlobalBacking(token);
    }

    function pushUnreserved(address token, address receiver, uint256 amount, uint256 maximumDebit)
        internal
        returns (uint256 spent, uint256 received)
    {
        uint256 available = unreservedBalance(token);
        if (maximumDebit > available) revert InsufficientUnreserved(token, maximumDebit, available);
        (spent, received) = _pushMeasured(token, receiver, amount);
        if (spent > maximumDebit) revert DebitExceedsAuthorization(token, spent, maximumDebit);
        _enforceGlobalBacking(token);
    }

    function beginUnreservedDebit(address token, uint256 maximumDebit) internal view returns (uint256 beforeBalance) {
        uint256 available = unreservedBalance(token);
        if (maximumDebit > available) revert InsufficientUnreserved(token, maximumDebit, available);
        return IERC20(token).balanceOf(address(this));
    }

    function finishUnreservedDebit(address token, uint256 beforeBalance, uint256 maximumDebit)
        internal
        view
        returns (uint256 spent)
    {
        uint256 afterBalance = IERC20(token).balanceOf(address(this));
        spent = beforeBalance > afterBalance ? beforeBalance - afterBalance : 0;
        if (spent > maximumDebit) revert DebitExceedsAuthorization(token, spent, maximumDebit);
        _enforceGlobalBacking(token);
    }

    function _pushMeasured(address token, address receiver, uint256 amount)
        private
        returns (uint256 spent, uint256 received)
    {
        uint256 senderBefore = IERC20(token).balanceOf(address(this));
        uint256 receiverBefore = IERC20(token).balanceOf(receiver);
        IERC20(token).safeTransfer(receiver, amount);
        uint256 senderAfter = IERC20(token).balanceOf(address(this));
        uint256 receiverAfter = IERC20(token).balanceOf(receiver);
        spent = senderBefore > senderAfter ? senderBefore - senderAfter : 0;
        received = receiverAfter > receiverBefore ? receiverAfter - receiverBefore : 0;
    }

    function _enforceGlobalBacking(address token) private view {
        uint256 reserved = globalReserved(token);
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance < reserved) revert GlobalReservationShortfall(token, reserved, balance);
    }
}
