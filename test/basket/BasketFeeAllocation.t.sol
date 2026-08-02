// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IStaticsBasketAdmin} from "../../src/interfaces/IStaticsBasketAdmin.sol";
import {IStaticsBasketLiquidity} from "../../src/interfaces/IStaticsBasketLiquidity.sol";
import {BasketAdminFacet} from "../../src/facets/BasketAdminFacet.sol";
import {StaticsTestBase} from "../helpers/StaticsTestBase.sol";

contract BasketFeeAllocationTest is StaticsTestBase {
    function testAllocationIsAtomicAndMustConserveOneHundredPercent() public {
        IStaticsBasketAdmin.BasketFeeAllocation memory initial = basketAdmin.basketFeeAllocation();
        assertEq(initial.holderShareBps, 4_500);
        assertEq(initial.liquidityShareBps, 4_500);
        assertEq(initial.protocolShareBps, 1_000);

        IStaticsBasketAdmin.BasketFeeAllocation memory invalid = IStaticsBasketAdmin.BasketFeeAllocation({
            holderShareBps: 5_000, liquidityShareBps: 4_000, protocolShareBps: 999
        });
        vm.expectRevert(abi.encodeWithSelector(BasketAdminFacet.InvalidFeeAllocation.selector, 9_999));
        basketAdmin.setBasketFeeAllocation(invalid);

        IStaticsBasketAdmin.BasketFeeAllocation memory updated = IStaticsBasketAdmin.BasketFeeAllocation({
            holderShareBps: 4_000, liquidityShareBps: 5_000, protocolShareBps: 1_000
        });
        basketAdmin.setBasketFeeAllocation(updated);
        IStaticsBasketAdmin.BasketFeeAllocation memory stored = basketAdmin.basketFeeAllocation();
        assertEq(stored.holderShareBps, 4_000);
        assertEq(stored.liquidityShareBps, 5_000);
        assertEq(stored.protocolShareBps, 1_000);
    }

    function testMintFeeWithoutEligibleHoldersRedirectsOnlyHolderShare() public {
        (uint256 basketId,) = _createDefaultBasket(0.1 ether, 0);
        uint256[] memory quote = baskets.quoteMint(basketId, 1 ether);
        _fundAndApprove(alice, quote[0], quote[1]);

        vm.prank(alice);
        baskets.mint(basketId, 1 ether, alice, quote);

        IStaticsBasketLiquidity.PrimaryFeeTotals memory totals =
            basketLiquidity.cumulativePrimaryFees(basketId, address(assetA));
        assertEq(totals.holderAmount, 0);
        assertEq(totals.liquidityAmount, 0.09 ether);
        assertEq(totals.protocolAmount, 0.11 ether);
        assertEq(totals.holderAmount + totals.liquidityAmount + totals.protocolAmount, 0.2 ether);
        assertEq(basketLiquidity.liquidityReserve(basketId, address(assetA)), 0.09 ether);
        assertEq(basketAdmin.protocolRevenue(basketId, address(assetA)), 0.11 ether);

        uint256 recorded = baskets.vaultBalance(basketId, address(assetA))
            + basketLiquidity.liquidityReserve(basketId, address(assetA))
            + basketAdmin.protocolRevenue(basketId, address(assetA));
        assertEq(custody.reservedByAccount(custody.basketCustodyAccount(basketId), address(assetA)), recorded);
        assertEq(assetA.balanceOf(address(diamond)), recorded);
    }

    function testSharedConstituentLiquidityReservesRemainBasketIsolated() public {
        (uint256 firstBasket, address firstToken) = _createDefaultBasket(0.1 ether, 0);
        (uint256 secondBasket,) = _createDefaultBasket(0.1 ether, 0);
        _createEligiblePosition(firstBasket, firstToken, 1 ether);

        uint256 secondReserveBefore = basketLiquidity.liquidityReserve(secondBasket, address(assetA));
        uint256[] memory quote = baskets.quoteMint(firstBasket, 1 ether);
        _fundAndApprove(bob, quote[0], quote[1]);
        vm.prank(bob);
        baskets.mint(firstBasket, 1 ether, bob, quote);

        IStaticsBasketLiquidity.PrimaryFeeTotals memory firstTotals =
            basketLiquidity.cumulativePrimaryFees(firstBasket, address(assetA));
        assertEq(firstTotals.holderAmount, 0.09 ether);
        assertEq(firstTotals.liquidityAmount, 0.18 ether);
        assertEq(firstTotals.protocolAmount, 0.13 ether);
        assertEq(basketLiquidity.liquidityReserve(firstBasket, address(assetA)), 0.18 ether);
        assertEq(basketLiquidity.liquidityReserve(secondBasket, address(assetA)), secondReserveBefore);
        assertEq(custody.globalReservedByToken(address(assetA)), assetA.balanceOf(address(diamond)));
    }

    function testOriginationRevenueDoesNotEnterPrimaryFeeClassification() public {
        (uint256 basketId, address token) = _createDefaultBasket(0, 0);
        uint256 positionId = _createEligiblePosition(basketId, token, 2 ether);
        IStaticsBasketLiquidity.PrimaryFeeTotals memory beforeTotals =
            basketLiquidity.cumulativePrimaryFees(basketId, address(assetA));

        vm.prank(alice);
        lending.borrow(positionId, basketId, 1 ether, alice);

        IStaticsBasketLiquidity.PrimaryFeeTotals memory afterTotals =
            basketLiquidity.cumulativePrimaryFees(basketId, address(assetA));
        assertEq(afterTotals.holderAmount, beforeTotals.holderAmount);
        assertEq(afterTotals.liquidityAmount, beforeTotals.liquidityAmount);
        assertEq(afterTotals.protocolAmount, beforeTotals.protocolAmount);
        assertEq(basketLiquidity.liquidityReserve(basketId, address(assetA)), 0);
        assertGt(basketAdmin.protocolRevenue(basketId, address(assetA)), 0);
    }

    function _createEligiblePosition(uint256 basketId, address token, uint256 shares)
        private
        returns (uint256 positionId)
    {
        uint256[] memory quote = baskets.quoteMint(basketId, shares);
        _fundAndApprove(alice, quote[0], quote[1]);
        vm.startPrank(alice);
        (positionId,) = basketRewards.createAndMintBasket(basketId, shares, alice, quote);
        vm.stopPrank();
        assertEq(IERC20(token).balanceOf(address(diamond)), shares);
    }
}
