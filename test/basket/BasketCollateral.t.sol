// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LibBasketCollateral} from "../../src/libraries/LibBasketCollateral.sol";
import {StaticsTestBase} from "../helpers/StaticsTestBase.sol";

contract BasketCollateralTest is StaticsTestBase {
    function testBasketSharesBecomeRewardEligiblePositionCollateral() external {
        (uint256 basketId, address token) = _createDefaultBasket(0, 0);
        uint256[] memory quote = baskets.quoteMint(basketId, 10 ether);
        _fundAndApprove(alice, quote[0], quote[1]);

        vm.prank(alice);
        (uint256 positionId,) = basketCollateral.createAndMintBasketCollateral(basketId, 10 ether, alice, quote);
        assertEq(basketCollateral.basketCollateralPosition(positionId, basketId).depositedShares, 10 ether);
        assertEq(basketRewards.basketRewardState(basketId, token).totalEligibleShares, 10 ether);
        assertEq(globalRewards.totalStaked(), 0);
        assertEq(IERC20(token).balanceOf(address(diamond)), 10 ether);

        vm.expectRevert(
            abi.encodeWithSelector(LibBasketCollateral.PositionDepositTooRecent.selector, positionId, basketId, 2)
        );
        vm.prank(alice);
        basketCollateral.withdrawBasketCollateral(positionId, basketId, 10 ether, alice);

        vm.roll(block.number + 1);
        vm.prank(alice);
        basketCollateral.withdrawBasketCollateral(positionId, basketId, 10 ether, alice);
        assertEq(IERC20(token).balanceOf(alice), 10 ether);
        assertEq(basketRewards.basketRewardState(basketId, token).totalEligibleShares, 0);
    }
}
