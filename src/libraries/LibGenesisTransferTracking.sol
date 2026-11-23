// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

library LibGenesisTransferTracking {
    // erc7201:statics.storage.genesis.transfer-tracking.v1
    bytes32 internal constant STORAGE_SLOT = 0xe8bb79b635f87f2421bb7bc1bcf8c0f959895dbdbe441bf55429ba2b69d32500;

    struct TransferState {
        uint64 nonce;
        uint64 lastTransferAt;
    }

    /// @custom:storage-location erc7201:statics.storage.genesis.transfer-tracking.v1
    struct Layout {
        address router;
        uint64 startedAt;
        mapping(uint256 genesisId => TransferState state) transfers;
    }

    function layout() internal pure returns (Layout storage data) {
        bytes32 slot = STORAGE_SLOT;
        assembly ("memory-safe") {
            data.slot := slot
        }
    }
}
