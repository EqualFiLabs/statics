// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IStaticsBasket} from "../interfaces/IStaticsBasket.sol";
import {IStaticsBasketCollateral} from "../interfaces/IStaticsBasketCollateral.sol";
import {StaticsBasketToken} from "../tokens/StaticsBasketToken.sol";
import {LibBasket} from "../libraries/LibBasket.sol";
import {LibBasketRewards} from "../libraries/LibBasketRewards.sol";
import {LibGlobalRewards} from "../libraries/LibGlobalRewards.sol";
import {LibCustody} from "../libraries/LibCustody.sol";
import {LibGovernance} from "../libraries/LibGovernance.sol";
import {LibMorpho} from "../libraries/LibMorpho.sol";
import {LibPosition} from "../position/LibPosition.sol";

contract BasketRedemptionFacet is ReentrancyGuard {
    error BasketNotFound(uint256 basketId);
    error InvalidReceiver();
    error InvalidShares();
    error InvalidAmountsLength();
    error MinimumOutputNotMet(address asset, uint256 actual, uint256 minimum);
    error ActionPaused(uint256 action);
    error InsufficientVaultBalance(address asset, uint256 required, uint256 available);

    struct RedeemSettlement {
        uint256 basketId;
        uint256 shares;
        uint256 supply;
        address receiver;
        bytes32 custodyAccount;
    }

    function redeem(uint256 basketId, uint256 shares, address receiver, uint256[] calldata minAmountsOut)
        external
        nonReentrant
        returns (uint256[] memory amountsOut)
    {
        if (shares == 0) revert InvalidShares();
        if (receiver == address(0)) revert InvalidReceiver();
        LibBasket.BasketStorage storage bs = LibBasket.basketStorage();
        LibBasket.Basket storage configured = _getBasket(bs, basketId);
        if (configured.status != IStaticsBasket.BasketStatus.ExitOnly) {
            _enforceNotPaused(LibGovernance.PAUSE_REDEEM);
        }
        if (minAmountsOut.length != configured.assets.length) revert InvalidAmountsLength();
        uint256 supply = IERC20(configured.token).totalSupply();
        if (shares > IERC20(configured.token).balanceOf(msg.sender)) revert InvalidShares();
        amountsOut = _quoteRedeem(bs, configured, basketId, shares, supply);

        StaticsBasketToken(configured.token).burn(msg.sender, shares);
        RedeemSettlement memory settlement = RedeemSettlement({
            basketId: basketId,
            shares: shares,
            supply: supply,
            receiver: receiver,
            custodyAccount: LibCustody.basketAccount(basketId)
        });
        _settleRedemption(bs, configured, settlement, minAmountsOut, amountsOut);
        emit IStaticsBasket.BasketRedeemed(basketId, msg.sender, receiver, shares);
    }

    function redeemBasketCollateral(
        uint256 positionId,
        uint256 basketId,
        uint256 shares,
        address receiver,
        uint256[] calldata minAmountsOut
    ) external nonReentrant returns (uint256[] memory amountsOut) {
        if (shares == 0) revert InvalidShares();
        if (receiver == address(0)) revert InvalidReceiver();
        LibPosition.enforceAuthorized(positionId, msg.sender);
        LibMorpho.syncIfInitialized(positionId, msg.sender);
        LibBasket.BasketStorage storage bs = LibBasket.basketStorage();
        LibBasket.Basket storage configured = _getBasket(bs, basketId);
        if (configured.status != IStaticsBasket.BasketStatus.ExitOnly) {
            _enforceNotPaused(LibGovernance.PAUSE_REDEEM);
        }
        if (minAmountsOut.length != configured.assets.length) revert InvalidAmountsLength();
        uint256 supply = IERC20(configured.token).totalSupply();
        amountsOut = _quoteRedeem(bs, configured, basketId, shares, supply);

        LibBasketRewards.decreasePosition(positionId, basketId, configured, shares);
        LibCustody.release(LibCustody.basketAccount(basketId), configured.token, shares);
        StaticsBasketToken(configured.token).burn(address(this), shares);
        RedeemSettlement memory settlement = RedeemSettlement({
            basketId: basketId,
            shares: shares,
            supply: supply,
            receiver: receiver,
            custodyAccount: LibCustody.basketAccount(basketId)
        });
        _settleRedemption(bs, configured, settlement, minAmountsOut, amountsOut);
        LibBasketRewards.deactivateIfEmpty(positionId, basketId);
        emit IStaticsBasket.BasketRedeemed(basketId, address(this), receiver, shares);
        emit IStaticsBasketCollateral.BasketCollateralRedeemed(positionId, basketId, receiver, shares);
    }

    function quoteRedeem(uint256 basketId, uint256 shares) external view returns (uint256[] memory amountsOut) {
        LibBasket.BasketStorage storage bs = LibBasket.basketStorage();
        LibBasket.Basket storage configured = _getBasket(bs, basketId);
        amountsOut = _quoteRedeem(bs, configured, basketId, shares, IERC20(configured.token).totalSupply());
    }

    function _settleRedemption(
        LibBasket.BasketStorage storage bs,
        LibBasket.Basket storage configured,
        RedeemSettlement memory settlement,
        uint256[] calldata minAmountsOut,
        uint256[] memory amountsOut
    ) private {
        uint256 length = configured.assets.length;
        for (uint256 i; i < length; ++i) {
            _redeemAsset(bs, configured, settlement, i, minAmountsOut[i], amountsOut[i]);
        }
    }

    function _redeemAsset(
        LibBasket.BasketStorage storage bs,
        LibBasket.Basket storage configured,
        RedeemSettlement memory settlement,
        uint256 index,
        uint256 minimumAmountOut,
        uint256 payout
    ) private {
        address asset = configured.assets[index];
        uint256 baseOut =
            LibBasket.backingReduction(configured.bundleAmounts[index], settlement.supply, settlement.shares);
        uint256 available = bs.vaultBalances[settlement.basketId][asset];
        if (baseOut > available) revert InsufficientVaultBalance(asset, baseOut, available);
        bs.vaultBalances[settlement.basketId][asset] = available - baseOut;
        LibGlobalRewards.accrueNonSwapFee(settlement.custodyAccount, asset, baseOut - payout);
        uint256 received;
        if (payout != 0) {
            (, received) =
                LibCustody.pushReserved(settlement.custodyAccount, asset, settlement.receiver, payout, payout);
        }
        if (received < minimumAmountOut) revert MinimumOutputNotMet(asset, received, minimumAmountOut);
    }

    function _quoteRedeem(
        LibBasket.BasketStorage storage bs,
        LibBasket.Basket storage configured,
        uint256 basketId,
        uint256 shares,
        uint256 supply
    ) private view returns (uint256[] memory amountsOut) {
        if (shares == 0 || shares > supply) revert InvalidShares();
        uint256 length = configured.assets.length;
        uint256 feeShares = LibBasket.selectFeeShares(configured.redemptionFeeTiers, shares);
        amountsOut = new uint256[](length);
        for (uint256 i; i < length; ++i) {
            address asset = configured.assets[i];
            uint256 bundleAmount = configured.bundleAmounts[i];
            uint256 baseOut = LibBasket.backingReduction(bundleAmount, supply, shares);
            uint256 available = bs.vaultBalances[basketId][asset];
            if (baseOut > available) revert InsufficientVaultBalance(asset, baseOut, available);
            uint256 fee = LibBasket.convertFeeShares(bundleAmount, feeShares);
            amountsOut[i] = fee < baseOut ? baseOut - fee : 0;
        }
    }

    function _getBasket(LibBasket.BasketStorage storage bs, uint256 basketId)
        private
        view
        returns (LibBasket.Basket storage configured)
    {
        configured = bs.baskets[basketId];
        if (configured.token == address(0)) revert BasketNotFound(basketId);
    }

    function _enforceNotPaused(uint256 action) private view {
        if (LibGovernance.governanceStorage().pausedActions & action != 0) revert ActionPaused(action);
    }
}
