// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

/// @notice Optional Statics-specific enumeration for state attached to a Position NFT.
/// @dev Page ordering is not stable across state changes. Read all pages at one block.
interface IStaticsPositionPortfolio {
    struct PositionPortfolioCounts {
        uint256 basketCount;
        uint256 loanCount;
        uint256 liquidityPositionCount;
        uint256 globalRewardAssetCount;
        uint256 riskSeriesCount;
    }

    error InvalidPortfolioPageSize(uint256 requested, uint256 maximum);

    function positionPortfolioCounts(uint256 positionId) external view returns (PositionPortfolioCounts memory counts);

    function basketIdsOfPosition(uint256 positionId, uint256 cursor, uint256 limit)
        external
        view
        returns (uint256[] memory basketIds, uint256 nextCursor);

    function loanIdsOfPosition(uint256 positionId, uint256 cursor, uint256 limit)
        external
        view
        returns (uint256[] memory loanIds, uint256 nextCursor);

    function liquidityPositionIdsOfPosition(uint256 positionId, uint256 cursor, uint256 limit)
        external
        view
        returns (uint256[] memory tokenIds, uint256 nextCursor);

    function globalRewardAssetsOfPosition(uint256 positionId, uint256 cursor, uint256 limit)
        external
        view
        returns (address[] memory assets, uint256 nextCursor);

    function riskSeriesIdsOfPosition(uint256 positionId, uint256 cursor, uint256 limit)
        external
        view
        returns (uint256[] memory seriesIds, uint256 nextCursor);
}
