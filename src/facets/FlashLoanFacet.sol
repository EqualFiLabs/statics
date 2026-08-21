// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {StorageSlot} from "@openzeppelin/contracts/utils/StorageSlot.sol";
import {IStaticsFlashBorrower} from "../interfaces/IStaticsFlashBorrower.sol";
import {IStaticsFlashLoan} from "../interfaces/IStaticsFlashLoan.sol";
import {LibBasket} from "../libraries/LibBasket.sol";
import {LibGlobalRewards} from "../libraries/LibGlobalRewards.sol";
import {LibCustody} from "../libraries/LibCustody.sol";
import {LibGovernance} from "../libraries/LibGovernance.sol";

contract FlashLoanFacet is IStaticsFlashLoan, ReentrancyGuardTransient {
    using StorageSlot for bytes32;

    bytes32 public constant CALLBACK_SUCCESS = keccak256("IStaticsFlashBorrower.onStaticsFlashLoan");
    // OpenZeppelin ReentrancyGuard's ERC-7201 slot. Transfer phases acquire the
    // same persistent lock as the ordinary Diamond facets; the explicit
    // receiver callback runs only under the transient flash lock.
    bytes32 private constant PERSISTENT_REENTRANCY_GUARD_STORAGE =
        0x9b779b17422d0df92223018b32b4d1fa46e071723d6817e2486d003becc55f00;
    uint256 private constant PERSISTENT_NOT_ENTERED = 1;
    uint256 private constant PERSISTENT_ENTERED = 2;

    error BasketNotFound(uint256 basketId);
    error InvalidShares();
    error InvalidReceiver();
    error ActionPaused(uint256 action);
    error InsufficientVaultBalance(address asset, uint256 required, uint256 available);
    error InvalidCallback(bytes32 result);
    error InsufficientRepayment(address asset, uint256 required, uint256 received);
    error IncompatibleFlashAsset(address asset, uint256 expected, uint256 spent, uint256 received);

    struct FlashContext {
        uint256 basketId;
        bytes32 custodyAccount;
        address receiver;
    }

    function flashLoan(uint256 basketId, uint256 shares, address receiver, bytes calldata data) external nonReentrant {
        _enforceNotPaused();
        if (receiver == address(0) || receiver.code.length == 0) revert InvalidReceiver();
        LibBasket.BasketStorage storage bs = LibBasket.basketStorage();
        address[] memory assets;
        uint256[] memory amounts;
        uint256[] memory fees;
        {
            LibBasket.Basket storage configured = _getBasket(bs, basketId);
            LibBasket.enforceActive(configured, basketId);
            (assets, amounts, fees) = _quote(configured, shares);
        }
        FlashContext memory ctx = FlashContext(basketId, LibCustody.basketAccount(basketId), receiver);

        uint256 length = assets.length;
        _enterPersistentGuard();
        for (uint256 i; i < length; ++i) {
            _lendAsset(bs, ctx, assets, amounts, i);
        }
        _exitPersistentGuard();

        bytes32 result =
            IStaticsFlashBorrower(receiver).onStaticsFlashLoan(msg.sender, basketId, assets, amounts, fees, data);
        if (result != CALLBACK_SUCCESS) revert InvalidCallback(result);

        _enterPersistentGuard();
        for (uint256 i; i < length; ++i) {
            _collectRepayment(bs, ctx, assets, amounts, fees, i);
        }
        _exitPersistentGuard();
        emit BasketFlashLoan(basketId, msg.sender, receiver, shares, amounts, fees);
    }

    function _lendAsset(
        LibBasket.BasketStorage storage bs,
        FlashContext memory ctx,
        address[] memory assets,
        uint256[] memory amounts,
        uint256 index
    ) private {
        address asset = assets[index];
        uint256 amount = amounts[index];
        uint256 available = bs.vaultBalances[ctx.basketId][asset];
        if (amount > available) revert InsufficientVaultBalance(asset, amount, available);
        bs.vaultBalances[ctx.basketId][asset] = available - amount;
        if (amount != 0) {
            (uint256 spent, uint256 received) =
                LibCustody.pushReserved(ctx.custodyAccount, asset, ctx.receiver, amount, amount);
            if (spent != amount || received != amount) {
                revert IncompatibleFlashAsset(asset, amount, spent, received);
            }
        }
    }

    function _collectRepayment(
        LibBasket.BasketStorage storage bs,
        FlashContext memory ctx,
        address[] memory assets,
        uint256[] memory amounts,
        uint256[] memory fees,
        uint256 index
    ) private {
        address asset = assets[index];
        uint256 amount = amounts[index];
        uint256 repayment = amount + fees[index];
        uint256 received =
            repayment == 0 ? 0 : LibCustody.pullAndReserve(ctx.custodyAccount, asset, ctx.receiver, repayment);
        if (received < amount) revert InsufficientRepayment(asset, amount, received);
        fees[index] = received - amount;
        bs.vaultBalances[ctx.basketId][asset] += amount;
        LibGlobalRewards.accrueNonSwapFee(ctx.custodyAccount, asset, fees[index]);
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

    function _enterPersistentGuard() private {
        StorageSlot.Uint256Slot storage guard = PERSISTENT_REENTRANCY_GUARD_STORAGE.getUint256Slot();
        if (guard.value == PERSISTENT_ENTERED) revert ReentrancyGuardReentrantCall();
        guard.value = PERSISTENT_ENTERED;
    }

    function _exitPersistentGuard() private {
        PERSISTENT_REENTRANCY_GUARD_STORAGE.getUint256Slot().value = PERSISTENT_NOT_ENTERED;
    }
}
