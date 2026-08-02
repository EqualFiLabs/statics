// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

interface IStaticsDollarCoreTypes {
    enum ProfileKind {
        Volatile,
        Pegged
    }

    enum ProfileMode {
        Inactive,
        Active,
        ReduceOnly,
        Retired
    }

    enum FeeKind {
        Mint,
        Redemption
    }

    enum SeriesStatus {
        None,
        Active,
        RecoveryPending,
        Recoverable,
        Retired,
        Closed
    }

    enum TransitionKind {
        None,
        Downside,
        Upside
    }

    enum RecoveryClaimMode {
        NAV,
        ExactUnits,
        CollateralOnly
    }

    enum GlobalHealthPhase {
        Healthy,
        Impaired,
        Recovering,
        Unavailable
    }

    enum ExitStatus {
        Available,
        Impaired,
        HealthUnavailable,
        Recovering,
        DownsideTransition
    }

    struct ProfileSolvency {
        uint256 collateralValueWad;
        uint256 seniorLiabilitiesWad;
        uint256 seniorDeficitWad;
        bool oracleAvailable;
        bool healthy;
    }

    struct StableCollateralProfile {
        address collateralToken;
        address oracle;
        uint8 decimals;
        uint16 collateralRatioBps;
        uint16 priceBandBps;
        uint16 mintFeeBps;
        uint16 redemptionFeeBps;
        uint16 insuranceTargetBps;
        uint16 insuranceFeeBps;
        ProfileKind kind;
        ProfileMode mode;
        uint256 pegMinPriceWad;
        uint256 pegMaxPriceWad;
        uint256 activeSeriesId;
        uint256 accountedCollateral;
        uint256 insuranceReserve;
        uint256 seniorOutstanding;
        uint256 debtCeiling;
    }

    struct RiskSeries {
        uint256 profileId;
        address collateralToken;
        uint256 seniorOutstanding;
        uint256 riskSharesOutstanding;
        uint256 accountedCollateral;
        uint256 startPriceWad;
        uint256 collateralPerPairWad;
        uint256 seniorCollateralPerUnitWad;
        uint256 juniorCollateralPerUnitWad;
        uint256 collateralRatioBps;
        uint256 priceBandBps;
        uint256 startedAt;
        uint256 retiredAt;
        uint256 successorSeriesId;
        SeriesStatus status;
    }

    struct SeriesRecoveryState {
        TransitionKind kind;
        uint64 startedAt;
        uint64 endsAt;
        uint64 finalizedAt;
        uint256 finalizationPriceWad;
        uint256 returnedShares;
        uint256 returnedSharesClaimed;
        uint256 seniorRecoveryOutstanding;
        uint256 seniorRecoveryCollateral;
        uint256 juniorRecoveryShares;
        uint256 juniorRecoveryCollateral;
    }

    struct RecoveryClaimPreview {
        uint256 oldSeriesId;
        uint256 successorSeriesId;
        uint256 oldShares;
        uint256 juniorCollateral;
        uint256 collateralIn;
        uint256 collateralOut;
        uint256 successorPairs;
    }

    struct ExpiredRiskRecoveryPreview {
        uint256 oldSeriesId;
        uint256 successorSeriesId;
        uint256 sharesBurned;
        uint256 staticsDollarBurned;
        uint256 seniorCollateralOut;
        uint256 juniorCollateral;
        uint256 keeperBounty;
        uint256 holderCollateral;
        uint256 holderPairs;
        uint256 holderCollateralDust;
    }

    struct DepositPreview {
        uint256 profileId;
        uint256 seriesId;
        uint256 collateralIn;
        uint256 staticsDollarMinted;
        uint256 sharesMinted;
        uint256 feeAmount;
        uint256 insuranceContribution;
        uint256 priceWad;
        uint256 collateralPerPairWad;
        uint256 collateralRatioBpsAfter;
    }

    struct RedemptionPreview {
        uint256 profileId;
        uint256 seriesId;
        address collateralToken;
        uint256 staticsDollarBurned;
        uint256 sharesBurned;
        uint256 collateralOut;
        uint256 feeAmount;
        // Informational only. Zero means the oracle was unavailable; redemption
        // amounts never depend on these two fields.
        uint256 priceWad;
        uint256 collateralRatioBpsAfter;
    }

    struct PeggedMintPreview {
        uint256 profileId;
        address collateralToken;
        uint256 staticsDollarMinted;
        uint256 principalCollateral;
        uint256 feeAmount;
        uint256 totalCollateralIn;
        uint256 priceWad;
    }

    struct PeggedRedemptionPreview {
        uint256 profileId;
        address collateralToken;
        uint256 staticsDollarBurned;
        uint256 grossCollateral;
        uint256 feeAmount;
        uint256 collateralOut;
        uint256 priceWad;
    }
}
