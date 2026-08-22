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

    struct ExpiredRecoveryContext {
        uint256 seriesId;
        uint256 shares;
        address holder;
        bool issuesSuccessor;
        uint256 keeperCollateralOut;
        uint256 gross;
        uint256 successorCollateral;
        uint256 transferredCollateral;
        CollateralExitCheckpoint exitCheckpoint;
    }

    struct ReturnedClaimContext {
        uint256 seriesId;
        address receiver;
        bool issuesSuccessor;
        CollateralExitCheckpoint exitCheckpoint;
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
        ReturnedClaimContext memory ctx = _prepareReturnedClaim(cs, seriesId, receiver, preview);
        _recordReturnedClaim(cs, ctx, preview);
        _settleReturnedClaim(cs, ctx, preview);
        return (preview.successorPairs, preview.collateralIn, preview.collateralOut);
    }

    /// @dev Exit checkpoint (when collateral exits) and the successor-issuance gate.
    function _prepareReturnedClaim(
        LibCoreStorage.CS storage cs,
        uint256 seriesId,
        address receiver,
        IStaticsDollarCoreTypes.RecoveryClaimPreview memory preview
    ) private returns (ReturnedClaimContext memory ctx) {
        IStaticsDollarCoreTypes.RiskSeries storage oldSeries = cs.riskSeries[seriesId];
        ctx = ReturnedClaimContext({
            seriesId: seriesId,
            receiver: receiver,
            issuesSuccessor: preview.successorPairs != 0,
            exitCheckpoint: CollateralExitCheckpoint(0, false)
        });
        if (preview.collateralOut != 0) {
            ctx.exitCheckpoint = _checkpointCollateralExit(cs, oldSeries.profileId);
        }
        if (ctx.issuesSuccessor) {
            _enforceIssuanceAvailable(cs, oldSeries.profileId, preview.successorSeriesId, preview.successorPairs);
        }
    }

    /// @dev Returned-share deletion, recovery bookkeeping, collateral-in pull,
    /// successor accounting with its health checkpoint, and the collateral-out
    /// exit accounting with the projected-exit guard.
    function _recordReturnedClaim(
        LibCoreStorage.CS storage cs,
        ReturnedClaimContext memory ctx,
        IStaticsDollarCoreTypes.RecoveryClaimPreview memory preview
    ) private {
        IStaticsDollarCoreTypes.RiskSeries storage oldSeries = cs.riskSeries[ctx.seriesId];
        IStaticsDollarCoreTypes.StableCollateralProfile storage profile = cs.collateralProfiles[oldSeries.profileId];
        IStaticsDollarCoreTypes.SeriesRecoveryState storage recovery = cs.seriesRecovery[ctx.seriesId];

        delete cs.returnedRiskShares[ctx.seriesId][msg.sender];
        recovery.returnedSharesClaimed += preview.oldShares;
        recovery.juniorRecoveryShares -= preview.oldShares;
        recovery.juniorRecoveryCollateral -= preview.juniorCollateral;

        if (preview.collateralIn != 0) {
            LibCoreAccounting.pullExact(oldSeries.collateralToken, msg.sender, preview.collateralIn);
            profile.accountedCollateral += preview.collateralIn;
            cs.accountedCollateralByToken[oldSeries.collateralToken] += preview.collateralIn;
        }
        if (ctx.issuesSuccessor) {
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
            _enforceProjectedCollateralExit(cs, oldSeries.profileId, ctx.exitCheckpoint);
        }
    }

    /// @dev Successor minting, collateral payout, custody enforcement, terminal
    /// close, and the claim event.
    function _settleReturnedClaim(
        LibCoreStorage.CS storage cs,
        ReturnedClaimContext memory ctx,
        IStaticsDollarCoreTypes.RecoveryClaimPreview memory preview
    ) private {
        IStaticsDollarCoreTypes.RiskSeries storage oldSeries = cs.riskSeries[ctx.seriesId];
        if (ctx.issuesSuccessor) {
            IStaticsDollar(cs.staticsDollar).mint(ctx.receiver, preview.successorPairs);
            IStaticsDollarRiskShares(cs.staticsDollarRisk)
                .mint(ctx.receiver, preview.successorSeriesId, preview.successorPairs);
        }
        LibCoreAccounting.pushExact(oldSeries.collateralToken, ctx.receiver, preview.collateralOut);
        LibCoreAccounting.enforceCustody(cs, oldSeries.collateralToken);
        if (LibCoreRecovery.closeIfEmpty(cs, ctx.seriesId)) emit SeriesClosed(oldSeries.profileId, ctx.seriesId);
        emit ReturnedRiskClaimed(
            msg.sender,
            ctx.receiver,
            ctx.seriesId,
            preview.oldShares,
            preview.successorPairs,
            preview.collateralIn,
            preview.collateralOut
        );
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
        uint256 keeperOut = preview.seniorCollateralOut + preview.keeperBounty;
        if (keeperOut < minimumKeeperOut) {
            revert SlippageExceeded(keeperOut, minimumKeeperOut);
        }

        ExpiredRecoveryContext memory ctx = _prepareExpiredRecovery(cs, holder, seriesId, shares, keeperOut, preview);
        _burnExpiredRisk(cs, ctx);
        _openSuccessorSeries(cs, ctx, preview);
        _closeExpiredCollateral(cs, ctx, preview);
        _settleExpiredRecovery(cs, ctx, preview);
        return (shares, ctx.keeperCollateralOut, preview.holderPairs);
    }

    /// @dev Exit checkpoint, successor-issuance gate, and derived recovery amounts.
    function _prepareExpiredRecovery(
        LibCoreStorage.CS storage cs,
        address holder,
        uint256 seriesId,
        uint256 shares,
        uint256 keeperOut,
        IStaticsDollarCoreTypes.ExpiredRiskRecoveryPreview memory preview
    ) private returns (ExpiredRecoveryContext memory ctx) {
        IStaticsDollarCoreTypes.RiskSeries storage oldSeries = cs.riskSeries[seriesId];
        ctx = ExpiredRecoveryContext({
            seriesId: seriesId,
            shares: shares,
            holder: holder,
            issuesSuccessor: preview.holderPairs != 0,
            keeperCollateralOut: keeperOut,
            gross: preview.seniorCollateralOut + preview.juniorCollateral,
            successorCollateral: preview.holderCollateral - preview.holderCollateralDust,
            transferredCollateral: keeperOut + preview.holderCollateralDust,
            exitCheckpoint: CollateralExitCheckpoint(0, false)
        });
        ctx.exitCheckpoint = _checkpointCollateralExit(cs, oldSeries.profileId);
        if (ctx.issuesSuccessor) {
            _enforceIssuanceAvailable(cs, oldSeries.profileId, preview.successorSeriesId, preview.holderPairs);
        }
    }

    /// @dev Expired-book consumption, old-series accounting, and the paired burns.
    function _burnExpiredRisk(LibCoreStorage.CS storage cs, ExpiredRecoveryContext memory ctx) private {
        IStaticsDollarCoreTypes.RiskSeries storage oldSeries = cs.riskSeries[ctx.seriesId];
        IStaticsDollarCoreTypes.StableCollateralProfile storage profile = cs.collateralProfiles[oldSeries.profileId];
        LibCoreRecovery.consumeExpiredBook(cs.expiredRecoveryBook[ctx.seriesId], ctx.shares, ctx.gross);
        oldSeries.seniorOutstanding -= ctx.shares;
        oldSeries.riskSharesOutstanding -= ctx.shares;
        oldSeries.accountedCollateral -= ctx.gross;
        profile.seniorOutstanding -= ctx.shares;
        cs.totalSeniorOutstanding -= ctx.shares;
        IStaticsDollar(cs.staticsDollar).burn(msg.sender, ctx.shares);
        IStaticsDollarRiskShares(cs.staticsDollarRisk).burn(ctx.holder, ctx.seriesId, ctx.shares);
    }

    /// @dev Successor-series accounting when the claim issues successor pairs.
    function _openSuccessorSeries(
        LibCoreStorage.CS storage cs,
        ExpiredRecoveryContext memory ctx,
        IStaticsDollarCoreTypes.ExpiredRiskRecoveryPreview memory preview
    ) private {
        if (!ctx.issuesSuccessor) return;
        IStaticsDollarCoreTypes.RiskSeries storage oldSeries = cs.riskSeries[ctx.seriesId];
        IStaticsDollarCoreTypes.StableCollateralProfile storage profile = cs.collateralProfiles[oldSeries.profileId];
        IStaticsDollarCoreTypes.RiskSeries storage successor = cs.riskSeries[preview.successorSeriesId];
        successor.seniorOutstanding += preview.holderPairs;
        successor.riskSharesOutstanding += preview.holderPairs;
        successor.accountedCollateral += ctx.successorCollateral;
        profile.seniorOutstanding += preview.holderPairs;
        cs.totalSeniorOutstanding += preview.holderPairs;
        LibCoreAccounting.updateSeriesIndex(cs, preview.successorSeriesId);
    }

    /// @dev Old-series collateral exit accounting plus the health projections.
    function _closeExpiredCollateral(
        LibCoreStorage.CS storage cs,
        ExpiredRecoveryContext memory ctx,
        IStaticsDollarCoreTypes.ExpiredRiskRecoveryPreview memory preview
    ) private {
        IStaticsDollarCoreTypes.RiskSeries storage oldSeries = cs.riskSeries[ctx.seriesId];
        IStaticsDollarCoreTypes.StableCollateralProfile storage profile = cs.collateralProfiles[oldSeries.profileId];
        profile.accountedCollateral -= ctx.transferredCollateral;
        cs.accountedCollateralByToken[oldSeries.collateralToken] -= ctx.transferredCollateral;
        LibCoreAccounting.updateSeriesIndex(cs, ctx.seriesId);
        if (ctx.issuesSuccessor) LibCoreAccounting.enforceHealthy(cs, oldSeries.profileId, profile);
        _enforceProjectedCollateralExit(cs, oldSeries.profileId, ctx.exitCheckpoint);
    }

    /// @dev Successor minting, keeper and holder payouts, custody enforcement,
    /// terminal close, and the recovery event.
    function _settleExpiredRecovery(
        LibCoreStorage.CS storage cs,
        ExpiredRecoveryContext memory ctx,
        IStaticsDollarCoreTypes.ExpiredRiskRecoveryPreview memory preview
    ) private {
        IStaticsDollarCoreTypes.RiskSeries storage oldSeries = cs.riskSeries[ctx.seriesId];
        if (ctx.issuesSuccessor) {
            IStaticsDollar(cs.staticsDollar).mint(ctx.holder, preview.holderPairs);
            IStaticsDollarRiskShares(cs.staticsDollarRisk)
                .mint(ctx.holder, preview.successorSeriesId, preview.holderPairs);
        }
        LibCoreAccounting.pushExact(oldSeries.collateralToken, msg.sender, ctx.keeperCollateralOut);
        LibCoreAccounting.pushExact(oldSeries.collateralToken, ctx.holder, preview.holderCollateralDust);
        LibCoreAccounting.enforceCustody(cs, oldSeries.collateralToken);
        if (LibCoreRecovery.closeIfEmpty(cs, ctx.seriesId)) emit SeriesClosed(oldSeries.profileId, ctx.seriesId);
        emit ExpiredRiskRecovered(
            msg.sender,
            ctx.holder,
            ctx.seriesId,
            ctx.shares,
            ctx.shares,
            preview.seniorCollateralOut,
            preview.keeperBounty,
            preview.holderPairs,
            preview.holderCollateralDust
        );
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
        preview.oldSeriesId = seriesId;
        preview.sharesBurned = shares;
        preview.staticsDollarBurned = shares;
        _fillExpiredSlice(preview, book, shares);
        _fillNavPairs(cs, mode, oldSeries, preview);
    }

    /// @dev Expired-book split into senior, junior, bounty, and holder amounts.
    function _fillExpiredSlice(
        IStaticsDollarCoreTypes.ExpiredRiskRecoveryPreview memory preview,
        LibCoreStorage.ExpiredRecoveryBook storage book,
        uint256 shares
    ) private view {
        (uint256 gross, uint256 senior, uint256 bounty) = LibCoreRecovery.expiredBookSlice(book, shares);
        preview.seniorCollateralOut = senior;
        preview.juniorCollateral = gross - senior;
        preview.keeperBounty = bounty;
        preview.holderCollateral = gross - senior - bounty;
    }

    /// @dev Successor valuation for NAV claims; collateral-only claims leave zeros.
    function _fillNavPairs(
        LibCoreStorage.CS storage cs,
        IStaticsDollarCoreTypes.RecoveryClaimMode mode,
        IStaticsDollarCoreTypes.RiskSeries storage oldSeries,
        IStaticsDollarCoreTypes.ExpiredRiskRecoveryPreview memory preview
    ) private view {
        IStaticsDollarCoreTypes.StableCollateralProfile storage profile = cs.collateralProfiles[oldSeries.profileId];
        preview.successorSeriesId = profile.activeSeriesId;
        if (mode != IStaticsDollarCoreTypes.RecoveryClaimMode.NAV) {
            preview.holderCollateralDust = preview.holderCollateral;
            return;
        }
        IStaticsDollarCoreTypes.RiskSeries storage successor = cs.riskSeries[preview.successorSeriesId];
        if (successor.status != IStaticsDollarCoreTypes.SeriesStatus.Active) {
            revert SeriesNotActive(preview.successorSeriesId);
        }
        (uint256 holderPairs, uint256 used) = _navHolderPairs(profile, successor, preview.holderCollateral);
        preview.holderPairs = holderPairs;
        preview.holderCollateralDust = preview.holderCollateral - used;
    }

    /// @dev Largest whole successor pair count whose collateral requirement fits
    /// the holder's junior recovery collateral, plus the collateral it consumes.
    function _navHolderPairs(
        IStaticsDollarCoreTypes.StableCollateralProfile storage profile,
        IStaticsDollarCoreTypes.RiskSeries storage successor,
        uint256 holderCollateral
    ) private view returns (uint256 holderPairs, uint256 used) {
        holderPairs = LibCoreRecovery.sharesForCollateral(
            holderCollateral, profile.decimals, successor.collateralPerPairWad
        );
        used = LibCoreRecovery.collateralForShares(holderPairs, profile.decimals, successor.collateralPerPairWad);
        while (used > holderCollateral && holderPairs != 0) {
            unchecked {
                --holderPairs;
            }
            used = LibCoreRecovery.collateralForShares(holderPairs, profile.decimals, successor.collateralPerPairWad);
        }
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
