// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {PonsRevenueAdapter} from "../../src/bootstrap/PonsRevenueAdapter.sol";
import {MoshTeamRevenueAdapter} from "../../src/bootstrap/MoshTeamRevenueAdapter.sol";
import {IMoshSwarm} from "../../src/interfaces/IMoshSwarm.sol";

contract VenueRevenueSdkParityTest is Test {
    function testSharedVenueRevenueCalldataMatchesSolidity() public view {
        string memory fixture = vm.readFile("test/fixtures/venue-revenue.json");
        assertEq(abi.encodeCall(PonsRevenueAdapter.collect, (42)), vm.parseJsonBytes(fixture, ".ponsCollect"));
        assertEq(abi.encodeCall(PonsRevenueAdapter.handoff, ()), vm.parseJsonBytes(fixture, ".ponsHandoff"));
        assertEq(
            abi.encodeCall(MoshTeamRevenueAdapter.bindSource, (IMoshSwarm(0x1111111111111111111111111111111111111111))),
            vm.parseJsonBytes(fixture, ".teamBind")
        );
        assertEq(
            abi.encodeCall(MoshTeamRevenueAdapter.acceptTeamHandoff, (42, 7)),
            vm.parseJsonBytes(fixture, ".teamHandoff")
        );
        assertEq(abi.encodeCall(MoshTeamRevenueAdapter.sync, ()), vm.parseJsonBytes(fixture, ".teamSync"));
        assertEq(abi.encodeCall(MoshTeamRevenueAdapter.flushTeamRevenue, ()), vm.parseJsonBytes(fixture, ".teamFlush"));
    }
}
