// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IStaticsLending} from "../interfaces/IStaticsLending.sol";
import {StaticsBasketToken} from "../tokens/StaticsBasketToken.sol";
import {LibBasket} from "../libraries/LibBasket.sol";
import {LibBasketRewards} from "../libraries/LibBasketRewards.sol";
import {LibGlobalRewards} from "../libraries/LibGlobalRewards.sol";
import {LibCustody} from "../libraries/LibCustody.sol";
import {LibGovernance} from "../libraries/LibGovernance.sol";
import {LibLending} from "../libraries/LibLending.sol";
import {LibLoanOrigination} from "../libraries/LibLoanOrigination.sol";
import {LibPosition} from "../position/LibPosition.sol";

contract LendingFacet is IStaticsLending, ReentrancyGuard {
    error BasketNotFound(uint256 basketId);
    error LoanNotFound(uint256 loanId);
    error ActionPaused(uint256 action);
    error InsufficientVaultBalance(address asset, uint256 required, uint256 available);
    error LoanExpired(uint256 loanId, uint40 maturity);
    error LoanNotRecoverable(uint256 loanId, uint256 recoverableAt);
    error MaturityOverflow();
    error InsufficientTransferReceived(address asset, uint256 required, uint256 received);
    error InvalidExtensionInputLength(uint256 provided, uint256 required);

    function borrow(uint256 positionId, uint256 basketId, uint256 sharesIn, address receiver)
        external
        nonReentrant
        returns (uint256 loanId, uint256[] memory principals)
    {
        return LibLoanOrigination.originate(positionId, basketId, sharesIn, msg.sender, receiver, receiver);
    }

    function repay(uint256 loanId) external nonReentrant {
        LibLending.LendingStorage storage ls = LibLending.lendingStorage();
        LibLending.Loan memory current = _getLoan(ls, loanId);
        LibBasket.BasketStorage storage bs = LibBasket.basketStorage();
        LibBasket.Basket storage configured = _getBasket(bs, current.basketId);
        bytes32 custodyAccount = LibCustody.basketAccount(current.basketId);

        uint256 length = configured.assets.length;
        for (uint256 i; i < length; ++i) {
            address asset = configured.assets[i];
            uint256 principal = ls.principals[loanId][asset];
            uint256 received =
                principal == 0 ? 0 : LibCustody.pullAndReserve(custodyAccount, asset, msg.sender, principal);
            if (received < principal) revert InsufficientTransferReceived(asset, principal, received);
            bs.vaultBalances[current.basketId][asset] += principal;
            LibGlobalRewards.accrueNonSwapFee(custodyAccount, asset, received - principal);
            ls.outstandingPrincipal[current.basketId][asset] -= principal;
            delete ls.principals[loanId][asset];
        }
        delete ls.loans[loanId];
        LibBasketRewards.unlockAfterRepay(current.positionId, current.basketId, configured, current.collateralShares);
        emit LoanRepaid(loanId, current.positionId, msg.sender);
    }

    function extend(uint256 loanId, uint256[] calldata grossAmountsIn)
        external
        nonReentrant
        returns (uint256[] memory receivedAmounts)
    {
        _enforceNotPaused(LibGovernance.PAUSE_EXTEND);
        LibLending.LendingStorage storage ls = LibLending.lendingStorage();
        LibLending.Loan storage current = _getLoanStorage(ls, loanId);
        LibPosition.enforceAuthorized(current.positionId, msg.sender);
        if (block.timestamp > current.maturity) revert LoanExpired(loanId, current.maturity);

        LibBasket.BasketStorage storage bs = LibBasket.basketStorage();
        LibBasket.Basket storage configured = _getBasket(bs, current.basketId);
        LibBasket.enforceActive(configured, current.basketId);
        uint256 length = configured.assets.length;
        if (grossAmountsIn.length != length) revert InvalidExtensionInputLength(grossAmountsIn.length, length);

        receivedAmounts = new uint256[](length);
        bytes32 custodyAccount = LibCustody.basketAccount(current.basketId);
        for (uint256 i; i < length; ++i) {
            address asset = configured.assets[i];
            uint256 requiredFee = Math.mulDiv(
                ls.principals[loanId][asset], configured.extensionFeeBps, LibBasket.BPS, Math.Rounding.Ceil
            );
            uint256 grossAmount = grossAmountsIn[i];
            uint256 received =
                grossAmount == 0 ? 0 : LibCustody.pullAndReserve(custodyAccount, asset, msg.sender, grossAmount);
            if (received < requiredFee) revert InsufficientTransferReceived(asset, requiredFee, received);
            receivedAmounts[i] = received;
            LibGlobalRewards.accrueNonSwapFee(custodyAccount, asset, received);
            emit LoanExtensionFeePaid(loanId, asset, requiredFee, received);
        }

        uint256 maturityValue = uint256(current.maturity) + configured.loanDuration;
        if (maturityValue > type(uint40).max) revert MaturityOverflow();
        // forge-lint: disable-next-line(unsafe-typecast)
        current.maturity = uint40(maturityValue);
        emit LoanExtended(loanId, current.maturity);
    }

    function recover(uint256 loanId) external nonReentrant {
        LibLending.LendingStorage storage ls = LibLending.lendingStorage();
        LibLending.Loan memory current = _getLoan(ls, loanId);
        LibBasket.BasketStorage storage bs = LibBasket.basketStorage();
        LibBasket.Basket storage configured = _getBasket(bs, current.basketId);
        RecoveryQuote memory quoted = _quoteRecovery(ls, loanId, current, configured);
        if (block.timestamp <= quoted.recoverableAt) {
            revert LoanNotRecoverable(loanId, quoted.recoverableAt);
        }

        LibBasketRewards.releaseAfterRecovery(
            current.positionId, current.basketId, configured, current.collateralShares, quoted.burnShares
        );
        bytes32 custodyAccount = LibCustody.basketAccount(current.basketId);
        uint256 length = configured.assets.length;
        for (uint256 i; i < length; ++i) {
            address asset = configured.assets[i];
            uint256 principal = ls.principals[loanId][asset];
            ls.outstandingPrincipal[current.basketId][asset] -= principal;
            delete ls.principals[loanId][asset];
            uint256 callerAmount = quoted.callerAmounts[i];
            uint256 protocolAmount = quoted.protocolAmounts[i];
            uint256 reclassified = callerAmount + protocolAmount;
            uint256 available = bs.vaultBalances[current.basketId][asset];
            if (reclassified > available) revert InsufficientVaultBalance(asset, reclassified, available);
            bs.vaultBalances[current.basketId][asset] = available - reclassified;
            uint256 callerReceived;
            if (callerAmount != 0) {
                (, callerReceived) =
                    LibCustody.pushReserved(custodyAccount, asset, msg.sender, callerAmount, callerAmount);
            }
            LibGlobalRewards.accrueNonSwapFee(custodyAccount, asset, protocolAmount);
            emit RecoveryPenaltyDistributed(loanId, asset, callerAmount, callerReceived, protocolAmount);
        }
        delete ls.loans[loanId];
        LibCustody.release(custodyAccount, configured.token, quoted.burnShares);
        StaticsBasketToken(configured.token).burn(address(this), quoted.burnShares);
        LibBasketRewards.deactivateIfEmpty(current.positionId, current.basketId);
        emit LoanRecovered(loanId, current.positionId, msg.sender, quoted.burnShares, quoted.unlockedShares);
    }

    function quoteBorrow(uint256 basketId, uint256 sharesIn) external view returns (BorrowQuote memory result) {
        LibBasket.Basket storage configured = _getBasket(LibBasket.basketStorage(), basketId);
        return LibLoanOrigination.quote(configured, sharesIn);
    }

    function quoteRecovery(uint256 loanId) external view returns (RecoveryQuote memory result) {
        LibLending.LendingStorage storage ls = LibLending.lendingStorage();
        LibLending.Loan memory current = _getLoan(ls, loanId);
        LibBasket.Basket storage configured = _getBasket(LibBasket.basketStorage(), current.basketId);
        return _quoteRecovery(ls, loanId, current, configured);
    }

    function quoteExtension(uint256 loanId)
        external
        view
        returns (address[] memory assets, uint256[] memory requiredFees)
    {
        LibLending.LendingStorage storage ls = LibLending.lendingStorage();
        LibLending.Loan storage current = _getLoanStorage(ls, loanId);
        LibBasket.Basket storage configured = _getBasket(LibBasket.basketStorage(), current.basketId);
        assets = configured.assets;
        uint256 length = assets.length;
        requiredFees = new uint256[](length);
        for (uint256 i; i < length; ++i) {
            requiredFees[i] = Math.mulDiv(
                ls.principals[loanId][assets[i]], configured.extensionFeeBps, LibBasket.BPS, Math.Rounding.Ceil
            );
        }
    }

    function loan(uint256 loanId) external view returns (LoanView memory result) {
        LibLending.LendingStorage storage ls = LibLending.lendingStorage();
        LibLending.Loan storage current = _getLoanStorage(ls, loanId);
        LibBasket.Basket storage configured = _getBasket(LibBasket.basketStorage(), current.basketId);
        uint256 length = configured.assets.length;
        uint256[] memory principals = new uint256[](length);
        for (uint256 i; i < length; ++i) {
            principals[i] = ls.principals[loanId][configured.assets[i]];
        }
        result = LoanView({
            positionId: current.positionId,
            basketId: current.basketId,
            collateralShares: current.collateralShares,
            feeShares: current.feeShares,
            debtShares: current.debtShares,
            penaltyShares: current.penaltyShares,
            maturity: current.maturity,
            assets: configured.assets,
            principals: principals
        });
    }

    function outstandingPrincipal(uint256 basketId, address asset) external view returns (uint256) {
        return LibLending.lendingStorage().outstandingPrincipal[basketId][asset];
    }

    function _getBasket(LibBasket.BasketStorage storage bs, uint256 basketId)
        private
        view
        returns (LibBasket.Basket storage configured)
    {
        configured = bs.baskets[basketId];
        if (configured.token == address(0)) revert BasketNotFound(basketId);
    }

    function _getLoan(LibLending.LendingStorage storage ls, uint256 loanId)
        private
        view
        returns (LibLending.Loan memory current)
    {
        LibLending.Loan storage stored = _getLoanStorage(ls, loanId);
        current = stored;
    }

    function _getLoanStorage(LibLending.LendingStorage storage ls, uint256 loanId)
        private
        view
        returns (LibLending.Loan storage current)
    {
        current = ls.loans[loanId];
        if (current.positionId == 0) revert LoanNotFound(loanId);
    }

    function _quoteRecovery(
        LibLending.LendingStorage storage ls,
        uint256 loanId,
        LibLending.Loan memory current,
        LibBasket.Basket storage configured
    ) private view returns (RecoveryQuote memory result) {
        result.recoverableAt =
            uint256(current.maturity) + LibLending.RECOVERY_GRACE_PERIOD;
        result.burnShares = current.debtShares + current.penaltyShares;
        result.unlockedShares = current.collateralShares - result.burnShares;
        result.assets = configured.assets;
        uint256 length = result.assets.length;
        result.callerAmounts = new uint256[](length);
        result.protocolAmounts = new uint256[](length);
        uint256 supply = IERC20(configured.token).totalSupply();
        for (uint256 i; i < length; ++i) {
            uint256 backingRemoved = LibBasket.backingReduction(configured.bundleAmounts[i], supply, result.burnShares);
            uint256 penaltyAmount = backingRemoved - ls.principals[loanId][result.assets[i]];
            uint256 callerAmount = Math.mulDiv(penaltyAmount, LibLending.RECOVERY_CALLER_SHARE_BPS, LibBasket.BPS);
            result.callerAmounts[i] = callerAmount;
            result.protocolAmounts[i] = penaltyAmount - callerAmount;
        }
    }

    function _enforceNotPaused(uint256 action) private view {
        if (LibGovernance.governanceStorage().pausedActions & action != 0) revert ActionPaused(action);
    }
}
