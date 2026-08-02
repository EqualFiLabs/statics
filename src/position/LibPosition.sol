// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

library LibPosition {
    bytes32 internal constant STORAGE_POSITION = keccak256("statics.position.storage.v1");
    bytes32 internal constant DOLLAR_MODULE = keccak256("statics.position.module.dollar");
    bytes32 internal constant BASKET_MODULE = keccak256("statics.position.module.basket");

    struct PositionStorage {
        uint256 nextPositionId;
        bool initialized;
        mapping(uint256 positionId => uint256 count) activeLegCount;
        mapping(uint256 positionId => bool initializing) positionInitializing;
        mapping(uint256 positionId => mapping(bytes32 legKey => bool active)) activeLeg;
    }

    event PositionLegActivated(uint256 indexed positionId, bytes32 indexed legKey);
    event PositionLegDeactivated(uint256 indexed positionId, bytes32 indexed legKey);

    error AlreadyInitialized();
    error NotInitialized();
    error NotPositionOwnerOrApproved(uint256 positionId, address caller);
    error ZeroLegKey();
    error PositionLegAlreadyActive(uint256 positionId, bytes32 legKey);
    error PositionLegNotActive(uint256 positionId, bytes32 legKey);

    function positionStorage() internal pure returns (PositionStorage storage ps) {
        bytes32 slot = STORAGE_POSITION;
        assembly {
            ps.slot := slot
        }
    }

    function initialize() internal {
        PositionStorage storage ps = positionStorage();
        if (ps.initialized) revert AlreadyInitialized();
        ps.nextPositionId = 1;
        ps.initialized = true;
    }

    function allocatePositionId() internal returns (uint256 positionId) {
        PositionStorage storage ps = positionStorage();
        if (!ps.initialized) revert NotInitialized();
        positionId = ps.nextPositionId++;
        ps.positionInitializing[positionId] = true;
    }

    function finishInitialization(uint256 positionId) internal {
        positionStorage().positionInitializing[positionId] = false;
    }

    function legKey(bytes32 moduleId, bytes32 localId) internal pure returns (bytes32) {
        return keccak256(abi.encode(moduleId, localId));
    }

    function dollarLegKey(uint256 seriesId) internal pure returns (bytes32) {
        return legKey(DOLLAR_MODULE, bytes32(seriesId));
    }

    function basketLegKey(uint256 basketId) internal pure returns (bytes32) {
        return legKey(BASKET_MODULE, bytes32(basketId));
    }

    function activateLeg(uint256 positionId, bytes32 key) internal {
        if (key == bytes32(0)) revert ZeroLegKey();
        IERC721(address(this)).ownerOf(positionId);
        PositionStorage storage ps = positionStorage();
        if (ps.activeLeg[positionId][key]) revert PositionLegAlreadyActive(positionId, key);
        ps.activeLeg[positionId][key] = true;
        ++ps.activeLegCount[positionId];
        emit PositionLegActivated(positionId, key);
    }

    function deactivateLeg(uint256 positionId, bytes32 key) internal {
        PositionStorage storage ps = positionStorage();
        if (!ps.activeLeg[positionId][key]) revert PositionLegNotActive(positionId, key);
        delete ps.activeLeg[positionId][key];
        --ps.activeLegCount[positionId];
        emit PositionLegDeactivated(positionId, key);
    }

    function isAuthorized(uint256 positionId, address actor) internal view returns (bool) {
        IERC721 nft = IERC721(address(this));
        address owner = nft.ownerOf(positionId);
        return actor != address(0)
            && (actor == owner || nft.getApproved(positionId) == actor || nft.isApprovedForAll(owner, actor));
    }

    function enforceAuthorized(uint256 positionId, address actor) internal view {
        if (!isAuthorized(positionId, actor)) revert NotPositionOwnerOrApproved(positionId, actor);
    }
}
