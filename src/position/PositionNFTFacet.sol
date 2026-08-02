// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {ERC721Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";

import {IStaticsPosition, IStaticsPositionModule} from "../interfaces/IStaticsPosition.sol";
import {LibPosition} from "./LibPosition.sol";

contract PositionNFTFacet is ERC721Upgradeable, IStaticsPosition, IStaticsPositionModule {
    event PositionCreated(uint256 indexed positionId, address indexed owner);
    event PositionClosed(uint256 indexed positionId);

    error OnlyDiamondSelf(address caller);
    error PositionInitializing(uint256 positionId);
    error PositionHasActiveLegs(uint256 positionId, uint256 activeLegCount);

    function createPosition(address receiver) external returns (uint256 positionId) {
        positionId = _createPosition(receiver, bytes32(0));
    }

    function createPositionForModule(address receiver, bytes32 initialLegKey) external returns (uint256 positionId) {
        if (msg.sender != address(this)) revert OnlyDiamondSelf(msg.sender);
        if (initialLegKey == bytes32(0)) revert LibPosition.ZeroLegKey();
        positionId = _createPosition(receiver, initialLegKey);
    }

    function closePosition(uint256 positionId) external {
        LibPosition.enforceAuthorized(positionId, msg.sender);
        LibPosition.PositionStorage storage ps = LibPosition.positionStorage();
        if (ps.positionInitializing[positionId]) revert PositionInitializing(positionId);
        uint256 count = ps.activeLegCount[positionId];
        if (count != 0) revert PositionHasActiveLegs(positionId, count);
        _burn(positionId);
        emit PositionClosed(positionId);
    }

    function nextPositionId() external view returns (uint256) {
        return LibPosition.positionStorage().nextPositionId;
    }

    function activeLegCount(uint256 positionId) external view returns (uint256) {
        return LibPosition.positionStorage().activeLegCount[positionId];
    }

    function positionInitializing(uint256 positionId) external view returns (bool) {
        return LibPosition.positionStorage().positionInitializing[positionId];
    }

    function isPositionLegActive(uint256 positionId, bytes32 legKey_) external view returns (bool) {
        return LibPosition.positionStorage().activeLeg[positionId][legKey_];
    }

    function positionKey(uint256 positionId) external view returns (bytes32) {
        ownerOf(positionId);
        return keccak256(abi.encode(address(this), positionId));
    }

    function _createPosition(address receiver, bytes32 initialLegKey) private returns (uint256 positionId) {
        positionId = LibPosition.allocatePositionId();
        _safeMint(receiver, positionId);
        if (initialLegKey != bytes32(0)) LibPosition.activateLeg(positionId, initialLegKey);
        LibPosition.finishInitialization(positionId);
        emit PositionCreated(positionId, receiver);
    }
}
