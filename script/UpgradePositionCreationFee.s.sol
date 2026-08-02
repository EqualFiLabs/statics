// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Script} from "forge-std/Script.sol";

/// @dev Retained so callers of the former ceremony receive an explicit failure
/// instead of constructing an unsafe Diamond cut against a legacy deployment.
struct PositionCreationFeeUpgrade {
    address positionFacet;
    address basketFacet;
    address basketCollateralFacet;
    address globalRewardsFacet;
    address stakingFacet;
    uint256 feeAmount;
}

/// @notice Disabled legacy Position-fee upgrade ceremony.
/// @dev The Modular Position NFT release changes selectors and Position storage
/// semantics. It is supported only through a fresh deployment until a separate,
/// explicitly specified migration is implemented and tested.
contract UpgradePositionCreationFee is Script {
    error FreshDeploymentRequired();

    function runDeployFacets() external pure returns (PositionCreationFeeUpgrade memory) {
        revert FreshDeploymentRequired();
    }

    function runSchedule() external pure returns (bytes32) {
        revert FreshDeploymentRequired();
    }

    function runExecute() external pure {
        revert FreshDeploymentRequired();
    }

    function deployFacets(uint256) public pure returns (PositionCreationFeeUpgrade memory) {
        revert FreshDeploymentRequired();
    }

    function schedule(address, PositionCreationFeeUpgrade memory, bytes32) public pure returns (bytes32) {
        revert FreshDeploymentRequired();
    }

    function execute(address, PositionCreationFeeUpgrade memory, bytes32) public pure {
        revert FreshDeploymentRequired();
    }

    function buildBatch(address, PositionCreationFeeUpgrade memory)
        public
        pure
        returns (address[] memory, uint256[] memory, bytes[] memory)
    {
        revert FreshDeploymentRequired();
    }
}
