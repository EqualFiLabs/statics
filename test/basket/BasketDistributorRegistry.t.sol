// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BasketAdminFacet} from "../../src/facets/BasketAdminFacet.sol";
import {IStaticsBasketAdmin} from "../../src/interfaces/IStaticsBasketAdmin.sol";
import {LibGovernance} from "../../src/libraries/LibGovernance.sol";
import {CanonicalPoolTestBase} from "../helpers/CanonicalPoolTestBase.sol";

contract BasketDistributorRegistryTest is CanonicalPoolTestBase {
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
        basketAdmin.setBasketDistributor(basketId, bob, true);
        vm.expectRevert(abi.encodeWithSelector(BasketAdminFacet.InvalidDistributor.selector, address(0)));
        basketAdmin.setBasketDistributor(basketId, address(0), true);
        vm.prank(alice);
        vm.expectRevert();
        token.transfer(address(this), 1 ether);
        vm.expectEmit(true, true, false, true, address(diamond));
        emit IStaticsBasketAdmin.BasketDistributorSet(basketId, address(this), true);
        basketAdmin.setBasketDistributor(basketId, address(this), true);
        vm.prank(alice);
        token.transfer(address(this), 1 ether);
        token.transfer(bob, 1 ether);
        assertEq(token.balanceOf(bob), 1 ether);
    }

    function testApprovalIsIsolatedFromExistingAndFutureBaskets() public {
        (uint256 secondId, address secondToken) = _createDefaultBasket(0, 0);
        _mintToAlice(secondId);
        basketAdmin.setBasketDistributor(basketId, bob, true);
        (uint256 thirdId, address thirdToken) = _createDefaultBasket(0, 0);
        _mintToAlice(thirdId);
        vm.startPrank(alice);
        assertTrue(token.transfer(bob, 1 ether));
        vm.expectRevert();
        IERC20(secondToken).transfer(bob, 1 ether);
        vm.expectRevert();
        IERC20(thirdToken).transfer(bob, 1 ether);
        vm.stopPrank();
        assertEq(token.balanceOf(bob), 1 ether);
        assertEq(IERC20(secondToken).balanceOf(bob), 0);
        assertEq(IERC20(thirdToken).balanceOf(bob), 0);
        basketAdmin.setBasketDistributor(basketId, bob, false);
        vm.prank(bob);
        vm.expectRevert();
        token.transfer(alice, 1 ether);
    }

    function testDistributorTransferFromRequiresAllowanceAndUnapprovedEndpointsFail() public {
        basketAdmin.setBasketDistributor(basketId, bob, true);
        vm.expectRevert();
        token.transferFrom(alice, bob, 1 ether);
        vm.prank(alice);
        token.approve(address(this), 2 ether);
        token.transferFrom(alice, bob, 1 ether);
        assertEq(token.allowance(alice, address(this)), 1 ether);
        basketAdmin.setBasketDistributor(basketId, bob, false);
        basketAdmin.setBasketDistributor(basketId, address(this), true);
        vm.expectRevert();
        token.transferFrom(alice, bob, 1 ether);
    }

    function testDistributorTransfersRemainAvailableDuringProtocolPause() public {
        basketAdmin.setBasketDistributor(basketId, bob, true);
        governance.pause(LibGovernance.PAUSE_MINT | LibGovernance.PAUSE_LIQUIDITY);
        vm.prank(alice);
        token.transfer(bob, 1 ether);
        vm.prank(bob);
        token.transfer(alice, 1 ether);
        assertEq(token.balanceOf(alice), 10 ether);
    }
}
