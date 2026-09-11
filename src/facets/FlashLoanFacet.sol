// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {StorageSlot} from "@openzeppelin/contracts/utils/StorageSlot.sol";
import {IStaticsFlashAssetBorrower} from "../interfaces/IStaticsFlashAssetBorrower.sol";
import {IStaticsFlashBorrower} from "../interfaces/IStaticsFlashBorrower.sol";
import {IStaticsFlashLoan} from "../interfaces/IStaticsFlashLoan.sol";
import {LibBasket} from "../libraries/LibBasket.sol";
import {LibCustody} from "../libraries/LibCustody.sol";
import {LibDiamond} from "../libraries/LibDiamond.sol";
import {LibFlashLoan} from "../libraries/LibFlashLoan.sol";
import {LibGlobalRewards} from "../libraries/LibGlobalRewards.sol";
import {LibGovernance} from "../libraries/LibGovernance.sol";

contract FlashLoanFacet is IStaticsFlashLoan, ReentrancyGuardTransient {
    using StorageSlot for bytes32;

    bytes32 public constant CALLBACK_SUCCESS = keccak256("IStaticsFlashBorrower.onStaticsFlashLoan");
    bytes32 public constant ASSET_CALLBACK_SUCCESS = keccak256("IStaticsFlashAssetBorrower.onStaticsFlashLoanAsset");
    // OpenZeppelin ReentrancyGuard's ERC-7201 slot. Transfer phases acquire the
    // same persistent lock as the ordinary Diamond facets; the explicit
    // receiver callback runs only under the transient flash lock.
    bytes32 private constant PERSISTENT_REENTRANCY_GUARD_STORAGE =
        0x9b779b17422d0df92223018b32b4d1fa46e071723d6817e2486d003becc55f00;
    uint256 private constant PERSISTENT_NOT_ENTERED = 1;
    uint256 private constant PERSISTENT_ENTERED = 2;

    error BasketNotFound(uint256 basketId);
    error InvalidShares();
    error InvalidAmount();
    error InvalidAsset(address asset);
    error InvalidReceiver();
    error ActionPaused(uint256 action);
    error InsufficientFlashLiquidity(address asset, uint256 required, uint256 available);
    error InvalidCallback(bytes32 result);
    error InsufficientRepayment(address asset, uint256 required, uint256 received);
    error IncompatibleFlashAsset(address asset, uint256 expected, uint256 spent, uint256 received);

    enum CallbackKind {
        Basket,
        Asset
    }

    struct FlashContext {
        address initiator;
        address receiver;
        uint256 basketId;
        CallbackKind callbackKind;
    }

    function flashLoan(uint256 basketId, uint256 shares, address receiver, bytes calldata data) external nonReentrant {
        _enforceNotPaused();
        _enforceValidReceiver(receiver);
        LibBasket.Basket storage configured = _getBasket(LibBasket.basketStorage(), basketId);
        LibBasket.enforceActive(configured, basketId);
        (address[] memory assets, uint256[] memory amounts, uint256[] memory fees) = _quote(configured, shares);
        _executeFlash(assets, amounts, fees, FlashContext(msg.sender, receiver, basketId, CallbackKind.Basket), data);
        emit BasketFlashLoan(basketId, msg.sender, receiver, shares, amounts, fees);
    }

    function flashLoanAsset(address asset, uint256 amount, address receiver, bytes calldata data)
        external
        nonReentrant
    {
        _enforceNotPaused();
        _enforceValidAsset(asset);
        _enforceValidReceiver(receiver);
        if (amount == 0) revert InvalidAmount();
        address[] memory assets = new address[](1);
        assets[0] = asset;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;
        uint256 fee = _quoteFlashLoanAsset(amount);
        uint256[] memory fees = new uint256[](1);
        fees[0] = fee;
        _executeFlash(assets, amounts, fees, FlashContext(msg.sender, receiver, 0, CallbackKind.Asset), data);
        emit AssetFlashLoan(asset, msg.sender, receiver, amount, fee);
    }

    function quoteFlashLoan(uint256 basketId, uint256 shares)
        external
        view
        returns (address[] memory assets, uint256[] memory amounts, uint256[] memory fees)
    {
        LibBasket.Basket storage configured = _getBasket(LibBasket.basketStorage(), basketId);
        return _quote(configured, shares);
    }

    function quoteFlashLoanAsset(address asset, uint256 amount) external view returns (uint256 fee) {
        _enforceValidAsset(asset);
        if (amount == 0) revert InvalidAmount();
        return _quoteFlashLoanAsset(amount);
    }

    function maxFlashLoan(address asset) external view returns (uint256) {
        _enforceValidAsset(asset);
        return IERC20(asset).balanceOf(address(this));
    }

    function singleAssetFlashFeeBps() external view returns (uint16) {
        return LibFlashLoan.singleAssetFlashFeeBps();
    }

    function setSingleAssetFlashFeeBps(uint16 newFeeBps) external {
        LibDiamond.enforceIsContractOwner();
        LibFlashLoan.setSingleAssetFlashFeeBps(newFeeBps);
    }

    function _executeFlash(
        address[] memory assets,
        uint256[] memory amounts,
        uint256[] memory fees,
        FlashContext memory context,
        bytes calldata data
    ) private {
        uint256 length = assets.length;
        uint256[] memory startingUnreserved = new uint256[](length);
        _enterPersistentGuard();
        for (uint256 i; i < length; ++i) {
            startingUnreserved[i] = _lendAsset(assets[i], amounts[i], context.receiver);
        }
        _exitPersistentGuard();

        bytes32 result = _invokeCallback(context, assets, amounts, fees, data);
        bytes32 expected = context.callbackKind == CallbackKind.Basket ? CALLBACK_SUCCESS : ASSET_CALLBACK_SUCCESS;
        if (result != expected) revert InvalidCallback(result);

        _enterPersistentGuard();
        for (uint256 i; i < length; ++i) {
            _collectRepayment(assets[i], amounts[i], fees[i], startingUnreserved[i], context.receiver);
        }
        _exitPersistentGuard();
    }

    function _lendAsset(address asset, uint256 amount, address receiver) private returns (uint256 startingUnreserved) {
        uint256 startingBalance = IERC20(asset).balanceOf(address(this));
        uint256 startingReserved = LibCustody.globalReserved(asset);
        if (startingBalance < startingReserved) {
            revert LibCustody.GlobalReservationShortfall(asset, startingReserved, startingBalance);
        }
        startingUnreserved = startingBalance - startingReserved;
        if (amount > startingBalance) revert InsufficientFlashLiquidity(asset, amount, startingBalance);
        if (amount == 0) return startingUnreserved;
        (uint256 spent, uint256 received) = LibCustody.pushFlash(asset, receiver, amount);
        if (spent != amount || received != amount) {
            revert IncompatibleFlashAsset(asset, amount, spent, received);
        }
    }

    function _collectRepayment(address asset, uint256 amount, uint256 fee, uint256 startingUnreserved, address receiver)
        private
    {
        uint256 repayment = amount + fee;
        if (repayment != 0) {
            (uint256 spent, uint256 received) = LibCustody.pullFlash(asset, receiver, repayment);
            if (spent != repayment || received != repayment) {
                revert IncompatibleFlashAsset(asset, repayment, spent, received);
            }
        }
        uint256 endingBalance = IERC20(asset).balanceOf(address(this));
        uint256 requiredBalance = LibCustody.globalReserved(asset) + startingUnreserved + fee;
        if (endingBalance < requiredBalance) {
            revert InsufficientRepayment(asset, requiredBalance, endingBalance);
        }
        LibGlobalRewards.accrueUnreservedNonSwapFee(asset, fee);
    }

    function _invokeCallback(
        FlashContext memory context,
        address[] memory assets,
        uint256[] memory amounts,
        uint256[] memory fees,
        bytes calldata data
    ) private returns (bytes32) {
        if (context.callbackKind == CallbackKind.Basket) {
            return IStaticsFlashBorrower(context.receiver)
                .onStaticsFlashLoan(context.initiator, context.basketId, assets, amounts, fees, data);
        }
        return IStaticsFlashAssetBorrower(context.receiver)
            .onStaticsFlashLoanAsset(context.initiator, assets[0], amounts[0], fees[0], data);
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

    function _quoteFlashLoanAsset(uint256 amount) private view returns (uint256) {
        return Math.mulDiv(amount, LibFlashLoan.singleAssetFlashFeeBps(), LibFlashLoan.BPS, Math.Rounding.Ceil);
    }

    function _getBasket(LibBasket.BasketStorage storage bs, uint256 basketId)
        private
        view
        returns (LibBasket.Basket storage configured)
    {
        configured = bs.baskets[basketId];
        if (configured.token == address(0)) revert BasketNotFound(basketId);
    }

    function _enforceValidAsset(address asset) private view {
        if (asset == address(0) || asset == address(this) || asset.code.length == 0) revert InvalidAsset(asset);
    }

    function _enforceValidReceiver(address receiver) private view {
        if (receiver == address(0) || receiver.code.length == 0) revert InvalidReceiver();
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
