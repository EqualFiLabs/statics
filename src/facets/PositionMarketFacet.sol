// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IStaticsGlobalRewards} from "../interfaces/IStaticsGlobalRewards.sol";
import {IStaticsPositionRoyalty} from "../interfaces/IStaticsPositionRoyalty.sol";
import {LibDiamond} from "../libraries/LibDiamond.sol";
import {LibGlobalRewards} from "../libraries/LibGlobalRewards.sol";
import {LibPositionPortfolio} from "../libraries/LibPositionPortfolio.sol";
import {LibPositionRoyalty} from "../libraries/LibPositionRoyalty.sol";

/// @notice Bounded PositionNFT valuation views and marketplace royalty signaling.
contract PositionMarketFacet is IStaticsPositionRoyalty {
    uint256 private constant BPS_DENOMINATOR = 10_000;
    uint256 private constant MAX_REWARD_ASSET_PAGE_SIZE = 100;

    error InvalidRewardAssetPageSize(uint256 requested, uint256 maximum);

    function royaltyInfo(uint256, uint256 salePrice) external view returns (address receiver, uint256 royaltyAmount) {
        LibPositionRoyalty.RoyaltyStorage storage rs = LibPositionRoyalty.royaltyStorage();
        receiver = rs.receiver;
        royaltyAmount = Math.mulDiv(salePrice, rs.royaltyBps, BPS_DENOMINATOR);
    }

    function positionRoyalty() external view returns (address receiver, uint16 royaltyBps) {
        LibPositionRoyalty.RoyaltyStorage storage rs = LibPositionRoyalty.royaltyStorage();
        return (rs.receiver, rs.royaltyBps);
    }

    function setPositionRoyalty(address receiver, uint16 royaltyBps) external {
        LibDiamond.enforceIsContractOwner();
        LibPositionRoyalty.set(receiver, royaltyBps);
    }

    function pendingRewards(uint256 positionId, address[] calldata assets)
        external
        view
        returns (uint256[] memory amounts)
    {
        _requirePosition(positionId);
        uint256 length = assets.length;
        amounts = new uint256[](length);
        for (uint256 i; i < length; ++i) {
            amounts[i] = LibGlobalRewards.pending(positionId, assets[i]);
        }
    }

    function stakePosition(uint256 positionId)
        external
        view
        returns (IStaticsGlobalRewards.StakePositionView memory position)
    {
        _requirePosition(positionId);
        LibGlobalRewards.StakePosition storage stored = LibGlobalRewards.rewardStorage().positions[positionId];
        position = IStaticsGlobalRewards.StakePositionView({
            stakedBalance: stored.balance,
            rewardMultiplierBps: LibGlobalRewards.effectiveRewardMultiplier(stored),
            claimAssetCount: stored.claimAssetCount,
            optedInAssetCount: stored.optedInAssets.length
        });
    }

    function positionRewardAssets(uint256 positionId) external view returns (address[] memory assets) {
        _requirePosition(positionId);
        return LibGlobalRewards.rewardStorage().positions[positionId].optedInAssets;
    }

    function isRewardAssetOptedIn(uint256 positionId, address asset) external view returns (bool) {
        _requirePosition(positionId);
        return LibGlobalRewards.isOptedIn(positionId, asset);
    }

    function rewardSelection(uint256 positionId, address asset)
        external
        view
        returns (IStaticsGlobalRewards.RewardSelectionView memory selection)
    {
        _requirePosition(positionId);
        return LibGlobalRewards.selectionView(positionId, asset);
    }

    function globalRewardAssetsOfPosition(uint256 positionId, uint256 cursor, uint256 limit)
        external
        view
        returns (address[] memory assets, uint256 nextCursor)
    {
        _requirePosition(positionId);
        if (limit == 0 || limit > MAX_REWARD_ASSET_PAGE_SIZE) {
            revert InvalidRewardAssetPageSize(limit, MAX_REWARD_ASSET_PAGE_SIZE);
        }
        address[] storage values = LibPositionPortfolio.portfolioStorage().globalRewardAssets[positionId].values;
        uint256 length = values.length;
        if (cursor >= length) return (new address[](0), length);
        uint256 pageLength = length - cursor;
        if (pageLength > limit) pageLength = limit;
        assets = new address[](pageLength);
        for (uint256 i; i < pageLength; ++i) {
            assets[i] = values[cursor + i];
        }
        nextCursor = cursor + pageLength;
    }

    function _requirePosition(uint256 positionId) private view {
        IERC721(address(this)).ownerOf(positionId);
    }
}
