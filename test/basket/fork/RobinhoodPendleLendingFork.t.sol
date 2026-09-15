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

    struct MarketRun {
        uint256[3] traded;
        uint256[3] receivedUsdg;
        uint256[3] spentUsdg;
        uint256 sellGas;
        uint256 buyGas;
    }

    struct LendingRun {
        uint256 positionId;
        uint256 loanId;
        uint256 unlockedShares;
        uint256[] mintQuote;
        uint256[] principals;
        IStaticsLending.BorrowQuote borrowQuote;
        MarketRun markets;
        LendingGas gasUsed;
    }

    function setUp() public override {
        super.setUp();
        _fundAliceWithPts();
        _fundAliceWithLiveUsdg(USDG_BUFFER);
        _launchTermBasket(2 ether);
    }

    function testMultiPtCollateralTradesRepaysAndWithdraws() public {
        LendingSnapshot memory beforePosition = _snapshot();
        LendingRun memory run = _exerciseLending();
        _assertClosedPosition(run, beforePosition);
        _assertRouteDustAndApprovals(run.principals);
        _emitRun(run);
    }

    function _exerciseLending() private returns (LendingRun memory run) {
        run.mintQuote = baskets.quoteMint(termBasketId, POSITION_SHARES);
        (run.positionId, run.gasUsed.mint) = _mintPosition(run.mintQuote);
        run.borrowQuote = lending.quoteBorrow(termBasketId, BORROW_SHARES);
        (run.loanId, run.principals, run.gasUsed.borrow) = _borrow(run.positionId, run.borrowQuote);
        _assertOpenLoan(run.positionId, run.loanId, run.borrowQuote, run.principals);

        vm.prank(alice);
        IERC20(USDG).transfer(bob, USDG_BUFFER);
        run.markets = _tradePrincipalVector(run.principals);
        run.gasUsed.marketSell = run.markets.sellGas;
        run.gasUsed.marketBuy = run.markets.buyGas;
        run.gasUsed.repay = _repay(run.loanId, run.principals);
        (run.unlockedShares, run.gasUsed.withdraw) = _withdrawUnlocked(run.positionId);
    }

    function _mintPosition(uint256[] memory mintQuote) private returns (uint256 positionId, uint256 mintGas) {
        uint256 gasBefore = gasleft();
        vm.prank(alice);
        uint256[] memory actualInputs;
        (positionId, actualInputs) =
            basketCollateral.createAndMintBasketCollateral(termBasketId, POSITION_SHARES, alice, mintQuote);
        mintGas = gasBefore - gasleft();
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

    function _tradePrincipalVector(uint256[] memory principals) private returns (MarketRun memory result) {
        for (uint256 i; i < 3; ++i) {
            result.traded[i] = Math.mulDiv(principals[i], TRADE_BPS, BPS);
            assertGt(result.traded[i], 0);
            uint256 gasBefore = gasleft();
            result.receivedUsdg[i] = _sellPtForUsdg(bob, i, result.traded[i]);
            result.sellGas += gasBefore - gasleft();

            gasBefore = gasleft();
            result.spentUsdg[i] = _buyExactPtWithUsdg(bob, i, result.traded[i]);
            result.buyGas += gasBefore - gasleft();
            assertGt(result.receivedUsdg[i], 0);
            assertGt(result.spentUsdg[i], 0);
            assertEq(IERC20(_termMarket(i).pt).balanceOf(bob), principals[i]);
        }
    }

    function _repay(uint256 loanId, uint256[] memory principals) private returns (uint256 repayGas) {
        uint256 gasBefore = gasleft();
        vm.startPrank(bob);
        for (uint256 i; i < 3; ++i) {
            IERC20(_termMarket(i).pt).approve(address(diamond), principals[i]);
        }
        lending.repay(loanId);
        vm.stopPrank();
        repayGas = gasBefore - gasleft();
    }

    function _withdrawUnlocked(uint256 positionId) private returns (uint256 unlockedShares, uint256 withdrawGas) {
        IStaticsBasketCollateral.BasketCollateralPosition memory position =
            basketCollateral.basketCollateralPosition(positionId, termBasketId);
        unlockedShares = position.depositedShares;
        assertEq(position.lockedShares, 0);
        uint256 gasBefore = gasleft();
        vm.prank(alice);
        basketCollateral.withdrawBasketCollateral(positionId, termBasketId, unlockedShares, alice);
        withdrawGas = gasBefore - gasleft();
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

    function _assertClosedPosition(LendingRun memory run, LendingSnapshot memory beforePosition) private view {
        IStaticsBasketCollateral.BasketCollateralPosition memory position =
            basketCollateral.basketCollateralPosition(run.positionId, termBasketId);
        assertEq(position.depositedShares, 0);
        assertEq(position.lockedShares, 0);
        assertEq(run.unlockedShares, POSITION_SHARES - run.borrowQuote.feeShares);
        assertEq(IERC20(termBasketToken).balanceOf(alice), run.unlockedShares);
        assertEq(IERC20(termBasketToken).totalSupply(), beforePosition.termSupply + run.unlockedShares);
        assertEq(IERC20(termBasketToken).balanceOf(address(diamond)), beforePosition.termCustody);
        assertEq(custody.globalReservedByToken(termBasketToken), beforePosition.termCustody);

        bytes32 basketAccount = custody.basketCustodyAccount(termBasketId);
        bytes32 feeAccount = custody.feeCustodyAccount();
        for (uint256 i; i < 3; ++i) {
            address pt = _termMarket(i).pt;
            AssetSnapshot memory prior = beforePosition.assets[i];
            uint256 mintPrincipal = Math.mulDiv(termBundles[i], POSITION_SHARES, SHARE_SCALE);
            uint256 mintFee = run.mintQuote[i] - mintPrincipal;
            uint256 originationFee =
                Math.mulDiv(termBundles[i], run.borrowQuote.feeShares, SHARE_SCALE, Math.Rounding.Ceil);

            assertEq(lending.outstandingPrincipal(termBasketId, pt), 0);
            assertEq(IERC20(pt).balanceOf(bob), 0);
            assertEq(IERC20(pt).balanceOf(alice), prior.user - run.mintQuote[i]);
            assertEq(baskets.vaultBalance(termBasketId, pt), prior.vault + mintPrincipal - originationFee);
            assertEq(custody.reservedByAccount(basketAccount, pt), prior.basketReserve + mintPrincipal - originationFee);
            assertEq(custody.reservedByAccount(feeAccount, pt), prior.feeReserve + mintFee + originationFee);
            assertEq(custody.globalReservedByToken(pt), prior.globalReserve + run.mintQuote[i]);
            assertEq(globalRewards.treasuryAccrued(pt), prior.treasury + mintFee + originationFee);
            assertEq(IERC20(pt).balanceOf(address(diamond)), prior.diamondBalance + run.mintQuote[i]);
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

    function _emitRun(LendingRun memory run) private {
        emit log("sTERM collateral -> PT vector loan -> Pendle/SY/V3 markets -> exact PT repayment");
        emit log_named_uint("sTERM collateral mint gas", run.gasUsed.mint);
        emit log_named_uint("three-PT borrow gas", run.gasUsed.borrow);
        emit log_named_uint("three live PT sale routes gas", run.gasUsed.marketSell);
        emit log_named_uint("three live PT buyback routes gas", run.gasUsed.marketBuy);
        emit log_named_uint("three-PT repayment gas", run.gasUsed.repay);
        emit log_named_uint("unlocked sTERM withdrawal gas", run.gasUsed.withdraw);
        for (uint256 i; i < 3; ++i) {
            emit log_named_uint("PT principal traded", run.markets.traded[i]);
            emit log_named_uint("USDG received", run.markets.receivedUsdg[i]);
            emit log_named_uint("USDG spent to restore exact PT", run.markets.spentUsdg[i]);
        }
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
