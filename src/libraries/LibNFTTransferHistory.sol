// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IStaticsExternalModules} from "../interfaces/IStaticsExternalModules.sol";
import {LibGenesisIntegration} from "./LibGenesisIntegration.sol";

library LibNFTTransferHistory {
    bytes32 internal constant STORAGE_POSITION = keccak256("statics.storage.nft.transfer.history.v1");

    struct HistoryStorage {
        bool initialized;
        uint256 head;
        mapping(address => IStaticsExternalModules.HistoryCoverage) coverage;
        mapping(address => mapping(uint256 => IStaticsExternalModules.TransferState)) states;
        mapping(uint256 => IStaticsExternalModules.TransferChange) changes;
    }
    error HistoryAlreadyInitialized();

    function historyStorage() internal pure returns (HistoryStorage storage hs) {
        bytes32 slot = STORAGE_POSITION;
        assembly ("memory-safe") { hs.slot := slot }
    }

    function initialize() internal {
        HistoryStorage storage hs = historyStorage();
        if (hs.initialized) revert HistoryAlreadyInitialized();
        hs.initialized = true;
        _start(address(this));
        startOperatorCoverage();
    }

    function startOperatorCoverage() internal {
        HistoryStorage storage hs = historyStorage();
        if (hs.initialized && LibGenesisIntegration.recoveryReady()) {
            _start(LibGenesisIntegration.genesisStorage().genesis);
        }
    }

    function _start(address collection) private {
        HistoryStorage storage hs = historyStorage();
        if (hs.coverage[collection].ready) return;
        hs.coverage[collection] = IStaticsExternalModules.HistoryCoverage(block.number, hs.head, true);
        emit IStaticsExternalModules.NFTHistoryStarted(collection, block.number, hs.head);
    }

    function record(address collection, uint256 tokenId, address from, address to) internal {
        if (from == address(0) || to == address(0) || from == to) return;
        HistoryStorage storage hs = historyStorage();
        IStaticsExternalModules.TransferState storage state = hs.states[collection][tokenId];
        uint256 sequence = ++hs.head;
        ++state.nonce;
        state.transferredAt = uint64(block.timestamp);
        state.lastSequence = sequence;
        hs.changes[sequence] =
            IStaticsExternalModules.TransferChange(collection, state.nonce, state.transferredAt, tokenId);
        emit IStaticsExternalModules.NFTTransferRecorded(collection, tokenId, sequence, state.nonce, block.timestamp);
    }
}
