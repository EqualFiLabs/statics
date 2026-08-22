// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IStaticsBasket} from "../interfaces/IStaticsBasket.sol";
import {LibBasket} from "../libraries/LibBasket.sol";

contract BasketViewFacet {
    error BasketNotFound(uint256 basketId);

    function basket(uint256 basketId) external view returns (IStaticsBasket.BasketView memory result) {
        LibBasket.Basket storage configured = _getBasket(LibBasket.basketStorage(), basketId);
        result.token = configured.token;
        result.creator = configured.creator;
        result.status = configured.status;
        result.assets = configured.assets;
        result.bundleAmounts = configured.bundleAmounts;
        result.mintFeeTiers = configured.mintFeeTiers;
        result.redemptionFeeTiers = configured.redemptionFeeTiers;
        result.flashFeeBps = configured.flashFeeBps;
        result.originationFeeBps = configured.originationFeeBps;
        result.extensionFeeBps = configured.extensionFeeBps;
        result.ltvBps = configured.ltvBps;
        result.recoveryPenaltyBps = configured.recoveryPenaltyBps;
        result.loanDuration = configured.loanDuration;
    }

    function basketStatus(uint256 basketId) external view returns (IStaticsBasket.BasketStatus) {
        return _getBasket(LibBasket.basketStorage(), basketId).status;
    }

    function basketCount() external view returns (uint256) {
        return LibBasket.basketStorage().basketCount;
    }

    function basketIdOf(address token) external view returns (uint256 basketId, bool exists) {
        uint256 plusOne = LibBasket.basketStorage().basketIds[token];
        return plusOne == 0 ? (0, false) : (plusOne - 1, true);
    }

    function vaultBalance(uint256 basketId, address asset) external view returns (uint256) {
        return LibBasket.basketStorage().vaultBalances[basketId][asset];
    }

    function feeSharesFor(uint256 basketId, bool mintAction, uint256 actionShares)
        external
        view
        returns (uint256 feeShares)
    {
        LibBasket.Basket storage configured = _getBasket(LibBasket.basketStorage(), basketId);
        return
            LibBasket.selectFeeShares(
                mintAction ? configured.mintFeeTiers : configured.redemptionFeeTiers, actionShares
            );
    }

    function _getBasket(LibBasket.BasketStorage storage bs, uint256 basketId)
        private
        view
        returns (LibBasket.Basket storage configured)
    {
        configured = bs.baskets[basketId];
        if (configured.token == address(0)) revert BasketNotFound(basketId);
    }
}
