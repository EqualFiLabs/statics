// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {LibRestrictedBasket} from "./LibRestrictedBasket.sol";
import {LibCustody} from "./LibCustody.sol";

/// @notice Scoped helper returns, never a permanent helper transfer exemption.
library LibBasketManagerSettlement {
    bytes32 private constant MANAGER = keccak256("statics.transient.basket.manager.v1");
    bytes32 private constant RECEIVER = keccak256("statics.transient.basket.manager.receiver.v1");
    bytes32 private constant TOKEN0 = keccak256("statics.transient.basket.manager.token0.v1");
    bytes32 private constant TOKEN1 = keccak256("statics.transient.basket.manager.token1.v1");
    bytes32 private constant FLOOR0 = keccak256("statics.transient.basket.manager.floor0.v1");
    bytes32 private constant FLOOR1 = keccak256("statics.transient.basket.manager.floor1.v1");

    error InvalidManagerSettlement();
    error ManagerSettlementAlreadyActive();
    error ManagerReturnExceedsMovement(address token, uint256 amount, uint256 available);

    function begin(PoolKey memory key, address manager, address receiver) internal {
        address token0 = Currency.unwrap(key.currency0);
        address token1 = Currency.unwrap(key.currency1);
        if (!LibRestrictedBasket.isRestricted(token0) && !LibRestrictedBasket.isRestricted(token1)) return;
        if (_load(MANAGER) != 0) revert ManagerSettlementAlreadyActive();
        _store(MANAGER, uint160(manager));
        _store(RECEIVER, uint160(receiver));
        _store(TOKEN0, uint160(token0));
        _store(TOKEN1, uint160(token1));
        _store(FLOOR0, IERC20(token0).balanceOf(manager));
        _store(FLOOR1, IERC20(token1).balanceOf(manager));
    }

    function end() internal {
        _store(MANAGER, 0);
        _store(RECEIVER, 0);
        _store(TOKEN0, 0);
        _store(TOKEN1, 0);
        _store(FLOOR0, 0);
        _store(FLOOR1, 0);
    }

    function settle(address token, address receiver, uint256 amount)
        internal
        returns (uint256 spent, uint256 received)
    {
        if (
            uint160(msg.sender) != _load(MANAGER) || uint160(receiver) != _load(RECEIVER) || amount == 0
                || !LibRestrictedBasket.isRestricted(token)
        ) revert InvalidManagerSettlement();
        uint256 floor;
        if (uint160(token) == _load(TOKEN0)) floor = _load(FLOOR0);
        else if (uint160(token) == _load(TOKEN1)) floor = _load(FLOOR1);
        else revert InvalidManagerSettlement();
        uint256 balance = IERC20(token).balanceOf(msg.sender);
        uint256 available = balance > floor ? balance - floor : 0;
        if (amount > available) revert ManagerReturnExceedsMovement(token, amount, available);
        received = LibCustody.pull(token, msg.sender, amount);
        if (received != amount) revert InvalidManagerSettlement();
        spent = amount;
        if (receiver != address(this)) (, received) = LibCustody.pushUnreserved(token, receiver, amount, amount);
    }

    function _load(bytes32 slot) private view returns (uint256 value) {
        assembly ("memory-safe") { value := tload(slot) }
    }

    function _store(bytes32 slot, uint256 value) private {
        assembly ("memory-safe") { tstore(slot, value) }
    }
}
