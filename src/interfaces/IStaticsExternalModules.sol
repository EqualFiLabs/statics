// SPDX-License-Identifier: CC0-1.0
pragma solidity 0.8.33;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @notice Generic external account lifecycle and bounded discovery. No product callbacks.
interface IStaticsExternalModules is IERC165 {
    struct ExternalLeg {
        address authority;
        bytes32 moduleType;
        bytes32 localId;
        bytes32 legKey;
    }

    event ExternalModuleSet(address indexed authority, bytes32 indexed moduleType, bool enabled);

    function setExternalModule(address authority, bytes32 moduleType, bool enabled) external;
    function externalModuleEnabled(address authority, bytes32 moduleType) external view returns (bool);
    function attachExternalAccountLeg(uint256 positionId, bytes32 moduleType, bytes32 localId)
        external
        returns (bytes32);
    function detachExternalAccountLeg(uint256 positionId, bytes32 moduleType, bytes32 localId) external;
    function externalLegCount(uint256 positionId) external view returns (uint256);
    function externalLegCapacity() external pure returns (uint256);
    /// @dev Swap-and-pop ordering. Use positionState.stateNonce to detect changes between pages.
    function externalLegs(uint256 positionId, uint256 cursor, uint256 limit)
        external
        view
        returns (ExternalLeg[] memory legs, uint256 nextCursor);
}
