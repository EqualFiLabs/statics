// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IStaticsDollarRiskShares} from "../../interfaces/IStaticsDollarRiskShares.sol";
import {IStaticsDollar} from "../../interfaces/IStaticsDollar.sol";
import {IStaticsDollarCoreTypes} from "../../interfaces/IStaticsDollarCoreTypes.sol";
import {LibCoreAccounting} from "../libraries/LibCoreAccounting.sol";
import {LibCoreHealth} from "../libraries/LibCoreHealth.sol";
import {LibCoreRecovery} from "../libraries/LibCoreRecovery.sol";
import {LibCoreStorage} from "../libraries/LibCoreStorage.sol";

contract CoreRecoveryFacet is ReentrancyGuard {
    struct CollateralExitCheckpoint {
        uint256 baselineDeficitWad;
        bool impairedRunoff;
    }

    event ReturnedRiskClaimed(
        address indexed holder,
        address indexed receiver,
        uint256 indexed oldSeriesId,
        uint256 oldShares,
        uint256 successorPairs,
        uint256 collateralIn,
        uint256 collateralOut
    );
    event RecoverySeniorRedeemed(
        address indexed caller,
        address indexed receiver,
        uint256 indexed seriesId,
        uint256 staticsDollarBurned,
        uint256 collateralOut
    );
    event ExpiredRiskRecovered(
        address indexed keeper,
        address indexed holder,
        uint256 indexed oldSeriesId,
        uint256 sharesBurned,
        uint256 staticsDollarBurned,
        uint256 seniorCollateralOut,
        uint256 keeperBounty,
        uint256 holderPairs,
        uint256 holderCollateralDust
    );
    event SeriesClosed(uint256 indexed profileId, uint256 indexed seriesId);

    error ZeroAddress();
    error ZeroAmount();
    error SeriesNotRecoverable(uint256 seriesId);
    error SeriesNotActive(uint256 seriesId);
    error NoReturnedShares(uint256 seriesId, address holder);
    error EmptyPool();
    error CollateralAboveMaximum(uint256 required, uint256 maximum);
    error SlippageExceeded(uint256 actual, uint256 minimum);
    error InvalidRecoveryMode(IStaticsDollarCoreTypes.RecoveryClaimMode mode);
    error InvalidProfileMode(uint256 profileId, IStaticsDollarCoreTypes.ProfileMode mode);
    error DebtCeilingExceeded(uint256 profileId, uint256 attemptedSeniorOutstanding, uint256 debtCeiling);
    error TransitionRequired(uint256 profileId, uint256 seriesId, uint256 currentPriceWad);
    error CollateralExitUnavailable(IStaticsDollarCoreTypes.ExitStatus status, uint256 unhealthyProfileBitmap);
    error CollateralExitWorsensHealth(
        uint256 profileId,
        IStaticsDollarCoreTypes.GlobalHealthPhase projectedPhase,
        uint256 baselineDeficitWad,
        uint256 projectedDeficitWad
    );
    error Unauthorized(address caller);
    error PartialRecoveryNotAllowed(address holder, uint256 provided, uint256 fullBalance);

    function previewReturnedRiskClaim(address holder, uint256 seriesId, IStaticsDollarCoreTypes.RecoveryClaimMode mode)
        external
        view
        returns (IStaticsDollarCoreTypes.RecoveryClaimPreview memory preview)
    {
        return _previewReturnedRiskClaim(LibCoreStorage.s(), holder, seriesId, mode);
    }

    function claimReturnedRisk(
        uint256 seriesId,
        IStaticsDollarCoreTypes.RecoveryClaimMode mode,
        uint256 maximumCollateralIn,
        uint256 minimumSharesOut,
        uint256 minimumCollateralOut,
        address receiver
    ) external nonReentrant returns (uint256 successorPairs, uint256 collateralIn, uint256 collateralOut) {
        if (receiver == address(0)) revert ZeroAddress();
        LibCoreStorage.CS storage cs = LibCoreStorage.s();
        IStaticsDollarCoreTypes.RecoveryClaimPreview memory preview =
            _previewReturnedRiskClaim(cs, msg.sender, seriesId, mode);
        if (preview.collateralIn > maximumCollateralIn) {
            revert CollateralAboveMaximum(preview.collateralIn, maximumCollateralIn);
        }
        if (preview.successorPairs < minimumSharesOut) {
            revert SlippageExceeded(preview.successorPairs, minimumSharesOut);
        }
        if (preview.collateralOut < minimumCollateralOut) {
            revert SlippageExceeded(preview.collateralOut, minimumCollateralOut);
        }
        IStaticsDollarCoreTypes.RiskSeries storage oldSeries = cs.riskSeries[seriesId];
        CollateralExitCheckpoint memory exitCheckpoint;
        if (preview.collateralOut != 0) {
            exitCheckpoint = _checkpointCollateralExit(cs, oldSeries.profileId);
        }
        IStaticsDollarCoreTypes.StableCollateralProfile storage profile = cs.collateralProfiles[oldSeries.profileId];
        IStaticsDollarCoreTypes.SeriesRecoveryState storage recovery = cs.seriesRecovery[seriesId];
        bool issuesSuccessor = preview.successorPairs != 0;
        if (issuesSuccessor) {
            _enforceIssuanceAvailable(cs, oldSeries.profileId, preview.successorSeriesId, preview.successorPairs);
        }

        delete cs.returnedRiskShares[seriesId][msg.sender];
        recovery.returnedSharesClaimed += preview.oldShares;
        recovery.juniorRecoveryShares -= preview.oldShares;
        recovery.juniorRecoveryCollateral -= preview.juniorCollateral;

        if (preview.collateralIn != 0) {
            LibCoreAccounting.pullExact(oldSeries.collateralToken, msg.sender, preview.collateralIn);
            profile.accountedCollateral += preview.collateralIn;
            cs.accountedCollateralByToken[oldSeries.collateralToken] += preview.collateralIn;
        }
        if (issuesSuccessor) {
            IStaticsDollarCoreTypes.RiskSeries storage successor = cs.riskSeries[preview.successorSeriesId];
            uint256 successorCollateral = preview.juniorCollateral + preview.collateralIn - preview.collateralOut;
            successor.accountedCollateral += successorCollateral;
            successor.seniorOutstanding += preview.successorPairs;
            successor.riskSharesOutstanding += preview.successorPairs;
            profile.seniorOutstanding += preview.successorPairs;
            cs.totalSeniorOutstanding += preview.successorPairs;
            LibCoreAccounting.updateSeriesIndex(cs, preview.successorSeriesId);
            LibCoreAccounting.enforceHealthy(cs, oldSeries.profileId, profile);
        }
        if (preview.collateralOut != 0) {
            profile.accountedCollateral -= preview.collateralOut;
            cs.accountedCollateralByToken[oldSeries.collateralToken] -= preview.collateralOut;
            _enforceProjectedCollateralExit(cs, oldSeries.profileId, exitCheckpoint);
        }
        if (issuesSuccessor) {
            IStaticsDollar(cs.staticsDollar).mint(receiver, preview.successorPairs);
            IStaticsDollarRiskShares(cs.staticsDollarRisk)
                .mint(receiver, preview.successorSeriesId, preview.successorPairs);
        }
        LibCoreAccounting.pushExact(oldSeries.collateralToken, receiver, preview.collateralOut);
        LibCoreAccounting.enforceCustody(cs, oldSeries.collateralToken);
        if (LibCoreRecovery.closeIfEmpty(cs, seriesId)) emit SeriesClosed(oldSeries.profileId, seriesId);
        emit ReturnedRiskClaimed(
            msg.sender,
            receiver,
            seriesId,
            preview.oldShares,
            preview.successorPairs,
            preview.collateralIn,
            preview.collateralOut
        );
        return (preview.successorPairs, preview.collateralIn, preview.collateralOut);
    }

    function redeemRecoverySenior(
        uint256 seriesId,
        uint256 staticsDollarAmount,
        uint256 minimumCollateralOut,
        address receiver
    ) external nonReentrant returns (uint256 collateralOut) {
        if (receiver == address(0)) revert ZeroAddress();
        if (staticsDollarAmount == 0) revert ZeroAmount();
        LibCoreStorage.CS storage cs = LibCoreStorage.s();
        IStaticsDollarCoreTypes.RiskSeries storage series = cs.riskSeries[seriesId];
        if (series.status != IStaticsDollarCoreTypes.SeriesStatus.Recoverable) revert SeriesNotRecoverable(seriesId);
        IStaticsDollarCoreTypes.SeriesRecoveryState storage recovery = cs.seriesRecovery[seriesId];
        if (staticsDollarAmount > recovery.seniorRecoveryOutstanding) revert EmptyPool();
        collateralOut = LibCoreRecovery.proRata(
            recovery.seniorRecoveryCollateral, staticsDollarAmount, recovery.seniorRecoveryOutstanding
        );
        if (collateralOut < minimumCollateralOut) revert SlippageExceeded(collateralOut, minimumCollateralOut);
        CollateralExitCheckpoint memory exitCheckpoint = _checkpointCollateralExit(cs, series.profileId);

        recovery.seniorRecoveryOutstanding -= staticsDollarAmount;
        recovery.seniorRecoveryCollateral -= collateralOut;
        IStaticsDollarCoreTypes.StableCollateralProfile storage profile = cs.collateralProfiles[series.profileId];
        profile.seniorOutstanding -= staticsDollarAmount;
        profile.accountedCollateral -= collateralOut;
        cs.totalSeniorOutstanding -= staticsDollarAmount;
        cs.accountedCollateralByToken[series.collateralToken] -= collateralOut;
        LibCoreAccounting.updateSeriesIndex(cs, seriesId);
        _enforceProjectedCollateralExit(cs, series.profileId, exitCheckpoint);
        IStaticsDollar(cs.staticsDollar).burn(msg.sender, staticsDollarAmount);
        LibCoreAccounting.pushExact(series.collateralToken, receiver, collateralOut);
        LibCoreAccounting.enforceCustody(cs, series.collateralToken);
        if (LibCoreRecovery.closeIfEmpty(cs, seriesId)) emit SeriesClosed(series.profileId, seriesId);
        emit RecoverySeniorRedeemed(msg.sender, receiver, seriesId, staticsDollarAmount, collateralOut);
    }

    function previewExpiredRiskRecovery(
        address holder,
        uint256 seriesId,
        uint256 shares,
        IStaticsDollarCoreTypes.RecoveryClaimMode mode
    ) external view returns (IStaticsDollarCoreTypes.ExpiredRiskRecoveryPreview memory preview) {
        return _previewExpiredRiskRecovery(LibCoreStorage.s(), holder, seriesId, shares, mode);
    }

    function recoverExpiredRisk(
        address holder,
        uint256 seriesId,
        uint256 shares,
        IStaticsDollarCoreTypes.RecoveryClaimMode mode,
        uint256 minimumKeeperOut
    ) external nonReentrant returns (uint256 staticsDollarBurned, uint256 keeperCollateralOut, uint256 holderPairs) {
        if (holder == address(0)) revert ZeroAddress();
        if (mode == IStaticsDollarCoreTypes.RecoveryClaimMode.ExactUnits) revert InvalidRecoveryMode(mode);
        LibCoreStorage.CS storage cs = LibCoreStorage.s();
        bool managed = cs.managedRecoveryHolder[holder];
        if (managed && msg.sender != holder) revert Unauthorized(msg.sender);
        uint256 holderBalance = IStaticsDollarRiskShares(cs.staticsDollarRisk).balanceOf(holder, seriesId);
        if (!managed && shares != holderBalance) {
            revert PartialRecoveryNotAllowed(holder, shares, holderBalance);
        }
        IStaticsDollarCoreTypes.ExpiredRiskRecoveryPreview memory preview =
            _previewExpiredRiskRecovery(cs, holder, seriesId, shares, mode);
        keeperCollateralOut = preview.seniorCollateralOut + preview.keeperBounty;
        if (keeperCollateralOut < minimumKeeperOut) {
            revert SlippageExceeded(keeperCollateralOut, minimumKeeperOut);
        }
        IStaticsDollarCoreTypes.RiskSeries storage oldSeries = cs.riskSeries[seriesId];
        CollateralExitCheckpoint memory exitCheckpoint = _checkpointCollateralExit(cs, oldSeries.profileId);
        IStaticsDollarCoreTypes.StableCollateralProfile storage profile = cs.collateralProfiles[oldSeries.profileId];
        bool issuesSuccessor = preview.holderPairs != 0;
        if (issuesSuccessor) {
            _enforceIssuanceAvailable(cs, oldSeries.profileId, preview.successorSeriesId, preview.holderPairs);
        }
        LibCoreStorage.ExpiredRecoveryBook storage book = cs.expiredRecoveryBook[seriesId];
        uint256 gross = preview.seniorCollateralOut + preview.juniorCollateral;
        uint256 successorCollateral = preview.holderCollateral - preview.holderCollateralDust;

        LibCoreRecovery.consumeExpiredBook(book, shares, gross);
        oldSeries.seniorOutstanding -= shares;
        oldSeries.riskSharesOutstanding -= shares;
        oldSeries.accountedCollateral -= gross;
        profile.seniorOutstanding -= shares;
        cs.totalSeniorOutstanding -= shares;
        IStaticsDollar(cs.staticsDollar).burn(msg.sender, shares);
        IStaticsDollarRiskShares(cs.staticsDollarRisk).burn(holder, seriesId, shares);

        if (issuesSuccessor) {
            IStaticsDollarCoreTypes.RiskSeries storage successor = cs.riskSeries[preview.successorSeriesId];
            successor.seniorOutstanding += preview.holderPairs;
            successor.riskSharesOutstanding += preview.holderPairs;
            successor.accountedCollateral += successorCollateral;
            profile.seniorOutstanding += preview.holderPairs;
            cs.totalSeniorOutstanding += preview.holderPairs;
            LibCoreAccounting.updateSeriesIndex(cs, preview.successorSeriesId);
        }
        uint256 transferred = keeperCollateralOut + preview.holderCollateralDust;
        profile.accountedCollateral -= transferred;
        cs.accountedCollateralByToken[oldSeries.collateralToken] -= transferred;
        LibCoreAccounting.updateSeriesIndex(cs, seriesId);
        if (issuesSuccessor) LibCoreAccounting.enforceHealthy(cs, oldSeries.profileId, profile);
        _enforceProjectedCollateralExit(cs, oldSeries.profileId, exitCheckpoint);
        if (issuesSuccessor) {
            IStaticsDollar(cs.staticsDollar).mint(holder, preview.holderPairs);
            IStaticsDollarRiskShares(cs.staticsDollarRisk).mint(holder, preview.successorSeriesId, preview.holderPairs);
        }
        LibCoreAccounting.pushExact(oldSeries.collateralToken, msg.sender, keeperCollateralOut);
        LibCoreAccounting.pushExact(oldSeries.collateralToken, holder, preview.holderCollateralDust);
        LibCoreAccounting.enforceCustody(cs, oldSeries.collateralToken);
        if (LibCoreRecovery.closeIfEmpty(cs, seriesId)) emit SeriesClosed(oldSeries.profileId, seriesId);
        emit ExpiredRiskRecovered(
            msg.sender,
            holder,
            seriesId,
            shares,
            shares,
            preview.seniorCollateralOut,
            preview.keeperBounty,
            preview.holderPairs,
            preview.holderCollateralDust
        );
        return (shares, keeperCollateralOut, preview.holderPairs);
    }

    function _previewReturnedRiskClaim(
        LibCoreStorage.CS storage cs,
        address holder,
        uint256 seriesId,
        IStaticsDollarCoreTypes.RecoveryClaimMode mode
    ) private view returns (IStaticsDollarCoreTypes.RecoveryClaimPreview memory preview) {
        IStaticsDollarCoreTypes.RiskSeries storage oldSeries = cs.riskSeries[seriesId];
        if (oldSeries.status != IStaticsDollarCoreTypes.SeriesStatus.Recoverable) {
            revert SeriesNotRecoverable(seriesId);
        }
        uint256 oldShares = cs.returnedRiskShares[seriesId][holder];
        if (oldShares == 0) revert NoReturnedShares(seriesId, holder);
        IStaticsDollarCoreTypes.SeriesRecoveryState storage recovery = cs.seriesRecovery[seriesId];
        uint256 junior =
            LibCoreRecovery.proRata(recovery.juniorRecoveryCollateral, oldShares, recovery.juniorRecoveryShares);
        IStaticsDollarCoreTypes.StableCollateralProfile storage profile = cs.collateralProfiles[oldSeries.profileId];
        uint256 successorSeriesId = profile.activeSeriesId;
        if (mode == IStaticsDollarCoreTypes.RecoveryClaimMode.CollateralOnly) {
            return IStaticsDollarCoreTypes.RecoveryClaimPreview({
                oldSeriesId: seriesId,
                successorSeriesId: successorSeriesId,
                oldShares: oldShares,
                juniorCollateral: junior,
                collateralIn: 0,
                collateralOut: junior,
                successorPairs: 0
            });
        }
        IStaticsDollarCoreTypes.RiskSeries storage successor = cs.riskSeries[successorSeriesId];
        if (successor.status != IStaticsDollarCoreTypes.SeriesStatus.Active) revert SeriesNotActive(successorSeriesId);
        uint256 pairs = mode == IStaticsDollarCoreTypes.RecoveryClaimMode.ExactUnits
            ? oldShares
            : LibCoreRecovery.sharesForCollateral(junior, profile.decimals, successor.collateralPerPairWad);
        uint256 required = LibCoreRecovery.collateralForShares(pairs, profile.decimals, successor.collateralPerPairWad);
        while (required > junior && mode == IStaticsDollarCoreTypes.RecoveryClaimMode.NAV && pairs != 0) {
            unchecked {
                --pairs;
            }
            required = LibCoreRecovery.collateralForShares(pairs, profile.decimals, successor.collateralPerPairWad);
        }
        return IStaticsDollarCoreTypes.RecoveryClaimPreview({
            oldSeriesId: seriesId,
            successorSeriesId: successorSeriesId,
            oldShares: oldShares,
            juniorCollateral: junior,
            collateralIn: required > junior ? required - junior : 0,
            collateralOut: junior > required ? junior - required : 0,
            successorPairs: pairs
        });
    }

    function _previewExpiredRiskRecovery(
        LibCoreStorage.CS storage cs,
        address holder,
        uint256 seriesId,
        uint256 shares,
        IStaticsDollarCoreTypes.RecoveryClaimMode mode
    ) private view returns (IStaticsDollarCoreTypes.ExpiredRiskRecoveryPreview memory preview) {
        if (shares == 0) revert ZeroAmount();
        if (mode == IStaticsDollarCoreTypes.RecoveryClaimMode.ExactUnits) revert InvalidRecoveryMode(mode);
        IStaticsDollarCoreTypes.RiskSeries storage oldSeries = cs.riskSeries[seriesId];
        if (oldSeries.status != IStaticsDollarCoreTypes.SeriesStatus.Recoverable) {
            revert SeriesNotRecoverable(seriesId);
        }
        LibCoreStorage.ExpiredRecoveryBook storage book = cs.expiredRecoveryBook[seriesId];
        if (
            shares > IStaticsDollarRiskShares(cs.staticsDollarRisk).balanceOf(holder, seriesId)
                || shares > oldSeries.seniorOutstanding || shares > book.remainingShares
        ) revert EmptyPool();
        (uint256 gross, uint256 senior, uint256 bounty) = LibCoreRecovery.expiredBookSlice(book, shares);
        uint256 junior = gross - senior;
        uint256 holderCollateral = junior - bounty;
        IStaticsDollarCoreTypes.StableCollateralProfile storage profile = cs.collateralProfiles[oldSeries.profileId];
        uint256 successorSeriesId = profile.activeSeriesId;
        uint256 holderPairs;
        uint256 used;
        if (mode == IStaticsDollarCoreTypes.RecoveryClaimMode.NAV) {
            IStaticsDollarCoreTypes.RiskSeries storage successor = cs.riskSeries[successorSeriesId];
            if (successor.status != IStaticsDollarCoreTypes.SeriesStatus.Active) {
                revert SeriesNotActive(successorSeriesId);
            }
            holderPairs =
                LibCoreRecovery.sharesForCollateral(holderCollateral, profile.decimals, successor.collateralPerPairWad);
            used = LibCoreRecovery.collateralForShares(holderPairs, profile.decimals, successor.collateralPerPairWad);
            while (used > holderCollateral && holderPairs != 0) {
                unchecked {
                    --holderPairs;
                }
                used =
                    LibCoreRecovery.collateralForShares(holderPairs, profile.decimals, successor.collateralPerPairWad);
            }
        }
        return IStaticsDollarCoreTypes.ExpiredRiskRecoveryPreview({
            oldSeriesId: seriesId,
            successorSeriesId: successorSeriesId,
            sharesBurned: shares,
            staticsDollarBurned: shares,
            seniorCollateralOut: senior,
            juniorCollateral: junior,
            keeperBounty: bounty,
            holderCollateral: holderCollateral,
            holderPairs: holderPairs,
            holderCollateralDust: holderCollateral - used
        });
    }

    function _enforceIssuanceAvailable(
        LibCoreStorage.CS storage cs,
        uint256 profileId,
        uint256 successorSeriesId,
        uint256 pairs
    ) private view {
        IStaticsDollarCoreTypes.StableCollateralProfile storage profile = cs.collateralProfiles[profileId];
        if (profile.mode != IStaticsDollarCoreTypes.ProfileMode.Active) {
            revert InvalidProfileMode(profileId, profile.mode);
        }
        LibCoreAccounting.enforceOperationAvailable(cs, profileId, LibCoreAccounting.PAUSE_MINTING);
        LibCoreAccounting.enforceHealthy(cs, profileId, profile);
        IStaticsDollarCoreTypes.RiskSeries storage successor = cs.riskSeries[successorSeriesId];
        if (successor.status != IStaticsDollarCoreTypes.SeriesStatus.Active) revert SeriesNotActive(successorSeriesId);
        uint256 priceWad = LibCoreAccounting.readPriceWad(profile);
        if (
            priceWad <= LibCoreAccounting.downsideTriggerPrice(successor)
                || priceWad >= LibCoreAccounting.upsideTriggerPrice(successor)
        ) revert TransitionRequired(profileId, successorSeriesId, priceWad);
        uint256 attemptedSenior = profile.seniorOutstanding + pairs;
        if (attemptedSenior > profile.debtCeiling) {
            revert DebtCeilingExceeded(profileId, attemptedSenior, profile.debtCeiling);
        }
    }

    function _checkpointCollateralExit(LibCoreStorage.CS storage cs, uint256 profileId)
        private
        returns (CollateralExitCheckpoint memory checkpoint)
    {
        (IStaticsDollarCoreTypes.ExitStatus status, uint256 bitmap, uint256 deficit,) =
            LibCoreHealth.checkpointGlobalHealth(cs, false);
        if (status == IStaticsDollarCoreTypes.ExitStatus.Available) return checkpoint;
        if (status == IStaticsDollarCoreTypes.ExitStatus.Impaired && (bitmap & (uint256(1) << profileId)) != 0) {
            checkpoint.baselineDeficitWad = deficit;
            checkpoint.impairedRunoff = true;
            return checkpoint;
        }
        revert CollateralExitUnavailable(status, bitmap);
    }

    function _enforceProjectedCollateralExit(
        LibCoreStorage.CS storage cs,
        uint256 profileId,
        CollateralExitCheckpoint memory checkpoint
    ) private view {
        (IStaticsDollarCoreTypes.GlobalHealthPhase phase,, uint256 deficit) = LibCoreHealth.currentGlobalHealth(cs);
        bool valid = checkpoint.impairedRunoff
            ? phase != IStaticsDollarCoreTypes.GlobalHealthPhase.Unavailable && deficit <= checkpoint.baselineDeficitWad
            : phase == IStaticsDollarCoreTypes.GlobalHealthPhase.Healthy;
        if (!valid) {
            revert CollateralExitWorsensHealth(profileId, phase, checkpoint.baselineDeficitWad, deficit);
        }
    }
}
