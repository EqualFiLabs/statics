// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IStaticsBasket} from "../interfaces/IStaticsBasket.sol";
import {StaticsBasketToken} from "../tokens/StaticsBasketToken.sol";
import {LibBasket} from "./LibBasket.sol";
import {LibBasketRewards} from "./LibBasketRewards.sol";
import {LibCustody} from "./LibCustody.sol";
import {LibGovernance} from "./LibGovernance.sol";

library LibBasketMint {
    error BasketNotFound(uint256 basketId);
    error InvalidReceiver();
    error InvalidShares();
    error InvalidAmountsLength();
    error MaximumInputExceeded(address asset, uint256 required, uint256 maximum);
    error ActionPaused(uint256 action);
    error InsufficientTransferReceived(address asset, uint256 required, uint256 received);

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
        bytes32 custodyAccount = LibCustody.basketAccount(basketId);

        for (uint256 i; i < length; ++i) {
            address asset = configured.assets[i];
            uint256 required = amountsIn[i];
            if (required > maxAmountsIn[i]) revert MaximumInputExceeded(asset, required, maxAmountsIn[i]);
            uint256 baseIn = LibBasket.backingIncrease(configured.bundleAmounts[i], supply, shares);
            uint256 received = LibCustody.pullAndReserve(custodyAccount, asset, payer, required);
            if (received < baseIn) revert InsufficientTransferReceived(asset, baseIn, received);
            amountsIn[i] = received;
            bs.vaultBalances[basketId][asset] += baseIn;
            LibBasketRewards.accrueFee(bs, basketId, asset, received - baseIn);
        }
        StaticsBasketToken(configured.token).mint(receiver, shares);
        emit IStaticsBasket.BasketMinted(basketId, payer, receiver, shares);
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
            LibBasketRewards.accrueFee(bs, basketId, asset, amountsIn[i] - baseIn);
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
