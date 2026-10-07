// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {LibCustody} from "./LibCustody.sol";
import {IStaticsAggregatedBatchRewards} from "../interfaces/IStaticsAggregatedBatchRewards.sol";

/// @dev Only the three reward claim paths use this helper. Other custody flows never defer transfers.
library LibRewardPayout {
    bytes32 private constant DOMAIN = keccak256("statics.transient.aggregated.rewards.v1");
    bytes32 internal constant ACCOUNT = LibCustody.AGGREGATED_REWARD_ACCOUNT;
    uint256 private constant ACTIVE = 0;
    uint256 private constant CALLER = 1;
    uint256 private constant RECEIVER = 2;
    uint256 private constant ROUTE = 3;
    uint256 private constant RECORDS = 4;
    uint256 private constant TOKENS = 5;
    uint256 private constant MAX_ENTRIES = 64;

    function _slot(uint256 field, uint256 index) private pure returns (bytes32) {
        bytes32 domain = bytes32(uint256(DOMAIN) + field);
        bytes32 slot;
        assembly ("memory-safe") {
            mstore(0, domain)
            mstore(32, index)
            slot := keccak256(0, 64)
        }
        return slot;
    }

    function _get(uint256 field, uint256 index) private view returns (uint256 value) {
        bytes32 slot = _slot(field, index);
        assembly ("memory-safe") { value := tload(slot) }
    }

    function _set(uint256 field, uint256 index, uint256 value) private {
        bytes32 slot = _slot(field, index);
        assembly ("memory-safe") { tstore(slot, value) }
    }

    function begin(address receiver) internal {
        if (_get(ACTIVE, 0) != 0) revert IStaticsAggregatedBatchRewards.InvalidAggregatedClaimContext();
        _set(ACTIVE, 0, 1);
        _set(CALLER, 0, uint160(msg.sender));
        _set(RECEIVER, 0, uint160(receiver));
    }

    function startRoute(bytes4 selector) internal {
        if (_get(ACTIVE, 0) != 0) {
            if (_get(ROUTE, 0) != 0) revert IStaticsAggregatedBatchRewards.InvalidAggregatedClaimContext();
            _set(ROUTE, 0, uint32(selector));
        }
    }

    function finishRoute(bytes4 selector, uint256[] memory received) internal {
        if (_get(ACTIVE, 0) == 0) return;
        uint256 count = _get(RECORDS, 0);
        if (count != received.length) revert IStaticsAggregatedBatchRewards.AggregatedClaimRouteIncompatible(selector);
        for (uint256 i; i < count; ++i) {
            if (_get(6, i) != received[i]) {
                revert IStaticsAggregatedBatchRewards.AggregatedClaimRouteIncompatible(selector);
            }
            _set(6, i, 0);
        }
        _set(RECORDS, 0, 0);
        _set(ROUTE, 0, 0);
    }

    function pay(bytes32 source, address asset, address receiver, uint256 amount)
        internal
        returns (uint256 debited, uint256 received)
    {
        if (_get(ACTIVE, 0) == 0) {
            if (amount == 0) return (0, 0);
            return LibCustody.pushReserved(source, asset, receiver, amount, amount);
        }
        if (_get(ROUTE, 0) == 0 || _get(CALLER, 0) != uint160(msg.sender) || _get(RECEIVER, 0) != uint160(receiver)) {
            revert IStaticsAggregatedBatchRewards.InvalidAggregatedClaimContext();
        }
        uint256 records = _get(RECORDS, 0);
        if (records >= MAX_ENTRIES) revert IStaticsAggregatedBatchRewards.InvalidAggregatedClaimContext();
        _set(6, records, amount);
        _set(RECORDS, 0, records + 1);
        if (amount != 0) {
            uint256 total = LibCustody.accountReserved(ACCOUNT, asset);
            if (total == 0) {
                uint256 count = _get(TOKENS, 0);
                if (count >= MAX_ENTRIES) revert IStaticsAggregatedBatchRewards.InvalidAggregatedClaimContext();
                _set(7, count, uint160(asset));
                _set(TOKENS, 0, count + 1);
            }
            LibCustody.stageRewardReservation(source, asset, amount);
        }
        return (amount, amount);
    }

    /// @dev Caller must hold the shared custody guard throughout final token callbacks.
    function flush() internal {
        if (_get(ACTIVE, 0) == 0 || _get(ROUTE, 0) != 0 || _get(CALLER, 0) != uint160(msg.sender)) {
            revert IStaticsAggregatedBatchRewards.InvalidAggregatedClaimContext();
        }
        address receiver = address(uint160(_get(RECEIVER, 0)));
        uint256 count = _get(TOKENS, 0);
        for (uint256 i; i < count; ++i) {
            address asset = address(uint160(_get(7, i)));
            uint256 total = LibCustody.accountReserved(ACCOUNT, asset);
            LibCustody.pushReservedExact(ACCOUNT, asset, receiver, total);
            emit IStaticsAggregatedBatchRewards.AggregatedRewardPaid(receiver, asset, total);
            _set(7, i, 0);
        }
        _set(TOKENS, 0, 0);
        _set(RECEIVER, 0, 0);
        _set(CALLER, 0, 0);
        _set(ACTIVE, 0, 0);
    }
}
