// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IStaticsExternalModules} from "../interfaces/IStaticsExternalModules.sol";
import {LibDiamond} from "../libraries/LibDiamond.sol";
import {LibExternalModules} from "../libraries/LibExternalModules.sol";
import {LibPosition} from "../position/LibPosition.sol";

/// @notice Modules assert their own financial lifecycle; Statics only tracks closure protection.
contract ExternalModuleFacet {
    function setExternalModule(address authority, bytes32 moduleType, bool enabled) external {
        LibDiamond.enforceIsContractOwner();
        LibExternalModules.moduleStorage().enabled[authority][moduleType] = enabled;
        emit IStaticsExternalModules.ExternalModuleSet(authority, moduleType, enabled);
    }

    function externalModuleEnabled(address authority, bytes32 moduleType) external view returns (bool) {
        return LibExternalModules.moduleStorage().enabled[authority][moduleType];
    }

    function attachExternalAccountLeg(uint256 positionId, bytes32 moduleType, bytes32 localId)
        external
        returns (bytes32 key)
    {
        LibExternalModules.ModuleStorage storage ms = LibExternalModules.moduleStorage();
        if (!ms.enabled[msg.sender][moduleType]) revert LibExternalModules.ModuleNotEnabled(msg.sender, moduleType);
        if (LibPosition.positionStorage().state[positionId].initializing) {
            revert LibExternalModules.PositionInitializing(positionId);
        }
        if (ms.legs[positionId].length == LibExternalModules.CAPACITY) {
            revert LibExternalModules.ExternalLegCapacityReached(positionId);
        }
        key = LibPosition.activateLeg(positionId, msg.sender, moduleType, localId);
        ms.legs[positionId].push(IStaticsExternalModules.ExternalLeg(msg.sender, moduleType, localId, key));
        ms.indexPlusOne[positionId][key] = ms.legs[positionId].length;
    }

    function detachExternalAccountLeg(uint256 positionId, bytes32 moduleType, bytes32 localId) external {
        LibExternalModules.ModuleStorage storage ms = LibExternalModules.moduleStorage();
        bytes32 key = LibPosition.legKey(msg.sender, moduleType, localId);
        uint256 indexPlusOne = ms.indexPlusOne[positionId][key];
        if (indexPlusOne == 0) revert LibPosition.PositionLegNotActive(positionId, key);
        uint256 index = indexPlusOne - 1;
        uint256 last = ms.legs[positionId].length - 1;
        if (index != last) {
            IStaticsExternalModules.ExternalLeg memory moved = ms.legs[positionId][last];
            ms.legs[positionId][index] = moved;
            ms.indexPlusOne[positionId][moved.legKey] = indexPlusOne;
        }
        ms.legs[positionId].pop();
        delete ms.indexPlusOne[positionId][key];
        LibPosition.deactivateLeg(positionId, key);
    }

    function externalLegCount(uint256 positionId) external view returns (uint256) {
        return LibExternalModules.moduleStorage().legs[positionId].length;
    }

    function externalLegCapacity() external pure returns (uint256) {
        return LibExternalModules.CAPACITY;
    }

    function externalLegs(uint256 positionId, uint256 cursor, uint256 limit)
        external
        view
        returns (IStaticsExternalModules.ExternalLeg[] memory legs, uint256 nextCursor)
    {
        IStaticsExternalModules.ExternalLeg[] storage stored = LibExternalModules.moduleStorage().legs[positionId];
        nextCursor = LibExternalModules.pageEnd(cursor, limit, stored.length);
        legs = new IStaticsExternalModules.ExternalLeg[](nextCursor - cursor);
        for (uint256 i; i < legs.length; ++i) {
            legs[i] = stored[cursor + i];
        }
    }
}
