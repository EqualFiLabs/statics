// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IStaticsLending} from "../interfaces/IStaticsLending.sol";
import {StaticsBasketToken} from "../tokens/StaticsBasketToken.sol";
import {LibBasket} from "./LibBasket.sol";
import {LibBasketRewards} from "./LibBasketRewards.sol";
import {LibGlobalRewards} from "./LibGlobalRewards.sol";
import {LibCustody} from "./LibCustody.sol";
import {LibGovernance} from "./LibGovernance.sol";
import {LibLending} from "./LibLending.sol";
import {LibPosition} from "../position/LibPosition.sol";
import {LibPositionPortfolio} from "./LibPositionPortfolio.sol";

library LibLoanOrigination {
    error BasketNotFound(uint256 basketId);
    error InvalidReceiver();
    error InvalidShares();
    error ZeroPrincipal();
    error ActionPaused(uint256 action);
    error InsufficientVaultBalance(address asset, uint256 required, uint256 available);
    error MaturityOverflow();

    function originate(
        uint256 positionId,
        uint256 basketId,
        uint256 sharesIn,
        address operator,
        address eventReceiver,
        address principalReceiver
    ) internal returns (uint256 loanId, uint256[] memory principals) {
        if (LibGovernance.governanceStorage().pausedActions & LibGovernance.PAUSE_BORROW != 0) {
            revert ActionPaused(LibGovernance.PAUSE_BORROW);
        }
        if (eventReceiver == address(0)) revert InvalidReceiver();
        LibPosition.enforceAuthorized(positionId, operator);

        LibBasket.BasketStorage storage bs = LibBasket.basketStorage();
        LibBasket.Basket storage configured = basket(bs, basketId);
        LibBasket.enforceActive(configured, basketId);
        IStaticsLending.BorrowQuote memory quoted = quote(configured, sharesIn);
        principals = quoted.principals;

        LibBasketRewards.lockForLoan(
            positionId, basketId, configured, sharesIn, quoted.feeShares, quoted.collateralShares
        );
        bytes32 custodyAccount = LibCustody.basketAccount(basketId);
        uint256 supplyBeforeFee = IERC20(configured.token).totalSupply();
        if (quoted.feeShares != 0) {
            LibCustody.release(custodyAccount, configured.token, quoted.feeShares);
            StaticsBasketToken(configured.token).burn(address(this), quoted.feeShares);
        }

        LibLending.LendingStorage storage ls = LibLending.lendingStorage();
        loanId = ls.nextLoanId;
        ls.nextLoanId = loanId + 1;
        uint256 maturityValue = block.timestamp + configured.loanDuration;
        if (maturityValue > type(uint40).max) revert MaturityOverflow();
        uint40 maturity = uint40(maturityValue);
        ls.loans[loanId] = LibLending.Loan({
            positionId: positionId,
            basketId: basketId,
            collateralShares: quoted.collateralShares,
            feeShares: quoted.feeShares,
            debtShares: quoted.debtShares,
            penaltyShares: quoted.penaltyShares,
            maturity: maturity
        });
        LibPositionPortfolio.addLoan(positionId, loanId);

        uint256 length = configured.assets.length;
        for (uint256 i; i < length; ++i) {
            address asset = configured.assets[i];
            uint256 feeUnderlying =
                LibBasket.backingReduction(configured.bundleAmounts[i], supplyBeforeFee, quoted.feeShares);
            uint256 principal = principals[i];
            uint256 required = feeUnderlying + principal;
            uint256 available = bs.vaultBalances[basketId][asset];
            if (required > available) revert InsufficientVaultBalance(asset, required, available);
            bs.vaultBalances[basketId][asset] = available - required;
            LibGlobalRewards.accrueNonSwapFee(custodyAccount, asset, feeUnderlying);
            ls.principals[loanId][asset] = principal;
            ls.outstandingPrincipal[basketId][asset] += principal;
        }

        // Publish the live obligation only after all loan accounting is complete,
        // but before a principal receiver can observe state through a token callback.
        LibPosition.incrementObligation(positionId);
        if (principalReceiver != address(0)) {
            for (uint256 i; i < length; ++i) {
                uint256 principal = principals[i];
                if (principal != 0) {
                    LibCustody.pushReserved(
                        custodyAccount, configured.assets[i], principalReceiver, principal, principal
                    );
                }
            }
        }

        emit IStaticsLending.LoanOriginated(
            loanId,
            positionId,
            basketId,
            operator,
            eventReceiver,
            sharesIn,
            quoted.feeShares,
            quoted.collateralShares,
            quoted.debtShares,
            quoted.penaltyShares,
            maturity
        );
    }

    function quote(LibBasket.Basket storage configured, uint256 sharesIn)
        internal
        view
        returns (IStaticsLending.BorrowQuote memory result)
    {
        if (sharesIn == 0) {
            revert InvalidShares();
        }
        result.feeShares = Math.mulDiv(sharesIn, configured.originationFeeBps, LibBasket.BPS, Math.Rounding.Ceil);
        if (result.feeShares >= sharesIn) revert InvalidShares();
        result.collateralShares = sharesIn - result.feeShares;
        result.debtShares = Math.mulDiv(result.collateralShares, configured.ltvBps, LibBasket.BPS, Math.Rounding.Ceil);
        result.penaltyShares =
            Math.mulDiv(result.debtShares, configured.recoveryPenaltyBps, LibBasket.BPS, Math.Rounding.Ceil);
        if (result.debtShares + result.penaltyShares > result.collateralShares) revert InvalidShares();
        result.assets = configured.assets;
        uint256 length = result.assets.length;
        result.principals = new uint256[](length);
        bool hasPrincipal;
        for (uint256 i; i < length; ++i) {
            uint256 principal = Math.mulDiv(configured.bundleAmounts[i], result.debtShares, LibBasket.SHARE_SCALE);
            result.principals[i] = principal;
            hasPrincipal = hasPrincipal || principal != 0;
        }
        if (!hasPrincipal) revert ZeroPrincipal();
    }

    function basket(LibBasket.BasketStorage storage bs, uint256 basketId)
        internal
        view
        returns (LibBasket.Basket storage configured)
    {
        configured = bs.baskets[basketId];
        if (configured.token == address(0)) revert BasketNotFound(basketId);
    }
}
