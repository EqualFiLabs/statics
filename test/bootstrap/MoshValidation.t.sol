// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {LibMoshValidation} from "../../src/bootstrap/LibMoshValidation.sol";
import {IMoshSwarm, IMoshClaimMarket} from "../../src/interfaces/IMoshSwarm.sol";

/// @dev View-only harness: these tests cover validation branches, not external custody confidence.
contract MoshValidationHarness {
    function validateSource(address source, address token, LibMoshValidation.SourcePins calldata pins) external view {
        LibMoshValidation.validateNativeSource(IMoshSwarm(source), token, pins);
    }

    function validateMarket(address registry, LibMoshValidation.MarketPins calldata pins) external view {
        LibMoshValidation.validateMarket(registry, pins);
    }

    function validateOffer(
        address market,
        uint256 id,
        address source,
        address seller,
        address buyer,
        uint256 amount,
        uint256 fee
    ) external view returns (LibMoshValidation.Offer memory) {
        return LibMoshValidation.validateCustodyOffer(IMoshClaimMarket(market), id, source, seller, buyer, amount, fee);
    }
}

contract MoshOfferFixture {
    LibMoshValidation.Offer private offer;

    function set(LibMoshValidation.Offer calldata value) external {
        offer = value;
    }

    function offers(uint256) external view returns (address, address, address, uint256, uint256, uint64, uint16) {
        return (offer.swarm, offer.seller, offer.buyer, offer.amount, offer.price, offer.deadline, offer.feeBps);
    }
}

contract MoshValidationTest is Test {
    MoshValidationHarness private gate;
    MoshOfferFixture private market;
    address private constant SOURCE = address(0x11);
    address private constant SELLER = address(0x22);
    address private constant BUYER = address(0x33);

    function setUp() public {
        gate = new MoshValidationHarness();
        market = new MoshOfferFixture();
        market.set(_offer());
    }

    function _offer() private view returns (LibMoshValidation.Offer memory) {
        return LibMoshValidation.Offer(SOURCE, SELLER, BUYER, 7, 1, uint64(block.timestamp + 1 hours), 1000);
    }

    function _validate() private view returns (LibMoshValidation.Offer memory) {
        return gate.validateOffer(address(market), 42, SOURCE, SELLER, BUYER, 7, 1000);
    }

    function _invalid() private {
        vm.expectRevert(LibMoshValidation.InvalidMoshOffer.selector);
        _validate();
    }

    function testExactBuyerBoundOfferIsAccepted() public view {
        LibMoshValidation.Offer memory offer = _validate();
        assertEq(offer.amount, 7);
        assertEq(offer.price, 1);
    }

    function testSharedCustodyEncodingFixture() public view {
        string memory json = vm.readFile("test/fixtures/mosh-native-custody.json");
        address source = vm.parseJsonAddress(json, ".swarm");
        address buyer = vm.parseJsonAddress(json, ".buyer");
        uint256 amount = vm.parseUint(vm.parseJsonString(json, ".amount"));
        uint256 id = vm.parseUint(vm.parseJsonString(json, ".offerId"));
        uint64 deadline = uint64(vm.parseUint(vm.parseJsonString(json, ".deadline")));
        assertEq(
            abi.encodeCall(IMoshClaimMarket.list, (source, amount, 1, buyer, deadline)),
            vm.parseJsonBytes(json, ".list")
        );
        assertEq(abi.encodeCall(IMoshClaimMarket.fill, (id)), vm.parseJsonBytes(json, ".fill"));
        assertEq(abi.encodeCall(IMoshClaimMarket.cancel, (id)), vm.parseJsonBytes(json, ".cancel"));
        assertEq(abi.encodeCall(IMoshSwarm.syncFees, ()), vm.parseJsonBytes(json, ".sync"));
    }

    function testSourceSellerAndBuyerMismatchAreRejected() public {
        LibMoshValidation.Offer memory offer = _offer();
        offer.swarm = address(1);
        market.set(offer);
        _invalid();
        offer = _offer();
        offer.seller = address(1);
        market.set(offer);
        _invalid();
        offer = _offer();
        offer.buyer = address(1);
        market.set(offer);
        _invalid();
    }

    function testAmountPriceAndSnapshotFeeMismatchAreRejected() public {
        LibMoshValidation.Offer memory offer = _offer();
        offer.amount = 8;
        market.set(offer);
        _invalid();
        offer = _offer();
        offer.price = 2;
        market.set(offer);
        _invalid();
        offer = _offer();
        offer.feeBps = 999;
        market.set(offer);
        _invalid();
    }

    function testExpiredAndClearedOffersAreRejected() public {
        vm.warp(block.timestamp + 1 hours);
        _invalid();
        vm.warp(block.timestamp + 1);
        _invalid();
        LibMoshValidation.Offer memory cleared;
        market.set(cleared);
        _invalid();
    }

    function testZeroAndSelfMovementAreRejected() public {
        vm.expectRevert(LibMoshValidation.InvalidMoshOffer.selector);
        gate.validateOffer(address(market), 42, SOURCE, SELLER, BUYER, 0, 1000);
        vm.expectRevert(LibMoshValidation.InvalidMoshOffer.selector);
        gate.validateOffer(address(market), 42, SOURCE, SELLER, SELLER, 7, 1000);
        vm.expectRevert(LibMoshValidation.InvalidMoshOffer.selector);
        gate.validateOffer(address(market), 42, address(0), SELLER, BUYER, 7, 1000);
    }

    function testEntirePriceCannotBecomeMarketFee() public {
        LibMoshValidation.Offer memory offer = _offer();
        offer.feeBps = 10_000;
        market.set(offer);
        vm.expectRevert(LibMoshValidation.InvalidMoshOffer.selector);
        gate.validateOffer(address(market), 42, SOURCE, SELLER, BUYER, 7, 10_000);
    }

    function testFuzzNonUnitPricesAreRejected(uint256 price) public {
        vm.assume(price != 1);
        LibMoshValidation.Offer memory offer = _offer();
        offer.price = price;
        market.set(offer);
        _invalid();
    }
}
