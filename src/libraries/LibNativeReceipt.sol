// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/// @notice Authorizes one native sender only for the duration of an external settlement.
/// @dev Transient state never changes the Diamond's persistent storage layout.
library LibNativeReceipt {
    bytes32 private constant SENDER_SLOT = keccak256("statics.transient.native.receipt.sender.v1");

    function sender() internal view returns (address expected) {
        bytes32 slot = SENDER_SLOT;
        assembly ("memory-safe") { expected := tload(slot) }
    }

    function expect(address expected) internal {
        bytes32 slot = SENDER_SLOT;
        assembly ("memory-safe") { tstore(slot, expected) }
    }

    function clear() internal {
        expect(address(0));
    }
}
