// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IStaticsBasketCollateral} from "../../../src/interfaces/IStaticsBasketCollateral.sol";
import {IStaticsLending} from "../../../src/interfaces/IStaticsLending.sol";
import {IPendleMarket, RobinhoodPendleForkBase} from "../../helpers/RobinhoodPendleForkBase.sol";

/// @notice Proves a three-PT sTERM position provides self-backed vector credit.
///
/// A borrower trades ten percent of each PT principal through its live Pendle market and SY adapter,
/// reaches three independent V3/USDG pools, reacquires the exact PT debt, repays, and withdraws the
/// unlocked sTERM collateral. This is Statics lending only; it makes no Morpho or oracle claim.
contract RobinhoodPendleLendingForkTest is RobinhoodPendleForkBase {
    uint256 private constant POSITION_SHARES = 10 ether;
    uint256 private constant BORROW_SHARES = 5 ether;
    uint256 private constant TRADE_BPS = 1_000;
    uint256 private constant USDG_BUFFER = 5_000_000;

    struct AssetSnapshot {
        uint256 user;
        uint256 vault;
        uint256 basketReserve;
        uint256 feeReserve;
        uint256 globalReserve;
        uint256 treasury;
        uint256 diamondBalance;
    }

    struct LendingSnapshot {
        uint256 termSupply;
        uint256 termCustody;
        AssetSnapshot[3] assets;
    }

    struct LendingGas {
        uint256 mint;
        uint256 borrow;
        uint256 marketSell;
        uint256 marketBuy;
        uint256 repay;
        uint256 withdraw;
    }

    function setUp() public override {
        super.setUp();
        _fundAliceWithPts();
        _fundAliceWithLiveUsdg(USDG_BUFFER);
        _launchTermBasket(2 ether);
    }

    function testMultiPtCollateralTradesRepaysAndWithdraws() public {
        LendingSnapshot memory beforePosition = _snapshot();
        uint256[] memory mintQuote = baskets.quoteMint(termBasketId, POSITION_SHARES);
        (uint256 positionId, LendingGas memory gasUsed) = _mintPosition(mintQuote);

        IStaticsLending.BorrowQuote memory borrowQuote = lending.quoteBorrow(termBasketId, BORROW_SHARES);
        uint256 loanId;
        uint256[] memory principals;
        (loanId, principals, gasUsed.borrow) = _borrow(positionId, borrowQuote);
        _assertOpenLoan(positionId, loanId, borrowQuote, principals);

        vm.prank(alice);
        IERC20(USDG).transfer(bob, USDG_BUFFER);
        uint256[3] memory traded;
        uint256[3] memory receivedUsdg;
        uint256[3] memory spentUsdg;
        for (uint256 i; i < 3; ++i) {
            traded[i] = Math.mulDiv(principals[i], TRADE_BPS, BPS);
            assertGt(traded[i], 0);
            uint256 gasBefore = gasleft();
            receivedUsdg[i] = _sellPtForUsdg(bob, i, traded[i]);
            gasUsed.marketSell += gasBefore - gasleft();

            gasBefore = gasleft();
            spentUsdg[i] = _buyExactPtWithUsdg(bob, i, traded[i]);
            gasUsed.marketBuy += gasBefore - gasleft();
            assertGt(receivedUsdg[i], 0);
            assertGt(spentUsdg[i], 0);
            assertEq(IERC20(_termMarket(i).pt).balanceOf(bob), principals[i]);
        }

        uint256 gasBefore = gasleft();
        vm.startPrank(bob);
        for (uint256 i; i < 3; ++i) {
            IERC20(_termMarket(i).pt).approve(address(diamond), principals[i]);
        }
        lending.repay(loanId);
        vm.stopPrank();
        gasUsed.repay = gasBefore - gasleft();

        IStaticsBasketCollateral.BasketCollateralPosition memory position =
            basketCollateral.basketCollateralPosition(positionId, termBasketId);
        uint256 unlockedShares = position.depositedShares;
        assertEq(position.lockedShares, 0);
        gasBefore = gasleft();
        vm.prank(alice);
        basketCollateral.withdrawBasketCollateral(positionId, termBasketId, unlockedShares, alice);
        gasUsed.withdraw = gasBefore - gasleft();

        _assertClosedPosition(positionId, borrowQuote, mintQuote, beforePosition, unlockedShares);
        _assertRouteDustAndApprovals(principals);

        emit log("sTERM collateral -> PT vector loan -> Pendle/SY/V3 markets -> exact PT repayment");
        emit log_named_uint("sTERM collateral mint gas", gasUsed.mint);
        emit log_named_uint("three-PT borrow gas", gasUsed.borrow);
        emit log_named_uint("three live PT sale routes gas", gasUsed.marketSell);
        emit log_named_uint("three live PT buyback routes gas", gasUsed.marketBuy);
        emit log_named_uint("three-PT repayment gas", gasUsed.repay);
        emit log_named_uint("unlocked sTERM withdrawal gas", gasUsed.withdraw);
        for (uint256 i; i < 3; ++i) {
            emit log_named_uint("PT principal traded", traded[i]);
            emit log_named_uint("USDG received", receivedUsdg[i]);
            emit log_named_uint("USDG spent to restore exact PT", spentUsdg[i]);
        }
    }

    function _mintPosition(uint256[] memory mintQuote) private returns (uint256 positionId, LendingGas memory gasUsed) {
        uint256 gasBefore = gasleft();
        vm.prank(alice);
        uint256[] memory actualInputs;
        (positionId, actualInputs) =
            basketCollateral.createAndMintBasketCollateral(termBasketId, POSITION_SHARES, alice, mintQuote);
        gasUsed.mint = gasBefore - gasleft();
        assertEq(actualInputs, mintQuote);
        assertEq(IERC721(address(diamond)).ownerOf(positionId), alice);
    }

    function _borrow(uint256 positionId, IStaticsLending.BorrowQuote memory quoted)
        private
        returns (uint256 loanId, uint256[] memory principals, uint256 borrowGas)
    {
        uint256 gasBefore = gasleft();
        vm.prank(alice);
        (loanId, principals) = lending.borrow(positionId, termBasketId, BORROW_SHARES, bob);
        borrowGas = gasBefore - gasleft();
        assertEq(principals, quoted.principals);
    }

    function _assertOpenLoan(
        uint256 positionId,
        uint256 loanId,
        IStaticsLending.BorrowQuote memory quoted,
        uint256[] memory principals
    ) private view {
        assertEq(quoted.assets, _termPts());
        assertEq(principals.length, 3);
        IStaticsLending.LoanView memory current = lending.loan(loanId);
        assertEq(current.positionId, positionId);
        assertEq(current.basketId, termBasketId);
        assertEq(current.assets, quoted.assets);
        assertEq(current.principals, principals);
        assertEq(current.collateralShares, quoted.collateralShares);
        assertEq(current.feeShares, quoted.feeShares);
        assertGt(current.maturity, block.timestamp);
        for (uint256 i; i < 3; ++i) {
            assertGt(principals[i], 0);
            assertEq(IERC20(quoted.assets[i]).balanceOf(bob), principals[i]);
            assertEq(lending.outstandingPrincipal(termBasketId, quoted.assets[i]), principals[i]);
            assertLt(current.maturity, IPendleMarket(_termMarket(i).market).expiry());
        }
    }

    function _assertClosedPosition(
        uint256 positionId,
        IStaticsLending.BorrowQuote memory borrowQuote,
        uint256[] memory mintQuote,
        LendingSnapshot memory beforePosition,
        uint256 unlockedShares
    ) private view {
        IStaticsBasketCollateral.BasketCollateralPosition memory position =
            basketCollateral.basketCollateralPosition(positionId, termBasketId);
        assertEq(position.depositedShares, 0);
        assertEq(position.lockedShares, 0);
        assertEq(unlockedShares, POSITION_SHARES - borrowQuote.feeShares);
        assertEq(IERC20(termBasketToken).balanceOf(alice), unlockedShares);
        assertEq(IERC20(termBasketToken).totalSupply(), beforePosition.termSupply + unlockedShares);
        assertEq(IERC20(termBasketToken).balanceOf(address(diamond)), beforePosition.termCustody);
        assertEq(custody.globalReservedByToken(termBasketToken), beforePosition.termCustody);

        bytes32 basketAccount = custody.basketCustodyAccount(termBasketId);
        bytes32 feeAccount = custody.feeCustodyAccount();
        for (uint256 i; i < 3; ++i) {
            address pt = _termMarket(i).pt;
            AssetSnapshot memory prior = beforePosition.assets[i];
            uint256 mintPrincipal = Math.mulDiv(termBundles[i], POSITION_SHARES, SHARE_SCALE);
            uint256 mintFee = mintQuote[i] - mintPrincipal;
            uint256 originationFee = Math.mulDiv(termBundles[i], borrowQuote.feeShares, SHARE_SCALE, Math.Rounding.Ceil);

            assertEq(lending.outstandingPrincipal(termBasketId, pt), 0);
            assertEq(IERC20(pt).balanceOf(bob), 0);
            assertEq(IERC20(pt).balanceOf(alice), prior.user - mintQuote[i]);
            assertEq(baskets.vaultBalance(termBasketId, pt), prior.vault + mintPrincipal - originationFee);
            assertEq(custody.reservedByAccount(basketAccount, pt), prior.basketReserve + mintPrincipal - originationFee);
            assertEq(custody.reservedByAccount(feeAccount, pt), prior.feeReserve + mintFee + originationFee);
            assertEq(custody.globalReservedByToken(pt), prior.globalReserve + mintQuote[i]);
            assertEq(globalRewards.treasuryAccrued(pt), prior.treasury + mintFee + originationFee);
            assertEq(IERC20(pt).balanceOf(address(diamond)), prior.diamondBalance + mintQuote[i]);
            assertEq(IERC20(pt).balanceOf(address(diamond)), custody.globalReservedByToken(pt));
        }
    }

    function _assertRouteDustAndApprovals(uint256[] memory principals) private view {
        assertGt(IERC20(USDG).balanceOf(bob), 0);
        for (uint256 i; i < 3; ++i) {
            TermMarket memory configured = _termMarket(i);
            assertEq(IERC20(configured.sy).balanceOf(bob), 0);
            assertEq(IERC20(configured.underlying).balanceOf(bob), 0);
            assertEq(IERC20(configured.pt).balanceOf(address(pendleSwapRouter)), 0);
            assertEq(IERC20(configured.sy).balanceOf(address(pendleSwapRouter)), 0);
            assertEq(IERC20(configured.pt).allowance(bob, address(pendleSwapRouter)), 0);
            assertEq(IERC20(configured.sy).allowance(bob, address(pendleSwapRouter)), 0);
            assertEq(IERC20(configured.pt).allowance(bob, address(diamond)), 0);
            assertGt(principals[i], 0);
        }
        assertEq(IERC20(USDG).allowance(bob, V3_ROUTER), 0);
    }

    function _snapshot() private view returns (LendingSnapshot memory snapshot) {
        snapshot.termSupply = IERC20(termBasketToken).totalSupply();
        snapshot.termCustody = custody.globalReservedByToken(termBasketToken);
        bytes32 basketAccount = custody.basketCustodyAccount(termBasketId);
        bytes32 feeAccount = custody.feeCustodyAccount();
        for (uint256 i; i < 3; ++i) {
            address pt = _termMarket(i).pt;
            snapshot.assets[i] = AssetSnapshot({
                user: IERC20(pt).balanceOf(alice),
                vault: baskets.vaultBalance(termBasketId, pt),
                basketReserve: custody.reservedByAccount(basketAccount, pt),
                feeReserve: custody.reservedByAccount(feeAccount, pt),
                globalReserve: custody.globalReservedByToken(pt),
                treasury: globalRewards.treasuryAccrued(pt),
                diamondBalance: IERC20(pt).balanceOf(address(diamond))
            });
        }
    }
}
