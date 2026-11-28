// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IStaticsBasket} from "../../src/interfaces/IStaticsBasket.sol";
import {IStaticsBasketImpairment} from "../../src/interfaces/IStaticsBasketImpairment.sol";
import {IStaticsBasketStaging} from "../../src/interfaces/IStaticsBasketStaging.sol";
import {BasketRedemptionFacet} from "../../src/facets/BasketRedemptionFacet.sol";
import {GovernanceFacet} from "../../src/facets/GovernanceFacet.sol";
import {LibBasket} from "../../src/libraries/LibBasket.sol";
import {LibBasketCollateral} from "../../src/libraries/LibBasketCollateral.sol";
import {LibCustody} from "../../src/libraries/LibCustody.sol";
import {LibPosition} from "../../src/position/LibPosition.sol";
import {LibDiamond} from "../../src/libraries/LibDiamond.sol";
import {BasketImpairmentTestBase} from "../helpers/BasketImpairmentTestBase.sol";

contract BasketImpairmentTest is BasketImpairmentTestBase {
    function testMarkIsOwnerOnlyAndBasketScoped() public {
        (uint256 other,) = _createDefaultBasket(0, 0);
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(LibDiamond.NotContractOwner.selector, guardian, address(this)));
        impairment.markBasketAssetImpaired(id, address(bad));
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LibDiamond.NotContractOwner.selector, alice, address(this)));
        impairment.markBasketAssetImpaired(id, address(bad));
        vm.expectEmit(true, true, false, true, address(diamond));
        emit IStaticsBasketImpairment.BasketAssetImpaired(id, address(bad));
        impairment.markBasketAssetImpaired(id, address(bad));
        assertTrue(impairment.isBasketAssetImpaired(id, address(bad)));
        assertFalse(impairment.isBasketAssetImpaired(id, address(assetA)));
        assertFalse(impairment.isBasketAssetImpaired(other, address(bad)));
        assertEq(uint256(baskets.basketStatus(id)), uint256(IStaticsBasket.BasketStatus.ExitOnly));
        assertEq(uint256(baskets.basketStatus(other)), uint256(IStaticsBasket.BasketStatus.Active));
        assertTrue(IERC165(address(diamond)).supportsInterface(type(IStaticsBasketImpairment).interfaceId));
        assertTrue(IERC165(address(diamond)).supportsInterface(type(IStaticsBasket).interfaceId));
        vm.expectRevert(
            abi.encodeWithSelector(IStaticsBasketImpairment.AssetAlreadyImpaired.selector, id, address(bad))
        );
        impairment.markBasketAssetImpaired(id, address(bad));
    }

    function testInvalidBasketAssetAndPendingLaunchRejected() public {
        vm.expectRevert(abi.encodeWithSelector(GovernanceFacet.BasketNotFound.selector, 999));
        impairment.markBasketAssetImpaired(999, address(bad));
        vm.expectRevert(abi.encodeWithSelector(IStaticsBasketImpairment.AssetNotInBasket.selector, id, address(0)));
        impairment.markBasketAssetImpaired(id, address(0));
        IStaticsBasket.CreateBasketParams memory params = _defaultParams(0, 0);
        (IStaticsBasket.PoolLaunchParams[] memory pools, uint256[] memory maximums) =
            _fundDefaultLaunch(params.assets, alice);
        vm.prank(alice);
        (uint256 pending,) = IStaticsBasketStaging(address(diamond)).createBasketStaged{value: 1 ether}(
            params, pools, maximums, type(uint256).max, bytes32(0), 1
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                GovernanceFacet.InvalidBasketStatus.selector, pending, IStaticsBasket.BasketStatus.Pending
            )
        );
        impairment.markBasketAssetImpaired(pending, address(bad));
    }

    function testImpairQuarantinedAndExitOnlyBasketsWithoutReactivation() public {
        vm.prank(guardian);
        governance.quarantineBasket(id);
        impairment.markBasketAssetImpaired(id, address(bad));
        impairment.markBasketAssetImpaired(id, address(assetA));
        vm.expectRevert(
            abi.encodeWithSelector(
                GovernanceFacet.InvalidBasketStatus.selector, id, IStaticsBasket.BasketStatus.ExitOnly
            )
        );
        governance.releaseBasketQuarantine(id);
    }

    function testOrdinaryRedemptionRejectsEvenIfAssetRecovers() public {
        impairment.markBasketAssetImpaired(id, address(bad));
        vm.expectRevert(abi.encodeWithSelector(IStaticsBasketImpairment.ImpairedRedemptionRequired.selector, id));
        baskets.quoteRedeem(id, 1 ether);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IStaticsBasketImpairment.ImpairedRedemptionRequired.selector, id));
        baskets.redeem(id, 1 ether, alice, new uint256[](2));
    }

    function testImpairedRedemptionRequiresMarkedBasket() public {
        vm.expectRevert(abi.encodeWithSelector(IStaticsBasketImpairment.BasketNotImpaired.selector, id));
        impairment.quoteRedeemImpaired(id, 1 ether);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IStaticsBasketImpairment.BasketNotImpaired.selector, id));
        impairment.redeemImpaired(id, 1 ether, alice, new uint256[](2));
    }

    function testFrozenAssetDoesNotBlockHealthyExitOrMoveResidual() public {
        uint256 residual = baskets.vaultBalance(id, address(bad));
        uint256 badReserved = custody.globalReservedByToken(address(bad));
        uint256 supply = IERC20(token).totalSupply();
        _impair();
        uint256[] memory quote = impairment.quoteRedeemImpaired(id, 10 ether);
        assertEq(quote[0], 20 ether);
        assertEq(quote[1], 0);
        uint256 beforeHealthy = assetA.balanceOf(alice);
        governance.pause(1 << 4);
        vm.expectEmit(true, true, true, true, address(diamond));
        emit IStaticsBasketImpairment.BasketImpairedRedeemed(id, alice, alice, 10 ether);
        vm.prank(alice);
        impairment.redeemImpaired(id, 10 ether, alice, quote);
        assertEq(assetA.balanceOf(alice) - beforeHealthy, 20 ether);
        assertEq(IERC20(token).totalSupply(), supply - 10 ether);
        assertEq(IERC20(token).balanceOf(alice), 0);
        assertEq(baskets.vaultBalance(id, address(bad)), residual);
        assertEq(custody.globalReservedByToken(address(bad)), badReserved);
        assertEq(custody.reservedByAccount(LibCustody.basketAccount(id), address(bad)), residual);
    }

    function testImpairedMinimumAndHealthyMinimumRollBackBurn() public {
        _impair();
        uint256[] memory minimums = new uint256[](2);
        minimums[1] = 1;
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BasketRedemptionFacet.MinimumOutputNotMet.selector, address(bad), 0, 1));
        impairment.redeemImpaired(id, 1 ether, alice, minimums);
        minimums[1] = 0;
        minimums[0] = 2 ether + 1;
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                BasketRedemptionFacet.MinimumOutputNotMet.selector, address(assetA), 2 ether, 2 ether + 1
            )
        );
        impairment.redeemImpaired(id, 1 ether, alice, minimums);
        assertEq(IERC20(token).balanceOf(alice), 10 ether);
    }

    function testConfiguredFeesApplyOnlyToHealthyBacking() public {
        (uint256 feeId,) = _createDefaultBasket(0, 0.05 ether);
        _mintTestShares(feeId, 10 ether);
        uint256 residual = baskets.vaultBalance(feeId, address(bad));
        impairment.markBasketAssetImpaired(feeId, address(bad));
        bad.setFailures(true, true);
        uint256[] memory quote = impairment.quoteRedeemImpaired(feeId, 10 ether);
        assertEq(quote[0], 19.9 ether);
        assertEq(quote[1], 0);
        vm.prank(alice);
        impairment.redeemImpaired(feeId, 10 ether, alice, quote);
        assertEq(baskets.vaultBalance(feeId, address(bad)), residual);
    }

    function testAllImpairedAllowsExplicitZeroOutputBurn() public {
        _impair();
        impairment.markBasketAssetImpaired(id, address(assetA));
        uint256 healthyResidual = baskets.vaultBalance(id, address(assetA));
        vm.prank(alice);
        impairment.redeemImpaired(id, 10 ether, alice, new uint256[](2));
        assertEq(IERC20(token).balanceOf(alice), 0);
        assertEq(baskets.vaultBalance(id, address(assetA)), healthyResidual);
    }

    function testPositionExitPreservesAuthorizationAndLoanLocks() public {
        vm.startPrank(alice);
        IERC20(token).approve(address(diamond), 10 ether);
        uint256 position = basketCollateral.createAndDepositBasketCollateral(id, 10 ether, alice);
        lending.borrow(position, id, 4 ether, alice);
        vm.stopPrank();
        uint256 locked = basketCollateral.basketCollateralPosition(position, id).lockedShares;
        _impair();
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(LibPosition.NotPositionOwnerOrApproved.selector, position, bob));
        impairment.redeemImpairedBasketCollateral(position, id, 1 ether, bob, new uint256[](2));
        vm.prank(alice);
        vm.expectPartialRevert(LibBasketCollateral.PositionSharesLocked.selector);
        impairment.redeemImpairedBasketCollateral(position, id, 7 ether, alice, new uint256[](2));
        vm.prank(alice);
        impairment.redeemImpairedBasketCollateral(position, id, 1 ether, alice, new uint256[](2));
        assertEq(basketCollateral.basketCollateralPosition(position, id).lockedShares, locked);
    }

    function testFuzzInterleavedBurnsPreserveHealthyBacking(uint256 first) public {
        first = bound(first, 1, 10 ether - 1);
        _impair();
        uint256 beforeHealthy = assetA.balanceOf(alice);
        vm.startPrank(alice);
        impairment.redeemImpaired(id, first, alice, new uint256[](2));
        impairment.redeemImpaired(id, 10 ether - first, alice, new uint256[](2));
        vm.stopPrank();
        assertEq(assetA.balanceOf(alice) - beforeHealthy, 20 ether);
        assertEq(
            baskets.vaultBalance(id, address(assetA)), LibBasket.backingAtSupply(2 ether, IERC20(token).totalSupply())
        );
    }
}
