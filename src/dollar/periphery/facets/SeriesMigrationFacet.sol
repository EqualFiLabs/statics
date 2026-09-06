// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IStaticsDollarCoreTypes} from "../../interfaces/IStaticsDollarCoreTypes.sol";
import {IStaticsDollarRiskLiquidity} from "../../interfaces/IStaticsDollarRiskLiquidity.sol";
import {IStaticsDollarSeriesMigration} from "../../interfaces/IStaticsDollarSeriesMigration.sol";
import {IStaticsDollarCore} from "../../core/interfaces/IStaticsDollarCore.sol";
import {LibCustody} from "../../../libraries/LibCustody.sol";
import {LibPosition} from "../../../position/LibPosition.sol";
import {LibPeriphery} from "../libraries/LibPeriphery.sol";
import {LibRiskLiquidity} from "../libraries/LibRiskLiquidity.sol";

/// @notice Processes aggregate Risk Share recovery and lazily migrates each
/// PositionNFT leg into the successor series.
/// @dev This facet shares the canonical periphery storage with StakingFacet;
/// splitting the selectors keeps both implementations below EIP-170 without
/// changing the Diamond's external selector surface.
contract SeriesMigrationFacet is IStaticsDollarSeriesMigration, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct MigrationAmounts {
        uint256 oldPrincipal;
        uint256 newPrincipal;
        uint256 staticsDollarCredit;
        uint256 collateralCredit;
    }

    struct TransitionClaim {
        uint256 newSeriesId;
        uint256 newPrincipal;
        uint256 collateralCredit;
        uint256 oldPrincipal;
    }

    error ZeroAmount();
    error UnknownRiskLiquidity(uint256 positionId, uint256 seriesId);
    error NotPositionOwnerOrApproved(uint256 positionId, address caller);
    error SeriesIncentivesNotFinalizable(uint256 seriesId);
    error SeriesMigrationNotReady(uint256 seriesId);
    error SeriesMigrationAlreadyProcessed(uint256 seriesId);
    error SeriesMigrationReclaimPending(uint256 seriesId);
    error UnexpectedRiskIngressState();
    error InsufficientTransferReceived(address token, uint256 required, uint256 received);

    /// @notice Permissionless aggregate transition processing. During the
    /// return window this escrows every Risk Share held by the Diamond. After
    /// finalization it claims once and records lazy PositionNFT conversion.
    function processSeriesTransition(uint256 oldSeriesId)
        external
        override
        nonReentrant
        returns (uint256 newSeriesId, uint256 newPrincipal)
    {
        LibPeriphery.PS storage ps = LibPeriphery.s();
        LibPeriphery.SeriesMigration storage migration = ps.migration[oldSeriesId];
        IStaticsDollarCore core = IStaticsDollarCore(ps.pool);
        IStaticsDollarCoreTypes.RiskSeries memory series = core.riskSeries(oldSeriesId);

        if (series.status == IStaticsDollarCoreTypes.SeriesStatus.RecoveryPending) {
            uint256 balance = IERC1155(ps.staticsDollarRisk).balanceOf(address(this), oldSeriesId);
            if (balance == 0) {
                if (migration.returned) return (0, 0);
                revert ZeroAmount();
            }
            IERC1155(ps.staticsDollarRisk).setApprovalForAll(ps.pool, true);
            core.returnRiskShares(oldSeriesId, balance);
            migration.oldPrincipal += balance;
            migration.remainingOldPrincipal += balance;
            migration.returned = true;
            return (0, 0);
        }

        if (series.status == IStaticsDollarCoreTypes.SeriesStatus.Active && migration.returned && !migration.claimed) {
            LibRiskLiquidity.expectIngress(ps, ps.pool, ps.pool, oldSeriesId, migration.oldPrincipal);
            core.reclaimReturnedRiskShares(oldSeriesId, address(this));
            LibRiskLiquidity.requireIngressConsumed(ps);
            delete ps.migration[oldSeriesId];
            return (0, 0);
        }

        if (series.status != IStaticsDollarCoreTypes.SeriesStatus.Recoverable) {
            revert SeriesMigrationNotReady(oldSeriesId);
        }
        LibRiskLiquidity.finalizeIncentives(ps, oldSeriesId, series);
        if (migration.claimed) revert SeriesMigrationAlreadyProcessed(oldSeriesId);
        IStaticsDollarCoreTypes.RecoveryClaimMode claimMode = _transitionClaimMode(core, series);
        TransitionClaim memory claim = migration.returned
            ? _claimReturnedTransition(ps, core, oldSeriesId, series, claimMode)
            : _recoverExpiredTransition(ps, core, oldSeriesId, series, claimMode);
        newSeriesId = claim.newSeriesId;
        newPrincipal = claim.newPrincipal;
        if (!migration.returned) {
            migration.oldPrincipal = claim.oldPrincipal;
            migration.remainingOldPrincipal = claim.oldPrincipal;
        }
        migration.newSeriesId = newSeriesId;
        migration.remainingNewPrincipal = newPrincipal;
        migration.remainingStaticsDollar = newPrincipal;
        migration.remainingCollateral = claim.collateralCredit;
        migration.claimed = true;
        if (newPrincipal != 0) LibPeriphery.reserve(ps, ps.staticsDollar, newPrincipal);
        if (claim.collateralCredit != 0) LibPeriphery.reserve(ps, series.collateralToken, claim.collateralCredit);
        emit SeriesTransitionProcessed(
            oldSeriesId, newSeriesId, migration.oldPrincipal, newPrincipal, migration.returned
        );
    }

    function settleSeriesMigration(uint256 positionId, uint256 oldSeriesId)
        external
        override
        nonReentrant
        returns (uint256 newSeriesId, uint256 newPrincipal)
    {
        LibPeriphery.PS storage ps = LibPeriphery.s();
        LibPosition.enforceAuthorized(positionId, msg.sender);
        LibPeriphery.SeriesMigration storage migration = ps.migration[oldSeriesId];
        if (!migration.claimed) revert SeriesMigrationNotReady(oldSeriesId);
        LibPeriphery.PositionLeg storage oldLeg = LibRiskLiquidity.leg(ps, positionId, oldSeriesId);
        LibPeriphery.SeriesBook storage oldBook = ps.series[oldSeriesId];
        LibPeriphery.settleLeg(ps, positionId, oldSeriesId);
        uint64 oldEpoch = oldLeg.epoch;

        MigrationAmounts memory amounts;
        amounts.oldPrincipal =
            oldLeg.epoch == oldBook.epoch ? LibPeriphery.positionEffective(oldBook, oldLeg.stored) : 0;
        if (amounts.oldPrincipal == 0) revert ZeroAmount();
        uint256 settledPrincipal = amounts.oldPrincipal > migration.remainingOldPrincipal
            ? migration.remainingOldPrincipal
            : amounts.oldPrincipal;
        bool last = settledPrincipal == migration.remainingOldPrincipal;
        amounts.newPrincipal = last
            ? migration.remainingNewPrincipal
            : Math.mulDiv(migration.remainingNewPrincipal, settledPrincipal, migration.remainingOldPrincipal);
        amounts.staticsDollarCredit = last
            ? migration.remainingStaticsDollar
            : Math.mulDiv(migration.remainingStaticsDollar, settledPrincipal, migration.remainingOldPrincipal);
        amounts.collateralCredit = last
            ? migration.remainingCollateral
            : Math.mulDiv(migration.remainingCollateral, settledPrincipal, migration.remainingOldPrincipal);
        migration.remainingOldPrincipal -= settledPrincipal;
        migration.remainingNewPrincipal -= amounts.newPrincipal;
        migration.remainingStaticsDollar -= amounts.staticsDollarCredit;
        migration.remainingCollateral -= amounts.collateralCredit;
        if (settledPrincipal != amounts.oldPrincipal) {
            emit MigrationRoundingWrittenOff(positionId, oldSeriesId, amounts.oldPrincipal, settledPrincipal);
        }

        oldBook.totalStored -= oldLeg.stored;
        oldBook.effectivePrincipal -= amounts.oldPrincipal;
        oldLeg.stored = 0;
        if (oldBook.totalStored == 0) {
            oldBook.scaleRay = LibPeriphery.RAY;
            oldBook.epoch += 1;
            LibPeriphery.finalizeEpochToLeg(ps, positionId, oldSeriesId, oldEpoch);
        } else {
            oldBook.scaleRay = Math.mulDiv(oldBook.effectivePrincipal, LibPeriphery.RAY, oldBook.totalStored);
        }
        oldLeg.epoch = oldBook.epoch;
        oldLeg.collateralCheckpointRay = oldBook.collateralProceeds[oldBook.epoch].accPerStoredRay;
        oldLeg.staticsDollarCheckpointRay = oldBook.staticsDollarProceeds[oldBook.epoch].accPerStoredRay;
        oldLeg.staticsCheckpointRay = oldBook.staticsProceeds[oldBook.epoch].accPerStoredRay;
        oldLeg.accruedStaticsDollar += amounts.staticsDollarCredit;
        oldLeg.accruedCollateral += amounts.collateralCredit;

        newSeriesId = migration.newSeriesId;
        if (amounts.newPrincipal != 0) _stakeMigrated(ps, positionId, newSeriesId, amounts.newPrincipal);
        newPrincipal = amounts.newPrincipal;
        emit PositionMigrationSettled(
            positionId,
            oldSeriesId,
            newSeriesId,
            amounts.oldPrincipal,
            amounts.newPrincipal,
            amounts.staticsDollarCredit,
            amounts.collateralCredit
        );
    }

    function seriesMigration(uint256 oldSeriesId)
        external
        view
        override
        returns (SeriesMigrationView memory migration)
    {
        LibPeriphery.SeriesMigration storage stored = LibPeriphery.s().migration[oldSeriesId];
        migration = SeriesMigrationView({
            newSeriesId: stored.newSeriesId,
            oldPrincipal: stored.oldPrincipal,
            remainingOldPrincipal: stored.remainingOldPrincipal,
            remainingNewPrincipal: stored.remainingNewPrincipal,
            remainingStaticsDollar: stored.remainingStaticsDollar,
            remainingCollateral: stored.remainingCollateral,
            returned: stored.returned,
            claimed: stored.claimed
        });
    }

    function _transitionClaimMode(IStaticsDollarCore core, IStaticsDollarCoreTypes.RiskSeries memory oldSeries)
        private
        view
        returns (IStaticsDollarCoreTypes.RecoveryClaimMode claimMode)
    {
        IStaticsDollarCoreTypes.StableCollateralProfile memory profile = core.collateralProfile(oldSeries.profileId);
        IStaticsDollarCoreTypes.RiskSeries memory successor = core.riskSeries(profile.activeSeriesId);
        claimMode = profile.mode != IStaticsDollarCoreTypes.ProfileMode.Active
            || successor.status != IStaticsDollarCoreTypes.SeriesStatus.Active
            ? IStaticsDollarCoreTypes.RecoveryClaimMode.CollateralOnly
            : IStaticsDollarCoreTypes.RecoveryClaimMode.NAV;
    }

    function _claimReturnedTransition(
        LibPeriphery.PS storage ps,
        IStaticsDollarCore core,
        uint256 oldSeriesId,
        IStaticsDollarCoreTypes.RiskSeries memory series,
        IStaticsDollarCoreTypes.RecoveryClaimMode claimMode
    ) private returns (TransitionClaim memory claim) {
        IStaticsDollarCoreTypes.RecoveryClaimPreview memory preview =
            core.previewReturnedRiskClaim(address(this), oldSeriesId, claimMode);
        claim.newSeriesId = preview.successorSeriesId;
        _enforceSuccessorMigrationAvailable(ps, claim.newSeriesId, preview.successorPairs);
        if (preview.collateralIn != 0) IERC20(series.collateralToken).forceApprove(ps.pool, preview.collateralIn);
        uint256 collateralBefore = LibCustody.beginUnreservedDebit(series.collateralToken, preview.collateralIn);
        LibRiskLiquidity.expectIngress(ps, ps.pool, address(0), claim.newSeriesId, preview.successorPairs);
        (claim.newPrincipal,, claim.collateralCredit) = core.claimReturnedRisk(
            oldSeriesId, claimMode, preview.collateralIn, preview.successorPairs, preview.collateralOut, address(this)
        );
        LibCustody.finishUnreservedDebit(series.collateralToken, collateralBefore, preview.collateralIn);
        LibRiskLiquidity.requireIngressConsumed(ps);
    }

    function _recoverExpiredTransition(
        LibPeriphery.PS storage ps,
        IStaticsDollarCore core,
        uint256 oldSeriesId,
        IStaticsDollarCoreTypes.RiskSeries memory series,
        IStaticsDollarCoreTypes.RecoveryClaimMode claimMode
    ) private returns (TransitionClaim memory claim) {
        claim.oldPrincipal = IERC1155(ps.staticsDollarRisk).balanceOf(address(this), oldSeriesId);
        if (claim.oldPrincipal == 0) revert ZeroAmount();
        IStaticsDollarCoreTypes.ExpiredRiskRecoveryPreview memory preview =
            core.previewExpiredRiskRecovery(address(this), oldSeriesId, claim.oldPrincipal, claimMode);
        claim.newSeriesId = preview.successorSeriesId;
        _enforceSuccessorMigrationAvailable(ps, claim.newSeriesId, preview.holderPairs);
        uint256 receivedStaticsDollar = LibCustody.pull(ps.staticsDollar, msg.sender, preview.staticsDollarBurned);
        if (receivedStaticsDollar < preview.staticsDollarBurned) {
            revert InsufficientTransferReceived(ps.staticsDollar, preview.staticsDollarBurned, receivedStaticsDollar);
        }
        uint256 staticsDollarBefore = LibCustody.beginUnreservedDebit(ps.staticsDollar, preview.staticsDollarBurned);
        LibRiskLiquidity.expectIngress(ps, ps.pool, address(0), claim.newSeriesId, preview.holderPairs);
        (,, claim.newPrincipal) = core.recoverExpiredRisk(
            address(this),
            oldSeriesId,
            claim.oldPrincipal,
            claimMode,
            preview.seniorCollateralOut + preview.keeperBounty
        );
        LibCustody.finishUnreservedDebit(ps.staticsDollar, staticsDollarBefore, preview.staticsDollarBurned);
        LibRiskLiquidity.requireIngressConsumed(ps);
        uint256 callerCollateral = preview.seniorCollateralOut + preview.keeperBounty;
        LibCustody.pushUnreserved(series.collateralToken, msg.sender, callerCollateral, callerCollateral);
        claim.collateralCredit = preview.holderCollateralDust;
    }

    function _enforceSuccessorMigrationAvailable(
        LibPeriphery.PS storage ps,
        uint256 successorSeriesId,
        uint256 successorPrincipal
    ) private view {
        if (successorPrincipal == 0) return;
        LibPeriphery.SeriesMigration storage successorMigration = ps.migration[successorSeriesId];
        if (successorMigration.returned && !successorMigration.claimed) {
            revert SeriesMigrationReclaimPending(successorSeriesId);
        }
    }

    function _stakeMigrated(LibPeriphery.PS storage ps, uint256 positionId, uint256 seriesId, uint256 amount) private {
        LibPeriphery.PositionLeg storage leg_ = ps.leg[positionId][seriesId];
        LibPeriphery.SeriesBook storage book = ps.series[seriesId];
        if (!leg_.exists) {
            bytes32 legKey = LibPosition.dollarLegKey(seriesId);
            if (!LibPosition.positionStorage().activeLeg[positionId][legKey]) {
                LibPosition.activateLeg(positionId, LibPosition.DOLLAR_MODULE, bytes32(seriesId));
            }
            leg_.exists = true;
            leg_.epoch = book.epoch;
            leg_.collateralCheckpointRay = book.collateralProceeds[book.epoch].accPerStoredRay;
            leg_.staticsDollarCheckpointRay = book.staticsDollarProceeds[book.epoch].accPerStoredRay;
            leg_.staticsCheckpointRay = book.staticsProceeds[book.epoch].accPerStoredRay;
            LibPeriphery.addSeries(ps, positionId, seriesId);
        } else {
            LibPeriphery.settleLeg(ps, positionId, seriesId);
            LibPeriphery.clearZeroValueLiquidity(ps, positionId, seriesId);
        }
        uint256 storedAdded = LibPeriphery.addLiquidity(book, amount);
        leg_.stored += storedAdded;
        leg_.epoch = book.epoch;
        leg_.collateralCheckpointRay = book.collateralProceeds[book.epoch].accPerStoredRay;
        leg_.staticsDollarCheckpointRay = book.staticsDollarProceeds[book.epoch].accPerStoredRay;
        leg_.staticsCheckpointRay = book.staticsProceeds[book.epoch].accPerStoredRay;
        emit IStaticsDollarRiskLiquidity.RiskSharesStaked(positionId, seriesId, address(0), amount);
    }
}
