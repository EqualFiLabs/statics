// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IStaticsBasket} from "../../src/interfaces/IStaticsBasket.sol";
import {MockFlashBorrower} from "../mocks/MockFlashBorrower.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {StaticsTestBase} from "../helpers/StaticsTestBase.sol";

contract FlashCompositionFuzzTest is StaticsTestBase {
    function testFuzzFlashRedeemCompositionAcrossTokenDecimals(
        uint256 rawShares,
        uint256 rawDecimalsA,
        uint256 rawDecimalsB,
        uint256 rawFlashFeeBps
    ) public {
        uint256 shares = bound(rawShares, 0.5 ether, 1 ether);
        uint8 decimalsA = uint8(bound(rawDecimalsA, 0, 18));
        uint8 decimalsB = uint8(bound(rawDecimalsB, 0, 18));
        uint16 flashFeeBps = uint16(bound(rawFlashFeeBps, 0, 100));
        MockERC20 tokenA = new MockERC20("Decimal A", "DA", decimalsA);
        MockERC20 tokenB = new MockERC20("Decimal B", "DB", decimalsB);
        uint256 basketId;
        address basketToken;
        uint256[] memory amounts;
        (basketId, basketToken, amounts) =
            _seedDecimalFlashBasket(tokenA, tokenB, decimalsA, decimalsB, flashFeeBps, shares);

        MockFlashBorrower receiver = new MockFlashBorrower(address(diamond));
        vm.prank(alice);
        IERC20(basketToken).transfer(address(receiver), shares);
        receiver.setReentryData(
            abi.encodeCall(IStaticsBasket.redeem, (basketId, shares, address(receiver), new uint256[](2)))
        );
        uint256 vaultABefore = baskets.vaultBalance(basketId, address(tokenA));
        uint256 vaultBBefore = baskets.vaultBalance(basketId, address(tokenB));

        receiver.execute(basketId, shares, bytes("decimal composition"));

        assertTrue(receiver.reentrySucceeded());
        assertEq(baskets.vaultBalance(basketId, address(tokenA)), vaultABefore - amounts[0]);
        assertEq(baskets.vaultBalance(basketId, address(tokenB)), vaultBBefore - amounts[1]);
        bytes32 account = custody.basketCustodyAccount(basketId);
        assertEq(custody.reservedByAccount(account, address(tokenA)), baskets.vaultBalance(basketId, address(tokenA)));
        assertEq(custody.reservedByAccount(account, address(tokenB)), baskets.vaultBalance(basketId, address(tokenB)));
    }

    function _seedDecimalFlashBasket(
        MockERC20 tokenA,
        MockERC20 tokenB,
        uint8 decimalsA,
        uint8 decimalsB,
        uint16 flashFeeBps,
        uint256 shares
    ) private returns (uint256 basketId, address basketToken, uint256[] memory amounts) {
        address[] memory assets = new address[](2);
        assets[0] = address(tokenA);
        assets[1] = address(tokenB);
        uint256[] memory bundleAmounts = new uint256[](2);
        bundleAmounts[0] = 100 * (10 ** decimalsA);
        bundleAmounts[1] = 100 * (10 ** decimalsB);
        IStaticsBasket.CreateBasketParams memory params = IStaticsBasket.CreateBasketParams({
            name: "Decimal Flash Basket",
            symbol: "sDEC",
            assets: assets,
            bundleAmounts: bundleAmounts,
            mintFeeTiers: _singleFeeTier(0),
            redemptionFeeTiers: _singleFeeTier(0),
            flashFeeBps: flashFeeBps,
            originationFeeBps: 0,
            extensionFeeBps: 0,
            ltvBps: 9_500,
            recoveryPenaltyBps: 500,
            loanDuration: 30 days
        });
        (basketId, basketToken) = _launchBasket(params, alice, basketAdmin.creationFee());
        uint256[] memory initialMaximums = baskets.quoteMint(basketId, 10 ether);
        tokenA.mint(alice, initialMaximums[0]);
        tokenB.mint(alice, initialMaximums[1]);
        vm.startPrank(alice);
        tokenA.approve(address(diamond), initialMaximums[0]);
        tokenB.approve(address(diamond), initialMaximums[1]);
        baskets.mint(basketId, 10 ether, alice, initialMaximums);
        vm.stopPrank();
        basketToken = baskets.basket(basketId).token;
        (, amounts,) = flashLoans.quoteFlashLoan(basketId, shares);
    }
}
