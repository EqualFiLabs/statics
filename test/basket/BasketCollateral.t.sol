// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BasketCollateralFacet} from "../../src/facets/BasketCollateralFacet.sol";
import {BasketMintFacet} from "../../src/facets/BasketMintFacet.sol";
import {StaticsTestBase} from "../helpers/StaticsTestBase.sol";

contract BasketCollateralTest is StaticsTestBase {
    uint256 private constant PAUSE_STAKE = 1 << 7;

    function testBasketSharesBecomeRewardEligiblePositionCollateral() external {
        (uint256 basketId, address token) = _createDefaultBasket(0, 0);
        uint256[] memory quote = baskets.quoteMint(basketId, 10 ether);
        _fundAndApprove(alice, quote[0], quote[1]);

        vm.prank(alice);
        (uint256 positionId,) = basketCollateral.createAndMintBasketCollateral(basketId, 10 ether, alice, quote);
        assertEq(basketCollateral.basketCollateralPosition(positionId, basketId).depositedShares, 10 ether);
        assertEq(basketRewards.basketRewardState(basketId, token).totalEligibleShares, 0);
        assertEq(globalRewards.totalStaked(), 0);
        assertEq(IERC20(token).balanceOf(address(diamond)), 10 ether);

        vm.warp(block.timestamp + 25 hours);
        assertEq(basketRewards.basketRewardState(basketId, token).totalEligibleShares, 10 ether);
        vm.prank(alice);
        basketCollateral.withdrawBasketCollateral(positionId, basketId, 10 ether, alice);
        assertEq(IERC20(token).balanceOf(alice), 10 ether);
        assertEq(basketRewards.basketRewardState(basketId, token).totalEligibleShares, 0);
    }

    function testStakePauseBlocksBasketCollateralIngressButPreservesWithdrawal() external {
        (uint256 basketId, address token) = _createDefaultBasket(0, 0);
        uint256[] memory firstQuote = baskets.quoteMint(basketId, 10 ether);
        _fundAndApprove(alice, firstQuote[0], firstQuote[1]);
        vm.prank(alice);
        (uint256 positionId,) = basketCollateral.createAndMintBasketCollateral(basketId, 10 ether, alice, firstQuote);

        vm.prank(guardian);
        governance.pause(PAUSE_STAKE);

        uint256[] memory secondQuote = baskets.quoteMint(basketId, 1 ether);
        _fundAndApprove(alice, secondQuote[0] * 2, secondQuote[1] * 2);
        vm.startPrank(alice);
        baskets.mint(basketId, 1 ether, alice, secondQuote);
        IERC20(token).approve(address(diamond), 1 ether);
        vm.expectRevert(abi.encodeWithSelector(BasketCollateralFacet.ActionPaused.selector, PAUSE_STAKE));
        basketCollateral.depositBasketCollateral(positionId, basketId, 1 ether);
        vm.expectRevert(abi.encodeWithSelector(BasketMintFacet.ActionPaused.selector, PAUSE_STAKE));
        basketCollateral.mintBasketCollateral(positionId, basketId, 1 ether, secondQuote);

        basketCollateral.withdrawBasketCollateral(positionId, basketId, 10 ether, alice);
        vm.stopPrank();

        assertEq(basketCollateral.basketCollateralPosition(positionId, basketId).depositedShares, 0);
        assertEq(IERC20(token).balanceOf(alice), 11 ether);
    }
}
