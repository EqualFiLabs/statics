// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BasketAdminFacet} from "../../src/facets/BasketAdminFacet.sol";
import {IStaticsBasketAdmin} from "../../src/interfaces/IStaticsBasketAdmin.sol";
import {LibGovernance} from "../../src/libraries/LibGovernance.sol";
import {StaticsTestBase} from "../helpers/StaticsTestBase.sol";

contract BasketDistributorRegistryTest is StaticsTestBase {
    uint256 private basketId;
    IERC20 private token;

    function setUp() public override {
        super.setUp();
        address deployed;
        (basketId, deployed) = _createDefaultBasket(0, 0);
        token = IERC20(deployed);
        _mintToAlice(basketId);
    }

    function _mintToAlice(uint256 id) private {
        uint256[] memory quote = baskets.quoteMint(id, 10 ether);
        _fundAndApprove(alice, quote[0], quote[1]);
        vm.prank(alice);
        baskets.mint(id, 10 ether, alice, quote);
    }

    function testOnlyOwnerApprovesAndOwnershipDoesNotExemptTransfers() public {
        vm.prank(alice);
        vm.expectRevert();
        basketAdmin.setBasketDistributor(bob, true);
        vm.expectRevert(abi.encodeWithSelector(BasketAdminFacet.InvalidDistributor.selector, address(0)));
        basketAdmin.setBasketDistributor(address(0), true);
        vm.prank(alice);
        vm.expectRevert();
        token.transfer(address(this), 1 ether);
        vm.expectEmit(true, false, false, true, address(diamond));
        emit IStaticsBasketAdmin.BasketDistributorSet(address(this), true);
        basketAdmin.setBasketDistributor(address(this), true);
        vm.prank(alice);
        token.transfer(address(this), 1 ether);
        token.transfer(bob, 1 ether);
        assertEq(token.balanceOf(bob), 1 ether);
    }

    function testApprovalAppliesAcrossExistingAndNewBaskets() public {
        basketAdmin.setBasketDistributor(bob, true);
        (uint256 secondId, address secondToken) = _createDefaultBasket(0, 0);
        _mintToAlice(secondId);
        vm.startPrank(alice);
        token.transfer(bob, 1 ether);
        IERC20(secondToken).transfer(bob, 2 ether);
        vm.stopPrank();
        assertEq(IERC20(secondToken).balanceOf(bob), 2 ether);
        basketAdmin.setBasketDistributor(bob, false);
        vm.prank(bob);
        vm.expectRevert();
        token.transfer(alice, 1 ether);
    }

    function testDistributorTransferFromRequiresAllowanceAndUnapprovedEndpointsFail() public {
        basketAdmin.setBasketDistributor(bob, true);
        vm.expectRevert();
        token.transferFrom(alice, bob, 1 ether);
        vm.prank(alice);
        token.approve(address(this), 2 ether);
        token.transferFrom(alice, bob, 1 ether);
        assertEq(token.allowance(alice, address(this)), 1 ether);
        basketAdmin.setBasketDistributor(bob, false);
        basketAdmin.setBasketDistributor(address(this), true);
        vm.expectRevert();
        token.transferFrom(alice, bob, 1 ether);
    }

    function testDistributorTransfersRemainAvailableDuringProtocolPause() public {
        basketAdmin.setBasketDistributor(bob, true);
        governance.pause(LibGovernance.PAUSE_MINT | LibGovernance.PAUSE_LIQUIDITY);
        vm.prank(alice);
        token.transfer(bob, 1 ether);
        vm.prank(bob);
        token.transfer(alice, 1 ether);
        assertEq(token.balanceOf(alice), 10 ether);
    }
}
