// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

/// @notice ERC-721 Genesis collection and protocol-integration interface.
interface IStaticsGenesis is IERC721 {
    event ProtocolBound(address indexed protocol);

    function COLLECTION_SIZE() external view returns (uint256);
    function mintedSupply() external view returns (uint256);
    function vault() external view returns (address);
    function treasuryVesting() external view returns (address);
    function activationRegistry() external view returns (address);
    function protocol() external view returns (address);
    function launchFinalized() external view returns (bool);
    /// @notice Enables ownership-changing transfers after launch bootstrap.
    function finalizeLaunch() external;
    /// @notice Permanently binds the full Statics protocol integration.
    /// @param protocol_ Protocol contract that acknowledges the Genesis collection.
    function bindProtocol(address protocol_) external;
    /// @notice Refreshes metadata for one Genesis after activation changes.
    /// @param genesisId Genesis token ID.
    function refreshMetadata(uint256 genesisId) external;
    /// @notice Refreshes the protocol-linked lock status for one Genesis.
    /// @param genesisId Genesis token ID.
    function refreshLockStatus(uint256 genesisId) external;
    /// @notice Returns a recovered Genesis to the vault after protocol acknowledgement.
    /// @param genesisId Genesis token ID.
    /// @param expectedOwner Owner recorded by the recovery workflow.
    function recoverToVault(uint256 genesisId, address expectedOwner) external;
}

interface IStaticsGenesisProtocol {
    function genesisCollection() external view returns (address);
    function linkedPosition(uint256 genesisId) external view returns (uint256 positionId);
    function genesisRecoveryCallback() external pure returns (bytes4 acknowledgement);
    function onGenesisRecovery(uint256 genesisId, address previousOwner) external returns (bytes4 acknowledgement);
}
