// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IStaticsBasket} from "../interfaces/IStaticsBasket.sol";
import {IStaticsFlashLoan} from "../interfaces/IStaticsFlashLoan.sol";
import {LibRestrictedBasket} from "./LibRestrictedBasket.sol";
import {LibCustody} from "./LibCustody.sol";

/// @notice Exact settlement for the protocol-deployed immutable NAV receiver, not a transfer exemption.
library LibBasketArbitrageSettlement {
    bytes32 private constant STORAGE_POSITION = keccak256("statics.storage.basket.arbitrage.receiver.v1");
    bytes32 private constant ACTIVE = keccak256("statics.transient.basket.arbitrage.active.v1");
    bytes32 private constant EXECUTOR = keccak256("statics.transient.basket.arbitrage.executor.v1");
    bytes32 private constant COUNT = keccak256("statics.transient.basket.arbitrage.count.v1");
    bytes32 private constant TOKEN = keccak256("statics.transient.basket.arbitrage.token.v1");
    bytes32 private constant FLOOR = keccak256("statics.transient.basket.arbitrage.floor.v1");
    bytes32 private constant INPUT = keccak256("statics.transient.basket.arbitrage.input.v1");

    struct ReceiverStorage {
        address receiver;
    }
    error InvalidArbitrageSettlement();

    function receiverStorage() internal pure returns (ReceiverStorage storage rs) {
        bytes32 slot = STORAGE_POSITION;
        assembly ("memory-safe") { rs.slot := slot }
    }

    function begin(uint256 basketId, uint256 shares, address executor) internal {
        if (
            msg.sender != receiverStorage().receiver || executor == address(0) || executor == address(this)
                || _load(ACTIVE) != 0
        ) revert InvalidArbitrageSettlement();
        (address[] memory assets, uint256[] memory principal,) =
            IStaticsFlashLoan(address(this)).quoteFlashLoan(basketId, shares);
        uint256[] memory mintAmounts = IStaticsBasket(address(this)).quoteMint(basketId, shares);
        if (assets.length > 16 || assets.length != mintAmounts.length) revert InvalidArbitrageSettlement();
        _store(ACTIVE, uint160(msg.sender));
        _store(EXECUTOR, uint160(executor));
        _store(COUNT, assets.length);
        for (uint256 i; i < assets.length; ++i) {
            _store(_slot(TOKEN, i), uint160(assets[i]));
            _store(_slot(FLOOR, i), IERC20(assets[i]).balanceOf(msg.sender));
            _store(_slot(INPUT, i), mintAmounts[i] > principal[i] ? mintAmounts[i] - principal[i] : 0);
        }
    }

    function settleInput(address token, address executor, uint256 amount) internal {
        uint256 index = _authenticate(token, executor);
        uint256 available = _load(_slot(INPUT, index));
        if (amount == 0 || amount > available) revert InvalidArbitrageSettlement();
        _store(_slot(INPUT, index), available - amount);
        uint256 beforeBalance = IERC20(token).balanceOf(executor);
        uint256 received = LibCustody.pull(token, executor, amount);
        if (received != amount || beforeBalance - IERC20(token).balanceOf(executor) != amount) {
            revert InvalidArbitrageSettlement();
        }
        (uint256 spent, uint256 delivered) = LibCustody.pushUnreserved(token, msg.sender, amount, amount);
        if (spent != amount || delivered != amount) revert InvalidArbitrageSettlement();
    }

    function settleOutput(address token, address executor, uint256 amount) internal {
        uint256 index = _authenticate(token, executor);
        uint256 balance = IERC20(token).balanceOf(msg.sender);
        uint256 floor = _load(_slot(FLOOR, index));
        if (amount == 0 || balance < floor || amount > balance - floor) revert InvalidArbitrageSettlement();
        uint256 received = LibCustody.pull(token, msg.sender, amount);
        if (received != amount) revert InvalidArbitrageSettlement();
        (uint256 spent, uint256 delivered) = LibCustody.pushUnreserved(token, executor, amount, amount);
        if (spent != amount || delivered != amount) revert InvalidArbitrageSettlement();
    }

    function end() internal {
        if (_load(ACTIVE) != uint160(msg.sender) || msg.sender == address(0)) revert InvalidArbitrageSettlement();
        uint256 count = _load(COUNT);
        for (uint256 i; i < count; ++i) {
            address token = address(uint160(_load(_slot(TOKEN, i))));
            if (
                LibRestrictedBasket.isRestricted(token) && IERC20(token).balanceOf(msg.sender) != _load(_slot(FLOOR, i))
            ) {
                revert InvalidArbitrageSettlement();
            }
            _store(_slot(TOKEN, i), 0);
            _store(_slot(FLOOR, i), 0);
            _store(_slot(INPUT, i), 0);
        }
        _store(ACTIVE, 0);
        _store(EXECUTOR, 0);
        _store(COUNT, 0);
    }

    function _authenticate(address token, address executor) private view returns (uint256 index) {
        if (
            _load(ACTIVE) != uint160(msg.sender) || _load(EXECUTOR) != uint160(executor)
                || msg.sender != receiverStorage().receiver || !LibRestrictedBasket.isRestricted(token)
        ) {
            revert InvalidArbitrageSettlement();
        }
        uint256 count = _load(COUNT);
        for (index; index < count; ++index) {
            if (_load(_slot(TOKEN, index)) == uint160(token)) return index;
        }
        revert InvalidArbitrageSettlement();
    }

    function _slot(bytes32 domain, uint256 index) private pure returns (bytes32) {
        return keccak256(abi.encode(domain, index));
    }

    function _load(bytes32 slot) private view returns (uint256 value) {
        assembly ("memory-safe") { value := tload(slot) }
    }

    function _store(bytes32 slot, uint256 value) private {
        assembly ("memory-safe") { tstore(slot, value) }
    }
}
