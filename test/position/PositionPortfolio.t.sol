// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IStaticsPositionPortfolio} from "../../src/interfaces/IStaticsPositionPortfolio.sol";
import {StaticsTestBase} from "../helpers/StaticsTestBase.sol";

contract PositionPortfolioTest is StaticsTestBase {
    function testPortfolioTracksBasketLoanAndRewardLifecycles() external {
        (uint256 basketId,) = _createDefaultBasket(0, 0);
        uint256[] memory mintInputs = baskets.quoteMint(basketId, 10 ether);
        _fundAndApprove(alice, mintInputs[0], mintInputs[1]);

        vm.prank(alice);
        (uint256 positionId,) = basketCollateral.createAndMintBasketCollateral(basketId, 10 ether, alice, mintInputs);

        address[] memory rewardAssets = new address[](2);
        rewardAssets[0] = address(assetA);
        rewardAssets[1] = address(assetB);
        vm.prank(alice);
        globalRewards.optInRewardAssets(positionId, rewardAssets);

        IStaticsPositionPortfolio.PositionPortfolioCounts memory counts =
            positionPortfolio.positionPortfolioCounts(positionId);
        assertEq(counts.basketCount, 1);
        assertEq(counts.loanCount, 0);
        assertEq(counts.liquidityPositionCount, 0);
        assertEq(counts.globalRewardAssetCount, 2);
        assertEq(counts.riskSeriesCount, 0);

        (uint256[] memory basketIds, uint256 basketCursor) = positionPortfolio.basketIdsOfPosition(positionId, 0, 100);
        assertEq(basketIds.length, 1);
        assertEq(basketIds[0], basketId);
        assertEq(basketCursor, 1);

        (address[] memory firstRewardPage, uint256 rewardCursor) =
            positionPortfolio.globalRewardAssetsOfPosition(positionId, 0, 1);
        assertEq(firstRewardPage.length, 1);
        assertEq(firstRewardPage[0], address(assetA));
        (address[] memory secondRewardPage, uint256 rewardEnd) =
            positionPortfolio.globalRewardAssetsOfPosition(positionId, rewardCursor, 1);
        assertEq(secondRewardPage.length, 1);
        assertEq(secondRewardPage[0], address(assetB));
        assertEq(rewardEnd, 2);

        vm.prank(alice);
        (uint256 loanId, uint256[] memory principals) = lending.borrow(positionId, basketId, 5 ether, alice);
        (uint256[] memory loanIds,) = positionPortfolio.loanIdsOfPosition(positionId, 0, 100);
        assertEq(loanIds.length, 1);
        assertEq(loanIds[0], loanId);

        vm.startPrank(alice);
        assetA.approve(address(diamond), principals[0]);
        assetB.approve(address(diamond), principals[1]);
        lending.repay(loanId);
        globalRewards.optOutRewardAssets(positionId, rewardAssets);
        vm.roll(block.number + 1);
        basketCollateral.withdrawBasketCollateral(positionId, basketId, 9.95 ether, alice);
        vm.stopPrank();

        counts = positionPortfolio.positionPortfolioCounts(positionId);
        assertEq(counts.basketCount, 0);
        assertEq(counts.loanCount, 0);
        assertEq(counts.globalRewardAssetCount, 0);
    }

    function testPortfolioPageValidationAndEmptyCursorAreStable() external {
        (uint256 basketId,) = _createDefaultBasket(0, 0);
        uint256[] memory mintInputs = baskets.quoteMint(basketId, 1 ether);
        _fundAndApprove(alice, mintInputs[0], mintInputs[1]);
        vm.prank(alice);
        (uint256 positionId,) = basketCollateral.createAndMintBasketCollateral(basketId, 1 ether, alice, mintInputs);

        vm.expectRevert(abi.encodeWithSelector(IStaticsPositionPortfolio.InvalidPortfolioPageSize.selector, 0, 100));
        positionPortfolio.basketIdsOfPosition(positionId, 0, 0);

        vm.expectRevert(abi.encodeWithSelector(IStaticsPositionPortfolio.InvalidPortfolioPageSize.selector, 101, 100));
        positionPortfolio.basketIdsOfPosition(positionId, 0, 101);

        (uint256[] memory emptyPage, uint256 nextCursor) = positionPortfolio.basketIdsOfPosition(positionId, 99, 1);
        assertEq(emptyPage.length, 0);
        assertEq(nextCursor, 1);
        assertEq(lending.recoveryGracePeriod(), 1 hours);
    }
}
