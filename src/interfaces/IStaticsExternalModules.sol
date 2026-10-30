// SPDX-License-Identifier: CC0-1.0
pragma solidity 0.8.33;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @notice Shared account lifecycle and ordered NFT ownership changes. No module callbacks.
interface IStaticsExternalModules is IERC165 {
    struct ExternalLeg {
        address authority;
        bytes32 moduleType;
        bytes32 localId;
        bytes32 legKey;
    }

    struct TransferState {
        uint64 nonce;
        uint64 transferredAt;
        uint256 lastSequence;
    }

    struct TransferChange {
        address collection;
        uint64 nonce;
        uint64 transferredAt;
        uint256 tokenId;
    }

    struct HistoryCoverage {
        uint256 startBlock;
        uint256 startSequence;
        bool ready;
    }

    event ExternalModuleSet(address indexed authority, bytes32 indexed moduleType, bool enabled);
    event NFTHistoryStarted(address indexed collection, uint256 startBlock, uint256 startSequence);
    event NFTTransferRecorded(
        address indexed collection,
        uint256 indexed tokenId,
        uint256 indexed sequence,
        uint256 nonce,
        uint256 transferredAt
    );

    function setExternalModule(address authority, bytes32 moduleType, bool enabled) external;
    function externalModuleEnabled(address authority, bytes32 moduleType) external view returns (bool);
    function attachExternalAccountLeg(uint256 positionId, bytes32 moduleType, bytes32 localId)
        external
        returns (bytes32);
    function detachExternalAccountLeg(uint256 positionId, bytes32 moduleType, bytes32 localId) external;
    function externalLegCount(uint256 positionId) external view returns (uint256);
    function externalLegCapacity() external pure returns (uint256);
    /// @dev Swap-and-pop ordering. Use positionState.stateNonce to detect changes between pages.
    function externalLegs(uint256 positionId, uint256 cursor, uint256 limit)
        external
        view
        returns (ExternalLeg[] memory legs, uint256 nextCursor);
    function transferHead() external view returns (uint256);
    function transferState(address collection, uint256 tokenId) external view returns (TransferState memory);
    /// @dev Exclusive cursor. Record i has sequence afterSequence + i + 1.
    function transferChanges(uint256 afterSequence, uint256 limit)
        external
        view
        returns (TransferChange[] memory changes, uint256 nextSequence);
    function historyCoverage(address collection) external view returns (HistoryCoverage memory);
}
