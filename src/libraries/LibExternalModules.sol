// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IStaticsExternalModules} from "../interfaces/IStaticsExternalModules.sol";

library LibExternalModules {
    bytes32 internal constant STORAGE_POSITION = keccak256("statics.storage.external.modules.v1");
    uint256 internal constant CAPACITY = 64;
    uint256 internal constant PAGE_SIZE = 100;

    struct ModuleStorage {
        mapping(address => mapping(bytes32 => bool)) enabled;
        mapping(uint256 => IStaticsExternalModules.ExternalLeg[]) legs;
        mapping(uint256 => mapping(bytes32 => uint256)) indexPlusOne;
    }
    error ModuleNotEnabled(address authority, bytes32 moduleType);
    error PositionInitializing(uint256 positionId);
    error ExternalLegCapacityReached(uint256 positionId);
    error InvalidPage();

    function moduleStorage() internal pure returns (ModuleStorage storage ms) {
        bytes32 slot = STORAGE_POSITION;
        assembly ("memory-safe") { ms.slot := slot }
    }

    function pageEnd(uint256 cursor, uint256 limit, uint256 length) internal pure returns (uint256) {
        if (limit == 0 || limit > PAGE_SIZE || cursor > length) revert InvalidPage();
        return cursor + (limit < length - cursor ? limit : length - cursor);
    }
}
