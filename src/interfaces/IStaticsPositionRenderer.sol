// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

interface IStaticsPositionRenderer {
    function renderTokenURI(address collection, uint256 tokenId) external view returns (string memory uri);
}
