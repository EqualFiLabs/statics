// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IStaticsBasket} from "../interfaces/IStaticsBasket.sol";
import {StaticsBasketToken} from "../tokens/StaticsBasketToken.sol";
import {LibBasket} from "./LibBasket.sol";
import {LibGlobalRewards} from "./LibGlobalRewards.sol";
import {LibCustody} from "./LibCustody.sol";
import {LibGovernance} from "./LibGovernance.sol";

library LibBasketMint {
    error BasketNotFound(uint256 basketId);
    error InvalidReceiver();
    error InvalidShares();
    error InvalidAmountsLength();
    error MaximumInputExceeded(address asset, uint256 required, uint256 maximum);
    error InsufficientTransferReceived(address asset, uint256 required, uint256 received);
    error ActionPaused(uint256 action);

    struct MintSettlement {
        uint256 basketId;
        uint256 shares;
        uint256 supply;
        address payer;
        bytes32 custodyAccount;
    }

    function mintFromPayer(
        uint256 basketId,
        uint256 shares,
        address payer,
        address receiver,
        uint256[] memory maxAmountsIn
    ) internal returns (uint256[] memory amountsIn) {
        if (LibGovernance.governanceStorage().pausedActions & LibGovernance.PAUSE_MINT != 0) {
            revert ActionPaused(LibGovernance.PAUSE_MINT);
        }
        if (shares == 0) revert InvalidShares();
        if (receiver == address(0)) revert InvalidReceiver();
        LibBasket.BasketStorage storage bs = LibBasket.basketStorage();
        LibBasket.Basket storage configured = basket(bs, basketId);
        LibBasket.enforceActive(configured, basketId);
        uint256 length = configured.assets.length;
        if (maxAmountsIn.length != length) revert InvalidAmountsLength();
        uint256 supply = IERC20(configured.token).totalSupply();
        amountsIn = quote(configured, shares, supply);
        MintSettlement memory settlement =
            MintSettlement(basketId, shares, supply, payer, LibCustody.basketAccount(basketId));

        for (uint256 i; i < length; ++i) {
            _pullAsset(bs, configured, settlement, maxAmountsIn, amountsIn, i);
        }
        StaticsBasketToken(configured.token).mint(receiver, shares);
        emit IStaticsBasket.BasketMinted(basketId, payer, receiver, shares);
    }

    function _pullAsset(
        LibBasket.BasketStorage storage bs,
        LibBasket.Basket storage configured,
        MintSettlement memory settlement,
        uint256[] memory maxAmountsIn,
        uint256[] memory amountsIn,
        uint256 index
    ) private {
        address asset = configured.assets[index];
        uint256 required = amountsIn[index];
        if (required > maxAmountsIn[index]) revert MaximumInputExceeded(asset, required, maxAmountsIn[index]);
        uint256 baseIn =
            LibBasket.backingIncrease(configured.bundleAmounts[index], settlement.supply, settlement.shares);
        uint256 received = LibCustody.pullAndReserve(settlement.custodyAccount, asset, settlement.payer, required);
        if (received < baseIn) revert InsufficientTransferReceived(asset, baseIn, received);
        amountsIn[index] = received;
        bs.vaultBalances[settlement.basketId][asset] += baseIn;
        LibGlobalRewards.accrueNonSwapFee(settlement.custodyAccount, asset, received - baseIn);
    }

    function mintFromRetainedPrincipal(uint256 basketId, uint256 shares, address payer, address receiver)
        internal
        returns (uint256[] memory amountsIn)
    {
        if (LibGovernance.governanceStorage().pausedActions & LibGovernance.PAUSE_MINT != 0) {
            revert ActionPaused(LibGovernance.PAUSE_MINT);
        }
        if (shares == 0) revert InvalidShares();
        if (receiver == address(0)) revert InvalidReceiver();
        LibBasket.BasketStorage storage bs = LibBasket.basketStorage();
        LibBasket.Basket storage configured = basket(bs, basketId);
        LibBasket.enforceActive(configured, basketId);
        uint256 supply = IERC20(configured.token).totalSupply();
        amountsIn = quote(configured, shares, supply);
        uint256 length = configured.assets.length;
        for (uint256 i; i < length; ++i) {
            address asset = configured.assets[i];
            uint256 baseIn = LibBasket.backingIncrease(configured.bundleAmounts[i], supply, shares);
            bs.vaultBalances[basketId][asset] += baseIn;
            LibGlobalRewards.accrueNonSwapFee(LibCustody.basketAccount(basketId), asset, amountsIn[i] - baseIn);
        }
        StaticsBasketToken(configured.token).mint(receiver, shares);
        emit IStaticsBasket.BasketMinted(basketId, payer, receiver, shares);
    }

    function quote(LibBasket.Basket storage configured, uint256 shares, uint256 supply)
        internal
        view
        returns (uint256[] memory amountsIn)
    {
        if (shares == 0) revert InvalidShares();
        uint256 length = configured.assets.length;
        uint256 feeShares = LibBasket.selectFeeShares(configured.mintFeeTiers, shares);
        amountsIn = new uint256[](length);
        for (uint256 i; i < length; ++i) {
            uint256 bundleAmount = configured.bundleAmounts[i];
            amountsIn[i] = LibBasket.backingIncrease(bundleAmount, supply, shares)
                + LibBasket.convertFeeShares(bundleAmount, feeShares);
        }
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
