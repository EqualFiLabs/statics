// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

interface IStaticsDollarRiskIncentives {
    struct RiskIncentiveView {
        address collateralToken;
        address staticsToken;
        uint256 collateralReserve;
        uint256 staticsDollarReserve;
        uint256 staticsReserve;
        uint256 destinationSeriesId;
        bool routedGlobal;
        bool finalized;
    }

    event RiskIncentivesFunded(
        uint256 indexed seriesId,
        address indexed token,
        address indexed funder,
        uint256 requestedAmount,
        uint256 receivedAmount
    );
    event RiskIncentivesReleased(
        uint256 indexed seriesId,
        uint64 indexed epoch,
        uint256 riskSharesConsumed,
        uint256 collateralAmount,
        uint256 staticsDollarAmount,
        uint256 staticsAmount
    );
    event RiskIncentivesRolledOver(
        uint256 indexed seriesId,
        uint256 indexed destinationSeriesId,
        uint256 collateralAmount,
        uint256 staticsDollarAmount,
        uint256 staticsAmount
    );
    event RiskIncentivesRoutedGlobal(
        uint256 indexed seriesId, uint256 collateralAmount, uint256 staticsDollarAmount, uint256 staticsAmount
    );

    function fundRiskCollateralIncentives(uint256 seriesId, uint256 amount) external returns (uint256 received);

    function fundRiskDollarIncentives(uint256 seriesId, uint256 amount) external returns (uint256 received);

    function fundRiskStaticsIncentives(uint256 seriesId, uint256 amount) external returns (uint256 received);

    function riskIncentives(uint256 seriesId) external view returns (RiskIncentiveView memory view_);

    function finalizeRiskIncentives(uint256 seriesId) external returns (uint256 destinationSeriesId, bool routedGlobal);
}
