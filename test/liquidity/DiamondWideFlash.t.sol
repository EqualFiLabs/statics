// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IStaticsBasket} from "../../src/interfaces/IStaticsBasket.sol";
import {IStaticsFlashLoan} from "../../src/interfaces/IStaticsFlashLoan.sol";
import {FlashLoanFacet} from "../../src/facets/FlashLoanFacet.sol";
import {LibDiamond} from "../../src/libraries/LibDiamond.sol";
import {LibFlashLoan} from "../../src/libraries/LibFlashLoan.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockFlashBorrower} from "../mocks/MockFlashBorrower.sol";
import {StaticsTestBase} from "../helpers/StaticsTestBase.sol";

contract DiamondWideFlashTest is StaticsTestBase {
    struct BasketFlashSnapshot {
        uint256 firstVault;
        bytes32 firstAccount;
        uint256 firstReserved;
        bytes32 secondAccount;
        uint256 secondReserved;
        uint256 globalReserved;
        uint256 feeReserved;
    }

    function testBasketFlashUsesPhysicalLiquidityBeyondOriginatingVault() public {
        (uint256 firstBasket,) = _createDefaultBasket(0, 0);
        BasketFlashSnapshot memory before_;
        before_.firstVault = baskets.vaultBalance(firstBasket, address(assetA));
        before_.firstAccount = custody.basketCustodyAccount(firstBasket);
        before_.firstReserved = custody.reservedByAccount(before_.firstAccount, address(assetA));

        (uint256 secondBasket,) = _createDefaultBasket(0, 0);
        uint256 flashShares = 1 ether;
        (address[] memory assets, uint256[] memory amounts, uint256[] memory fees) =
            flashLoans.quoteFlashLoan(firstBasket, flashShares);
        while (amounts[0] <= before_.firstVault) {
            flashShares *= 2;
            (assets, amounts, fees) = flashLoans.quoteFlashLoan(firstBasket, flashShares);
        }
        _mintBasket(secondBasket, bob, flashShares * 2);
        before_.secondAccount = custody.basketCustodyAccount(secondBasket);
        before_.secondReserved = custody.reservedByAccount(before_.secondAccount, address(assetA));
        before_.globalReserved = custody.globalReservedByToken(address(assetA));
        before_.feeReserved = custody.reservedByAccount(custody.feeCustodyAccount(), address(assetA));

        MockFlashBorrower receiver = new MockFlashBorrower(address(diamond));
        assertGt(amounts[0], before_.firstVault);
        assertLe(amounts[0], assetA.balanceOf(address(diamond)));
        assetA.mint(address(receiver), fees[0]);
        assetB.mint(address(receiver), fees[1]);

        receiver.execute(firstBasket, flashShares, bytes("Diamond-wide basket liquidity"));

        assertEq(assets[0], address(assetA));
        assertEq(baskets.vaultBalance(firstBasket, address(assetA)), before_.firstVault);
        assertEq(custody.reservedByAccount(before_.firstAccount, address(assetA)), before_.firstReserved);
        assertEq(custody.reservedByAccount(before_.secondAccount, address(assetA)), before_.secondReserved);
        assertEq(custody.globalReservedByToken(address(assetA)), before_.globalReserved + fees[0]);
        assertEq(custody.reservedByAccount(custody.feeCustodyAccount(), address(assetA)), before_.feeReserved + fees[0]);
    }

    function testSingleAssetFlashBorrowsFullPhysicalBalanceAndRoutesFee() public {
        MockERC20 asset = new MockERC20("Flash Asset", "FLASH", 18);
        asset.mint(address(diamond), 100 ether);
        MockFlashBorrower receiver = new MockFlashBorrower(address(diamond));
        uint256 fee = flashLoans.quoteFlashLoanAsset(address(asset), 100 ether);
        asset.mint(address(receiver), fee);

        assertEq(flashLoans.maxFlashLoan(address(asset)), 100 ether);
        assertEq(fee, 0.05 ether);
        assertEq(flashLoans.quoteFlashLoanAsset(address(asset), 1), 1);
        vm.expectEmit(true, true, true, true);
        emit IStaticsFlashLoan.AssetFlashLoan(address(asset), address(this), address(receiver), 100 ether, fee);

        flashLoans.flashLoanAsset(address(asset), 100 ether, address(receiver), bytes("full balance"));

        assertEq(asset.balanceOf(address(diamond)), 100 ether + fee);
        assertEq(custody.globalReservedByToken(address(asset)), fee);
        assertEq(custody.reservedByAccount(custody.feeCustodyAccount(), address(asset)), fee);
        assertEq(globalRewards.treasuryAccrued(address(asset)), fee);
    }

    function testSingleAssetCallbackCanUseOrdinaryBasketMint() public {
        (uint256 basketId, address basketToken) = _createDefaultBasket(0, 0);
        MockFlashBorrower receiver = new MockFlashBorrower(address(diamond));
        uint256[] memory maximums = baskets.quoteMint(basketId, 1 ether);
        uint256 fee = flashLoans.quoteFlashLoanAsset(address(assetA), maximums[0]);
        // Mint reservation needs independent physical slack while assetA principal is out.
        assetA.mint(address(diamond), maximums[0]);
        assetA.mint(address(receiver), maximums[0] + fee);
        assetB.mint(address(receiver), maximums[1]);
        receiver.approveProtocol(address(assetA), type(uint256).max);
        receiver.approveProtocol(address(assetB), type(uint256).max);
        receiver.setReentryData(abi.encodeCall(IStaticsBasket.mint, (basketId, 1 ether, address(receiver), maximums)));

        receiver.executeAsset(address(assetA), maximums[0], bytes("mint composition"));

        assertTrue(receiver.reentrySucceeded());
        assertEq(IERC20(basketToken).balanceOf(address(receiver)), 1 ether);
    }

    function testSingleAssetRejectsInvalidCallbackAtomically() public {
        MockERC20 asset = new MockERC20("Flash Asset", "FLASH", 18);
        asset.mint(address(diamond), 10 ether);
        MockFlashBorrower receiver = new MockFlashBorrower(address(diamond));
        asset.mint(address(receiver), flashLoans.quoteFlashLoanAsset(address(asset), 10 ether));
        receiver.setCallbackResult(bytes32(uint256(1)));

        vm.expectRevert(abi.encodeWithSelector(FlashLoanFacet.InvalidCallback.selector, bytes32(uint256(1))));
        receiver.executeAsset(address(asset), 10 ether, bytes("invalid callback"));

        assertEq(asset.balanceOf(address(diamond)), 10 ether);
        assertEq(custody.globalReservedByToken(address(asset)), 0);
    }

    function testSingleAssetUnderRepaymentRevertsAtomically() public {
        MockERC20 asset = new MockERC20("Flash Asset", "FLASH", 18);
        asset.mint(address(diamond), 10 ether);
        MockFlashBorrower receiver = new MockFlashBorrower(address(diamond));
        receiver.setRepay(false);

        vm.expectRevert();
        receiver.executeAsset(address(asset), 10 ether, bytes("underpay"));

        assertEq(asset.balanceOf(address(diamond)), 10 ether);
        assertEq(asset.balanceOf(address(receiver)), 0);
        assertEq(custody.globalReservedByToken(address(asset)), 0);
        assertEq(globalRewards.treasuryAccrued(address(asset)), 0);
    }

    function testSingleAssetRejectsInsufficientPhysicalLiquidity() public {
        MockERC20 asset = new MockERC20("Flash Asset", "FLASH", 18);
        asset.mint(address(diamond), 10 ether);
        MockFlashBorrower receiver = new MockFlashBorrower(address(diamond));

        vm.expectRevert(
            abi.encodeWithSelector(
                FlashLoanFacet.InsufficientFlashLiquidity.selector, address(asset), 10 ether + 1, 10 ether
            )
        );
        receiver.executeAsset(address(asset), 10 ether + 1, bytes("insufficient"));
    }

    function testSingleAssetRejectsInvalidInputs() public {
        MockERC20 asset = new MockERC20("Flash Asset", "FLASH", 18);
        MockFlashBorrower receiver = new MockFlashBorrower(address(diamond));

        vm.expectRevert(FlashLoanFacet.InvalidAmount.selector);
        receiver.executeAsset(address(asset), 0, bytes("zero"));
        vm.expectRevert(abi.encodeWithSelector(FlashLoanFacet.InvalidAsset.selector, address(0)));
        flashLoans.quoteFlashLoanAsset(address(0), 1);
        vm.expectRevert(abi.encodeWithSelector(FlashLoanFacet.InvalidAsset.selector, alice));
        flashLoans.maxFlashLoan(alice);
        vm.expectRevert(abi.encodeWithSelector(FlashLoanFacet.InvalidAsset.selector, address(diamond)));
        flashLoans.maxFlashLoan(address(diamond));
        vm.expectRevert(FlashLoanFacet.InvalidReceiver.selector);
        flashLoans.flashLoanAsset(address(asset), 1, alice, bytes("EOA receiver"));
    }

    function testFlashPauseAppliesToSingleAssetLoans() public {
        MockERC20 asset = new MockERC20("Flash Asset", "FLASH", 18);
        asset.mint(address(diamond), 10 ether);
        MockFlashBorrower receiver = new MockFlashBorrower(address(diamond));
        vm.prank(guardian);
        governance.pause(1 << 3);

        vm.expectRevert(abi.encodeWithSelector(FlashLoanFacet.ActionPaused.selector, 1 << 3));
        receiver.executeAsset(address(asset), 1 ether, bytes("paused"));
    }

    function testSingleAssetCannotNestBasketOrAssetFlash() public {
        (uint256 basketId,) = _createDefaultBasket(0, 0);
        MockERC20 asset = new MockERC20("Flash Asset", "FLASH", 18);
        asset.mint(address(diamond), 10 ether);
        MockFlashBorrower receiver = new MockFlashBorrower(address(diamond));
        uint256 fee = flashLoans.quoteFlashLoanAsset(address(asset), 1 ether);
        asset.mint(address(receiver), fee);
        receiver.setReentryData(
            abi.encodeCall(IStaticsFlashLoan.flashLoan, (basketId, 1 ether, address(receiver), bytes("nested")))
        );

        receiver.executeAsset(address(asset), 1 ether, bytes("outer asset"));

        assertFalse(receiver.reentrySucceeded());
        assertEq(bytes4(receiver.reentryResult()), ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);

        receiver.setReentryData(
            abi.encodeCall(
                IStaticsFlashLoan.flashLoanAsset, (address(asset), 1 ether, address(receiver), bytes("nested asset"))
            )
        );
        asset.mint(address(receiver), fee);
        receiver.executeAsset(address(asset), 1 ether, bytes("outer asset again"));
        assertFalse(receiver.reentrySucceeded());
        assertEq(bytes4(receiver.reentryResult()), ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
    }

    function testBasketFlashCannotNestSingleAssetFlash() public {
        (uint256 basketId, address basketToken) = _createDefaultBasket(0, 0);
        _mintBasket(basketId, alice, 10 ether);
        MockFlashBorrower receiver = new MockFlashBorrower(address(diamond));
        (,, uint256[] memory fees) = flashLoans.quoteFlashLoan(basketId, 1 ether);
        assetA.mint(address(receiver), fees[0]);
        assetB.mint(address(receiver), fees[1]);
        receiver.setReentryData(
            abi.encodeCall(
                IStaticsFlashLoan.flashLoanAsset,
                (address(assetA), 1 ether, address(receiver), bytes("nested single asset"))
            )
        );

        receiver.execute(basketId, 1 ether, bytes("outer basket"));

        assertFalse(receiver.reentrySucceeded());
        assertEq(bytes4(receiver.reentryResult()), ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        assertGt(IERC20(basketToken).totalSupply(), 0);
    }

    function testSingleAssetFeeIsOwnerGovernedAndBounded() public {
        assertEq(flashLoans.singleAssetFlashFeeBps(), 5);
        vm.expectEmit(false, false, false, true);
        emit IStaticsFlashLoan.SingleAssetFlashFeeBpsUpdated(5, 25);
        flashLoans.setSingleAssetFlashFeeBps(25);
        assertEq(flashLoans.singleAssetFlashFeeBps(), 25);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LibDiamond.NotContractOwner.selector, alice, address(this)));
        flashLoans.setSingleAssetFlashFeeBps(10);

        vm.expectRevert(abi.encodeWithSelector(LibFlashLoan.InvalidSingleAssetFlashFeeBps.selector, 10_001));
        flashLoans.setSingleAssetFlashFeeBps(10_001);
        flashLoans.setSingleAssetFlashFeeBps(0);
        assertEq(flashLoans.singleAssetFlashFeeBps(), 0);
    }

    function testFuzzSingleAssetFeeAndAccounting(uint256 rawAmount, uint256 rawFeeBps) public {
        uint256 amount = bound(rawAmount, 1, 1e30);
        uint256 feeBps = bound(rawFeeBps, 0, 10_000);
        flashLoans.setSingleAssetFlashFeeBps(uint16(feeBps));
        MockERC20 asset = new MockERC20("Flash Asset", "FLASH", 18);
        asset.mint(address(diamond), amount);
        MockFlashBorrower receiver = new MockFlashBorrower(address(diamond));
        uint256 expectedFee = Math.mulDiv(amount, feeBps, 10_000, Math.Rounding.Ceil);
        asset.mint(address(receiver), expectedFee);

        assertEq(flashLoans.quoteFlashLoanAsset(address(asset), amount), expectedFee);
        receiver.executeAsset(address(asset), amount, bytes("fuzz"));

        assertEq(asset.balanceOf(address(diamond)), amount + expectedFee);
        assertEq(custody.globalReservedByToken(address(asset)), expectedFee);
        assertEq(globalRewards.treasuryAccrued(address(asset)), expectedFee);
    }

    function _mintBasket(uint256 basketId, address user, uint256 shares) private {
        uint256[] memory maximums = baskets.quoteMint(basketId, shares);
        _fundAndApprove(user, maximums[0], maximums[1]);
        vm.prank(user);
        baskets.mint(basketId, shares, user, maximums);
    }
}
