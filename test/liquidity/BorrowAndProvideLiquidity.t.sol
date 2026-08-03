// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IStaticsBasketCollateral} from "../../src/interfaces/IStaticsBasketCollateral.sol";
import {IStaticsBorrowLiquidity} from "../../src/interfaces/IStaticsBorrowLiquidity.sol";
import {IStaticsLending} from "../../src/interfaces/IStaticsLending.sol";
import {BorrowLiquidityFacet} from "../../src/facets/BorrowLiquidityFacet.sol";
import {LibGovernance} from "../../src/libraries/LibGovernance.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {BorrowLiquidityTestBase} from "../helpers/BorrowLiquidityTestBase.sol";

contract RefundCallbackERC20 is MockERC20 {
    address private guardedSender;
    address private guardedReceiver;
    address private callbackTarget;
    bytes private callbackData;

    bool public callbackInvoked;
    bool public reentrySucceeded;
    bytes public reentryResult;

    constructor() MockERC20("Refund Callback", "REFUND", 18) {}

    function setCallback(address sender, address receiver, address target, bytes calldata data) external {
        guardedSender = sender;
        guardedReceiver = receiver;
        callbackTarget = target;
        callbackData = data;
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (from == guardedSender && to == guardedReceiver && callbackTarget != address(0)) {
            callbackInvoked = true;
            (reentrySucceeded, reentryResult) = callbackTarget.call(callbackData);
        }
    }
}

