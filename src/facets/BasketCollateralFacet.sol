// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IStaticsBasketCollateral} from "../interfaces/IStaticsBasketCollateral.sol";
import {IStaticsPositionModule} from "../interfaces/IStaticsPosition.sol";
import {LibBasket} from "../libraries/LibBasket.sol";
import {LibBasketCollateral} from "../libraries/LibBasketCollateral.sol";
import {LibBasketRewards} from "../libraries/LibBasketRewards.sol";
import {LibCustody} from "../libraries/LibCustody.sol";
import {LibMorpho} from "../libraries/LibMorpho.sol";
import {LibPosition} from "../position/LibPosition.sol";

contract BasketCollateralFacet is ReentrancyGuard {
    error BasketNotFound(uint256 basketId);
    error InvalidShares();
    error InvalidReceiver();
    error InsufficientTransferReceived(address token, uint256 required, uint256 received);

    function createAndDepositBasketCollateral(uint256 basketId, uint256 shares, address receiver)
        external
        payable
        nonReentrant
        returns (uint256 positionId)
    {
        if (shares == 0) revert InvalidShares();
        if (receiver == address(0)) revert InvalidReceiver();
        LibBasket.Basket storage configured = _getBasket(LibBasket.basketStorage(), basketId);
        LibBasket.enforceActive(configured, basketId);
        positionId = IStaticsPositionModule(address(this)).createPositionForModule{value: msg.value}(
            receiver, LibPosition.BASKET_MODULE, bytes32(basketId)
        );
        _pullBasketToken(configured, basketId, shares);
        LibBasketRewards.increasePosition(positionId, basketId, configured, shares);
        emit IStaticsBasketCollateral.BasketCollateralDeposited(positionId, basketId, msg.sender, shares);
    }

    function depositBasketCollateral(uint256 positionId, uint256 basketId, uint256 shares) external nonReentrant {
        if (shares == 0) revert InvalidShares();
        LibPosition.enforceAuthorized(positionId, msg.sender);
        LibMorpho.syncIfInitialized(positionId, msg.sender);
        LibBasket.Basket storage configured = _getBasket(LibBasket.basketStorage(), basketId);
        LibBasket.enforceActive(configured, basketId);
        _pullBasketToken(configured, basketId, shares);
        LibBasketRewards.increasePosition(positionId, basketId, configured, shares);
        emit IStaticsBasketCollateral.BasketCollateralDeposited(positionId, basketId, msg.sender, shares);
    }

    function withdrawBasketCollateral(uint256 positionId, uint256 basketId, uint256 shares, address receiver)
        external
        nonReentrant
    {
        if (shares == 0) revert InvalidShares();
        if (receiver == address(0)) revert InvalidReceiver();
        LibPosition.enforceAuthorized(positionId, msg.sender);
        LibBasket.Basket storage configured = _getBasket(LibBasket.basketStorage(), basketId);
        LibBasketRewards.decreasePosition(positionId, basketId, configured, shares);
        LibCustody.pushReserved(LibCustody.basketAccount(basketId), configured.token, receiver, shares, shares);
        LibBasketRewards.deactivateIfEmpty(positionId, basketId);
        emit IStaticsBasketCollateral.BasketCollateralWithdrawn(positionId, basketId, receiver, shares);
    }

    function basketCollateralPosition(uint256 positionId, uint256 basketId)
        external
        view
        returns (IStaticsBasketCollateral.BasketCollateralPosition memory result)
    {
        IERC721(address(this)).ownerOf(positionId);
        _getBasket(LibBasket.basketStorage(), basketId);
        LibBasketCollateral.PositionBasketCollateral storage position =
            LibBasketCollateral.collateralStorage().positions[positionId][basketId];
        result = IStaticsBasketCollateral.BasketCollateralPosition({
            depositedShares: position.depositedShares,
            lockedShares: position.lockedShares,
            rewardEligibleAt: LibBasketRewards.rewardStorage().positions[positionId][basketId].eligibleAt
        });
    }

    function _pullBasketToken(LibBasket.Basket storage configured, uint256 basketId, uint256 shares) private {
        uint256 received =
            LibCustody.pullAndReserve(LibCustody.basketAccount(basketId), configured.token, msg.sender, shares);
        if (received < shares) revert InsufficientTransferReceived(configured.token, shares, received);
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
