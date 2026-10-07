// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {LibCustody} from "./LibCustody.sol";
import {IStaticsAggregatedBatchRewards} from "../interfaces/IStaticsAggregatedBatchRewards.sol";

/// @dev Only the three reward claim paths use this helper. Other custody flows never defer transfers.
library LibRewardPayout {
    bytes32 private constant DOMAIN = keccak256("statics.transient.aggregated.rewards.v1");
    bytes32 internal constant ACCOUNT = LibCustody.AGGREGATED_REWARD_ACCOUNT;
    uint256 private constant CALLER = 1;
    uint256 private constant RECEIVER = 2;
    uint256 private constant RECORDS = 4;
    uint256 private constant TOKENS = 5;

    function _slot(uint256 field, uint256 index) private pure returns (bytes32) {
        // Eight disjoint 256-slot ranges; indices are bounded below 64.
        bytes32 domain = DOMAIN;
        bytes32 slot;
        assembly ("memory-safe") { slot := add(domain, add(shl(8, field), index)) }
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
        if (_get(CALLER, 0) != 0) revert IStaticsAggregatedBatchRewards.InvalidAggregatedClaimContext();
        _set(CALLER, 0, uint160(msg.sender));
        _set(RECEIVER, 0, uint160(receiver));
    }

    function startRoute(bytes4 selector) internal {
        uint256 caller = _get(CALLER, 0);
        if (caller != 0) {
            if (caller >> 160 != 0) revert IStaticsAggregatedBatchRewards.InvalidAggregatedClaimContext();
            _set(CALLER, 0, caller | (uint256(uint32(selector)) << 160));
        }
    }

    function finishRoute(bytes4 selector, uint256[] memory received) internal {
        if (_get(CALLER, 0) == 0) return;
        uint256 count = _get(RECORDS, 0);
        if (count != received.length) revert IStaticsAggregatedBatchRewards.AggregatedClaimRouteIncompatible(selector);
        for (uint256 i; i < count; ++i) {
            if (_get(6, i) != received[i]) {
                revert IStaticsAggregatedBatchRewards.AggregatedClaimRouteIncompatible(selector);
            }
            _set(6, i, 0);
        }
        _set(RECORDS, 0, 0);
        _set(CALLER, 0, uint160(msg.sender));
    }

    function pay(bytes32 source, address asset, address receiver, uint256 amount) internal returns (uint256 received) {
        bytes32 domain = DOMAIN;
        uint256 boundCaller;
        assembly ("memory-safe") { boundCaller := tload(add(domain, 256)) }
        if (boundCaller == 0) {
            if (amount == 0) return 0;
            (, received) = LibCustody.pushReserved(source, asset, receiver, amount, amount);
            return received;
        }
        // Bind acknowledgement to this typed dispatch and its original sender/receiver.
        // Scalar and record slots occupy disjoint ranges within the namespace.
        bytes4 invalidContext = IStaticsAggregatedBatchRewards.InvalidAggregatedClaimContext.selector;
        assembly ("memory-safe") {
            let expected := or(caller(), shl(160, shr(224, calldataload(0))))
            if or(
                iszero(eq(boundCaller, expected)),
                iszero(eq(tload(add(domain, 512)), and(receiver, 0xffffffffffffffffffffffffffffffffffffffff)))
            ) {
                mstore(0, invalidContext)
                revert(0, 4)
            }
            let records := tload(add(domain, 1024))
            if iszero(lt(records, 64)) {
                mstore(0, invalidContext)
                revert(0, 4)
            }
            tstore(add(add(domain, 1536), records), amount)
            tstore(add(domain, 1024), add(records, 1))
        }
        if (amount != 0 && LibCustody.stageRewardReservation(source, asset, amount) == 0) {
            // At most 64 positive entries can reach this branch after batch validation.
            assembly ("memory-safe") {
                let count := tload(add(domain, 1280))
                tstore(add(add(domain, 1792), count), asset)
                tstore(add(domain, 1280), add(count, 1))
            }
        }
        return amount;
    }

    /// @dev Caller must hold the shared custody guard throughout final token callbacks.
    function flush() internal {
        if (_get(CALLER, 0) != uint160(msg.sender)) {
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
    }
}
