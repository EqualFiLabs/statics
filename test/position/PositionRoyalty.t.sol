// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC2981} from "@openzeppelin/contracts/interfaces/IERC2981.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IStaticsPosition} from "../../src/interfaces/IStaticsPosition.sol";
import {IStaticsPositionRoyalty} from "../../src/interfaces/IStaticsPositionRoyalty.sol";
import {LibDiamond} from "../../src/libraries/LibDiamond.sol";
import {StaticsTestBase} from "../helpers/StaticsTestBase.sol";

contract PositionRoyaltyTest is StaticsTestBase {
    IStaticsPositionRoyalty private royalties;

    function setUp() public override {
        super.setUp();
        royalties = IStaticsPositionRoyalty(address(diamond));
    }

    function testDefaultRoyaltyAndInterfaceSupport() public view {
        (address configuredReceiver, uint16 royaltyBps) = royalties.positionRoyalty();
        assertEq(configuredReceiver, treasury);
        assertEq(royaltyBps, 500);
        (address receiver, uint256 amount) = royalties.royaltyInfo(type(uint256).max, 1 ether);
        assertEq(receiver, treasury);
        assertEq(amount, 0.05 ether);
        assertTrue(IERC165(address(diamond)).supportsInterface(type(IERC2981).interfaceId));
        assertTrue(IERC165(address(diamond)).supportsInterface(type(IStaticsPositionRoyalty).interfaceId));
    }

    function testOwnerCanConfigureRoyaltyWithinBound() public {
        address receiver = makeAddr("royaltyReceiver");
        royalties.setPositionRoyalty(receiver, 1_000);
        (address actualReceiver, uint256 amount) = royalties.royaltyInfo(1, 123 ether);
        assertEq(actualReceiver, receiver);
        assertEq(amount, 12.3 ether);

        royalties.setPositionRoyalty(receiver, 0);
        (actualReceiver, amount) = royalties.royaltyInfo(1, 123 ether);
        assertEq(actualReceiver, address(0));
        assertEq(amount, 0);
    }

    function testRoyaltyConfigurationRejectsUnauthorizedAndInvalidValues() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LibDiamond.NotContractOwner.selector, alice, address(this)));
        royalties.setPositionRoyalty(alice, 100);

        vm.expectRevert(
            abi.encodeWithSelector(IStaticsPositionRoyalty.PositionRoyaltyExceedsMaximum.selector, 1_001, 1_000)
        );
        royalties.setPositionRoyalty(alice, 1_001);
        vm.expectRevert(
            abi.encodeWithSelector(IStaticsPositionRoyalty.InvalidPositionRoyaltyReceiver.selector, address(0))
        );
        royalties.setPositionRoyalty(address(0), 100);
        vm.expectRevert(
            abi.encodeWithSelector(IStaticsPositionRoyalty.InvalidPositionRoyaltyReceiver.selector, address(diamond))
        );
        royalties.setPositionRoyalty(address(diamond), 100);
    }

    function testRawPositionTransferDoesNotEnforceRoyalty() public {
        vm.prank(alice);
        uint256 positionId = IStaticsPosition(address(diamond)).createPosition(alice);
        uint256 treasuryBefore = treasury.balance;
        vm.prank(alice);
        IERC721(address(diamond)).transferFrom(alice, bob, positionId);
        assertEq(IERC721(address(diamond)).ownerOf(positionId), bob);
        assertEq(treasury.balance, treasuryBefore);
    }
}
