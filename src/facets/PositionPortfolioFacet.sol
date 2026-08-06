// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IStaticsPositionPortfolio} from "../interfaces/IStaticsPositionPortfolio.sol";
import {LibPeriphery} from "../dollar/periphery/libraries/LibPeriphery.sol";
import {LibPositionPortfolio} from "../libraries/LibPositionPortfolio.sol";

contract PositionPortfolioFacet is IStaticsPositionPortfolio {
    uint256 internal constant MAX_PORTFOLIO_PAGE_SIZE = 100;

    function positionPortfolioCounts(uint256 positionId) external view returns (PositionPortfolioCounts memory counts) {
        _requirePosition(positionId);
        LibPositionPortfolio.PortfolioStorage storage ps = LibPositionPortfolio.portfolioStorage();
        counts = PositionPortfolioCounts({
            basketCount: ps.baskets[positionId].values.length,
            loanCount: ps.loans[positionId].values.length,
            liquidityPositionCount: ps.liquidityPositions[positionId].values.length,
            globalRewardAssetCount: ps.globalRewardAssets[positionId].values.length,
            riskSeriesCount: LibPeriphery.s().positionSeries[positionId].length
        });
    }

    function basketIdsOfPosition(uint256 positionId, uint256 cursor, uint256 limit)
        external
        view
        returns (uint256[] memory basketIds, uint256 nextCursor)
    {
        _requirePosition(positionId);
        return _uintPage(LibPositionPortfolio.portfolioStorage().baskets[positionId].values, cursor, limit);
    }

    function loanIdsOfPosition(uint256 positionId, uint256 cursor, uint256 limit)
        external
        view
        returns (uint256[] memory loanIds, uint256 nextCursor)
    {
        _requirePosition(positionId);
        return _uintPage(LibPositionPortfolio.portfolioStorage().loans[positionId].values, cursor, limit);
    }

    function liquidityPositionIdsOfPosition(uint256 positionId, uint256 cursor, uint256 limit)
        external
        view
        returns (uint256[] memory tokenIds, uint256 nextCursor)
    {
        _requirePosition(positionId);
        return _uintPage(LibPositionPortfolio.portfolioStorage().liquidityPositions[positionId].values, cursor, limit);
    }

    function globalRewardAssetsOfPosition(uint256 positionId, uint256 cursor, uint256 limit)
        external
        view
        returns (address[] memory assets, uint256 nextCursor)
    {
        _requirePosition(positionId);
        _validateLimit(limit);
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

    function riskSeriesIdsOfPosition(uint256 positionId, uint256 cursor, uint256 limit)
        external
        view
        returns (uint256[] memory seriesIds, uint256 nextCursor)
    {
        _requirePosition(positionId);
        return _uintPage(LibPeriphery.s().positionSeries[positionId], cursor, limit);
    }

    function _uintPage(uint256[] storage values, uint256 cursor, uint256 limit)
        private
        view
        returns (uint256[] memory page, uint256 nextCursor)
    {
        _validateLimit(limit);
        uint256 length = values.length;
        if (cursor >= length) return (new uint256[](0), length);
        uint256 pageLength = length - cursor;
        if (pageLength > limit) pageLength = limit;
        page = new uint256[](pageLength);
        for (uint256 i; i < pageLength; ++i) {
            page[i] = values[cursor + i];
        }
        nextCursor = cursor + pageLength;
    }

    function _validateLimit(uint256 limit) private pure {
        if (limit == 0 || limit > MAX_PORTFOLIO_PAGE_SIZE) {
            revert InvalidPortfolioPageSize(limit, MAX_PORTFOLIO_PAGE_SIZE);
        }
    }

    function _requirePosition(uint256 positionId) private view {
        IERC721(address(this)).ownerOf(positionId);
    }
}
