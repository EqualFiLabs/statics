// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IStaticsFlashBorrower} from "../interfaces/IStaticsFlashBorrower.sol";
import {IStaticsFlashLoan} from "../interfaces/IStaticsFlashLoan.sol";
import {LibBasket} from "../libraries/LibBasket.sol";
import {LibBasketRewards} from "../libraries/LibBasketRewards.sol";
import {LibCustody} from "../libraries/LibCustody.sol";
import {LibGovernance} from "../libraries/LibGovernance.sol";

contract FlashLoanFacet is IStaticsFlashLoan, ReentrancyGuard {
    bytes32 public constant CALLBACK_SUCCESS = keccak256("IStaticsFlashBorrower.onStaticsFlashLoan");

    error BasketNotFound(uint256 basketId);
    error InvalidShares();
    error InvalidReceiver();
    error ActionPaused(uint256 action);
    error InsufficientVaultBalance(address asset, uint256 required, uint256 available);
    error InvalidCallback(bytes32 result);
    error InsufficientRepayment(address asset, uint256 required, uint256 received);

    function flashLoan(uint256 basketId, uint256 shares, address receiver, bytes calldata data) external nonReentrant {
        _enforceNotPaused();
        if (receiver == address(0) || receiver.code.length == 0) revert InvalidReceiver();
        LibBasket.BasketStorage storage bs = LibBasket.basketStorage();
        LibBasket.Basket storage configured = _getBasket(bs, basketId);
        LibBasket.enforceActive(configured, basketId);
        (address[] memory assets, uint256[] memory amounts, uint256[] memory fees) = _quote(configured, shares);
        bytes32 custodyAccount = LibCustody.basketAccount(basketId);

        uint256 length = assets.length;
        for (uint256 i; i < length; ++i) {
            uint256 available = bs.vaultBalances[basketId][assets[i]];
            if (amounts[i] > available) revert InsufficientVaultBalance(assets[i], amounts[i], available);
            bs.vaultBalances[basketId][assets[i]] = available - amounts[i];
            if (amounts[i] != 0) {
                (, amounts[i]) = LibCustody.pushReserved(custodyAccount, assets[i], receiver, amounts[i], amounts[i]);
            }
        }

        bytes32 result =
            IStaticsFlashBorrower(receiver).onStaticsFlashLoan(msg.sender, basketId, assets, amounts, fees, data);
        if (result != CALLBACK_SUCCESS) revert InvalidCallback(result);

        for (uint256 i; i < length; ++i) {
            uint256 repayment = amounts[i] + fees[i];
            uint256 received =
                repayment == 0 ? 0 : LibCustody.pullAndReserve(custodyAccount, assets[i], receiver, repayment);
            if (received < amounts[i]) revert InsufficientRepayment(assets[i], amounts[i], received);
            fees[i] = received - amounts[i];
            bs.vaultBalances[basketId][assets[i]] += amounts[i];
            _distributeFee(bs, basketId, assets[i], fees[i]);
        }
        emit BasketFlashLoan(basketId, msg.sender, receiver, shares, amounts, fees);
    }

    function quoteFlashLoan(uint256 basketId, uint256 shares)
        external
        view
        returns (address[] memory assets, uint256[] memory amounts, uint256[] memory fees)
    {
        LibBasket.Basket storage configured = _getBasket(LibBasket.basketStorage(), basketId);
        return _quote(configured, shares);
    }

    function _quote(LibBasket.Basket storage configured, uint256 shares)
        private
        view
        returns (address[] memory assets, uint256[] memory amounts, uint256[] memory fees)
    {
        if (shares == 0) revert InvalidShares();
        assets = configured.assets;
        uint256 length = assets.length;
        amounts = new uint256[](length);
        fees = new uint256[](length);
        bool hasAmount;
        for (uint256 i; i < length; ++i) {
            uint256 amount = Math.mulDiv(configured.bundleAmounts[i], shares, LibBasket.SHARE_SCALE);
            amounts[i] = amount;
            fees[i] = Math.mulDiv(amount, configured.flashFeeBps, LibBasket.BPS, Math.Rounding.Ceil);
            hasAmount = hasAmount || amount != 0;
        }
        if (!hasAmount) revert InvalidShares();
    }

    function _distributeFee(LibBasket.BasketStorage storage bs, uint256 basketId, address asset, uint256 fee) private {
        LibBasketRewards.accrueFee(bs, basketId, asset, fee);
    }

    function _getBasket(LibBasket.BasketStorage storage bs, uint256 basketId)
        private
        view
        returns (LibBasket.Basket storage configured)
    {
        configured = bs.baskets[basketId];
        if (configured.token == address(0)) revert BasketNotFound(basketId);
    }

    function _enforceNotPaused() private view {
        if (LibGovernance.governanceStorage().pausedActions & LibGovernance.PAUSE_FLASH != 0) {
            revert ActionPaused(LibGovernance.PAUSE_FLASH);
        }
    }
}
