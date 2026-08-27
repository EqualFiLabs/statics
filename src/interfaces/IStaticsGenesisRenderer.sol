// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

/// @notice Deterministic on-chain metadata renderer for the Genesis collection.
interface IStaticsGenesisRenderer {
    /// @notice Returns a base64-encoded JSON data URI containing SVG artwork and traits.
    /// @dev The trait seed includes the current chain ID, collection address, and token ID.
    ///      Registry lookup failures currently result in activation tier zero.
    /// @param collection Genesis collection address used in seed derivation.
    /// @param tokenId Genesis token ID.
    /// @param activationRegistry Registry queried for the activation tier; zero disables lookup.
    /// @param externalURLBase URL prefix to which `tokenId` is appended.
    /// @return uri Base64-encoded JSON data URI.
    function renderTokenURI(
        address collection,
        uint256 tokenId,
        address activationRegistry,
        string calldata externalURLBase
    ) external view returns (string memory uri);
}
