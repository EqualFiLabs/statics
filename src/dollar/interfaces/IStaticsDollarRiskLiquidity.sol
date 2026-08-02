// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

interface IStaticsDollarRiskLiquidity {
    struct RiskLiquidityView {
        uint256 effectiveShares;
        uint256 claimableCollateral;
        uint256 claimableStaticsDollar;
        uint256 claimableStatics;
        uint64 epoch;
        bool exists;
    }

    event RiskSharesStaked(
        uint256 indexed positionId, uint256 indexed seriesId, address indexed supplier, uint256 amount
    );
    event RiskSharesUnstaked(
        uint256 indexed positionId, uint256 indexed seriesId, address indexed receiver, uint256 amount
    );
    event RiskProceedsClaimed(
        uint256 indexed positionId,
        uint256 indexed seriesId,
        address indexed receiver,
        address collateralToken,
        address staticsToken,
        uint256 collateralAmount,
        uint256 staticsDollarAmount,
        uint256 staticsAmount
    );

    function createAndStakeRiskShares(uint256 seriesId, uint256 amount, address receiver)
        external
        payable
        returns (uint256 positionId);

    function stakeRiskShares(uint256 positionId, uint256 seriesId, uint256 amount) external;

    function unstakeRiskShares(uint256 positionId, uint256 seriesId, uint256 amount, address receiver)
        external
        returns (uint256 principalOut);

    function claimRiskProceeds(uint256 positionId, uint256 seriesId, address receiver)
        external
        returns (uint256 collateralAmount, uint256 staticsDollarAmount, uint256 staticsAmount);

    function riskLiquidity(uint256 positionId, uint256 seriesId)
        external
        view
        returns (RiskLiquidityView memory view_);

    function totalRiskLiquidity(uint256 seriesId) external view returns (uint256);
}
