// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";

import {PositionCreationFeeUpgrade, UpgradePositionCreationFee} from "../../script/UpgradePositionCreationFee.s.sol";

contract PositionCreationFeeUpgradeTest is Test {
    UpgradePositionCreationFee internal ceremony;

    function setUp() public {
        ceremony = new UpgradePositionCreationFee();
    }

    function testLegacyFacetDeploymentRequiresFreshProtocolDeployment() public {
        vm.expectRevert(UpgradePositionCreationFee.FreshDeploymentRequired.selector);
        ceremony.deployFacets(0.001 ether);
    }

    function testLegacyTimelockBatchCannotBeConstructed() public {
        PositionCreationFeeUpgrade memory upgrade;
        vm.expectRevert(UpgradePositionCreationFee.FreshDeploymentRequired.selector);
        ceremony.buildBatch(makeAddr("legacy diamond"), upgrade);
    }
}
