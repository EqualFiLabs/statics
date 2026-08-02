// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IStaticsBasketRewards} from "../interfaces/IStaticsBasketRewards.sol";
import {LibBasket} from "./LibBasket.sol";
import {LibBasketCollateral} from "./LibBasketCollateral.sol";
import {LibGlobalRewards} from "./LibGlobalRewards.sol";

library LibBasketRewards {
    bytes32 internal constant STORAGE_POSITION = keccak256("statics.storage.basket.rewards.v2");
    uint256 internal constant RAY = 1e27;

    struct RewardBook {
        uint256 indexRay;
        uint256 indexedAmount;
        uint256 crystallizedAmount;
    }

    struct PositionRewards {
        uint256 claimAssetCount;
        mapping(address asset => uint256 indexRay) checkpoints;
        mapping(address asset => uint256 amount) claimable;
    }

    struct RewardStorage {
        mapping(uint256 basketId => uint256 shares) totalEligibleShares;
        mapping(uint256 basketId => mapping(address asset => RewardBook book)) books;
        mapping(uint256 positionId => mapping(uint256 basketId => PositionRewards rewards)) positions;
        mapping(uint256 basketId => mapping(address asset => uint256 amount)) totalClaimable;
    }

    error InvalidBasketRewardAsset(uint256 basketId, address asset);
    error BasketHasNoEligibleShares(uint256 basketId);

    function rewardStorage() internal pure returns (RewardStorage storage rs) {
        bytes32 slot = STORAGE_POSITION;
        assembly ("memory-safe") {
            rs.slot := slot
        }
    }

    function rewardAssets(LibBasket.Basket storage configured) internal view returns (address[] memory assets) {
        uint256 length = configured.assets.length;
        assets = new address[](length + 1);
        assets[0] = configured.token;
        for (uint256 i; i < length; ++i) {
            assets[i + 1] = configured.assets[i];
        }
    }

    function isRewardAsset(LibBasket.Basket storage configured, address asset) internal view returns (bool) {
        if (asset == configured.token) return true;
        uint256 length = configured.assets.length;
        for (uint256 i; i < length; ++i) {
            if (configured.assets[i] == asset) return true;
        }
        return false;
    }

    function canAccrue(uint256 basketId) internal view returns (bool) {
        return rewardStorage().totalEligibleShares[basketId] != 0;
    }

    function accrueReserved(uint256 basketId, LibBasket.Basket storage configured, address asset, uint256 amount)
        internal
        returns (uint256 indexRay)
    {
        if (amount == 0) return 0;
        if (!isRewardAsset(configured, asset)) revert InvalidBasketRewardAsset(basketId, asset);
        RewardStorage storage rs = rewardStorage();
        uint256 total = rs.totalEligibleShares[basketId];
        if (total == 0) revert BasketHasNoEligibleShares(basketId);
        RewardBook storage book = rs.books[basketId][asset];
        book.indexRay += Math.mulDiv(amount, RAY, total);
        book.indexedAmount += amount;
        emit IStaticsBasketRewards.BasketRewardAccrued(basketId, asset, amount, book.indexRay);
        return book.indexRay;
    }

    function settle(uint256 positionId, uint256 basketId, LibBasket.Basket storage configured) internal {
        RewardStorage storage rs = rewardStorage();
        PositionRewards storage position = rs.positions[positionId][basketId];
        uint256 shares = LibBasketCollateral.collateralStorage().positions[positionId][basketId].depositedShares;
        _settleAsset(rs, position, positionId, basketId, configured.token, shares);
        uint256 length = configured.assets.length;
        for (uint256 i; i < length; ++i) {
            _settleAsset(rs, position, positionId, basketId, configured.assets[i], shares);
        }
    }

    function pending(uint256 positionId, uint256 basketId, LibBasket.Basket storage configured)
        internal
        view
        returns (address[] memory assets, uint256[] memory amounts)
    {
        RewardStorage storage rs = rewardStorage();
        PositionRewards storage position = rs.positions[positionId][basketId];
        uint256 shares = LibBasketCollateral.collateralStorage().positions[positionId][basketId].depositedShares;
        assets = rewardAssets(configured);
        uint256 length = assets.length;
        amounts = new uint256[](length);
        for (uint256 i; i < length; ++i) {
            address asset = assets[i];
            uint256 amount = position.claimable[asset];
            uint256 current = rs.books[basketId][asset].indexRay;
            uint256 prior = position.checkpoints[asset];
            if (shares != 0 && current > prior) amount += Math.mulDiv(shares, current - prior, RAY);
            amounts[i] = amount;
        }
    }

    function increasePosition(uint256 positionId, uint256 basketId, LibBasket.Basket storage configured, uint256 shares)
        internal
    {
        settle(positionId, basketId, configured);
        LibBasketCollateral.increasePosition(positionId, basketId, shares);
        rewardStorage().totalEligibleShares[basketId] += shares;
    }

    function decreasePosition(uint256 positionId, uint256 basketId, LibBasket.Basket storage configured, uint256 shares)
        internal
    {
        settle(positionId, basketId, configured);
        LibBasketCollateral.decreasePosition(positionId, basketId, shares);
        RewardStorage storage rs = rewardStorage();
        rs.totalEligibleShares[basketId] -= shares;
        if (rs.totalEligibleShares[basketId] == 0) _routeDust(basketId, configured);
    }

    function lockForLoan(
        uint256 positionId,
        uint256 basketId,
        LibBasket.Basket storage configured,
        uint256 sharesIn,
        uint256 feeShares,
        uint256 collateralShares
    ) internal {
        settle(positionId, basketId, configured);
        LibBasketCollateral.lockForLoan(positionId, basketId, sharesIn, feeShares, collateralShares);
        if (feeShares == 0) return;
        RewardStorage storage rs = rewardStorage();
        rs.totalEligibleShares[basketId] -= feeShares;
        if (rs.totalEligibleShares[basketId] == 0) _routeDust(basketId, configured);
    }

    function unlockAfterRepay(
        uint256 positionId,
        uint256 basketId,
        LibBasket.Basket storage configured,
        uint256 collateralShares
    ) internal {
        settle(positionId, basketId, configured);
        LibBasketCollateral.unlockAfterRepay(positionId, basketId, collateralShares);
    }

    function releaseAfterRecovery(
        uint256 positionId,
        uint256 basketId,
        LibBasket.Basket storage configured,
        uint256 collateralShares,
        uint256 burnShares
    ) internal {
        settle(positionId, basketId, configured);
        LibBasketCollateral.releaseAfterRecovery(positionId, basketId, collateralShares, burnShares);
        RewardStorage storage rs = rewardStorage();
        rs.totalEligibleShares[basketId] -= burnShares;
        if (rs.totalEligibleShares[basketId] == 0) _routeDust(basketId, configured);
    }

    function deactivateIfEmpty(uint256 positionId, uint256 basketId) internal {
        PositionRewards storage rewards = rewardStorage().positions[positionId][basketId];
        if (rewards.claimAssetCount != 0) return;
        LibBasketCollateral.deactivateIfEmpty(positionId, basketId);
    }

    function clearClaim(uint256 positionId, uint256 basketId, address asset) internal returns (uint256 amount) {
        RewardStorage storage rs = rewardStorage();
        PositionRewards storage position = rs.positions[positionId][basketId];
        amount = position.claimable[asset];
        if (amount == 0) return 0;
        position.claimable[asset] = 0;
        --position.claimAssetCount;
        rs.totalClaimable[basketId][asset] -= amount;
    }

    function _settleAsset(
        RewardStorage storage rs,
        PositionRewards storage position,
        uint256 positionId,
        uint256 basketId,
        address asset,
        uint256 shares
    ) private {
        RewardBook storage book = rs.books[basketId][asset];
        uint256 prior = position.checkpoints[asset];
        uint256 added;
        if (shares != 0 && book.indexRay > prior) {
            added = Math.mulDiv(shares, book.indexRay - prior, RAY);
            if (added != 0) {
                if (position.claimable[asset] == 0) ++position.claimAssetCount;
                position.claimable[asset] += added;
                rs.totalClaimable[basketId][asset] += added;
                book.crystallizedAmount += added;
            }
        }
        position.checkpoints[asset] = book.indexRay;
        emit IStaticsBasketRewards.BasketRewardSettled(positionId, basketId, asset, added);
    }

    function _routeDust(uint256 basketId, LibBasket.Basket storage configured) private {
        RewardStorage storage rs = rewardStorage();
        _routeAssetDust(rs, basketId, configured.token);
        uint256 length = configured.assets.length;
        for (uint256 i; i < length; ++i) {
            _routeAssetDust(rs, basketId, configured.assets[i]);
        }
    }

    function _routeAssetDust(RewardStorage storage rs, uint256 basketId, address asset) private {
        RewardBook storage book = rs.books[basketId][asset];
        uint256 dust = book.indexedAmount - book.crystallizedAmount;
        book.indexedAmount = 0;
        book.crystallizedAmount = 0;
        if (dust == 0) return;
        LibGlobalRewards.accrueReservedTreasuryFee(asset, dust);
        emit IStaticsBasketRewards.BasketRewardDustRouted(basketId, asset, dust);
    }
}
