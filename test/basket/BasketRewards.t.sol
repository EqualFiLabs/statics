// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IStaticsBasket} from "../../src/interfaces/IStaticsBasket.sol";
import {IStaticsPosition} from "../../src/interfaces/IStaticsPosition.sol";
import {IStaticsBasketRewards} from "../../src/interfaces/IStaticsBasketRewards.sol";
import {LibBasketRewards} from "../../src/libraries/LibBasketRewards.sol";
import {LibPosition} from "../../src/position/LibPosition.sol";
import {PositionNFTFacet} from "../../src/position/PositionNFTFacet.sol";
import {MockFlashBorrower} from "../mocks/MockFlashBorrower.sol";
import {StaticsTestBase} from "../helpers/StaticsTestBase.sol";

contract BasketPositionReentrantReceiver is IERC721Receiver {
    address internal immutable DIAMOND;
    bytes internal callback;
    bool public reentrySucceeded;
    bytes public reentryResult;

    constructor(address diamond) {
        DIAMOND = diamond;
    }

    function setCallback(bytes calldata data) external {
        callback = data;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
        (reentrySucceeded, reentryResult) = DIAMOND.call(callback);
        return IERC721Receiver.onERC721Received.selector;
    }
}

contract BasketRewardsTest is StaticsTestBase {
    function testDirectMintExcludesNewPrincipalFromItsEntryFee() public {
        (uint256 basketId, address token) = _createDefaultBasket(0.1 ether, 0);
        uint256 alicePosition = _createMintPosition(basketId, token, alice, 10 ether);
        (, uint256[] memory alicePending) = basketRewards.pendingBasketRewards(alicePosition, basketId);
        assertEq(alicePending[0], 0);
        assertEq(basketAdmin.protocolRevenue(basketId, address(assetA)), 0.11 ether);

        uint256 bobPosition = _createMintPosition(basketId, token, bob, 10 ether);
        (, alicePending) = basketRewards.pendingBasketRewards(alicePosition, basketId);
        (, uint256[] memory bobPending) = basketRewards.pendingBasketRewards(bobPosition, basketId);
        assertEq(alicePending[0], 0.09 ether);
        assertEq(bobPending[0], 0);

        vm.prank(alice);
        basketRewards.claimBasketRewards(alicePosition, basketId, alice, alicePending);
        uint256[] memory quote = baskets.quoteMint(basketId, 10 ether);
        _fundAndApprove(alice, quote[0], quote[1]);
        vm.prank(alice);
        basketRewards.mintBasketToPosition(alicePosition, basketId, 10 ether, quote);

        (, alicePending) = basketRewards.pendingBasketRewards(alicePosition, basketId);
        (, bobPending) = basketRewards.pendingBasketRewards(bobPosition, basketId);
        assertEq(alicePending[0], 0.045 ether);
        assertEq(bobPending[0], 0.045 ether);
        assertEq(basketRewards.basketPosition(alicePosition, basketId).eligibleShares, 20 ether);
    }

    function testPositionRedemptionRemovesExitSharesBeforeFeeAccrual() public {
        (uint256 basketId, address token) = _createDefaultBasket(0, 0.1 ether);
        uint256 alicePosition = _createMintPosition(basketId, token, alice, 10 ether);
        uint256 bobPosition = _createMintPosition(basketId, token, bob, 10 ether);
        vm.roll(block.number + 1);

        uint256[] memory minimums = baskets.quoteRedeem(basketId, 10 ether);
        assertEq(minimums[0], 19.8 ether);
        vm.prank(alice);
        basketRewards.redeemBasketFromPosition(alicePosition, basketId, 10 ether, alice, minimums);

        (, uint256[] memory alicePending) = basketRewards.pendingBasketRewards(alicePosition, basketId);
        (, uint256[] memory bobPending) = basketRewards.pendingBasketRewards(bobPosition, basketId);
        assertEq(alicePending[0], 0);
        assertEq(bobPending[0], 0.09 ether);
        assertEq(IStaticsPosition(address(diamond)).activeLegCount(alicePosition), 0);
        assertEq(basketAdmin.protocolRevenue(basketId, address(assetA)), 0.02 ether);
    }

    function testDepositedLegTransfersAndCannotWithdrawInDepositBlock() public {
        (uint256 basketId, address token) = _createDefaultBasket(0, 0);
        uint256[] memory quote = baskets.quoteMint(basketId, 1 ether);
        _fundAndApprove(alice, quote[0], quote[1]);
        vm.startPrank(alice);
        baskets.mint(basketId, 1 ether, alice, quote);
        IERC20(token).approve(address(diamond), 1 ether);
        uint256 positionId = basketRewards.createAndDepositBasket(basketId, 1 ether, alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                LibBasketRewards.PositionDepositTooRecent.selector, positionId, basketId, block.number + 1
            )
        );
        basketRewards.withdrawBasket(positionId, basketId, 1 ether, alice);
        IERC721(address(diamond)).transferFrom(alice, bob, positionId);
        vm.stopPrank();

        vm.roll(block.number + 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LibPosition.NotPositionOwnerOrApproved.selector, positionId, alice));
        basketRewards.withdrawBasket(positionId, basketId, 1 ether, alice);
        vm.prank(bob);
        basketRewards.withdrawBasket(positionId, basketId, 1 ether, bob);
        assertEq(IERC20(token).balanceOf(bob), 1 ether);
        assertEq(IStaticsPosition(address(diamond)).activeLegCount(positionId), 0);
        vm.prank(bob);
        IStaticsPosition(address(diamond)).closePosition(positionId);
    }

    function testClaimTouchesOnlyItsBasketAndConstituentReserves() public {
        (uint256 firstBasket, address firstToken) = _createDefaultBasket(0.1 ether, 0);
        (uint256 secondBasket, address secondToken) = _createDefaultBasket(0.1 ether, 0);
        uint256 positionId = _createMintPosition(firstBasket, firstToken, alice, 10 ether);

        uint256[] memory secondQuote = baskets.quoteMint(secondBasket, 10 ether);
        _fundAndApprove(alice, secondQuote[0], secondQuote[1]);
        vm.startPrank(alice);
        baskets.mint(secondBasket, 10 ether, alice, secondQuote);
        IERC20(secondToken).approve(address(diamond), 10 ether);
        basketRewards.depositBasket(positionId, secondBasket, 10 ether);
        vm.stopPrank();

        uint256[] memory firstQuote = baskets.quoteMint(firstBasket, 10 ether);
        _fundAndApprove(bob, firstQuote[0], firstQuote[1]);
        vm.prank(bob);
        baskets.mint(firstBasket, 10 ether, bob, firstQuote);
        IStaticsBasketRewards.BasketRewardState memory firstState =
            basketRewards.basketRewardState(firstBasket, address(assetA));
        IStaticsBasketRewards.BasketRewardState memory secondState =
            basketRewards.basketRewardState(secondBasket, address(assetA));
        assertEq(firstState.feeYieldReserve, 0.09 ether);
        assertEq(secondState.feeYieldReserve, 0);

        (, uint256[] memory pending) = basketRewards.pendingBasketRewards(positionId, firstBasket);
        uint256 secondReservation =
            custody.reservedByAccount(custody.basketCustodyAccount(secondBasket), address(assetA));
        vm.prank(alice);
        basketRewards.claimBasketRewards(positionId, firstBasket, alice, pending);

        assertEq(basketRewards.basketRewardState(firstBasket, address(assetA)).feeYieldReserve, 0);
        assertEq(basketRewards.basketRewardState(secondBasket, address(assetA)).feeYieldReserve, 0);
        assertEq(
            custody.reservedByAccount(custody.basketCustodyAccount(secondBasket), address(assetA)), secondReservation
        );
        assertEq(basketRewards.basketPosition(positionId, secondBasket).eligibleShares, 10 ether);
    }

    function testFlashFeeAccruesToEligibleBasketPosition() public {
        (uint256 basketId, address token) = _createDefaultBasket(0, 0);
        uint256 positionId = _createMintPosition(basketId, token, alice, 10 ether);
        MockFlashBorrower receiver = new MockFlashBorrower(address(diamond));
        (,, uint256[] memory fees) = flashLoans.quoteFlashLoan(basketId, 2 ether);
        assetA.mint(address(receiver), fees[0]);
        assetB.mint(address(receiver), fees[1]);

        receiver.execute(basketId, 2 ether, bytes("arb"));

        (, uint256[] memory pending) = basketRewards.pendingBasketRewards(positionId, basketId);
        assertEq(pending[0], 0.0009 ether);
        assertEq(basketAdmin.protocolRevenue(basketId, address(assetA)), 0.0002 ether);
        assertEq(basketRewards.basketRewardState(basketId, address(assetA)).feeYieldReserve, 0.0009 ether);
    }

    function testDirectMintSafeReceiverCannotReenterBasketValuePath() public {
        (uint256 basketId,) = _createDefaultBasket(0, 0);
        uint256[] memory quote = baskets.quoteMint(basketId, 1 ether);
        _fundAndApprove(alice, quote[0], quote[1]);
        BasketPositionReentrantReceiver receiver = new BasketPositionReentrantReceiver(address(diamond));
        receiver.setCallback(abi.encodeCall(IStaticsBasket.mint, (basketId, 1 ether, address(receiver), quote)));

        vm.prank(alice);
        basketRewards.createAndMintBasket(basketId, 1 ether, address(receiver), quote);

        assertFalse(receiver.reentrySucceeded());
        assertEq(bytes4(receiver.reentryResult()), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
    }

    function testClaimableRewardsKeepBasketLegActiveAfterPrincipalWithdrawal() public {
        (uint256 basketId, address token) = _createDefaultBasket(0.1 ether, 0);
        uint256 positionId = _createMintPosition(basketId, token, alice, 10 ether);
        uint256[] memory quote = baskets.quoteMint(basketId, 10 ether);
        _fundAndApprove(bob, quote[0], quote[1]);
        vm.prank(bob);
        baskets.mint(basketId, 10 ether, bob, quote);
        vm.roll(block.number + 1);

        vm.startPrank(alice);
        basketRewards.withdrawBasket(positionId, basketId, 10 ether, alice);
        vm.expectRevert(abi.encodeWithSelector(PositionNFTFacet.PositionHasActiveLegs.selector, positionId, 1));
        IStaticsPosition(address(diamond)).closePosition(positionId);
        (, uint256[] memory pending) = basketRewards.pendingBasketRewards(positionId, basketId);
        basketRewards.claimBasketRewards(positionId, basketId, alice, pending);
        IStaticsPosition(address(diamond)).closePosition(positionId);
        vm.stopPrank();

        assertEq(IERC20(token).balanceOf(alice), 10 ether);
    }

    function _createMintPosition(uint256 basketId, address token, address user, uint256 shares)
        private
        returns (uint256 positionId)
    {
        uint256[] memory quote = baskets.quoteMint(basketId, shares);
        _fundAndApprove(user, quote[0], quote[1]);
        vm.prank(user);
        (positionId,) = basketRewards.createAndMintBasket(basketId, shares, user, quote);
        assertGe(IERC20(token).balanceOf(address(diamond)), shares);
        assertEq(basketRewards.basketPosition(positionId, basketId).eligibleShares, shares);
    }
}
