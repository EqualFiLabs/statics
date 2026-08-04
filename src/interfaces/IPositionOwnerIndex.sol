// SPDX-License-Identifier: CC0-1.0
pragma solidity 0.8.33;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @notice Optional owner-index extension for ERC-721 Position NFTs.
interface IPositionOwnerIndex is IERC165 {
    event PositionOwnerIndexSynced(uint256 indexed positionId, address indexed owner);

    function positionCount(address owner) external view returns (uint256);

    function positionsOfOwner(address owner, uint256 cursor, uint256 limit)
        external
        view
        returns (uint256[] memory positionIds, uint256 nextCursor);

    function syncPositionOwnerIndex(uint256 positionId) external;
}
