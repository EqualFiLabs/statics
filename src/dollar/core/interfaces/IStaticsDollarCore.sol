// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IStaticsDollarCoreTypes} from "../../interfaces/IStaticsDollarCoreTypes.sol";

interface IStaticsDollarCore {
    function staticsDollar() external view returns (address);
    function staticsDollarRisk() external view returns (address);
    function periphery() external view returns (address);
    function positionNFT() external view returns (address);
    function bootstrapFinalized() external view returns (bool);
    function seniorLiabilities() external view returns (uint256);
    function globalImpairmentLatched() external view returns (bool);

    function collateralProfile(uint256 profileId)
        external
        view
        returns (IStaticsDollarCoreTypes.StableCollateralProfile memory profile);

    function riskSeries(uint256 seriesId) external view returns (IStaticsDollarCoreTypes.RiskSeries memory series);

    function previewDeposit(uint256 profileId, uint256 collateralAmount)
        external
        view
        returns (IStaticsDollarCoreTypes.DepositPreview memory preview);

    function depositCollateral(
        uint256 profileId,
        uint256 collateralAmount,
        uint256 minimumStaticsDollar,
        uint256 minimumShares,
        address staticsDollarReceiver,
        address shareReceiver
    ) external returns (uint256 seriesId, uint256 staticsDollarMinted, uint256 sharesMinted);

    function previewPeggedMint(uint256 profileId, uint256 staticsDollarAmount)
        external
        view
        returns (IStaticsDollarCoreTypes.PeggedMintPreview memory preview);

    function mintPegged(
        uint256 profileId,
        uint256 staticsDollarAmount,
        uint256 maximumCollateralIn,
        address staticsDollarReceiver
    ) external returns (uint256 collateralIn);

    function previewPeggedRedemption(uint256 profileId, uint256 staticsDollarAmount)
        external
        view
        returns (IStaticsDollarCoreTypes.PeggedRedemptionPreview memory preview);

    function redeemPegged(
        uint256 profileId,
        uint256 staticsDollarAmount,
        uint256 minimumCollateralOut,
        address receiver
    ) external returns (IStaticsDollarCoreTypes.ExitStatus status, uint256 collateralOut);

    function previewRecombine(uint256 seriesId, uint256 staticsDollarAmount)
        external
        view
        returns (IStaticsDollarCoreTypes.RedemptionPreview memory preview);

    function recombine(
        uint256 seriesId,
        uint256 staticsDollarAmount,
        uint256 shareAmount,
        uint256 minimumCollateralOut,
        address receiver
    ) external returns (IStaticsDollarCoreTypes.ExitStatus status, uint256 collateralOut);

    function recombineManaged(
        uint256 seriesId,
        uint256 staticsDollarAmount,
        uint256 shareAmount,
        uint256 minimumCollateralOut,
        address receiver
    ) external returns (IStaticsDollarCoreTypes.ExitStatus status, uint256 collateralOut);

    function globalImpairment()
        external
        view
        returns (
            IStaticsDollarCoreTypes.GlobalHealthPhase phase,
            uint256 unhealthyProfileBitmap,
            uint256 totalSeniorDeficitWad,
            uint256 recoveryAvailableAt
        );

    function checkpointGlobalCollateralExit()
        external
        returns (
            IStaticsDollarCoreTypes.ExitStatus status,
            uint256 unhealthyProfileBitmap,
            uint256 totalSeniorDeficitWad,
            uint256 recoveryAvailableAt
        );

    function peggedRedemptionStatus()
        external
        view
        returns (
            IStaticsDollarCoreTypes.ExitStatus status,
            uint256 unhealthyProfileBitmap,
            uint256 totalSeniorDeficitWad,
            uint256 recoveryAvailableAt
        );

    function checkpointPeggedRedemption()
        external
        returns (
            IStaticsDollarCoreTypes.ExitStatus status,
            uint256 unhealthyProfileBitmap,
            uint256 totalSeniorDeficitWad,
            uint256 recoveryAvailableAt
        );

    function profileOperationPaused(uint256 profileId, uint256 operation) external view returns (bool paused);

    function topUpInsurance(uint256 profileId, uint256 amount) external;

    function returnRiskShares(uint256 seriesId, uint256 shares) external;

    function reclaimReturnedRiskShares(uint256 seriesId, address receiver) external returns (uint256 shares);

    function previewReturnedRiskClaim(address holder, uint256 seriesId, IStaticsDollarCoreTypes.RecoveryClaimMode mode)
        external
        view
        returns (IStaticsDollarCoreTypes.RecoveryClaimPreview memory preview);

    function claimReturnedRisk(
        uint256 seriesId,
        IStaticsDollarCoreTypes.RecoveryClaimMode mode,
        uint256 maximumCollateralIn,
        uint256 minimumSharesOut,
        uint256 minimumCollateralOut,
        address receiver
    ) external returns (uint256 successorPairs, uint256 collateralIn, uint256 collateralOut);

    function previewExpiredRiskRecovery(
        address holder,
        uint256 seriesId,
        uint256 shares,
        IStaticsDollarCoreTypes.RecoveryClaimMode mode
    ) external view returns (IStaticsDollarCoreTypes.ExpiredRiskRecoveryPreview memory preview);

    function recoverExpiredRisk(
        address holder,
        uint256 seriesId,
        uint256 shares,
        IStaticsDollarCoreTypes.RecoveryClaimMode mode,
        uint256 minimumKeeperOut
    ) external returns (uint256 staticsDollarBurned, uint256 keeperCollateralOut, uint256 holderPairs);
}
