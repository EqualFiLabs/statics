// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IStaticsDollarCoreTypes} from "../../interfaces/IStaticsDollarCoreTypes.sol";
import {LibCoreAccounting} from "../libraries/LibCoreAccounting.sol";
import {LibCoreHealth} from "../libraries/LibCoreHealth.sol";
import {LibCoreStorage} from "../libraries/LibCoreStorage.sol";
import {LibSolvencyIndex} from "../libraries/LibSolvencyIndex.sol";

contract CoreViewFacet {
    using LibSolvencyIndex for LibSolvencyIndex.Tree;

    uint256 internal constant ALL_OPERATION_PAUSES = (1 << 0) | (1 << 1) | (1 << 2);

    error InvalidOperationMask(uint256 operations);
    error InvalidProfile(uint256 profileId);
    error InvalidSeries(uint256 seriesId);

    function staticsDollar() external view returns (address) {
        return LibCoreStorage.s().staticsDollar;
    }

    function staticsDollarRisk() external view returns (address) {
        return LibCoreStorage.s().staticsDollarRisk;
    }

    function initialOracle() external view returns (address) {
        return LibCoreStorage.s().initialOracle;
    }

    function requiredSequencerUptimeFeed() external view returns (address) {
        return LibCoreStorage.s().requiredSequencerUptimeFeed;
    }

    function minimumSequencerGracePeriod() external view returns (uint256) {
        return LibCoreStorage.s().minimumSequencerGracePeriod;
    }

    function profileGuardian() external view returns (address) {
        return LibCoreStorage.s().profileGuardian;
    }

    function bootstrapAuthority() external view returns (address) {
        return LibCoreStorage.s().bootstrapAuthority;
    }

    function periphery() external view returns (address) {
        return LibCoreStorage.s().periphery;
    }

    function positionNFT() external view returns (address) {
        return LibCoreStorage.s().periphery;
    }

    function initialized() external view returns (bool) {
        return LibCoreStorage.s().initialized;
    }

    function bootstrapFinalized() external view returns (bool) {
        return LibCoreStorage.s().bootstrapFinalized;
    }

    function firstCollateralProfileId() external pure returns (uint256) {
        return 1;
    }

    function nextProfileId() external view returns (uint256) {
        return LibCoreStorage.s().nextProfileId;
    }

    function nextSeriesId() external view returns (uint256) {
        return LibCoreStorage.s().nextSeriesId;
    }

    function seniorLiabilities() external view returns (uint256) {
        return LibCoreStorage.s().totalSeniorOutstanding;
    }

    function globalImpairmentLatched() external view returns (bool) {
        return LibCoreStorage.s().globalImpairmentLatched;
    }

    function globalRecoveryStartedAt() external view returns (uint256) {
        return LibCoreStorage.s().globalRecoveryStartedAt;
    }

    function collateralProfile(uint256 profileId)
        external
        view
        returns (IStaticsDollarCoreTypes.StableCollateralProfile memory profile)
    {
        profile = LibCoreStorage.s().collateralProfiles[profileId];
        if (profile.collateralToken == address(0)) revert InvalidProfile(profileId);
    }

    function riskSeries(uint256 seriesId) external view returns (IStaticsDollarCoreTypes.RiskSeries memory series) {
        series = LibCoreStorage.s().riskSeries[seriesId];
        if (series.status == IStaticsDollarCoreTypes.SeriesStatus.None) revert InvalidSeries(seriesId);
    }

    function seriesRecoveryState(uint256 seriesId)
        external
        view
        returns (IStaticsDollarCoreTypes.SeriesRecoveryState memory state)
    {
        if (LibCoreStorage.s().riskSeries[seriesId].status == IStaticsDollarCoreTypes.SeriesStatus.None) {
            revert InvalidSeries(seriesId);
        }
        return LibCoreStorage.s().seriesRecovery[seriesId];
    }

    function returnedRiskShares(uint256 seriesId, address holder) external view returns (uint256 shares) {
        if (LibCoreStorage.s().riskSeries[seriesId].status == IStaticsDollarCoreTypes.SeriesStatus.None) {
            revert InvalidSeries(seriesId);
        }
        return LibCoreStorage.s().returnedRiskShares[seriesId][holder];
    }

    function totalCollateral(address collateralToken) external view returns (uint256 amount) {
        return LibCoreStorage.s().accountedCollateralByToken[collateralToken];
    }

    function collateralTokenProfileId(address collateralToken) external view returns (uint256 profileId) {
        return LibCoreStorage.s().profileIdByCollateralToken[collateralToken];
    }

    function profileOracleRevision(uint256 profileId) external view returns (uint256 revision) {
        return LibCoreStorage.s().profileOracleRevision[profileId];
    }

    function profileSeniorLiabilities(uint256 profileId) external view returns (uint256 amount) {
        return LibCoreStorage.s().collateralProfiles[profileId].seniorOutstanding;
    }

    function insuranceReserve(uint256 profileId) external view returns (uint256 amount) {
        return LibCoreStorage.s().collateralProfiles[profileId].insuranceReserve;
    }

    function profileSeriesCount(uint256 profileId) external view returns (uint256 count) {
        return LibCoreStorage.s().profileSeries[profileId].length;
    }

    function profileSeriesAt(uint256 profileId, uint256 index) external view returns (uint256 seriesId) {
        return LibCoreStorage.s().profileSeries[profileId][index];
    }

    function pausedProfileOperations(uint256 profileId) external view returns (uint256 operations) {
        return LibCoreStorage.s().pausedProfileOperations[profileId];
    }

    function profileOperationPaused(uint256 profileId, uint256 operation) external view returns (bool paused) {
        if (LibCoreStorage.s().collateralProfiles[profileId].collateralToken == address(0)) {
            revert InvalidProfile(profileId);
        }
        if (operation == 0 || (operation & ~ALL_OPERATION_PAUSES) != 0) revert InvalidOperationMask(operation);
        return (LibCoreStorage.s().pausedProfileOperations[profileId] & operation) != 0;
    }

    function solvencyBookContribution(uint256 profileId, bytes32 bookId)
        external
        view
        returns (LibSolvencyIndex.BookContribution memory contribution)
    {
        return LibCoreStorage.s().solvencyIndex[profileId].bookContribution(bookId);
    }

    function solvencyIndexMetadata(uint256 profileId) external view returns (uint256 activeBooks, uint256 height) {
        LibSolvencyIndex.Tree storage tree = LibCoreStorage.s().solvencyIndex[profileId];
        return (tree.activeBooks, tree.rootHeight());
    }

    function cumulativeFeesPaid(address payer, address collateralToken) external view returns (uint256 amount) {
        return LibCoreStorage.s().cumulativeFeesPaid[payer][collateralToken];
    }

    function seriesCollateralValueWad(uint256 seriesId) external view returns (uint256 valueWad) {
        LibCoreStorage.CS storage cs = LibCoreStorage.s();
        IStaticsDollarCoreTypes.RiskSeries storage series = cs.riskSeries[seriesId];
        if (series.status == IStaticsDollarCoreTypes.SeriesStatus.None) revert InvalidSeries(seriesId);
        IStaticsDollarCoreTypes.SeriesRecoveryState storage recovery = cs.seriesRecovery[seriesId];
        IStaticsDollarCoreTypes.StableCollateralProfile storage profile = cs.collateralProfiles[series.profileId];
        uint256 collateral =
            series.accountedCollateral + recovery.seniorRecoveryCollateral + recovery.juniorRecoveryCollateral;
        return LibCoreHealth.valueWad(
            LibCoreAccounting.toWad(collateral, profile.decimals), LibCoreAccounting.readPriceWad(profile)
        );
    }

    function seriesCollateralRatioBps(uint256 seriesId) external view returns (uint256 ratioBps) {
        LibCoreStorage.CS storage cs = LibCoreStorage.s();
        IStaticsDollarCoreTypes.RiskSeries storage series = cs.riskSeries[seriesId];
        if (series.status == IStaticsDollarCoreTypes.SeriesStatus.None) revert InvalidSeries(seriesId);
        IStaticsDollarCoreTypes.SeriesRecoveryState storage recovery = cs.seriesRecovery[seriesId];
        IStaticsDollarCoreTypes.StableCollateralProfile storage profile = cs.collateralProfiles[series.profileId];
        return LibCoreAccounting.collateralRatioBps(
            profile.decimals,
            series.accountedCollateral + recovery.seniorRecoveryCollateral,
            series.seniorOutstanding + recovery.seniorRecoveryOutstanding,
            LibCoreAccounting.readPriceWad(profile)
        );
    }

    function collateralUsdPriceWad(uint256 profileId) external view returns (uint256 priceWad) {
        return LibCoreAccounting.readPriceWad(LibCoreAccounting.profile(LibCoreStorage.s(), profileId));
    }

    function seriesDownsideTriggerPriceWad(uint256 seriesId) external view returns (uint256 priceWad) {
        return LibCoreAccounting.downsideTriggerPrice(LibCoreAccounting.series(LibCoreStorage.s(), seriesId));
    }

    function seriesUpsideTriggerPriceWad(uint256 seriesId) external view returns (uint256 priceWad) {
        return LibCoreAccounting.upsideTriggerPrice(LibCoreAccounting.series(LibCoreStorage.s(), seriesId));
    }

    function expiredRecoveryBook(uint256 seriesId)
        external
        view
        returns (
            uint256 remainingShares,
            uint256 remainingCollateral,
            uint256 remainingSeniorCollateral,
            uint256 remainingBountyCollateral
        )
    {
        LibCoreStorage.ExpiredRecoveryBook storage book = LibCoreStorage.s().expiredRecoveryBook[seriesId];
        return (
            book.remainingShares,
            book.remainingCollateral,
            book.remainingSeniorCollateral,
            book.remainingBountyCollateral
        );
    }

    function transitionSnapshot(uint256 seriesId)
        external
        view
        returns (address oracle, uint256 oracleRevision, uint256 collateralRatioBps, uint256 priceBandBps)
    {
        LibCoreStorage.TransitionSnapshot storage snapshot = LibCoreStorage.s().transitionSnapshot[seriesId];
        return (snapshot.oracle, snapshot.oracleRevision, snapshot.collateralRatioBps, snapshot.priceBandBps);
    }

    function managedRecoveryHolder(address holder) external view returns (bool managed) {
        return LibCoreStorage.s().managedRecoveryHolder[holder];
    }
}
