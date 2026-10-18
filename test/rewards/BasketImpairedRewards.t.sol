// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IStaticsPosition} from "../../src/interfaces/IStaticsPosition.sol";
import {IDiamondCut} from "../../src/interfaces/IDiamondCut.sol";
import {IStaticsBasketRewards} from "../../src/interfaces/IStaticsBasketRewards.sol";
import {BasketRewardsFacet} from "../../src/facets/BasketRewardsFacet.sol";
import {LibBasket} from "../../src/libraries/LibBasket.sol";
import {LibBasketRewards} from "../../src/libraries/LibBasketRewards.sol";
import {LibCustody} from "../../src/libraries/LibCustody.sol";
import {LibPosition} from "../../src/position/LibPosition.sol";
import {BasketImpairmentTestBase} from "../helpers/BasketImpairmentTestBase.sol";

/// @dev Injects funded fees at the internal accrual boundary to isolate claim
/// timing and cleanup. Real swap-funded claims are covered in NativeBasketRewards.
contract BasketRewardFundingHarness {
    function fund(uint256 basketId, address asset, uint256 amount) external {
        require(LibCustody.pullAndReserve(LibCustody.feeAccount(), asset, msg.sender, amount) == amount);
        LibBasketRewards.accrueReserved(basketId, LibBasket.basketStorage().baskets[basketId], asset, amount);
    }

    function checkpoint(uint256 positionId, uint256 basketId) external {
        LibBasketRewards.settle(positionId, basketId, LibBasket.basketStorage().baskets[basketId]);
    }
}

