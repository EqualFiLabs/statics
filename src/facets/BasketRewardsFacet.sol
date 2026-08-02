// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IStaticsBasketRewards} from "../interfaces/IStaticsBasketRewards.sol";
import {IStaticsPositionModule} from "../interfaces/IStaticsPosition.sol";
import {LibBasket} from "../libraries/LibBasket.sol";
import {LibBasketRewards} from "../libraries/LibBasketRewards.sol";
import {LibCustody} from "../libraries/LibCustody.sol";
import {LibPosition} from "../position/LibPosition.sol";

contract BasketRewardsFacet is ReentrancyGuard {
    error BasketNotFound(uint256 basketId);
    error InvalidShares();
    error InvalidReceiver();
    error InvalidAmountsLength();
    error InsufficientTransferReceived(address token, uint256 required, uint256 received);
    error MinimumOutputNotMet(address asset, uint256 actual, uint256 minimum);
    error NoRewards(uint256 positionId, uint256 basketId);

    function createAndDepositBasket(uint256 basketId, uint256 shares, address receiver)
        external
        nonReentrant
        returns (uint256 positionId)
    {
        if (shares == 0) revert InvalidShares();
        if (receiver == address(0)) revert InvalidReceiver();
        LibBasket.BasketStorage storage bs = LibBasket.basketStorage();
        LibBasket.Basket storage configured = _getBasket(bs, basketId);
        LibBasket.enforceActive(configured, basketId);
        positionId =
            IStaticsPositionModule(address(this)).createPositionForModule(receiver, LibPosition.basketLegKey(basketId));
        _pullBasketToken(configured, basketId, shares);
        LibBasketRewards.increasePosition(configured, positionId, basketId, shares);
        emit IStaticsBasketRewards.BasketPositionDeposited(positionId, basketId, msg.sender, shares);
    }

    function depositBasket(uint256 positionId, uint256 basketId, uint256 shares) external nonReentrant {
        if (shares == 0) revert InvalidShares();
        LibPosition.enforceAuthorized(positionId, msg.sender);
        LibBasket.BasketStorage storage bs = LibBasket.basketStorage();
        LibBasket.Basket storage configured = _getBasket(bs, basketId);
        LibBasket.enforceActive(configured, basketId);
        _pullBasketToken(configured, basketId, shares);
        LibBasketRewards.increasePosition(configured, positionId, basketId, shares);
        emit IStaticsBasketRewards.BasketPositionDeposited(positionId, basketId, msg.sender, shares);
    }

    function withdrawBasket(uint256 positionId, uint256 basketId, uint256 shares, address receiver)
        external
        nonReentrant
    {
        if (shares == 0) revert InvalidShares();
        if (receiver == address(0)) revert InvalidReceiver();
        LibPosition.enforceAuthorized(positionId, msg.sender);
        LibBasket.BasketStorage storage bs = LibBasket.basketStorage();
        LibBasket.Basket storage configured = _getBasket(bs, basketId);
        LibBasketRewards.decreasePosition(bs, configured, positionId, basketId, shares);
        LibCustody.pushReserved(LibCustody.basketAccount(basketId), configured.token, receiver, shares, shares);
        LibBasketRewards.deactivateIfEmpty(configured, positionId, basketId);
        emit IStaticsBasketRewards.BasketPositionWithdrawn(positionId, basketId, receiver, shares);
    }

    function claimBasketRewards(
        uint256 positionId,
        uint256 basketId,
        address receiver,
        uint256[] calldata minAmountsOut
    ) external nonReentrant returns (uint256[] memory amountsOut) {
        if (receiver == address(0)) revert InvalidReceiver();
        LibPosition.enforceAuthorized(positionId, msg.sender);
        LibBasket.Basket storage configured = _getBasket(LibBasket.basketStorage(), basketId);
        uint256 length = configured.assets.length;
        if (minAmountsOut.length != length) revert InvalidAmountsLength();
        LibBasketRewards.settlePosition(configured, positionId, basketId);

        LibBasketRewards.RewardStorage storage rs = LibBasketRewards.rewardStorage();
        LibBasketRewards.PositionBasket storage position = rs.positions[positionId][basketId];
        bytes32 custodyAccount = LibCustody.basketAccount(basketId);
        amountsOut = new uint256[](length);
        bool hasRewards;
        for (uint256 i; i < length; ++i) {
            address asset = configured.assets[i];
            uint256 amount = position.claimable[asset];
            hasRewards = hasRewards || amount != 0;
            if (amount != 0) {
                position.claimable[asset] = 0;
                rs.totalClaimable[basketId][asset] -= amount;
                rs.feeYieldReserve[basketId][asset] -= amount;
                (, amountsOut[i]) = LibCustody.pushReserved(custodyAccount, asset, receiver, amount, amount);
                emit IStaticsBasketRewards.BasketRewardsClaimed(positionId, basketId, receiver, asset, amount);
            }
            if (amountsOut[i] < minAmountsOut[i]) {
                revert MinimumOutputNotMet(asset, amountsOut[i], minAmountsOut[i]);
            }
        }
        if (!hasRewards) revert NoRewards(positionId, basketId);
        LibBasketRewards.deactivateIfEmpty(configured, positionId, basketId);
    }

    function pendingBasketRewards(uint256 positionId, uint256 basketId)
        external
        view
        returns (address[] memory assets, uint256[] memory amounts)
    {
        IERC721(address(this)).ownerOf(positionId);
        LibBasket.Basket storage configured = _getBasket(LibBasket.basketStorage(), basketId);
        return LibBasketRewards.pending(configured, positionId, basketId);
    }

    function basketRewardState(uint256 basketId, address asset)
        external
        view
        returns (IStaticsBasketRewards.BasketRewardState memory state)
    {
        _getBasket(LibBasket.basketStorage(), basketId);
        LibBasketRewards.RewardStorage storage rs = LibBasketRewards.rewardStorage();
        LibBasketRewards.RewardIndex storage index = rs.indexes[basketId][asset];
        state = IStaticsBasketRewards.BasketRewardState({
            totalEligibleShares: rs.totalEligibleShares[basketId],
            indexRay: index.accumulatedPerShareRay,
            indexRemainder: index.remainder,
            feeYieldReserve: rs.feeYieldReserve[basketId][asset],
            totalClaimable: rs.totalClaimable[basketId][asset]
        });
    }

    function basketPosition(uint256 positionId, uint256 basketId)
        external
        view
        returns (IStaticsBasketRewards.BasketPositionView memory result)
    {
        IERC721(address(this)).ownerOf(positionId);
        LibBasket.Basket storage configured = _getBasket(LibBasket.basketStorage(), basketId);
        LibBasketRewards.RewardStorage storage rs = LibBasketRewards.rewardStorage();
        LibBasketRewards.PositionBasket storage position = rs.positions[positionId][basketId];
        uint256 length = configured.assets.length;
        uint256[] memory checkpoints = new uint256[](length);
        uint256[] memory claimable = new uint256[](length);
        for (uint256 i; i < length; ++i) {
            address asset = configured.assets[i];
            checkpoints[i] = position.checkpointRay[asset];
            claimable[i] = position.claimable[asset];
        }
        result = IStaticsBasketRewards.BasketPositionView({
            eligibleShares: position.eligibleShares,
            lockedShares: position.lockedShares,
            withdrawableAfterBlock: position.lastDepositBlock + 1,
            assets: configured.assets,
            checkpointsRay: checkpoints,
            claimable: claimable
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
