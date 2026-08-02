// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IStaticsLending} from "../interfaces/IStaticsLending.sol";
import {StaticsBasketToken} from "../tokens/StaticsBasketToken.sol";
import {LibBasket} from "./LibBasket.sol";
import {LibBasketCollateral} from "./LibBasketCollateral.sol";
import {LibGlobalRewards} from "./LibGlobalRewards.sol";
import {LibCustody} from "./LibCustody.sol";
import {LibGovernance} from "./LibGovernance.sol";
import {LibLending} from "./LibLending.sol";
import {LibPosition} from "../position/LibPosition.sol";

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
        (uint256 feeShares, uint256 collateralShares,, uint256[] memory quotedPrincipals) = quote(configured, sharesIn);
        principals = quotedPrincipals;

        LibBasketCollateral.lockForLoan(positionId, basketId, sharesIn, feeShares, collateralShares);
        bytes32 custodyAccount = LibCustody.basketAccount(basketId);
        uint256 supplyBeforeFee = IERC20(configured.token).totalSupply();
        if (feeShares != 0) {
            LibCustody.release(custodyAccount, configured.token, feeShares);
            StaticsBasketToken(configured.token).burn(address(this), feeShares);
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
            collateralShares: collateralShares,
            feeShares: feeShares,
            maturity: maturity
        });

        uint256 length = configured.assets.length;
        for (uint256 i; i < length; ++i) {
            address asset = configured.assets[i];
            uint256 feeUnderlying = LibBasket.backingReduction(configured.bundleAmounts[i], supplyBeforeFee, feeShares);
            uint256 principal = principals[i];
            uint256 required = feeUnderlying + principal;
            uint256 available = bs.vaultBalances[basketId][asset];
            if (required > available) revert InsufficientVaultBalance(asset, required, available);
            bs.vaultBalances[basketId][asset] = available - required;
            LibGlobalRewards.accrueNonSwapFee(custodyAccount, asset, feeUnderlying);
            ls.principals[loanId][asset] = principal;
            ls.outstandingPrincipal[basketId][asset] += principal;
            if (principalReceiver != address(0) && principal != 0) {
                LibCustody.pushReserved(custodyAccount, asset, principalReceiver, principal, principal);
            }
        }

        emit IStaticsLending.LoanOriginated(
            loanId, positionId, basketId, operator, eventReceiver, sharesIn, feeShares, collateralShares, maturity
        );
    }

    function quote(LibBasket.Basket storage configured, uint256 sharesIn)
        internal
        view
        returns (uint256 feeShares, uint256 collateralShares, address[] memory assets, uint256[] memory principals)
    {
        if (sharesIn == 0) {
            revert InvalidShares();
        }
        feeShares = Math.mulDiv(sharesIn, configured.originationFeeBps, LibBasket.BPS, Math.Rounding.Ceil);
        if (feeShares >= sharesIn) revert InvalidShares();
        collateralShares = sharesIn - feeShares;
        assets = configured.assets;
        uint256 length = assets.length;
        principals = new uint256[](length);
        bool hasPrincipal;
        for (uint256 i; i < length; ++i) {
            uint256 proportional = Math.mulDiv(configured.bundleAmounts[i], collateralShares, LibBasket.SHARE_SCALE);
            uint256 principal = Math.mulDiv(proportional, configured.ltvBps, LibBasket.BPS);
            principals[i] = principal;
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
