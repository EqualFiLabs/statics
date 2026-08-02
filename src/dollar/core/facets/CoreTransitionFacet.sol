// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IStaticsDollarRiskShares} from "../../interfaces/IStaticsDollarRiskShares.sol";
import {IStaticsDollarCoreTypes} from "../../interfaces/IStaticsDollarCoreTypes.sol";
import {LibCoreAccounting} from "../libraries/LibCoreAccounting.sol";
import {LibCorePeggedRedemption} from "../libraries/LibCorePeggedRedemption.sol";
import {LibCoreRecovery} from "../libraries/LibCoreRecovery.sol";
import {LibCoreStorage} from "../libraries/LibCoreStorage.sol";

contract CoreTransitionFacet is ReentrancyGuard {
    uint256 public constant SERIES_TRANSITION_DELAY = 7 days;

    event SeriesTransitionStarted(
        uint256 indexed profileId,
        uint256 indexed seriesId,
        IStaticsDollarCoreTypes.TransitionKind kind,
        uint256 priceWad,
        uint256 endsAt
    );
    event SeriesTransitionCancelled(uint256 indexed profileId, uint256 indexed seriesId, uint256 priceWad);
    event RiskSharesReturned(address indexed holder, uint256 indexed seriesId, uint256 shares);
    event ReturnedRiskSharesReclaimed(
        address indexed holder, address indexed receiver, uint256 indexed seriesId, uint256 shares
    );
    event SeriesTransitionFinalized(
        uint256 indexed profileId,
        uint256 indexed oldSeriesId,
        uint256 indexed successorSeriesId,
        IStaticsDollarCoreTypes.TransitionKind kind,
        uint256 priceWad,
        uint256 insuranceAdded
    );
    event SeriesOpened(uint256 indexed profileId, uint256 indexed seriesId, uint256 priceWad);
    event SeriesClosed(uint256 indexed profileId, uint256 indexed seriesId);

    error ZeroAddress();
    error ZeroAmount();
    error InvalidProfileKind(
        uint256 profileId, IStaticsDollarCoreTypes.ProfileKind expected, IStaticsDollarCoreTypes.ProfileKind actual
    );
    error InvalidProfileMode(uint256 profileId, IStaticsDollarCoreTypes.ProfileMode mode);
    error SeriesNotActive(uint256 seriesId);
    error SeriesNotPending(uint256 seriesId);
    error TransitionNotEligible(uint256 currentPriceWad, uint256 downsidePriceWad, uint256 upsidePriceWad);
    error TransitionStillEligible(uint256 currentPriceWad, uint256 boundaryPriceWad);
    error TransitionDirectionChanged(uint256 currentPriceWad);
    error TransitionDelayActive(uint256 executableAt);
    error ReturnWindowClosed(uint256 seriesId);
    error NoReturnedShares(uint256 seriesId, address holder);
    error UnexpectedRiskIngressState();
    error TransitionOracleChanged(uint256 seriesId, address expectedOracle, address actualOracle);

    function startSeriesTransition(uint256 profileId)
        external
        nonReentrant
        returns (uint256 seriesId, IStaticsDollarCoreTypes.TransitionKind kind)
    {
        LibCoreStorage.CS storage cs = LibCoreStorage.s();
        LibCoreAccounting.enforceBootstrapFinalized(cs);
        IStaticsDollarCoreTypes.StableCollateralProfile storage profile = LibCoreAccounting.profile(cs, profileId);
        LibCoreAccounting.enforceOperationAvailable(cs, profileId, LibCoreAccounting.PAUSE_ROLLOVER);
        if (profile.kind != IStaticsDollarCoreTypes.ProfileKind.Volatile) {
            revert InvalidProfileKind(profileId, IStaticsDollarCoreTypes.ProfileKind.Volatile, profile.kind);
        }
        if (profile.mode != IStaticsDollarCoreTypes.ProfileMode.Active) {
            revert InvalidProfileMode(profileId, profile.mode);
        }
        seriesId = profile.activeSeriesId;
        IStaticsDollarCoreTypes.RiskSeries storage series = cs.riskSeries[seriesId];
        if (series.status != IStaticsDollarCoreTypes.SeriesStatus.Active) revert SeriesNotActive(seriesId);

        uint256 priceWad = LibCoreAccounting.readPriceWad(profile);
        uint256 downside = LibCoreAccounting.downsideTriggerPrice(series);
        uint256 upside = LibCoreAccounting.upsideTriggerPrice(series);
        if (priceWad > downside && priceWad < upside) {
            revert TransitionNotEligible(priceWad, downside, upside);
        }
        kind = priceWad <= downside
            ? IStaticsDollarCoreTypes.TransitionKind.Downside
            : IStaticsDollarCoreTypes.TransitionKind.Upside;
        IStaticsDollarCoreTypes.SeriesRecoveryState storage recovery = cs.seriesRecovery[seriesId];
        recovery.kind = kind;
        recovery.startedAt = uint64(block.timestamp);
        recovery.endsAt = uint64(block.timestamp + SERIES_TRANSITION_DELAY);
        series.status = IStaticsDollarCoreTypes.SeriesStatus.RecoveryPending;
        if (kind == IStaticsDollarCoreTypes.TransitionKind.Downside) {
            LibCorePeggedRedemption.startDownside(cs, seriesId);
        }
        cs.transitionSnapshot[seriesId] = LibCoreStorage.TransitionSnapshot({
            oracle: profile.oracle,
            oracleRevision: cs.profileOracleRevision[profileId],
            collateralRatioBps: profile.collateralRatioBps,
            priceBandBps: profile.priceBandBps
        });
        emit SeriesTransitionStarted(profileId, seriesId, kind, priceWad, recovery.endsAt);
    }

    function cancelSeriesTransition(uint256 seriesId) external nonReentrant {
        LibCoreStorage.CS storage cs = LibCoreStorage.s();
        IStaticsDollarCoreTypes.RiskSeries storage series = cs.riskSeries[seriesId];
        if (series.status != IStaticsDollarCoreTypes.SeriesStatus.RecoveryPending) revert SeriesNotPending(seriesId);
        IStaticsDollarCoreTypes.StableCollateralProfile storage profile = cs.collateralProfiles[series.profileId];
        IStaticsDollarCoreTypes.SeriesRecoveryState storage recovery = cs.seriesRecovery[seriesId];
        uint256 priceWad = LibCoreAccounting.readPriceWad(profile);
        uint256 boundary = recovery.kind == IStaticsDollarCoreTypes.TransitionKind.Downside
            ? LibCoreAccounting.downsideTriggerPrice(series)
            : LibCoreAccounting.upsideTriggerPrice(series);
        bool stillEligible = recovery.kind == IStaticsDollarCoreTypes.TransitionKind.Downside
            ? priceWad <= boundary
            : priceWad >= boundary;
        if (stillEligible) revert TransitionStillEligible(priceWad, boundary);
        LibCorePeggedRedemption.resolveDownside(cs, seriesId);
        recovery.kind = IStaticsDollarCoreTypes.TransitionKind.None;
        recovery.startedAt = 0;
        recovery.endsAt = 0;
        series.status = IStaticsDollarCoreTypes.SeriesStatus.Active;
        delete cs.transitionSnapshot[seriesId];
        emit SeriesTransitionCancelled(series.profileId, seriesId, priceWad);
    }

    function returnRiskShares(uint256 seriesId, uint256 shares) external nonReentrant {
        if (shares == 0) revert ZeroAmount();
        LibCoreStorage.CS storage cs = LibCoreStorage.s();
        IStaticsDollarCoreTypes.RiskSeries storage series = cs.riskSeries[seriesId];
        if (series.status != IStaticsDollarCoreTypes.SeriesStatus.RecoveryPending) revert SeriesNotPending(seriesId);
        IStaticsDollarCoreTypes.SeriesRecoveryState storage recovery = cs.seriesRecovery[seriesId];
        if (block.timestamp >= recovery.endsAt) revert ReturnWindowClosed(seriesId);
        cs.expectedRiskIngress =
            LibCoreStorage.ExpectedRiskIngress({from: msg.sender, seriesId: seriesId, amount: shares, active: true});
        IStaticsDollarRiskShares(cs.staticsDollarRisk).safeTransferFrom(msg.sender, address(this), seriesId, shares, "");
        if (cs.expectedRiskIngress.active) revert UnexpectedRiskIngressState();
        cs.returnedRiskShares[seriesId][msg.sender] += shares;
        recovery.returnedShares += shares;
        emit RiskSharesReturned(msg.sender, seriesId, shares);
    }

    function reclaimReturnedRiskShares(uint256 seriesId, address receiver)
        external
        nonReentrant
        returns (uint256 shares)
    {
        if (receiver == address(0)) revert ZeroAddress();
        LibCoreStorage.CS storage cs = LibCoreStorage.s();
        IStaticsDollarCoreTypes.RiskSeries storage series = cs.riskSeries[seriesId];
        IStaticsDollarCoreTypes.SeriesRecoveryState storage recovery = cs.seriesRecovery[seriesId];
        if (
            series.status != IStaticsDollarCoreTypes.SeriesStatus.Active
                || recovery.kind != IStaticsDollarCoreTypes.TransitionKind.None
        ) {
            revert SeriesNotActive(seriesId);
        }
        shares = cs.returnedRiskShares[seriesId][msg.sender];
        if (shares == 0) revert NoReturnedShares(seriesId, msg.sender);
        delete cs.returnedRiskShares[seriesId][msg.sender];
        recovery.returnedShares -= shares;
        IStaticsDollarRiskShares(cs.staticsDollarRisk).safeTransferFrom(address(this), receiver, seriesId, shares, "");
        emit ReturnedRiskSharesReclaimed(msg.sender, receiver, seriesId, shares);
    }

    function finalizeSeriesTransition(uint256 seriesId) external nonReentrant returns (uint256 successorSeriesId) {
        LibCoreStorage.CS storage cs = LibCoreStorage.s();
        IStaticsDollarCoreTypes.RiskSeries storage series = cs.riskSeries[seriesId];
        if (series.status != IStaticsDollarCoreTypes.SeriesStatus.RecoveryPending) revert SeriesNotPending(seriesId);
        IStaticsDollarCoreTypes.SeriesRecoveryState storage recovery = cs.seriesRecovery[seriesId];
        if (block.timestamp < recovery.endsAt) revert TransitionDelayActive(recovery.endsAt);
        IStaticsDollarCoreTypes.StableCollateralProfile storage profile = cs.collateralProfiles[series.profileId];
        LibCoreStorage.TransitionSnapshot memory snapshot = cs.transitionSnapshot[seriesId];
        if (snapshot.oracle != profile.oracle || snapshot.oracleRevision != cs.profileOracleRevision[series.profileId])
        {
            revert TransitionOracleChanged(seriesId, snapshot.oracle, profile.oracle);
        }
        uint256 priceWad = LibCoreAccounting.readPriceWad(profile);
        uint256 boundary = recovery.kind == IStaticsDollarCoreTypes.TransitionKind.Downside
            ? LibCoreAccounting.downsideTriggerPrice(series)
            : LibCoreAccounting.upsideTriggerPrice(series);
        bool stillEligible = recovery.kind == IStaticsDollarCoreTypes.TransitionKind.Downside
            ? priceWad <= boundary
            : priceWad >= boundary;
        if (!stillEligible) revert TransitionDirectionChanged(priceWad);

        uint256 insuranceAdded;
        if (recovery.kind == IStaticsDollarCoreTypes.TransitionKind.Downside) {
            insuranceAdded = LibCoreRecovery.drawAvailableInsurance(cs, seriesId, series, profile, priceWad);
        }
        LibCoreRecovery.partitionReturned(cs, seriesId, series, profile, recovery, priceWad);
        LibCoreRecovery.snapshotExpiredBook(cs, seriesId, series, profile, priceWad);

        successorSeriesId = cs.nextSeriesId++;
        series.status = IStaticsDollarCoreTypes.SeriesStatus.Recoverable;
        series.retiredAt = block.timestamp;
        series.successorSeriesId = successorSeriesId;
        recovery.finalizedAt = uint64(block.timestamp);
        recovery.finalizationPriceWad = priceWad;
        LibCoreRecovery.openSeries(
            cs, successorSeriesId, series.profileId, priceWad, snapshot.collateralRatioBps, snapshot.priceBandBps
        );
        profile.activeSeriesId = successorSeriesId;
        LibCoreAccounting.updateSeriesIndex(cs, seriesId);
        delete cs.transitionSnapshot[seriesId];
        LibCorePeggedRedemption.resolveDownside(cs, seriesId);
        if (LibCoreRecovery.closeIfEmpty(cs, seriesId)) emit SeriesClosed(series.profileId, seriesId);
        emit SeriesOpened(series.profileId, successorSeriesId, priceWad);
        emit SeriesTransitionFinalized(
            series.profileId, seriesId, successorSeriesId, recovery.kind, priceWad, insuranceAdded
        );
    }
}
