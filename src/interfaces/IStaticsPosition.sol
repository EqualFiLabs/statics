// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IModularPositionNFT} from "./IModularPositionNFT.sol";

interface IStaticsPosition is IModularPositionNFT {
    function createPosition(address receiver) external payable returns (uint256 positionId);

    function closePosition(uint256 positionId) external;

    function nextPositionId() external view returns (uint256);

    function activeLegCount(uint256 positionId) external view returns (uint256);

    function positionInitializing(uint256 positionId) external view returns (bool);
}

/// @dev Self-call surface used by protocol facets that create a position and
/// attach its first module leg atomically.
interface IStaticsPositionModule {
    function createPositionForModule(address receiver, bytes32 moduleType, bytes32 localPositionId)
        external
        payable
        returns (uint256 positionId);
}

interface IStaticsPositionFees {
    function setPositionCreationFee(uint256 amount) external;

    function positionCreationFee() external view returns (uint256);
}
