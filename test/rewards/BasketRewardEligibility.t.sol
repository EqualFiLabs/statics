// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IStaticsBasketCollateral} from "../../src/interfaces/IStaticsBasketCollateral.sol";
import {StaticsTestBase} from "../helpers/StaticsTestBase.sol";

contract BasketRewardEligibilityTest is StaticsTestBase {
    function testLockedCollateralRemainsEligibleAndOriginationFeeDoesNot() public {
        (uint256 basketId, address token) = _createDefaultBasket(0, 0);
        uint256 launchSupply = IERC20(token).totalSupply();
        uint256[] memory inputs = baskets.quoteMint(basketId, 10 ether);
        _fundAndApprove(alice, inputs[0], inputs[1]);
        vm.prank(alice);
        (uint256 positionId,) = basketCollateral.createAndMintBasketCollateral(basketId, 10 ether, alice, inputs);

        vm.prank(alice);
        lending.borrow(positionId, basketId, 5 ether, alice);

        assertEq(basketCollateral.basketCollateralPosition(positionId, basketId).lockedShares, 4.95 ether);
        assertEq(basketRewards.basketRewardState(basketId, token).totalEligibleShares, 9.95 ether);
        assertEq(IERC20(token).totalSupply(), launchSupply + 9.95 ether);
    }

    function testRepaymentOnlyUnlocksAndKeepsRewardEligibility() public {
        (uint256 basketId, address token) = _createDefaultBasket(0, 0);
        uint256[] memory inputs = baskets.quoteMint(basketId, 10 ether);
        _fundAndApprove(alice, inputs[0], inputs[1]);
        vm.prank(alice);
        (uint256 positionId,) = basketCollateral.createAndMintBasketCollateral(basketId, 10 ether, alice, inputs);
        vm.prank(alice);
        (uint256 loanId, uint256[] memory principals) = lending.borrow(positionId, basketId, 5 ether, alice);

        vm.startPrank(alice);
        assetA.approve(address(diamond), principals[0]);
        assetB.approve(address(diamond), principals[1]);
        lending.repay(loanId);
        vm.stopPrank();

        assertEq(basketCollateral.basketCollateralPosition(positionId, basketId).lockedShares, 0);
        assertEq(basketRewards.basketRewardState(basketId, token).totalEligibleShares, 9.95 ether);
    }

    function testRecoveryRemovesOnlyBurnedSharesFromRewardEligibility() public {
        (uint256 basketId, address token) = _createDefaultBasket(0, 0);
        uint256[] memory inputs = baskets.quoteMint(basketId, 10 ether);
        _fundAndApprove(alice, inputs[0], inputs[1]);
        vm.prank(alice);
        (uint256 positionId,) = basketCollateral.createAndMintBasketCollateral(basketId, 10 ether, alice, inputs);
        vm.prank(alice);
        (uint256 loanId,) = lending.borrow(positionId, basketId, 10 ether, alice);

        uint256 burnShares = lending.quoteRecovery(loanId).burnShares;
        uint256 eligibleBefore = basketRewards.basketRewardState(basketId, token).totalEligibleShares;
        vm.warp(lending.quoteRecovery(loanId).recoverableAt + 1);
        lending.recover(loanId);

        IStaticsBasketCollateral.BasketCollateralPosition memory position =
            basketCollateral.basketCollateralPosition(positionId, basketId);
        assertEq(position.lockedShares, 0);
        assertEq(position.depositedShares, eligibleBefore - burnShares);
        assertEq(basketRewards.basketRewardState(basketId, token).totalEligibleShares, eligibleBefore - burnShares);
    }
}
