// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IStaticsBasketRewards} from "../interfaces/IStaticsBasketRewards.sol";
import {LibBasket} from "../libraries/LibBasket.sol";
import {LibBasketRewards} from "../libraries/LibBasketRewards.sol";
import {LibCustody} from "../libraries/LibCustody.sol";
import {LibPosition} from "../position/LibPosition.sol";

contract BasketRewardsFacet is IStaticsBasketRewards, ReentrancyGuard {
    error BasketNotFound(uint256 basketId);
    error InvalidReceiver();
    error IncompatibleRewardTransfer(address asset, uint256 expected, uint256 received);
    error NoBasketRewards(uint256 positionId, uint256 basketId);

    function getBasketRewardAssets(uint256 basketId) external view returns (address[] memory assets) {
        return LibBasketRewards.rewardAssets(_basket(basketId));
    }

    function getBasketRewards(uint256 positionId, uint256 basketId)
        external
        view
        returns (address[] memory assets, uint256[] memory amounts)
    {
        IERC721(address(this)).ownerOf(positionId);
        return LibBasketRewards.pending(positionId, basketId, _basket(basketId));
    }

    function claimBasketRewards(uint256 positionId, uint256 basketId, address receiver)
        external
        nonReentrant
        returns (address[] memory assets, uint256[] memory amounts)
    {
        if (receiver == address(0)) revert InvalidReceiver();
        LibPosition.enforceAuthorized(positionId, msg.sender);
        LibBasket.Basket storage configured = _basket(basketId);
        LibBasketRewards.settle(positionId, basketId, configured);
        assets = LibBasketRewards.rewardAssets(configured);
        uint256 length = assets.length;
        amounts = new uint256[](length);
        bool hasRewards;
        for (uint256 i; i < length; ++i) {
            address asset = assets[i];
            uint256 amount = LibBasketRewards.clearClaim(positionId, basketId, asset);
            if (amount == 0) continue;
            hasRewards = true;
            (, amounts[i]) = LibCustody.pushReserved(LibCustody.feeAccount(), asset, receiver, amount, amount);
            if (amounts[i] != amount) revert IncompatibleRewardTransfer(asset, amount, amounts[i]);
            emit BasketRewardClaimed(positionId, basketId, asset, receiver, amount);
        }
        if (!hasRewards) revert NoBasketRewards(positionId, basketId);
        LibBasketRewards.deactivateIfEmpty(positionId, basketId);
    }

    function basketRewardState(uint256 basketId, address asset) external view returns (BasketRewardState memory state) {
        LibBasket.Basket storage configured = _basket(basketId);
        if (!LibBasketRewards.isRewardAsset(configured, asset)) {
            revert LibBasketRewards.InvalidBasketRewardAsset(basketId, asset);
        }
        LibBasketRewards.RewardStorage storage rs = LibBasketRewards.rewardStorage();
        LibBasketRewards.RewardBook storage book = rs.books[basketId][asset];
        state = BasketRewardState({
            totalEligibleShares: rs.totalEligibleShares[basketId],
            indexRay: book.indexRay,
            indexedReserve: book.indexedAmount,
            crystallizedReserve: book.crystallizedAmount,
            totalClaimable: rs.totalClaimable[basketId][asset]
        });
    }

    function _basket(uint256 basketId) private view returns (LibBasket.Basket storage configured) {
        configured = LibBasket.basketStorage().baskets[basketId];
        if (configured.token == address(0)) revert BasketNotFound(basketId);
    }
}
