// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IStaticsBasket} from "../../src/interfaces/IStaticsBasket.sol";
import {IStaticsGovernance} from "../../src/interfaces/IStaticsGovernance.sol";
import {IStaticsLending} from "../../src/interfaces/IStaticsLending.sol";
import {GovernanceFacet} from "../../src/facets/GovernanceFacet.sol";
import {LibBasket} from "../../src/libraries/LibBasket.sol";
import {LibDiamond} from "../../src/libraries/LibDiamond.sol";
import {MockFlashBorrower} from "../mocks/MockFlashBorrower.sol";
import {StaticsTestBase} from "../helpers/StaticsTestBase.sol";

contract BasketDecommissionTest is StaticsTestBase {
    uint256 internal constant PAUSE_REDEEM = 1 << 4;

    function testGuardianQuarantineBlocksExposureAndKeepsSettlementOpen() public {
        (uint256 basketId, address token) = _createDefaultBasket(0, 0);
        uint256 launchSupply = IERC20(token).totalSupply();
        _mintShares(basketId, token, alice, 10 ether);
        vm.startPrank(alice);
        IERC20(token).approve(address(diamond), type(uint256).max);
        uint256 positionId = basketCollateral.createAndDepositBasketCollateral(basketId, 10 ether, alice);
        (uint256 loanId, uint256[] memory principals) = lending.borrow(positionId, basketId, 4 ether, alice);
        vm.stopPrank();

        vm.expectEmit(true, true, false, true, address(diamond));
        emit IStaticsGovernance.BasketQuarantined(basketId, guardian);
        vm.prank(guardian);
        governance.quarantineBasket(basketId);
        assertEq(uint8(baskets.basketStatus(basketId)), uint8(IStaticsBasket.BasketStatus.Quarantined));
        assertEq(uint8(baskets.basket(basketId).status), uint8(IStaticsBasket.BasketStatus.Quarantined));

        uint256[] memory mintQuote = baskets.quoteMint(basketId, 1 ether);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                LibBasket.BasketNotActive.selector, basketId, IStaticsBasket.BasketStatus.Quarantined
            )
        );
        baskets.mint(basketId, 1 ether, alice, mintQuote);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                LibBasket.BasketNotActive.selector, basketId, IStaticsBasket.BasketStatus.Quarantined
            )
        );
        lending.borrow(positionId, basketId, 1 ether, alice);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                LibBasket.BasketNotActive.selector, basketId, IStaticsBasket.BasketStatus.Quarantined
            )
        );
        lending.extend(loanId, new uint256[](2));

        MockFlashBorrower receiver = new MockFlashBorrower(address(diamond));
        vm.expectRevert(
            abi.encodeWithSelector(
                LibBasket.BasketNotActive.selector, basketId, IStaticsBasket.BasketStatus.Quarantined
            )
        );
        receiver.execute(basketId, 1 ether, bytes(""));

        vm.startPrank(alice);
        assetA.approve(address(diamond), principals[0]);
        assetB.approve(address(diamond), principals[1]);
        lending.repay(loanId);
        vm.roll(block.number + 1);
        uint256 positionShares = basketCollateral.basketCollateralPosition(positionId, basketId).depositedShares;
        uint256[] memory redemption = baskets.quoteRedeem(basketId, positionShares);
        basketCollateral.redeemBasketCollateral(positionId, basketId, positionShares, alice, redemption);
        vm.stopPrank();

        globalRewards.distributeTreasuryFees(address(assetA));
        assertEq(IERC20(token).totalSupply(), launchSupply);
    }

    function testGuardianCannotReleaseOrPermanentlyDecommission() public {
        (uint256 basketId,) = _createDefaultBasket(0, 0);
        vm.prank(guardian);
        governance.quarantineBasket(basketId);

        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(LibDiamond.NotContractOwner.selector, guardian, address(this)));
        governance.releaseBasketQuarantine(basketId);

        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(LibDiamond.NotContractOwner.selector, guardian, address(this)));
        governance.decommissionBasket(basketId);
    }

    function testGovernanceReleaseAndPermanentDecommissionAreBasketScoped() public {
        (uint256 firstBasket,) = _createDefaultBasket(0, 0);
        (uint256 secondBasket, address secondToken) = _createDefaultBasket(0, 0);
        vm.prank(guardian);
        governance.quarantineBasket(firstBasket);

        governance.releaseBasketQuarantine(firstBasket);
        assertEq(uint8(baskets.basketStatus(firstBasket)), uint8(IStaticsBasket.BasketStatus.Active));

        vm.expectEmit(true, false, false, true, address(diamond));
        emit IStaticsGovernance.BasketDecommissioned(firstBasket);
        governance.decommissionBasket(firstBasket);
        assertEq(uint8(baskets.basketStatus(firstBasket)), uint8(IStaticsBasket.BasketStatus.ExitOnly));
        assertEq(uint8(baskets.basketStatus(secondBasket)), uint8(IStaticsBasket.BasketStatus.Active));

        vm.expectRevert(
            abi.encodeWithSelector(
                GovernanceFacet.InvalidBasketStatus.selector, firstBasket, IStaticsBasket.BasketStatus.ExitOnly
            )
        );
        governance.releaseBasketQuarantine(firstBasket);
        vm.expectRevert(
            abi.encodeWithSelector(
                GovernanceFacet.InvalidBasketStatus.selector, firstBasket, IStaticsBasket.BasketStatus.ExitOnly
            )
        );
        governance.decommissionBasket(firstBasket);

        _mintShares(secondBasket, secondToken, alice, 1 ether);
    }

    function testExitOnlyKeepsPermissionlessRecoveryAvailable() public {
        (uint256 basketId, address token) = _createDefaultBasket(0, 0);
        uint256 launchSupply = IERC20(token).totalSupply();
        _mintShares(basketId, token, alice, 10 ether);
        vm.startPrank(alice);
        IERC20(token).approve(address(diamond), 10 ether);
        uint256 positionId = basketCollateral.createAndDepositBasketCollateral(basketId, 10 ether, alice);
        (uint256 loanId,) = lending.borrow(positionId, basketId, 10 ether, alice);
        vm.stopPrank();
        governance.decommissionBasket(basketId);

        uint40 maturity = lending.loan(loanId).maturity;
        IStaticsLending.RecoveryQuote memory recoveryQuote = lending.quoteRecovery(loanId);
        vm.warp(uint256(maturity) + 1 hours + 1);
        vm.prank(bob);
        lending.recover(loanId);

        assertEq(IERC20(token).totalSupply(), launchSupply + recoveryQuote.unlockedShares);
        assertEq(
            basketCollateral.basketCollateralPosition(positionId, basketId).depositedShares,
            recoveryQuote.unlockedShares
        );
        assertEq(uint8(baskets.basketStatus(basketId)), uint8(IStaticsBasket.BasketStatus.ExitOnly));

        vm.roll(block.number + 1);
        uint256[] memory redemption = baskets.quoteRedeem(basketId, recoveryQuote.unlockedShares);
        vm.prank(alice);
        basketCollateral.redeemBasketCollateral(
            positionId, basketId, recoveryQuote.unlockedShares, alice, redemption
        );
        assertEq(IERC20(token).totalSupply(), launchSupply);
    }

    function testExitOnlyRedemptionBypassesGlobalPause() public {
        (uint256 basketId, address token) = _createDefaultBasket(0, 0);
        uint256 launchSupply = IERC20(token).totalSupply();
        _mintShares(basketId, token, alice, 10 ether);

        governance.pause(PAUSE_REDEEM);
        governance.decommissionBasket(basketId);

        uint256 shares = IERC20(token).balanceOf(alice);
        uint256[] memory redemption = baskets.quoteRedeem(basketId, shares);
        vm.prank(alice);
        baskets.redeem(basketId, shares, alice, redemption);

        assertEq(IERC20(token).totalSupply(), launchSupply);
        assertEq(uint8(baskets.basketStatus(basketId)), uint8(IStaticsBasket.BasketStatus.ExitOnly));
        assertTrue(governance.isPaused(PAUSE_REDEEM));
    }

    function testExitOnlyPositionRedemptionBypassesGlobalPause() public {
        (uint256 basketId, address token) = _createDefaultBasket(0, 0);
        uint256 launchSupply = IERC20(token).totalSupply();
        uint256[] memory quote = baskets.quoteMint(basketId, 10 ether);
        _fundAndApprove(alice, quote[0], quote[1]);
        vm.prank(alice);
        (uint256 positionId,) = basketCollateral.createAndMintBasketCollateral(basketId, 10 ether, alice, quote);
        vm.roll(block.number + 1);

        governance.pause(PAUSE_REDEEM);
        governance.decommissionBasket(basketId);
        uint256[] memory redemption = baskets.quoteRedeem(basketId, 10 ether);
        vm.prank(alice);
        basketCollateral.redeemBasketCollateral(positionId, basketId, 10 ether, alice, redemption);

        assertEq(IERC20(token).totalSupply(), launchSupply);
        assertEq(uint8(baskets.basketStatus(basketId)), uint8(IStaticsBasket.BasketStatus.ExitOnly));
        assertTrue(governance.isPaused(PAUSE_REDEEM));
    }

    function _mintShares(uint256 basketId, address token, address user, uint256 shares) private {
        uint256[] memory quote = baskets.quoteMint(basketId, shares);
        _fundAndApprove(user, quote[0], quote[1]);
        vm.prank(user);
        baskets.mint(basketId, shares, user, quote);
        assertEq(IERC20(token).balanceOf(user), shares);
    }
}
