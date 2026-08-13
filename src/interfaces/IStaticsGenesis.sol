// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

interface IStaticsGenesis is IERC721 {
    function COLLECTION_SIZE() external view returns (uint256);
    function protocol() external view returns (address);
    function bindProtocol(address protocol_) external;
    function refreshMetadata(uint256 genesisId) external;
}

interface IStaticsGenesisProtocol {
    function onGenesisTransfer(uint256 genesisId, address previousOwner, address newOwner) external;
    function genesisTier(uint256 genesisId) external view returns (uint8);
}

interface IStaticsGenesisBinding {
    function genesisCollection() external view returns (address);
}
