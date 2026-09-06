// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

interface IStaticsDollarSeriesMigration {
    struct SeriesMigrationView {
        uint256 newSeriesId;
        uint256 oldPrincipal;
        uint256 remainingOldPrincipal;
        uint256 remainingNewPrincipal;
        uint256 remainingStaticsDollar;
        uint256 remainingCollateral;
        bool returned;
        bool claimed;
    }

    event SeriesTransitionProcessed(
        uint256 indexed oldSeriesId,
        uint256 indexed newSeriesId,
        uint256 oldPrincipal,
        uint256 newPrincipal,
        bool returnedDuringWindow
    );
    event PositionMigrationSettled(
        uint256 indexed positionId,
        uint256 indexed oldSeriesId,
        uint256 indexed newSeriesId,
        uint256 oldPrincipal,
        uint256 newPrincipal,
        uint256 staticsDollarCredit,
        uint256 collateralCredit
    );
    event MigrationRoundingWrittenOff(
        uint256 indexed positionId, uint256 indexed oldSeriesId, uint256 nominalPrincipal, uint256 settledPrincipal
    );

    function processSeriesTransition(uint256 oldSeriesId) external returns (uint256 newSeriesId, uint256 newPrincipal);

    function settleSeriesMigration(uint256 positionId, uint256 oldSeriesId)
        external
        returns (uint256 newSeriesId, uint256 newPrincipal);

    function seriesMigration(uint256 oldSeriesId) external view returns (SeriesMigrationView memory migration);
}