contract BorrowAndProvideLiquidityTest is BorrowLiquidityTestBase {
    address private carol = makeAddr("carol");

    function testSingleAssetBorrowMintsUserOwnedV4PositionWithoutManagerResidue() public {
        _createReadyBasket(1);
        IStaticsBorrowLiquidity.LiquidityParams[] memory params = _poolParams(5 ether);
        IStaticsLending.BorrowQuote memory expected = lending.quoteBorrow(basketId, 20 ether);
        uint256 supplyBefore = IERC20(basketToken).totalSupply();

        vm.prank(alice);
        (uint256 loanId, uint256[] memory tokenIds) =
            borrowLiquidity.borrowAndProvideLiquidity(basketPositionId, basketId, 20 ether, params, bob);

        assertEq(tokenIds.length, 1);
        assertEq(IERC721(address(positionManagerContract)).ownerOf(tokenIds[0]), bob);
        assertEq(positionManagerContract.getPositionLiquidity(tokenIds[0]), params[0].liquidity);
        IStaticsLending.LoanView memory loan = lending.loan(loanId);
        assertEq(loan.feeShares, expected.feeShares);
        assertEq(loan.collateralShares, expected.collateralShares);
        assertEq(loan.principals, expected.principals);
        assertGt(IERC20(basketToken).totalSupply(), supplyBefore - expected.feeShares);
        _assertManagerHasNoUserResidue();

        IStaticsBasketCollateral.BasketCollateralPosition memory basketCollateralPosition =
            basketCollateral.basketCollateralPosition(basketPositionId, basketId);
        assertEq(basketCollateralPosition.depositedShares, 100 ether - expected.feeShares);
        assertEq(basketCollateralPosition.lockedShares, expected.collateralShares);

        vm.prank(alice);
        IERC721(address(diamond)).transferFrom(alice, carol, basketPositionId);
        assertEq(IERC721(address(positionManagerContract)).ownerOf(tokenIds[0]), bob);

        for (uint256 i; i < basketAssets.length; ++i) {
            MockERC20(basketAssets[i]).mint(alice, expected.principals[i]);
            vm.prank(alice);
            IERC20(basketAssets[i]).approve(address(diamond), expected.principals[i]);
        }
        vm.prank(alice);
        lending.repay(loanId);
        assertEq(IERC721(address(positionManagerContract)).ownerOf(tokenIds[0]), bob);
    }

    function testThreeAssetBorrowCreatesIndependentPositionsAndRefundsRecipient() public {
        _createReadyBasket(3);
        IStaticsBorrowLiquidity.LiquidityParams[] memory params = _poolParams(4 ether);
        uint256[] memory balancesBefore = new uint256[](basketAssets.length);
        for (uint256 i; i < basketAssets.length; ++i) {
            balancesBefore[i] = IERC20(basketAssets[i]).balanceOf(bob);
        }

        vm.prank(alice);
        (, uint256[] memory tokenIds) =
            borrowLiquidity.borrowAndProvideLiquidity(basketPositionId, basketId, 20 ether, params, bob);

        assertEq(tokenIds.length, 3);
        for (uint256 i; i < tokenIds.length; ++i) {
            assertEq(IERC721(address(positionManagerContract)).ownerOf(tokenIds[i]), bob);
            assertEq(positionManagerContract.getPositionLiquidity(tokenIds[i]), params[i].liquidity);
            assertGt(IERC20(basketAssets[i]).balanceOf(bob), balancesBefore[i]);
        }
        _assertManagerHasNoUserResidue();
    }

    function testApprovedOperatorAtomicStakeRefundsPositionOwner() public {
        _createReadyBasket(1);
        IStaticsBorrowLiquidity.LiquidityParams[] memory params = _poolParams(5 ether);
        vm.prank(alice);
        IERC721(address(diamond)).approve(bob, basketPositionId);
        uint256 ownerBalanceBefore = IERC20(basketAssets[0]).balanceOf(alice);
        uint256 operatorBalanceBefore = IERC20(basketAssets[0]).balanceOf(bob);

        vm.prank(bob);
        (, uint256[] memory tokenIds) =
            borrowLiquidity.borrowAndStakeLiquidity(basketPositionId, basketId, 20 ether, params);

        assertEq(IERC721(address(positionManagerContract)).ownerOf(tokenIds[0]), address(diamond));
        assertGt(IERC20(basketAssets[0]).balanceOf(alice), ownerBalanceBefore);
        assertEq(IERC20(basketAssets[0]).balanceOf(bob), operatorBalanceBefore);
        _assertManagerHasNoUserResidue();
    }

    function testExtensionAndRecoveryLeaveUserV4PositionIndependentAndBackingExact() public {
        _createReadyBasket(1);
        IStaticsBorrowLiquidity.LiquidityParams[] memory params = _poolParams(5 ether);
        vm.prank(alice);
        (uint256 loanId, uint256[] memory tokenIds) =
            borrowLiquidity.borrowAndProvideLiquidity(basketPositionId, basketId, 20 ether, params, bob);

        (, uint256[] memory extensionFees) = lending.quoteExtension(loanId);
        MockERC20(basketAssets[0]).mint(alice, extensionFees[0]);
        vm.startPrank(alice);
        IERC20(basketAssets[0]).approve(address(diamond), extensionFees[0]);
        lending.extend(loanId, extensionFees);
        vm.stopPrank();
        assertEq(IERC721(address(positionManagerContract)).ownerOf(tokenIds[0]), bob);

        vm.warp(uint256(lending.loan(loanId).maturity) + 1 hours + 1);
        vm.prank(carol);
        lending.recover(loanId);
        assertEq(IERC721(address(positionManagerContract)).ownerOf(tokenIds[0]), bob);
        assertEq(baskets.vaultBalance(basketId, basketAssets[0]), IERC20(basketToken).totalSupply());
    }

    function testInvalidPoolInputsRevertLoanMintAndPositionEffectsAtomically() public {
        _createReadyBasket(3);
        IStaticsBorrowLiquidity.LiquidityParams[] memory params = _poolParams(4 ether);
        uint256 supplyBefore = IERC20(basketToken).totalSupply();
        IStaticsBasketCollateral.BasketCollateralPosition memory beforePosition =
            basketCollateral.basketCollateralPosition(basketPositionId, basketId);

        params[1].asset = params[0].asset;
        _expectAtomicRevert(BorrowLiquidityFacet.DuplicatePoolAsset.selector, params, supplyBefore, beforePosition);
        params = _poolParams(4 ether);
        params[0].tickUpper = params[0].tickLower;
        _expectAtomicRevert(
            BorrowLiquidityFacet.InvalidLiquidityParameters.selector, params, supplyBefore, beforePosition
        );
        params = _poolParams(4 ether);
        params[0].deadline = block.timestamp - 1;
        _expectAtomicRevert(
            BorrowLiquidityFacet.InvalidLiquidityParameters.selector, params, supplyBefore, beforePosition
        );
        params = _poolParams(4 ether);
        params[0].amount0Max = 0;
        _expectAtomicRevert(BorrowLiquidityFacet.AmountCapExceeded.selector, params, supplyBefore, beforePosition);
        params = _poolParams(4 ether);
        params[0].liquidity = 0;
        _expectAtomicRevert(
            BorrowLiquidityFacet.InvalidLiquidityParameters.selector, params, supplyBefore, beforePosition
        );
        params = _poolParams(20 ether);
        _expectAtomicRevert(BorrowLiquidityFacet.InsufficientPrincipal.selector, params, supplyBefore, beforePosition);
    }

    function testBorrowMintAndLiquidityPausesEachBlockTheCombinedPath() public {
        _createReadyBasket(1);
        IStaticsBorrowLiquidity.LiquidityParams[] memory params = _poolParams(5 ether);
        uint256[3] memory actions =
            [LibGovernance.PAUSE_BORROW, LibGovernance.PAUSE_MINT, LibGovernance.PAUSE_LIQUIDITY];
        for (uint256 i; i < actions.length; ++i) {
            governance.pause(actions[i]);
            vm.prank(alice);
            vm.expectRevert();
            borrowLiquidity.borrowAndProvideLiquidity(basketPositionId, basketId, 20 ether, params, bob);
            vm.prank(alice);
            vm.expectRevert();
            borrowLiquidity.borrowAndStakeLiquidity(basketPositionId, basketId, 20 ether, params);
            governance.unpause(actions[i]);
        }
    }

    function testPrincipalRefundTokenCallbackCannotReenterCombinedPath() public {
        RefundCallbackERC20 reentrant = new RefundCallbackERC20();
        address[] memory assets = new address[](1);
        assets[0] = address(reentrant);
        _createReadyBasket(assets);
        IStaticsBorrowLiquidity.LiquidityParams[] memory params = _poolParams(5 ether);
        reentrant.setCallback(
            address(diamond),
            bob,
            address(diamond),
            abi.encodeCall(
                IStaticsBorrowLiquidity.borrowAndProvideLiquidity, (basketPositionId, basketId, 20 ether, params, bob)
            )
        );

        vm.prank(alice);
        (, uint256[] memory tokenIds) =
            borrowLiquidity.borrowAndProvideLiquidity(basketPositionId, basketId, 20 ether, params, bob);

        assertTrue(reentrant.callbackInvoked());
        assertFalse(reentrant.reentrySucceeded());
        assertEq(bytes4(reentrant.reentryResult()), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(IERC721(address(positionManagerContract)).ownerOf(tokenIds[0]), bob);
        _assertManagerHasNoUserResidue();
    }

    function _expectAtomicRevert(
        bytes4 selector,
        IStaticsBorrowLiquidity.LiquidityParams[] memory params,
        uint256 supplyBefore,
        IStaticsBasketCollateral.BasketCollateralPosition memory beforePosition
    ) private {
        vm.prank(alice);
        vm.expectPartialRevert(selector);
        borrowLiquidity.borrowAndProvideLiquidity(basketPositionId, basketId, 20 ether, params, bob);
        assertEq(IERC20(basketToken).totalSupply(), supplyBefore);
        IStaticsBasketCollateral.BasketCollateralPosition memory afterPosition =
            basketCollateral.basketCollateralPosition(basketPositionId, basketId);
        assertEq(afterPosition.depositedShares, beforePosition.depositedShares);
        assertEq(afterPosition.lockedShares, beforePosition.lockedShares);
        for (uint256 i; i < basketAssets.length; ++i) {
            assertEq(lending.outstandingPrincipal(basketId, basketAssets[i]), 0);
        }
    }
}
