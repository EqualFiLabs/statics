// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

interface IStaticsDollarRiskSeriesRewards {
    struct SeriesRewardState {
        uint256 eligiblePrincipal;
        uint256 collateralPassiveIndexRay;
        uint256 staticsDollarPassiveIndexRay;
        uint256 collateralOptInReserve;
        uint256 staticsDollarOptInReserve;
        uint256 optInEffectivePrincipal;
        bool retiredRewardsFinalized;
    }

    event SeriesRewardsDonated(
        uint256 indexed seriesId,
        address indexed token,
        address indexed donor,
        uint256 passiveAmount,
        uint256 optInAmount
    );
    event SeriesRewardsClaimed(
        uint256 indexed positionId,
        uint256 indexed seriesId,
        address indexed receiver,
        address collateralToken,
        uint256 collateralAmount,
        uint256 staticsDollarAmount
    );
    event RetiredSeriesRewardsFinalized(
        uint256 indexed seriesId, uint256 collateralAmount, uint256 staticsDollarAmount, bool distributedToPassive
    );

    function donateCollateralRewards(uint256 seriesId, uint256 passiveAmount, uint256 optInAmount) external;
    function donateStaticsDollarRewards(uint256 seriesId, uint256 passiveAmount, uint256 optInAmount) external;
    function claimSeriesRewards(uint256 positionId, uint256 seriesId, address receiver)
        external
        returns (uint256 collateralAmount, uint256 staticsDollarAmount);
    function pendingSeriesRewards(uint256 positionId, uint256 seriesId)
        external
        view
        returns (uint256 collateralAmount, uint256 staticsDollarAmount);
    function seriesRewardState(uint256 seriesId) external view returns (SeriesRewardState memory state);
}
