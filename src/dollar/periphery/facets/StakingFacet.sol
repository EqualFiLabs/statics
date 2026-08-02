// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {IERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IStaticsDollarCoreTypes} from "../../interfaces/IStaticsDollarCoreTypes.sol";
import {IStaticsDollarCore} from "../../core/interfaces/IStaticsDollarCore.sol";
import {IStaticsPositionModule} from "../../../interfaces/IStaticsPosition.sol";
import {LibCustody} from "../../../libraries/LibCustody.sol";
import {LibPosition} from "../../../position/LibPosition.sol";
import {LibPeriphery} from "../libraries/LibPeriphery.sol";

contract StakingFacet is IERC1155Receiver, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct MigrationAmounts {
        uint256 oldPrincipal;
        uint256 oldEligible;
        uint256 oldPending;
        uint256 oldOptIn;
        uint256 oldPendingSince;
        uint256 newPrincipal;
        uint256 staticsDollarCredit;
        uint256 collateralCredit;
    }

    event LegIncreased(uint256 indexed positionId, uint256 indexed seriesId, uint256 amount, uint256 pendingSince);
    event LegActivated(uint256 indexed positionId, uint256 indexed seriesId, uint256 principal);
    event LegWithdrawn(uint256 indexed positionId, uint256 indexed seriesId, address indexed receiver, uint256 amount);
    event LegMigrated(
        uint256 indexed positionId,
        uint256 indexed oldSeriesId,
        uint256 indexed newSeriesId,
        uint256 oldPrincipal,
        uint256 newPrincipal
    );
    event LegMigrationDeferred(
        address indexed caller,
        uint256 indexed positionId,
        uint256 indexed oldSeriesId,
        uint256 newSeriesId,
        IStaticsDollarCoreTypes.ExitStatus status,
        uint256 unhealthyProfileBitmap
    );
    event LegClosed(uint256 indexed positionId, uint256 indexed seriesId);
    event SeriesTransitionProcessed(
        uint256 indexed oldSeriesId,
        uint256 indexed newSeriesId,
        uint256 oldPrincipal,
        uint256 newPrincipal,
        bool returnedDuringWindow
    );
    event PositionMigrationSettled(
        uint256 indexed positionId,
        uint256 indexed oldSeriesId,
        uint256 indexed newSeriesId,
        uint256 oldPrincipal,
        uint256 newPrincipal,
        uint256 staticsDollarCredit,
        uint256 collateralCredit
    );
    event MigrationRoundingWrittenOff(
        uint256 indexed positionId, uint256 indexed oldSeriesId, uint256 nominalPrincipal, uint256 settledPrincipal
    );

    error ZeroAmount();
    error ZeroAddress();
    error UnknownLeg(uint256 positionId, uint256 seriesId);
    error NotPositionOwnerOrApproved(uint256 positionId, address caller);
    error PositionNotMature(uint256 positionId, uint256 seriesId, uint256 eligibleAt);
    error InsufficientPrincipal(uint256 requested, uint256 available);
    error SeriesNotActive(uint256 seriesId);
    error SeriesNotRetired(uint256 seriesId);
    error InvalidSuccessor(uint256 expected, uint256 actual);
    error SlippageExceeded(uint256 received, uint256 minimum);
    error LegHasValue(uint256 positionId, uint256 seriesId);
    error UnexpectedExitStatus(IStaticsDollarCoreTypes.ExitStatus status);
    error SeriesMigrationNotReady(uint256 seriesId);
    error SeriesMigrationAlreadyProcessed(uint256 seriesId);
    error UnexpectedRiskIngress(address token, address operator, address from, uint256 seriesId, uint256 amount);
    error UnexpectedRiskIngressState();
    error RiskBatchIngressUnsupported();
    error InsufficientTransferReceived(address token, uint256 required, uint256 received);

    function createAndStake(uint256 seriesId, uint256 amount, address receiver)
        external
        nonReentrant
        returns (uint256 positionId)
    {
        if (amount == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();
        LibPeriphery.PS storage ps = LibPeriphery.s();
        _requireActive(ps, seriesId);
        positionId =
            IStaticsPositionModule(address(this)).createPositionForModule(receiver, LibPosition.dollarLegKey(seriesId));
        _pullRisk(ps, msg.sender, seriesId, amount);
        _increaseLeg(ps, positionId, seriesId, amount);
    }

    function stake(uint256 positionId, uint256 seriesId, uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        LibPeriphery.PS storage ps = LibPeriphery.s();
        _enforceOwnerOrApproved(ps, positionId);
        _requireActive(ps, seriesId);
        _pullRisk(ps, msg.sender, seriesId, amount);
        _increaseLeg(ps, positionId, seriesId, amount);
    }

    function activateLeg(uint256 positionId, uint256 seriesId) external nonReentrant {
        LibPeriphery.PS storage ps = LibPeriphery.s();
        LibPeriphery.PositionLeg storage positionLeg = _leg(ps, positionId, seriesId);
        _requireActive(ps, seriesId);
        if (positionLeg.pendingPrincipal == 0) revert ZeroAmount();
        uint256 eligibleAt = positionLeg.pendingSince + LibPeriphery.REWARD_GATE;
        if (block.timestamp < eligibleAt) revert PositionNotMature(positionId, seriesId, eligibleAt);
        LibPeriphery.settleLeg(ps, positionId, seriesId);
        uint256 amount = positionLeg.pendingPrincipal;
        positionLeg.pendingPrincipal = 0;
        positionLeg.pendingSince = 0;
        positionLeg.eligiblePrincipal += amount;
        ps.series[seriesId].eligiblePrincipal += amount;
        emit LegActivated(positionId, seriesId, amount);
    }

    function withdrawLeg(uint256 positionId, uint256 seriesId, uint256 amount, address receiver) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();
        LibPeriphery.PS storage ps = LibPeriphery.s();
        _enforceOwnerOrApproved(ps, positionId);
        LibPeriphery.PositionLeg storage positionLeg = _leg(ps, positionId, seriesId);
        uint256 available = positionLeg.pendingPrincipal + positionLeg.eligiblePrincipal;
        if (amount > available) revert InsufficientPrincipal(amount, available);
        LibPeriphery.settleLeg(ps, positionId, seriesId);
        _removeBasePrincipal(ps, seriesId, positionLeg, amount);
        IERC1155(ps.staticsDollarRisk).safeTransferFrom(address(this), receiver, seriesId, amount, "");
        emit LegWithdrawn(positionId, seriesId, receiver, amount);
    }

    function migrateLeg(uint256 positionId, uint256 oldSeriesId, uint256 principal, uint256 minNewPrincipal)
        external
        nonReentrant
        returns (IStaticsDollarCoreTypes.ExitStatus status, uint256 newSeriesId, uint256 newPrincipal)
    {
        if (principal == 0) revert ZeroAmount();
        LibPeriphery.PS storage ps = LibPeriphery.s();
        _enforceOwnerOrApproved(ps, positionId);
        LibPeriphery.PositionLeg storage oldLeg = _leg(ps, positionId, oldSeriesId);
        IStaticsDollarCore core = IStaticsDollarCore(ps.pool);
        IStaticsDollarCoreTypes.RiskSeries memory oldSeries = core.riskSeries(oldSeriesId);
        if (
            oldSeries.status != IStaticsDollarCoreTypes.SeriesStatus.Recoverable
                && oldSeries.status != IStaticsDollarCoreTypes.SeriesStatus.Retired
        ) revert SeriesNotRetired(oldSeriesId);
        uint256 available = oldLeg.pendingPrincipal + oldLeg.eligiblePrincipal;
        if (principal > available) revert InsufficientPrincipal(principal, available);
        newSeriesId = core.collateralProfile(oldSeries.profileId).activeSeriesId;
        _requireActive(ps, newSeriesId);

        uint256 unhealthyBitmap;
        (status, unhealthyBitmap,,) = core.checkpointGlobalCollateralExit();
        if (status != IStaticsDollarCoreTypes.ExitStatus.Available) {
            emit LegMigrationDeferred(msg.sender, positionId, oldSeriesId, newSeriesId, status, unhealthyBitmap);
            return (status, newSeriesId, 0);
        }
        LibPeriphery.settleLeg(ps, positionId, oldSeriesId);
        _removeBasePrincipal(ps, oldSeriesId, oldLeg, principal);

        uint256 receivedStaticsDollar = LibCustody.pull(ps.staticsDollar, msg.sender, principal);
        if (receivedStaticsDollar < principal) {
            revert InsufficientTransferReceived(ps.staticsDollar, principal, receivedStaticsDollar);
        }
        uint256 beforeCollateral = IERC20(oldSeries.collateralToken).balanceOf(address(this));
        uint256 staticsDollarBefore = LibCustody.beginUnreservedDebit(ps.staticsDollar, principal);
        (IStaticsDollarCoreTypes.ExitStatus recombinationStatus,) =
            core.recombineManaged(oldSeriesId, principal, principal, 0, address(this));
        LibCustody.finishUnreservedDebit(ps.staticsDollar, staticsDollarBefore, principal);
        if (recombinationStatus != IStaticsDollarCoreTypes.ExitStatus.Available) {
            revert UnexpectedExitStatus(recombinationStatus);
        }
        uint256 collateral = IERC20(oldSeries.collateralToken).balanceOf(address(this)) - beforeCollateral;
        IERC20(oldSeries.collateralToken).forceApprove(ps.pool, collateral);
        uint256 collateralBefore = LibCustody.beginUnreservedDebit(oldSeries.collateralToken, collateral);
        IStaticsDollarCoreTypes.DepositPreview memory depositPreview =
            core.previewDeposit(oldSeries.profileId, collateral);
        _expectRiskIngress(ps, ps.pool, address(0), depositPreview.seriesId, depositPreview.sharesMinted);
        (uint256 depositedSeriesId,, uint256 sharesMinted) =
            core.depositCollateral(oldSeries.profileId, collateral, 0, minNewPrincipal, msg.sender, address(this));
        LibCustody.finishUnreservedDebit(oldSeries.collateralToken, collateralBefore, collateral);
        _requireRiskIngressConsumed(ps);
        if (depositedSeriesId != newSeriesId) revert InvalidSuccessor(newSeriesId, depositedSeriesId);
        if (sharesMinted < minNewPrincipal) revert SlippageExceeded(sharesMinted, minNewPrincipal);
        newPrincipal = sharesMinted;
        _increaseLeg(ps, positionId, newSeriesId, sharesMinted);
        emit LegMigrated(positionId, oldSeriesId, newSeriesId, principal, sharesMinted);
        return (IStaticsDollarCoreTypes.ExitStatus.Available, newSeriesId, sharesMinted);
    }

    /// @notice Permissionless aggregate transition processing. During the
    /// window this escrows every StaticsDollarRisk unit held by the Diamond. After
    /// finalization it claims once and records a lazy Position-NFT conversion.
    function processSeriesTransition(uint256 oldSeriesId)
        external
        nonReentrant
        returns (uint256 newSeriesId, uint256 newPrincipal)
    {
        LibPeriphery.PS storage ps = LibPeriphery.s();
        LibPeriphery.SeriesMigration storage migration = ps.migration[oldSeriesId];
        IStaticsDollarCore core = IStaticsDollarCore(ps.pool);
        IStaticsDollarCoreTypes.RiskSeries memory series = core.riskSeries(oldSeriesId);

        if (series.status == IStaticsDollarCoreTypes.SeriesStatus.RecoveryPending) {
            if (migration.returned) revert SeriesMigrationAlreadyProcessed(oldSeriesId);
            uint256 balance = IERC1155(ps.staticsDollarRisk).balanceOf(address(this), oldSeriesId);
            if (balance == 0) revert ZeroAmount();
            IERC1155(ps.staticsDollarRisk).setApprovalForAll(ps.pool, true);
            core.returnRiskShares(oldSeriesId, balance);
            migration.oldPrincipal = balance;
            migration.remainingOldPrincipal = balance;
            migration.returned = true;
            return (0, 0);
        }

        if (series.status == IStaticsDollarCoreTypes.SeriesStatus.Active && migration.returned && !migration.claimed) {
            _expectRiskIngress(ps, ps.pool, ps.pool, oldSeriesId, migration.oldPrincipal);
            core.reclaimReturnedRiskShares(oldSeriesId, address(this));
            _requireRiskIngressConsumed(ps);
            delete ps.migration[oldSeriesId];
            return (0, 0);
        }

        if (series.status != IStaticsDollarCoreTypes.SeriesStatus.Recoverable) {
            revert SeriesMigrationNotReady(oldSeriesId);
        }
        if (migration.claimed) revert SeriesMigrationAlreadyProcessed(oldSeriesId);
        IStaticsDollarCoreTypes.StableCollateralProfile memory profile = core.collateralProfile(series.profileId);
        IStaticsDollarCoreTypes.RiskSeries memory successor = core.riskSeries(profile.activeSeriesId);
        IStaticsDollarCoreTypes.RecoveryClaimMode claimMode = profile.mode
                == IStaticsDollarCoreTypes.ProfileMode.Retired
            || successor.status != IStaticsDollarCoreTypes.SeriesStatus.Active
            ? IStaticsDollarCoreTypes.RecoveryClaimMode.CollateralOnly
            : IStaticsDollarCoreTypes.RecoveryClaimMode.NAV;
        LibPeriphery.SeriesBook storage retiringBook = ps.series[oldSeriesId];
        if (!retiringBook.retiredRewardsFinalized) {
            LibPeriphery.finalizeRetiredRewards(ps, oldSeriesId, series);
        }
        uint256 collateralCredit;
        if (migration.returned) {
            IStaticsDollarCoreTypes.RecoveryClaimPreview memory preview =
                core.previewReturnedRiskClaim(address(this), oldSeriesId, claimMode);
            newSeriesId = preview.successorSeriesId;
            if (preview.collateralIn != 0) {
                IERC20(series.collateralToken).forceApprove(ps.pool, preview.collateralIn);
            }
            uint256 collateralBefore = LibCustody.beginUnreservedDebit(series.collateralToken, preview.collateralIn);
            _expectRiskIngress(ps, ps.pool, address(0), newSeriesId, preview.successorPairs);
            (newPrincipal,, collateralCredit) = core.claimReturnedRisk(
                oldSeriesId,
                claimMode,
                preview.collateralIn,
                preview.successorPairs,
                preview.collateralOut,
                address(this)
            );
            LibCustody.finishUnreservedDebit(series.collateralToken, collateralBefore, preview.collateralIn);
            _requireRiskIngressConsumed(ps);
        } else {
            uint256 oldPrincipal = IERC1155(ps.staticsDollarRisk).balanceOf(address(this), oldSeriesId);
            if (oldPrincipal == 0) revert ZeroAmount();
            IStaticsDollarCoreTypes.ExpiredRiskRecoveryPreview memory preview =
                core.previewExpiredRiskRecovery(address(this), oldSeriesId, oldPrincipal, claimMode);
            newSeriesId = preview.successorSeriesId;
            uint256 receivedStaticsDollar = LibCustody.pull(ps.staticsDollar, msg.sender, preview.staticsDollarBurned);
            if (receivedStaticsDollar < preview.staticsDollarBurned) {
                revert InsufficientTransferReceived(
                    ps.staticsDollar, preview.staticsDollarBurned, receivedStaticsDollar
                );
            }
            uint256 staticsDollarBefore = LibCustody.beginUnreservedDebit(ps.staticsDollar, preview.staticsDollarBurned);
            _expectRiskIngress(ps, ps.pool, address(0), newSeriesId, preview.holderPairs);
            (,, newPrincipal) = core.recoverExpiredRisk(
                address(this), oldSeriesId, oldPrincipal, claimMode, preview.seniorCollateralOut + preview.keeperBounty
            );
            LibCustody.finishUnreservedDebit(ps.staticsDollar, staticsDollarBefore, preview.staticsDollarBurned);
            _requireRiskIngressConsumed(ps);
            uint256 callerCollateral = preview.seniorCollateralOut + preview.keeperBounty;
            LibCustody.pushUnreserved(series.collateralToken, msg.sender, callerCollateral, callerCollateral);
            collateralCredit = preview.holderCollateralDust;
            migration.oldPrincipal = oldPrincipal;
            migration.remainingOldPrincipal = oldPrincipal;
        }
        migration.newSeriesId = newSeriesId;
        migration.remainingNewPrincipal = newPrincipal;
        migration.remainingStaticsDollar = newPrincipal;
        migration.remainingCollateral = collateralCredit;
        migration.claimed = true;
        if (newPrincipal != 0) LibPeriphery.reserve(ps, ps.staticsDollar, newPrincipal);
        if (collateralCredit != 0) LibPeriphery.reserve(ps, series.collateralToken, collateralCredit);
        emit SeriesTransitionProcessed(
            oldSeriesId, newSeriesId, migration.oldPrincipal, newPrincipal, migration.returned
        );
    }

    function settleSeriesMigration(uint256 positionId, uint256 oldSeriesId)
        external
        nonReentrant
        returns (uint256 newSeriesId, uint256 newPrincipal)
    {
        LibPeriphery.PS storage ps = LibPeriphery.s();
        _enforceOwnerOrApproved(ps, positionId);
        LibPeriphery.SeriesMigration storage migration = ps.migration[oldSeriesId];
        if (!migration.claimed) revert SeriesMigrationNotReady(oldSeriesId);
        LibPeriphery.PositionLeg storage oldLeg = _leg(ps, positionId, oldSeriesId);
        LibPeriphery.SeriesBook storage oldBook = ps.series[oldSeriesId];
        LibPeriphery.settleLeg(ps, positionId, oldSeriesId);
        MigrationAmounts memory amounts;
        amounts.oldOptIn = oldLeg.optInEpoch == oldBook.optInEpoch
            ? LibPeriphery.optInPositionEffective(oldBook, oldLeg.optInStored)
            : 0;
        amounts.oldEligible = oldLeg.eligiblePrincipal;
        amounts.oldPending = oldLeg.pendingPrincipal;
        amounts.oldPendingSince = oldLeg.pendingSince;
        amounts.oldPrincipal = amounts.oldPending + amounts.oldEligible + amounts.oldOptIn;
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

        oldBook.eligiblePrincipal -= amounts.oldEligible;
        if (oldLeg.optInEpoch == oldBook.optInEpoch) {
            oldBook.optInTotalStored -= oldLeg.optInStored;
            oldBook.optInPrincipal -= amounts.oldOptIn;
        }
        oldLeg.eligiblePrincipal = 0;
        oldLeg.pendingPrincipal = 0;
        oldLeg.pendingSince = 0;
        oldLeg.optInStored = 0;
        oldLeg.accruedStaticsDollar += amounts.staticsDollarCredit;
        oldLeg.accruedCollateral += amounts.collateralCredit;

        newSeriesId = migration.newSeriesId;
        _creditMigratedPrincipal(
            ps,
            positionId,
            newSeriesId,
            amounts.newPrincipal,
            amounts.oldEligible,
            amounts.oldPending,
            amounts.oldOptIn,
            amounts.oldPendingSince
        );
        emit PositionMigrationSettled(
            positionId,
            oldSeriesId,
            newSeriesId,
            amounts.oldPrincipal,
            amounts.newPrincipal,
            amounts.staticsDollarCredit,
            amounts.collateralCredit
        );
        return (newSeriesId, amounts.newPrincipal);
    }

    function closeLeg(uint256 positionId, uint256 seriesId) external nonReentrant {
        LibPeriphery.PS storage ps = LibPeriphery.s();
        _enforceOwnerOrApproved(ps, positionId);
        LibPeriphery.PositionLeg storage positionLeg = _leg(ps, positionId, seriesId);
        LibPeriphery.settleLeg(ps, positionId, seriesId);
        if (positionLeg.optInStored != 0 && positionLeg.optInEpoch != ps.series[seriesId].optInEpoch) {
            positionLeg.optInStored = 0;
        } else {
            LibPeriphery.clearZeroEffectiveOptInDust(ps, positionId, seriesId);
        }
        if (
            positionLeg.eligiblePrincipal != 0 || positionLeg.pendingPrincipal != 0 || positionLeg.optInStored != 0
                || positionLeg.accruedCollateral != 0 || positionLeg.accruedStaticsDollar != 0
        ) revert LegHasValue(positionId, seriesId);
        delete ps.leg[positionId][seriesId];
        LibPeriphery.removeSeries(ps, positionId, seriesId);
        LibPosition.deactivateLeg(positionId, LibPosition.dollarLegKey(seriesId));
        emit LegClosed(positionId, seriesId);
    }

    function leg(uint256 positionId, uint256 seriesId) external view returns (LibPeriphery.PositionLeg memory) {
        return LibPeriphery.s().leg[positionId][seriesId];
    }

    function positionSeriesCount(uint256 positionId) external view returns (uint256) {
        return LibPeriphery.s().positionSeries[positionId].length;
    }

    function positionSeriesAt(uint256 positionId, uint256 index) external view returns (uint256) {
        return LibPeriphery.s().positionSeries[positionId][index];
    }

    function seriesMigration(uint256 oldSeriesId)
        external
        view
        returns (LibPeriphery.SeriesMigration memory migration)
    {
        return LibPeriphery.s().migration[oldSeriesId];
    }

    function rewardEligibleAt(uint256 positionId, uint256 seriesId) external view returns (uint256) {
        LibPeriphery.PositionLeg storage positionLeg = _leg(LibPeriphery.s(), positionId, seriesId);
        return positionLeg.pendingPrincipal == 0 ? 0 : positionLeg.pendingSince + LibPeriphery.REWARD_GATE;
    }

    function _creditMigratedPrincipal(
        LibPeriphery.PS storage ps,
        uint256 positionId,
        uint256 seriesId,
        uint256 newPrincipal,
        uint256 oldEligible,
        uint256 oldPending,
        uint256 oldOptIn,
        uint256 oldPendingSince
    ) internal {
        if (newPrincipal == 0) return;
        uint256 oldTotal = oldEligible + oldPending + oldOptIn;
        uint256 newEligible = Math.mulDiv(newPrincipal, oldEligible, oldTotal);
        uint256 newOptInTarget = Math.mulDiv(newPrincipal, oldOptIn, oldTotal);
        uint256 newPending = newPrincipal - newEligible - newOptInTarget;
        LibPeriphery.PositionLeg storage newLeg = ps.leg[positionId][seriesId];
        LibPeriphery.SeriesBook storage newBook = ps.series[seriesId];
        if (!newLeg.exists) {
            LibPosition.activateLeg(positionId, LibPosition.dollarLegKey(seriesId));
            newLeg.exists = true;
            newLeg.collateralPassiveCheckpointRay = newBook.collateralPassive.accPerStoredRay;
            newLeg.staticsDollarPassiveCheckpointRay = newBook.staticsDollarPassive.accPerStoredRay;
            newLeg.optInEpoch = newBook.optInEpoch;
            newLeg.collateralOptInCheckpointRay = newBook.collateralOptIn[newBook.optInEpoch].accPerStoredRay;
            newLeg.staticsDollarOptInCheckpointRay = newBook.staticsDollarOptIn[newBook.optInEpoch].accPerStoredRay;
            LibPeriphery.addSeries(ps, positionId, seriesId);
        } else {
            LibPeriphery.settleLeg(ps, positionId, seriesId);
        }
        if (newLeg.optInEpoch != newBook.optInEpoch) {
            newLeg.optInStored = 0;
            newLeg.optInEpoch = newBook.optInEpoch;
            newLeg.collateralOptInCheckpointRay = newBook.collateralOptIn[newBook.optInEpoch].accPerStoredRay;
            newLeg.staticsDollarOptInCheckpointRay = newBook.staticsDollarOptIn[newBook.optInEpoch].accPerStoredRay;
        }
        LibPeriphery.ensureLiveOptInScale(newBook);
        newLeg.eligiblePrincipal += newEligible;
        newBook.eligiblePrincipal += newEligible;
        if (newPending != 0) {
            if (newLeg.pendingPrincipal == 0) {
                newLeg.pendingPrincipal = newPending;
                newLeg.pendingSince = oldPendingSince == 0 ? block.timestamp : oldPendingSince;
            } else {
                uint256 combined = newLeg.pendingPrincipal + newPending;
                uint256 existingAge = block.timestamp - newLeg.pendingSince;
                uint256 incomingSince = oldPendingSince == 0 ? block.timestamp : oldPendingSince;
                uint256 incomingAge = block.timestamp - incomingSince;
                uint256 weightedAge = Math.mulDiv(newLeg.pendingPrincipal, existingAge, combined)
                    + Math.mulDiv(newPending, incomingAge, combined);
                newLeg.pendingPrincipal = combined;
                newLeg.pendingSince = block.timestamp - weightedAge;
            }
        }
        if (newOptInTarget != 0) {
            (uint256 stored, uint256 newOptIn) =
                LibPeriphery.storedAdditionForEffectiveDown(newBook, newLeg.optInStored, newOptInTarget);
            if (stored != 0) {
                newLeg.optInStored += stored;
                newBook.optInTotalStored += stored;
                newBook.optInPrincipal += newOptIn;
            }
            uint256 optInDust = newOptInTarget - newOptIn;
            if (optInDust != 0) LibPeriphery.addPending(newLeg, optInDust);
        }
    }

    function _increaseLeg(LibPeriphery.PS storage ps, uint256 positionId, uint256 seriesId, uint256 amount) internal {
        LibPeriphery.PositionLeg storage positionLeg = ps.leg[positionId][seriesId];
        LibPeriphery.SeriesBook storage book = ps.series[seriesId];
        if (!positionLeg.exists) {
            bytes32 sharedLegKey = LibPosition.dollarLegKey(seriesId);
            if (!LibPosition.positionStorage().activeLeg[positionId][sharedLegKey]) {
                LibPosition.activateLeg(positionId, sharedLegKey);
            }
            positionLeg.exists = true;
            positionLeg.collateralPassiveCheckpointRay = book.collateralPassive.accPerStoredRay;
            positionLeg.staticsDollarPassiveCheckpointRay = book.staticsDollarPassive.accPerStoredRay;
            positionLeg.optInEpoch = book.optInEpoch;
            positionLeg.collateralOptInCheckpointRay = book.collateralOptIn[book.optInEpoch].accPerStoredRay;
            positionLeg.staticsDollarOptInCheckpointRay = book.staticsDollarOptIn[book.optInEpoch].accPerStoredRay;
            LibPeriphery.addSeries(ps, positionId, seriesId);
        } else {
            LibPeriphery.settleLeg(ps, positionId, seriesId);
        }
        LibPeriphery.ensureLiveOptInScale(book);
        LibPeriphery.addPending(positionLeg, amount);
        emit LegIncreased(positionId, seriesId, amount, positionLeg.pendingSince);
    }

    function _removeBasePrincipal(
        LibPeriphery.PS storage ps,
        uint256 seriesId,
        LibPeriphery.PositionLeg storage positionLeg,
        uint256 amount
    ) internal {
        uint256 pending = amount < positionLeg.pendingPrincipal ? amount : positionLeg.pendingPrincipal;
        positionLeg.pendingPrincipal -= pending;
        if (positionLeg.pendingPrincipal == 0) positionLeg.pendingSince = 0;
        uint256 eligible = amount - pending;
        if (eligible != 0) {
            positionLeg.eligiblePrincipal -= eligible;
            ps.series[seriesId].eligiblePrincipal -= eligible;
        }
    }

    function _requireActive(LibPeriphery.PS storage ps, uint256 seriesId) internal view {
        if (IStaticsDollarCore(ps.pool).riskSeries(seriesId).status != IStaticsDollarCoreTypes.SeriesStatus.Active) {
            revert SeriesNotActive(seriesId);
        }
    }

    function _leg(LibPeriphery.PS storage ps, uint256 positionId, uint256 seriesId)
        internal
        view
        returns (LibPeriphery.PositionLeg storage positionLeg)
    {
        positionLeg = ps.leg[positionId][seriesId];
        if (!positionLeg.exists) revert UnknownLeg(positionId, seriesId);
    }

    function _enforceOwnerOrApproved(LibPeriphery.PS storage, uint256 positionId) internal view {
        if (!LibPosition.isAuthorized(positionId, msg.sender)) {
            revert NotPositionOwnerOrApproved(positionId, msg.sender);
        }
    }

    function pool() external view returns (address) {
        return LibPeriphery.s().pool;
    }

    function staticsDollar() external view returns (address) {
        return LibPeriphery.s().staticsDollar;
    }

    function staticsDollarRisk() external view returns (address) {
        return LibPeriphery.s().staticsDollarRisk;
    }

    function positionNFT() external view returns (address) {
        return address(this);
    }

    function onERC1155Received(address operator, address from, uint256 seriesId, uint256 amount, bytes calldata)
        external
        returns (bytes4)
    {
        LibPeriphery.PS storage ps = LibPeriphery.s();
        LibPeriphery.ExpectedRiskIngress memory expected = ps.expectedRiskIngress;
        if (
            msg.sender != ps.staticsDollarRisk || !expected.active || operator != expected.operator
                || from != expected.from || seriesId != expected.seriesId || amount != expected.amount
        ) {
            revert UnexpectedRiskIngress(msg.sender, operator, from, seriesId, amount);
        }
        delete ps.expectedRiskIngress;
        return IERC1155Receiver.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert RiskBatchIngressUnsupported();
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IERC1155Receiver).interfaceId;
    }

    function _pullRisk(LibPeriphery.PS storage ps, address from, uint256 seriesId, uint256 amount) internal {
        _expectRiskIngress(ps, address(this), from, seriesId, amount);
        IERC1155(ps.staticsDollarRisk).safeTransferFrom(from, address(this), seriesId, amount, "");
        _requireRiskIngressConsumed(ps);
    }

    function _expectRiskIngress(
        LibPeriphery.PS storage ps,
        address operator,
        address from,
        uint256 seriesId,
        uint256 amount
    ) internal {
        if (amount == 0) return;
        if (ps.expectedRiskIngress.active) revert UnexpectedRiskIngressState();
        ps.expectedRiskIngress = LibPeriphery.ExpectedRiskIngress({
            operator: operator, from: from, seriesId: seriesId, amount: amount, active: true
        });
    }

    function _requireRiskIngressConsumed(LibPeriphery.PS storage ps) internal view {
        if (ps.expectedRiskIngress.active) revert UnexpectedRiskIngressState();
    }
}
