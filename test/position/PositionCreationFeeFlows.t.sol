// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IStaticsPositionFees} from "../../src/interfaces/IStaticsPosition.sol";
import {StaticsTestBase} from "../helpers/StaticsTestBase.sol";

contract PositionCreationFeeFlowsTest is StaticsTestBase {
    uint256 internal constant POSITION_FEE = 0.001 ether;

    IStaticsPositionFees internal positionFees;

    function setUp() public override {
        super.setUp();
        positionFees = IStaticsPositionFees(address(diamond));
        positionFees.setPositionCreationFee(POSITION_FEE);
    }

    function test_CreateAndMintBasketCollateralPaysOnceAndExistingPositionMintIsFree() public {
        (uint256 basketId,) = _createDefaultBasket(0, 0);
        uint256[] memory quote = baskets.quoteMint(basketId, 10 ether);
        _fundAndApprove(alice, quote[0] * 2, quote[1] * 2);
        uint256 treasuryBefore = treasury.balance;

        vm.prank(alice);
        (uint256 positionId,) =
            basketCollateral.createAndMintBasketCollateral{value: POSITION_FEE}(basketId, 10 ether, alice, quote);

        assertEq(treasury.balance, treasuryBefore + POSITION_FEE);
        vm.prank(alice);
        basketCollateral.mintBasketCollateral(positionId, basketId, 10 ether, quote);
        assertEq(treasury.balance, treasuryBefore + POSITION_FEE);
        assertEq(basketCollateral.basketCollateralPosition(positionId, basketId).depositedShares, 20 ether);
    }

    function test_CreateAndDepositBasketCollateralPaysOnceAndExistingDepositIsFree() public {
        (uint256 basketId, address basketToken) = _createDefaultBasket(0, 0);
        uint256[] memory quote = baskets.quoteMint(basketId, 20 ether);
        _fundAndApprove(alice, quote[0], quote[1]);
        vm.startPrank(alice);
        baskets.mint(basketId, 20 ether, alice, quote);
        IERC20(basketToken).approve(address(diamond), type(uint256).max);
        vm.stopPrank();
        uint256 treasuryBefore = treasury.balance;

        vm.prank(alice);
        uint256 positionId =
            basketCollateral.createAndDepositBasketCollateral{value: POSITION_FEE}(basketId, 10 ether, alice);

        assertEq(treasury.balance, treasuryBefore + POSITION_FEE);
        vm.prank(alice);
        basketCollateral.depositBasketCollateral(positionId, basketId, 10 ether);
        assertEq(treasury.balance, treasuryBefore + POSITION_FEE);
        assertEq(basketCollateral.basketCollateralPosition(positionId, basketId).depositedShares, 20 ether);
    }

    function test_CreateAndStakePaysOnceAndExistingPositionStakeIsFree() public {
        stakingAsset.mint(alice, 20 ether);
        vm.prank(alice);
        stakingAsset.approve(address(diamond), type(uint256).max);
        address[] memory rewardAssets = new address[](0);
        uint256 treasuryBefore = treasury.balance;

        vm.prank(alice);
        uint256 positionId = globalRewards.createAndStake{value: POSITION_FEE}(10 ether, alice, rewardAssets);

        assertEq(treasury.balance, treasuryBefore + POSITION_FEE);
        vm.prank(alice);
        globalRewards.stake(positionId, 10 ether);
        assertEq(treasury.balance, treasuryBefore + POSITION_FEE);
        vm.prank(alice);
        assertEq(globalRewards.stakePosition(positionId).stakedBalance, 20 ether);
    }
}
