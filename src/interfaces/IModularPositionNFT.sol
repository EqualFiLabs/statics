// SPDX-License-Identifier: CC0-1.0
pragma solidity 0.8.33;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @notice Minimal structural reporting surface for an ERC-721 PositionNFT.
interface IModularPositionNFT is IERC165 {
    struct PositionState {
        bool exists;
        uint256 stateNonce;
        uint256 activeLegCount;
        uint256 unresolvedObligationCount;
    }

    event PositionLegAttached(
        uint256 indexed tokenId,
        bytes32 indexed legKey,
        address indexed moduleAuthority,
        bytes32 moduleType,
        bytes32 localPositionId,
        uint256 stateNonce
    );

    event PositionLegDetached(uint256 indexed tokenId, bytes32 indexed legKey, uint256 stateNonce);

    event PositionStateChanged(
        uint256 indexed tokenId, uint256 stateNonce, uint256 activeLegCount, uint256 unresolvedObligationCount
    );

    function positionState(uint256 tokenId) external view returns (PositionState memory state);

    function isLegActive(uint256 tokenId, bytes32 legKey) external view returns (bool);

    function isPositionClosable(uint256 tokenId) external view returns (bool);
}
