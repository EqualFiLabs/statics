// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BasketAdminFacet} from "../../src/facets/BasketAdminFacet.sol";
import {IStaticsBasketAdmin} from "../../src/interfaces/IStaticsBasketAdmin.sol";
import {IStaticsBasketImpairment} from "../../src/interfaces/IStaticsBasketImpairment.sol";
import {IStaticsRewardPolicy} from "../../src/interfaces/IStaticsRewardPolicy.sol";
import {StaticsTestBase} from "../helpers/StaticsTestBase.sol";

contract BasketMintRedemptionFeesTest is StaticsTestBase {
    uint256 private constant FEE_SHARES = 0.1 ether + 1;
    uint256 private constant ASSET_A_FEE = 2 * FEE_SHARES;
    uint256 private constant ASSET_B_FEE = 5 * FEE_SHARES;
    uint256 private constant TRADE_SHARES = 1 ether;

    function testOnlyGovernanceCanConfigureTheExistingBasket() public {
        (uint256 basketId,) = _createDefaultBasket(0, 0);
        (uint256 otherId,) = _createDefaultBasket(0, 0);
        assertEq(basketAdmin.basketMintRedemptionStakerShareBps(basketId), 10_000);
        vm.prank(alice);
        vm.expectRevert();
        basketAdmin.setBasketMintRedemptionStakerShareBps(basketId, 8_000);
        vm.expectRevert(
            abi.encodeWithSelector(BasketAdminFacet.InvalidBasketMintRedemptionStakerShareBps.selector, 10_001)
        );
        basketAdmin.setBasketMintRedemptionStakerShareBps(basketId, 10_001);
        vm.expectRevert(abi.encodeWithSelector(BasketAdminFacet.BasketNotFound.selector, otherId + 1));
        basketAdmin.setBasketMintRedemptionStakerShareBps(otherId + 1, 1);
        vm.expectEmit(true, false, false, true, address(diamond));
        emit IStaticsBasketAdmin.BasketMintRedemptionStakerShareSet(basketId, 10_000, 0);
        basketAdmin.setBasketMintRedemptionStakerShareBps(basketId, 0);
        assertEq(basketAdmin.basketMintRedemptionStakerShareBps(basketId), 0);
        assertEq(basketAdmin.basketMintRedemptionStakerShareBps(otherId), 10_000);
    }

    function testFuzzMintAndRedemptionShareTheSplitAndConserveEachAsset(uint16 input) public {
        uint16 share = uint16(bound(input, 0, 10_000));
        (uint256 basketId, address token) = _createDefaultBasket(FEE_SHARES, FEE_SHARES);
        uint256 stake = _deposit(basketId);
        vm.warp(block.timestamp + 25 hours);
        basketAdmin.setBasketMintRedemptionStakerShareBps(basketId, share);
        uint256 beforeA = globalRewards.treasuryAccrued(address(assetA));
        uint256 beforeB = globalRewards.treasuryAccrued(address(assetB));
        uint256 backingA = baskets.vaultBalance(basketId, address(assetA));
        uint256 backingB = baskets.vaultBalance(basketId, address(assetB));
        uint256 supply = IERC20(token).totalSupply();

        _mint(basketId);
        uint256 stakerA = ASSET_A_FEE * share / 10_000;
        uint256 stakerB = ASSET_B_FEE * share / 10_000;
        _assertRewards(stake, basketId, stakerA, stakerB);
        _redeem(basketId);
        _assertRewards(stake, basketId, 2 * stakerA, 2 * stakerB);

        assertEq(globalRewards.treasuryAccrued(address(assetA)) - beforeA, 2 * (ASSET_A_FEE - stakerA));
        assertEq(globalRewards.treasuryAccrued(address(assetB)) - beforeB, 2 * (ASSET_B_FEE - stakerB));
        assertEq(baskets.vaultBalance(basketId, address(assetA)), backingA);
        assertEq(baskets.vaultBalance(basketId, address(assetB)), backingB);
        assertEq(IERC20(token).totalSupply(), supply);

        if (stakerA + stakerB != 0) {
            vm.prank(alice);
            (, uint256[] memory paid) = basketRewards.claimBasketRewards(stake, basketId, alice);
            assertEq(paid[1], 2 * stakerA);
            assertEq(paid[2], 2 * stakerB);
            assertEq(assetA.balanceOf(alice), paid[1]);
            assertEq(assetB.balanceOf(alice), paid[2]);
        }
    }

    function testPendingAndForeignStakeCannotEarnAndSplitChangesAreProspective() public {
        (uint256 otherId,) = _createDefaultBasket(0, 0);
        uint256 otherStake = _deposit(otherId);
        vm.warp(block.timestamp + 25 hours);
        (uint256 basketId,) = _createDefaultBasket(FEE_SHARES, FEE_SHARES);
        uint256 stake = _deposit(basketId);
        uint256 treasuryBefore = globalRewards.treasuryAccrued(address(assetA));
        _mint(basketId);
        _redeem(basketId);
        assertEq(globalRewards.treasuryAccrued(address(assetA)) - treasuryBefore, 2 * ASSET_A_FEE);
        _assertRewards(stake, basketId, 0, 0);
        _assertRewards(otherStake, otherId, 0, 0);

        vm.warp(block.timestamp + 25 hours);
        _mint(basketId);
        _assertRewards(stake, basketId, ASSET_A_FEE, ASSET_B_FEE);
        basketAdmin.setBasketMintRedemptionStakerShareBps(basketId, 0);
        _redeem(basketId);
        _assertRewards(stake, basketId, ASSET_A_FEE, ASSET_B_FEE);
        assertEq(globalRewards.treasuryAccrued(address(assetA)) - treasuryBefore, 3 * ASSET_A_FEE);
        _assertRewards(otherStake, otherId, 0, 0);
    }

    function testLastCollateralRedeemerKeepsPriorRewardsAndPaysNewFeeToTreasury() public {
        (uint256 basketId,) = _createDefaultBasket(FEE_SHARES, FEE_SHARES);
        uint256 stake = _deposit(basketId);
        vm.warp(block.timestamp + 25 hours);
        _mint(basketId);
        uint256 treasuryBefore = globalRewards.treasuryAccrued(address(assetA));

        vm.prank(alice);
        basketCollateral.redeemBasketCollateral(stake, basketId, 10 ether, alice, new uint256[](2));
        assertEq(globalRewards.treasuryAccrued(address(assetA)) - treasuryBefore, ASSET_A_FEE);
        _assertRewards(stake, basketId, ASSET_A_FEE, ASSET_B_FEE);
        vm.prank(alice);
        (, uint256[] memory claimed) = basketRewards.claimBasketRewards(stake, basketId, alice);
        assertEq(claimed[1], ASSET_A_FEE);
        assertEq(claimed[2], ASSET_B_FEE);
    }

    function testSeparateCohortsMaturingTogetherEarnTheSameNewFees() public {
        (uint256 basketId,) = _createDefaultBasket(FEE_SHARES, FEE_SHARES);
        uint256 original = _deposit(basketId);
        vm.warp(block.timestamp + 25 hours);
        _mint(basketId);
        uint256 first = _deposit(basketId);
        vm.warp(block.timestamp + 1 hours);
        uint256 second = _deposit(basketId);
        _mint(basketId);
        _assertRewards(first, basketId, 0, 0);
        _assertRewards(second, basketId, 0, 0);
        (, uint256[] memory originalBefore) = basketRewards.getBasketRewards(original, basketId);

        vm.warp(block.timestamp + 25 hours);
        _mint(basketId);
        (, uint256[] memory firstRewards) = basketRewards.getBasketRewards(first, basketId);
        (, uint256[] memory secondRewards) = basketRewards.getBasketRewards(second, basketId);
        (, uint256[] memory originalAfter) = basketRewards.getBasketRewards(original, basketId);
        assertEq(firstRewards, secondRewards);
        assertApproxEqAbs(firstRewards[1], ASSET_A_FEE / 3, 1);
        assertApproxEqAbs(firstRewards[2], ASSET_B_FEE / 3, 1);
        assertEq(originalAfter[1] - originalBefore[1], firstRewards[1]);
        assertEq(originalAfter[2] - originalBefore[2], firstRewards[2]);
        vm.prank(alice);
        (, uint256[] memory claimed) = basketRewards.claimBasketRewards(second, basketId, alice);
        assertEq(claimed, secondRewards);
    }

    function testRewardRestrictedConstituentFeeGoesToTreasury() public {
        (uint256 basketId,) = _createDefaultBasket(FEE_SHARES, FEE_SHARES);
        uint256 stake = _deposit(basketId);
        vm.warp(block.timestamp + 25 hours);
        IStaticsRewardPolicy(address(diamond)).addRewardRestriction(address(assetA));
        uint256 beforeA = globalRewards.treasuryAccrued(address(assetA));
        uint256 beforeB = globalRewards.treasuryAccrued(address(assetB));
        _mint(basketId);
        _redeem(basketId);
        assertEq(globalRewards.treasuryAccrued(address(assetA)) - beforeA, 2 * ASSET_A_FEE);
        assertEq(globalRewards.treasuryAccrued(address(assetB)), beforeB);
        _assertRewards(stake, basketId, 0, 2 * ASSET_B_FEE);
    }

    function testGlobalStakeDoesNotEarnPrimaryBasketFees() public {
        (uint256 basketId,) = _createDefaultBasket(FEE_SHARES, FEE_SHARES);
        uint256 stake = _deposit(basketId);
        address[] memory assets = new address[](1);
        assets[0] = address(assetA);
        stakingAsset.mint(alice, 10 ether);
        vm.startPrank(alice);
        stakingAsset.approve(address(diamond), 10 ether);
        uint256 globalStake = globalRewards.createAndStake(10 ether, alice, assets);
        vm.stopPrank();
        vm.warp(block.timestamp + 25 hours);
        basketAdmin.setBasketMintRedemptionStakerShareBps(basketId, 8_000);
        _mint(basketId);
        _redeem(basketId);
        assertEq(globalRewards.pendingRewards(globalStake, assets)[0], 0);
        _assertRewards(stake, basketId, 2 * (ASSET_A_FEE * 8 / 10), 2 * (ASSET_B_FEE * 8 / 10));
    }

    function testImpairedRedemptionPaysTheSplitOnlyForHealthyConstituents() public {
        (uint256 basketId,) = _createDefaultBasket(FEE_SHARES, FEE_SHARES);
        uint256 stake = _deposit(basketId);
        vm.warp(block.timestamp + 25 hours);
        basketAdmin.setBasketMintRedemptionStakerShareBps(basketId, 5_000);
        _mint(basketId);

        IStaticsBasketImpairment impairment = IStaticsBasketImpairment(address(diamond));
        impairment.markBasketAssetImpaired(basketId, address(assetA));
        uint256 beforeA = globalRewards.treasuryAccrued(address(assetA));
        uint256 beforeB = globalRewards.treasuryAccrued(address(assetB));
        uint256[] memory outputs = impairment.quoteRedeemImpaired(basketId, TRADE_SHARES);
        vm.prank(bob);
        impairment.redeemImpaired(basketId, TRADE_SHARES, bob, outputs);
        assertEq(globalRewards.treasuryAccrued(address(assetA)), beforeA);
        assertEq(globalRewards.treasuryAccrued(address(assetB)) - beforeB, ASSET_B_FEE - ASSET_B_FEE / 2);
        _assertRewards(stake, basketId, 0, 2 * (ASSET_B_FEE / 2));
        vm.prank(alice);
        (, uint256[] memory claimed) = basketRewards.claimBasketRewards(stake, basketId, alice);
        assertEq(claimed[1], 0);
        assertEq(claimed[2], 2 * (ASSET_B_FEE / 2));
    }

    function _deposit(uint256 basketId) private returns (uint256 positionId) {
        uint256[] memory inputs = baskets.quoteMint(basketId, 10 ether);
        _fundAndApprove(alice, inputs[0], inputs[1]);
        vm.prank(alice);
        (positionId,) = basketCollateral.createAndMintBasketCollateral(basketId, 10 ether, alice, inputs);
    }

    function _mint(uint256 basketId) private {
        uint256[] memory inputs = baskets.quoteMint(basketId, TRADE_SHARES);
        _fundAndApprove(bob, inputs[0], inputs[1]);
        vm.prank(bob);
        baskets.mint(basketId, TRADE_SHARES, bob, inputs);
    }

    function _redeem(uint256 basketId) private {
        uint256[] memory outputs = baskets.quoteRedeem(basketId, TRADE_SHARES);
        vm.prank(bob);
        baskets.redeem(basketId, TRADE_SHARES, bob, outputs);
    }

    function _assertRewards(uint256 positionId, uint256 basketId, uint256 amountA, uint256 amountB) private view {
        (, uint256[] memory pending) = basketRewards.getBasketRewards(positionId, basketId);
        assertEq(pending[0], 0);
        assertEq(pending[1], amountA);
        assertEq(pending[2], amountB);
    }
}
