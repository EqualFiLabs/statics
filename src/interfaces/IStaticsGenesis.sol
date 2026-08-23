// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

interface IStaticsGenesis is IERC721 {
    event ProtocolBound(address indexed protocol);

    function COLLECTION_SIZE() external view returns (uint256);
    function mintedSupply() external view returns (uint256);
    function vault() external view returns (address);
    function activationRegistry() external view returns (address);
    function protocol() external view returns (address);
    function launchFinalized() external view returns (bool);
    function finalizeLaunch() external;
    function bindProtocol(address protocol_) external;
    function refreshMetadata(uint256 genesisId) external;
    function refreshLockStatus(uint256 genesisId) external;
    function recoverToVault(uint256 genesisId, address expectedOwner) external;
}

interface IStaticsGenesisProtocol {
    function genesisCollection() external view returns (address);
    function linkedPosition(uint256 genesisId) external view returns (uint256 positionId);
    function genesisRecoveryCallback() external pure returns (bytes4 acknowledgement);
    function onGenesisRecovery(uint256 genesisId, address previousOwner) external returns (bytes4 acknowledgement);
}
