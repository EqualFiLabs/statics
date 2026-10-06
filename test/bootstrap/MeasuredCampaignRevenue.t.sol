// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {MeasuredCampaignRevenue} from "../../src/bootstrap/MeasuredCampaignRevenue.sol";
import {BasketBootstrapCampaign} from "../../src/bootstrap/BasketBootstrapCampaign.sol";
import {CampaignTestBase} from "./BasketBootstrapCampaign.t.sol";

contract MeasuredCampaignRevenueTest is CampaignTestBase {
    MeasuredCampaignRevenue private adapter;
    BasketBootstrapCampaign private destination;
    function setUp() public override {
        super.setUp();
        adapter = new MeasuredCampaignRevenue(vm.addr(CREATOR_KEY), address(assetA), campaignFactory);
        BasketBootstrapCampaign.Terms memory terms = _terms(false);
        terms.adapters = new address[](1); terms.adapters[0] = address(adapter);
        destination = _campaign(terms, keccak256("measured"));
        vm.prank(vm.addr(CREATOR_KEY));
        adapter.bindCampaign(destination,0);
        assetA.mint(alice, 100 ether);
        vm.prank(alice); assetA.approve(address(adapter),100 ether);
    }
    function testMeasuredReceiptFundsOnlyLiveCampaignAndClearsApproval() public {
        assetA.mint(address(adapter),7 ether);
        vm.prank(alice); adapter.deliverRealized(3 ether);
        (,,uint256 held,) = destination.inventory(0);
        assertEq(held,3 ether);
        assertEq(assetA.balanceOf(address(adapter)),7 ether);
        assertEq(assetA.allowance(address(adapter),address(destination)),0);
        assertEq(adapter.totalDelivered(),3 ether);
        assertFalse(destination.ready());
    }
    function testExpiredRevenueRoutesToFixedBeneficiary() public {
        vm.warp(destination.deadline());
        vm.prank(alice); adapter.deliverRealized(3 ether);
        assertEq(adapter.recipient(),bob);
        assertEq(assetA.balanceOf(bob),3 ether);
        (,,uint256 held,) = destination.inventory(0);
        assertEq(held,0);
    }
    function testSuccessfulRevenueRoutesToFixedBeneficiary() public {
        _fundLaunch(destination,true);
        destination.finalize();
        vm.prank(alice); adapter.deliverRealized(3 ether);
        assertEq(assetA.balanceOf(bob),3 ether);
        assertEq(adapter.recipient(),bob);
    }
    function testBindingCannotBeRedirectedOrReplaced() public {
        vm.expectRevert(MeasuredCampaignRevenue.InvalidRevenueIntegration.selector);
        adapter.bindCampaign(destination,0);
        vm.prank(vm.addr(CREATOR_KEY));
        vm.expectRevert(MeasuredCampaignRevenue.InvalidRevenueIntegration.selector);
        adapter.bindCampaign(destination,0);
        MeasuredCampaignRevenue other = new MeasuredCampaignRevenue(vm.addr(CREATOR_KEY),address(assetB),campaignFactory);
        vm.prank(vm.addr(CREATOR_KEY));
        vm.expectRevert(MeasuredCampaignRevenue.InvalidRevenueIntegration.selector);
        other.bindCampaign(destination,0);
    }
    function testAdapterCannotBecomeItsOwnTerminalBeneficiary() public {
        MeasuredCampaignRevenue other = new MeasuredCampaignRevenue(vm.addr(CREATOR_KEY),address(assetA),campaignFactory);
        BasketBootstrapCampaign.Terms memory terms = _terms(false);
        terms.beneficiary = address(other);
        terms.adapters = new address[](1); terms.adapters[0] = address(other);
        BasketBootstrapCampaign invalid = _campaign(terms,keccak256("self beneficiary"));
        vm.prank(vm.addr(CREATOR_KEY));
        vm.expectRevert(MeasuredCampaignRevenue.InvalidRevenueIntegration.selector);
        other.bindCampaign(invalid,0);
    }
}
