// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {WETH} from "solmate/src/tokens/WETH.sol";
import {NativeCampaignRevenue} from "../../src/bootstrap/NativeCampaignRevenue.sol";
import {MeasuredCampaignRevenue} from "../../src/bootstrap/MeasuredCampaignRevenue.sol";
import {BasketBootstrapCampaign} from "../../src/bootstrap/BasketBootstrapCampaign.sol";
import {CampaignTestBase} from "./BasketBootstrapCampaign.t.sol";
import {IStaticsProtocolPools} from "../../src/interfaces/IStaticsProtocolPools.sol";

contract UnderMintingRevenueWeth is WETH {
    function deposit() public payable override {
        _mint(msg.sender, msg.value - 1);
    }
}

contract ReentrantRevenueWeth is WETH {
    bool public blocked;

    function deposit() public payable override {
        (bool entered,) = msg.sender.call(abi.encodeCall(NativeCampaignRevenue.deliverNative, ()));
        require(!entered, "nested delivery must revert");
        blocked = true;
        super.deposit();
    }
}

contract RejectingRevenueWeth is WETH {
    error DeliveryBlocked();

    function transferFrom(address, address, uint256) public pure override returns (bool) {
        revert DeliveryBlocked();
    }
}

contract NativeCampaignRevenueTest is CampaignTestBase {
    WETH private wrapped;
    NativeCampaignRevenue private adapter;
    BasketBootstrapCampaign private destination;

    function setUp() public override {
        super.setUp();
        wrapped = new WETH();
        (adapter, destination) = _bound(wrapped, keccak256("native revenue"));
    }

    function _bound(WETH token, bytes32 salt)
        private
        returns (NativeCampaignRevenue delivery, BasketBootstrapCampaign campaign)
    {
        delivery = new NativeCampaignRevenue(
            vm.addr(CREATOR_KEY), address(token), address(token).codehash, campaignFactory
        );
        BasketBootstrapCampaign.Terms memory terms = _terms(false);
        terms.basket.assets[0] = address(token);
        terms.adapters = new address[](1);
        terms.adapters[0] = address(delivery);
        campaign = _campaign(terms, salt);
        vm.prank(vm.addr(CREATOR_KEY));
        delivery.bindCampaign(campaign, 0);
    }

    function testNativeReceiptFundsCampaignWithoutSpendingExistingBalances() public {
        wrapped.deposit{value: 7 ether}();
        wrapped.transfer(address(adapter), 7 ether);
        // Force-sent native balance cannot arrive through a regular receive hook.
        vm.deal(address(adapter), 5 ether);
        uint256 senderBefore = alice.balance;
        vm.prank(alice);
        adapter.deliverNative{value: 3 ether}();
        (,, uint256 held,) = destination.inventory(0);
        assertEq(held, 3 ether);
        assertEq(wrapped.balanceOf(address(adapter)), 7 ether);
        assertEq(address(adapter).balance, 5 ether);
        assertEq(senderBefore - alice.balance, 3 ether);
        assertEq(wrapped.allowance(address(adapter), address(destination)), 0);
        assertEq(adapter.totalDelivered(), 3 ether);
    }

    function testExpiredNativeRevenueRoutesOnlyToFixedBeneficiary() public {
        vm.warp(destination.deadline());
        vm.prank(alice);
        adapter.deliverNative{value: 3 ether}();
        assertEq(wrapped.balanceOf(bob), 3 ether);
        assertEq(adapter.recipient(), bob);
        (,, uint256 held,) = destination.inventory(0);
        assertEq(held, 0);
    }

    function testSuccessfulLaunchKeepsActualPolAndRoutesLaterNativeRevenue() public {
        (, uint256 target,,) = destination.inventory(0);
        adapter.deliverNative{value: target}();
        (, uint256 otherTarget,,) = destination.inventory(1);
        assetB.mint(alice, otherTarget);
        vm.startPrank(alice);
        assetB.approve(address(destination), otherTarget);
        destination.fund(1, otherTarget);
        vm.stopPrank();
        destination.fundNative{value: destination.nativeRequired()}();
        assertTrue(destination.ready());
        (uint256 id,) = destination.finalize();
        assertEq(baskets.basket(id).creator, vm.addr(CREATOR_KEY));
        for (uint256 i; i < 2; ++i) {
            (address asset,,,) = destination.inventory(i);
            assertEq(
                IStaticsProtocolPools(address(diamond))
                .protocolPool(basketLiquidity.canonicalPool(id, asset).poolId)
                .activePolPositions,
                1
            );
        }
        vm.prank(alice);
        adapter.deliverNative{value: 2 ether}();
        assertEq(wrapped.balanceOf(bob), 2 ether);
        assertEq(adapter.totalDelivered(), target + 2 ether);
        assertEq(wrapped.balanceOf(address(adapter)), 0);
    }

    function testExistingErc20DeliveryStillWorksForNativeAdapter() public {
        vm.startPrank(alice);
        wrapped.deposit{value: 2 ether}();
        wrapped.approve(address(adapter), 2 ether);
        adapter.deliverRealized(2 ether);
        vm.stopPrank();
        (,, uint256 held,) = destination.inventory(0);
        assertEq(held, 2 ether);
        assertEq(adapter.totalDelivered(), 2 ether);
    }

    function testInvalidRuntimeAndZeroValueAreRejected() public {
        vm.expectRevert(MeasuredCampaignRevenue.InvalidRevenueIntegration.selector);
        new NativeCampaignRevenue(vm.addr(CREATOR_KEY), address(wrapped), bytes32(0), campaignFactory);
        vm.expectRevert(MeasuredCampaignRevenue.InvalidRevenueIntegration.selector);
        new NativeCampaignRevenue(vm.addr(CREATOR_KEY), address(wrapped), bytes32(uint256(1)), campaignFactory);
        vm.expectRevert(MeasuredCampaignRevenue.InvalidRevenueIntegration.selector);
        adapter.deliverNative();
    }

    function testWrapperRuntimeDriftAndUnboundDeliveryAreRejected() public {
        NativeCampaignRevenue unbound = new NativeCampaignRevenue(
            vm.addr(CREATOR_KEY), address(wrapped), address(wrapped).codehash, campaignFactory
        );
        vm.expectRevert(MeasuredCampaignRevenue.InvalidRevenueIntegration.selector);
        unbound.deliverNative{value: 1 ether}();
        // Narrow corruption check: immutable production wrappers cannot normally change runtime.
        vm.etch(address(wrapped), hex"00");
        vm.expectRevert(MeasuredCampaignRevenue.InvalidRevenueIntegration.selector);
        adapter.deliverNative{value: 1 ether}();
    }

    function testUnderMintingWrapperRollsBackTheCompleteReceipt() public {
        UnderMintingRevenueWeth bad = new UnderMintingRevenueWeth();
        (NativeCampaignRevenue delivery, BasketBootstrapCampaign campaign) = _bound(bad, keccak256("under mint"));
        uint256 beforeNative = address(this).balance;
        vm.expectRevert(MeasuredCampaignRevenue.InexactRevenue.selector);
        delivery.deliverNative{value: 1 ether}();
        assertEq(address(this).balance, beforeNative);
        assertEq(address(bad).balance, 0);
        assertEq(bad.balanceOf(address(delivery)), 0);
        assertEq(delivery.totalDelivered(), 0);
        (,, uint256 held,) = campaign.inventory(0);
        assertEq(held, 0);
    }

    function testWrapperCallbackCannotReenterRevenueDelivery() public {
        ReentrantRevenueWeth token = new ReentrantRevenueWeth();
        (NativeCampaignRevenue delivery, BasketBootstrapCampaign campaign) = _bound(token, keccak256("reentrant wrap"));
        delivery.deliverNative{value: 1 ether}();
        assertTrue(token.blocked());
        (,, uint256 held,) = campaign.inventory(0);
        assertEq(held, 1 ether);
        assertEq(delivery.totalDelivered(), 1 ether);
    }

    function testForwardingFailureRollsBackWrappingAndApprovals() public {
        RejectingRevenueWeth token = new RejectingRevenueWeth();
        (NativeCampaignRevenue delivery, BasketBootstrapCampaign campaign) = _bound(token, keccak256("failed delivery"));
        uint256 beforeNative = address(this).balance;
        vm.expectRevert(RejectingRevenueWeth.DeliveryBlocked.selector);
        delivery.deliverNative{value: 1 ether}();
        assertEq(address(this).balance, beforeNative);
        assertEq(address(token).balance, 0);
        assertEq(token.balanceOf(address(delivery)), 0);
        assertEq(token.allowance(address(delivery), address(campaign)), 0);
        assertEq(delivery.totalDelivered(), 0);
        (,, uint256 held,) = campaign.inventory(0);
        assertEq(held, 0);
    }

    function testUnsolicitedNativeSendDoesNotBecomeFunding() public {
        (bool sent,) = address(adapter).call{value: 1 ether}("");
        assertFalse(sent);
        assertEq(adapter.totalDelivered(), 0);
        (,, uint256 held,) = destination.inventory(0);
        assertEq(held, 0);
    }

    function testFuzzExpiredNativeReceiptsAreExact(uint256 amount, uint256 existing) public {
        amount = bound(amount, 1, 50 ether);
        existing = bound(existing, 0, 50 ether);
        vm.deal(address(this), amount + existing);
        wrapped.deposit{value: existing}();
        wrapped.transfer(address(adapter), existing);
        vm.warp(destination.deadline());
        adapter.deliverNative{value: amount}();
        assertEq(wrapped.balanceOf(bob), amount);
        assertEq(wrapped.balanceOf(address(adapter)), existing);
        assertEq(adapter.totalDelivered(), amount);
    }
}
