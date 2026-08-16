// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

interface IStaticsGenesisRenderer {
    function renderTokenURI(address collection, uint256 tokenId, address protocol, string calldata externalURLBase)
        external
        view
        returns (string memory uri);
}