contract BasketImpairedRewardsTest is BasketImpairmentTestBase {
    BasketRewardFundingHarness private funding;
    uint256 private position;

    function setUp() public override {
        super.setUp();
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = BasketRewardFundingHarness.fund.selector;
        selectors[1] = BasketRewardFundingHarness.checkpoint.selector;
        IDiamondCut.FacetCut[] memory cut = new IDiamondCut.FacetCut[](1);
        cut[0] =
            IDiamondCut.FacetCut(address(new BasketRewardFundingHarness()), IDiamondCut.FacetCutAction.Add, selectors);
        IDiamondCut(address(diamond)).diamondCut(cut, address(0), "");
        funding = BasketRewardFundingHarness(address(diamond));
        vm.startPrank(alice);
        IERC20(token).approve(address(diamond), 10 ether);
        position = basketCollateral.createAndDepositBasketCollateral(id, 10 ether, alice);
        vm.stopPrank();
        vm.warp(block.timestamp + 25 hours);
    }

    function _fund(uint256 basketId, address asset, uint256 amount) private {
        // Funding uses real token transfers and custody reservations, not seeded claims.
        deal(asset, address(this), amount);
        IERC20(asset).approve(address(diamond), amount);
        funding.fund(basketId, asset, amount);
    }

    function _claim() private returns (uint256[] memory amounts) {
        vm.prank(alice);
        (, amounts) = basketRewards.claimBasketRewards(position, id, alice);
    }

    function testMixedClaimSkipsFrozenTokenAndPreservesItsReservation() public {
        _fund(id, address(assetA), 2 ether);
        _fund(id, address(bad), 3 ether);
        uint256 reserved = custody.reservedByAccount(LibCustody.feeAccount(), address(bad));
        uint256 global = custody.globalReservedByToken(address(bad));
        uint256 treasury = globalRewards.treasuryAccrued(address(bad));
        _impair();
        (, uint256[] memory visible) = basketRewards.getBasketRewards(position, id);
        assertEq(visible[1], 2 ether);
        assertEq(visible[2], 0);
        uint256 healthyBefore = assetA.balanceOf(alice);
        vm.expectEmit(true, true, true, true, address(diamond));
        emit IStaticsBasketRewards.BasketRewardForfeited(position, id, address(bad), 3 ether);
        uint256[] memory paid = _claim();
        assertEq(paid[1], 2 ether);
        assertEq(paid[2], 0);
        assertEq(assetA.balanceOf(alice) - healthyBefore, 2 ether);
        assertEq(custody.reservedByAccount(LibCustody.feeAccount(), address(bad)), reserved);
        assertEq(custody.globalReservedByToken(address(bad)), global);
        assertEq(globalRewards.treasuryAccrued(address(bad)), treasury);
        assertEq(basketRewards.basketRewardState(id, address(bad)).totalClaimable, 0);
        bad.setFailures(false, false);
        vm.expectRevert(abi.encodeWithSelector(BasketRewardsFacet.NoBasketRewards.selector, position, id));
        _claim();
    }

    function testCrystallizedImpairedOnlyClaimClearsAndAllowsPositionClosure() public {
        _fund(id, address(bad), 3 ether);
        funding.checkpoint(position, id);
        assertEq(basketRewards.basketRewardState(id, address(bad)).totalClaimable, 3 ether);
        _impair();
        vm.prank(alice);
        impairment.redeemImpairedBasketCollateral(position, id, 10 ether, alice, new uint256[](2));
        assertEq(basketRewards.basketRewardState(id, address(bad)).totalClaimable, 3 ether);
        uint256[] memory paid = _claim();
        assertEq(paid, new uint256[](3));
        vm.prank(alice);
        IStaticsPosition(address(diamond)).closePosition(position);
    }

    function testHealthyFailureRollsBackEarlierForfeiture() public {
        _fund(id, address(assetA), 2 ether);
        _fund(id, address(bad), 3 ether);
        funding.checkpoint(position, id);
        // Asset A is forfeited first; the later, unmarked currency fails.
        impairment.markBasketAssetImpaired(id, address(assetA));
        bad.setFailures(true, true);
        vm.expectRevert();
        _claim();
        assertEq(basketRewards.basketRewardState(id, address(assetA)).totalClaimable, 2 ether);
        assertEq(basketRewards.basketRewardState(id, address(bad)).totalClaimable, 3 ether);
        bad.setFailures(false, false);
        uint256[] memory paid = _claim();
        assertEq(paid[1], 0);
        assertEq(paid[2], 3 ether);
    }

    function testAllConstituentsImpairedDoNotForfeitBasketTokenRewards() public {
        _mintTestShares(id, 1 ether);
        basketAdmin.setBasketDistributor(address(this), true);
        vm.prank(alice);
        IERC20(token).transfer(address(this), 1 ether);
        IERC20(token).approve(address(diamond), 1 ether);
        funding.fund(id, token, 1 ether);
        _fund(id, address(assetA), 2 ether);
        _fund(id, address(bad), 3 ether);
        impairment.markBasketAssetImpaired(id, address(assetA));
        _impair();
        vm.mockCallRevert(address(assetA), abi.encodeWithSelector(IERC20.balanceOf.selector), "frozen");
        uint256[] memory paid = _claim();
        assertEq(paid[0], 1 ether);
        assertEq(paid[1], 0);
        assertEq(paid[2], 0);
    }

    function testLaterEarningsRemainForfeitedAfterTokenUnfreezes() public {
        _fund(id, address(bad), 1 ether);
        _impair();
        _claim();
        bad.setFailures(false, false);
        _fund(id, address(bad), 2 ether);
        (, uint256[] memory visible) = basketRewards.getBasketRewards(position, id);
        assertEq(visible[2], 0);
        uint256 balance = bad.balanceOf(alice);
        uint256[] memory paid = _claim();
        assertEq(paid[2], 0);
        assertEq(bad.balanceOf(alice), balance);
        assertEq(custody.reservedByAccount(LibCustody.feeAccount(), address(bad)), 3 ether);
    }

    function testImpairmentDoesNotApplyToOtherBasketUsingSameCurrency() public {
        (uint256 other, address otherToken) = _createDefaultBasket(0, 0);
        _mintTestShares(other, 10 ether);
        vm.startPrank(alice);
        IERC20(otherToken).approve(address(diamond), 10 ether);
        uint256 otherPosition = basketCollateral.createAndDepositBasketCollateral(other, 10 ether, alice);
        vm.stopPrank();
        vm.warp(block.timestamp + 25 hours);
        _fund(id, address(bad), 1 ether);
        _fund(other, address(bad), 2 ether);
        impairment.markBasketAssetImpaired(id, address(bad));
        _claim();
        vm.prank(alice);
        (, uint256[] memory paid) = basketRewards.claimBasketRewards(otherPosition, other, alice);
        assertEq(paid[2], 2 ether);
        assertEq(custody.reservedByAccount(LibCustody.feeAccount(), address(bad)), 1 ether);
    }

    function testUnauthorizedCallerCannotClearForfeiture() public {
        _fund(id, address(bad), 1 ether);
        funding.checkpoint(position, id);
        _impair();
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(LibPosition.NotPositionOwnerOrApproved.selector, position, bob));
        basketRewards.claimBasketRewards(position, id, bob);
        assertEq(basketRewards.basketRewardState(id, address(bad)).totalClaimable, 1 ether);
        _claim();
    }

    function testNoEntitlementsStillRevertsWhenBasketImpaired() public {
        _impair();
        vm.expectRevert(abi.encodeWithSelector(BasketRewardsFacet.NoBasketRewards.selector, position, id));
        _claim();
    }
}
