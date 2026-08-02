// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {IERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IStaticsDollarCoreTypes} from "../../interfaces/IStaticsDollarCoreTypes.sol";
import {IStaticsDollarRiskLiquidity} from "../../interfaces/IStaticsDollarRiskLiquidity.sol";
import {IStaticsDollarRiskIncentives} from "../../interfaces/IStaticsDollarRiskIncentives.sol";
import {IStaticsDollarCore} from "../../core/interfaces/IStaticsDollarCore.sol";
import {IStaticsPositionModule} from "../../../interfaces/IStaticsPosition.sol";
import {LibCustody} from "../../../libraries/LibCustody.sol";
import {LibGlobalRewards} from "../../../libraries/LibGlobalRewards.sol";
import {LibPosition} from "../../../position/LibPosition.sol";
import {LibPeriphery} from "../libraries/LibPeriphery.sol";

contract StakingFacet is IStaticsDollarRiskLiquidity, IStaticsDollarRiskIncentives, IERC1155Receiver, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct MigrationAmounts {
        uint256 oldPrincipal;
        uint256 newPrincipal;
        uint256 staticsDollarCredit;
        uint256 collateralCredit;
    }

    event RiskLiquidityClosed(uint256 indexed positionId, uint256 indexed seriesId);
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
    error UnknownRiskLiquidity(uint256 positionId, uint256 seriesId);
    error NotPositionOwnerOrApproved(uint256 positionId, address caller);
    error InsufficientRiskLiquidity(uint256 requested, uint256 available);
    error NoRiskProceeds(uint256 positionId, uint256 seriesId);
    error SeriesNotActive(uint256 seriesId);
    error SeriesNotIncentiveEligible(uint256 seriesId);
    error SeriesIncentivesNotFinalizable(uint256 seriesId);
    error RiskLiquidityHasValue(uint256 positionId, uint256 seriesId);
    error SeriesMigrationNotReady(uint256 seriesId);
    error SeriesMigrationAlreadyProcessed(uint256 seriesId);
    error UnexpectedRiskIngress(address token, address operator, address from, uint256 seriesId, uint256 amount);
    error UnexpectedRiskIngressState();
    error RiskBatchIngressUnsupported();
    error InsufficientTransferReceived(address token, uint256 required, uint256 received);

    function fundRiskCollateralIncentives(uint256 seriesId, uint256 amount)
        external
        override
        nonReentrant
        returns (uint256 received)
    {
        LibPeriphery.PS storage ps = LibPeriphery.s();
        address token = _requireIncentiveEligible(ps, seriesId).collateralToken;
        received = _fundRiskIncentives(ps, seriesId, token, amount);
        ps.series[seriesId].collateralIncentiveReserve += received;
    }

    function fundRiskDollarIncentives(uint256 seriesId, uint256 amount)
        external
        override
        nonReentrant
        returns (uint256 received)
    {
        LibPeriphery.PS storage ps = LibPeriphery.s();
        _requireIncentiveEligible(ps, seriesId);
        received = _fundRiskIncentives(ps, seriesId, ps.staticsDollar, amount);
        ps.series[seriesId].staticsDollarIncentiveReserve += received;
    }

    function fundRiskStaticsIncentives(uint256 seriesId, uint256 amount)
        external
        override
        nonReentrant
        returns (uint256 received)
    {
        LibPeriphery.PS storage ps = LibPeriphery.s();
        _requireIncentiveEligible(ps, seriesId);
        received = _fundRiskIncentives(ps, seriesId, ps.staticsToken, amount);
        ps.series[seriesId].staticsIncentiveReserve += received;
    }

    function riskIncentives(uint256 seriesId) external view override returns (RiskIncentiveView memory view_) {
        LibPeriphery.PS storage ps = LibPeriphery.s();
        IStaticsDollarCoreTypes.RiskSeries memory series = IStaticsDollarCore(ps.pool).riskSeries(seriesId);
        LibPeriphery.SeriesBook storage book = ps.series[seriesId];
        view_ = RiskIncentiveView({
            collateralToken: series.collateralToken,
            staticsToken: ps.staticsToken,
            collateralReserve: book.collateralIncentiveReserve,
            staticsDollarReserve: book.staticsDollarIncentiveReserve,
            staticsReserve: book.staticsIncentiveReserve,
            destinationSeriesId: book.incentiveDestinationSeriesId,
            routedGlobal: book.incentivesRoutedGlobal,
            finalized: book.incentivesFinalized
        });
    }

    function finalizeRiskIncentives(uint256 seriesId)
        external
        override
        nonReentrant
        returns (uint256 destinationSeriesId, bool routedGlobal)
    {
        LibPeriphery.PS storage ps = LibPeriphery.s();
        return _finalizeRiskIncentives(ps, seriesId, IStaticsDollarCore(ps.pool).riskSeries(seriesId));
    }

    function createAndStakeRiskShares(uint256 seriesId, uint256 amount, address receiver)
        external
        payable
        override
        nonReentrant
        returns (uint256 positionId)
    {
        if (amount == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();
        LibPeriphery.PS storage ps = LibPeriphery.s();
        _requireActive(ps, seriesId);
        positionId = IStaticsPositionModule(address(this)).createPositionForModule{value: msg.value}(
            receiver, LibPosition.dollarLegKey(seriesId)
        );
        _stake(ps, positionId, seriesId, msg.sender, amount, true);
    }

    function stakeRiskShares(uint256 positionId, uint256 seriesId, uint256 amount) external override nonReentrant {
        if (amount == 0) revert ZeroAmount();
        LibPeriphery.PS storage ps = LibPeriphery.s();
        _enforceAuthorized(positionId);
        _requireActive(ps, seriesId);
        _stake(ps, positionId, seriesId, msg.sender, amount, true);
    }

    function unstakeRiskShares(uint256 positionId, uint256 seriesId, uint256 amount, address receiver)
        external
        override
        nonReentrant
        returns (uint256 principalOut)
    {
        if (amount == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();
        LibPeriphery.PS storage ps = LibPeriphery.s();
        _enforceAuthorized(positionId);
        LibPeriphery.PositionLeg storage leg_ = _leg(ps, positionId, seriesId);
        LibPeriphery.SeriesBook storage book = ps.series[seriesId];
        if (leg_.epoch != book.epoch) revert InsufficientRiskLiquidity(amount, 0);
        uint256 available = LibPeriphery.positionEffective(book, leg_.stored);
        if (amount > available) revert InsufficientRiskLiquidity(amount, available);

        LibPeriphery.settleLeg(ps, positionId, seriesId);
        (uint256 storedRemoved, uint256 removed) = LibPeriphery.removeLiquidity(book, leg_.stored, amount);
        leg_.stored -= storedRemoved;
        principalOut = removed;
        if (leg_.stored == 0) {
            leg_.epoch = book.epoch;
            leg_.collateralCheckpointRay = book.collateralProceeds[book.epoch].accPerStoredRay;
        }
        IERC1155(ps.staticsDollarRisk).safeTransferFrom(address(this), receiver, seriesId, principalOut, "");
        emit RiskSharesUnstaked(positionId, seriesId, receiver, principalOut);
    }

    function claimRiskProceeds(uint256 positionId, uint256 seriesId, address receiver)
        external
        override
        nonReentrant
        returns (uint256 collateralAmount, uint256 staticsDollarAmount, uint256 staticsAmount)
    {
        if (receiver == address(0)) revert ZeroAddress();
        LibPeriphery.PS storage ps = LibPeriphery.s();
        _enforceAuthorized(positionId);
        LibPeriphery.PositionLeg storage leg_ = _leg(ps, positionId, seriesId);
        LibPeriphery.settleLeg(ps, positionId, seriesId);
        collateralAmount = leg_.accruedCollateral;
        staticsDollarAmount = leg_.accruedStaticsDollar;
        staticsAmount = leg_.accruedStatics;
        if (collateralAmount == 0 && staticsDollarAmount == 0 && staticsAmount == 0) {
            revert NoRiskProceeds(positionId, seriesId);
        }
        leg_.accruedCollateral = 0;
        leg_.accruedStaticsDollar = 0;
        leg_.accruedStatics = 0;

        address collateralToken = IStaticsDollarCore(ps.pool).riskSeries(seriesId).collateralToken;
        _pushRiskProceeds(
            ps,
            receiver,
            collateralToken,
            collateralAmount,
            ps.staticsDollar,
            staticsDollarAmount,
            ps.staticsToken,
            staticsAmount
        );
        emit RiskProceedsClaimed(
            positionId,
            seriesId,
            receiver,
            collateralToken,
            ps.staticsToken,
            collateralAmount,
            staticsDollarAmount,
            staticsAmount
        );
    }

    /// @notice Permissionless aggregate transition processing. During the
    /// return window this escrows every Risk Share held by the Diamond. After
    /// finalization it claims once and records lazy PositionNFT conversion.
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
        _finalizeRiskIncentives(ps, oldSeriesId, series);
        if (migration.claimed) revert SeriesMigrationAlreadyProcessed(oldSeriesId);
        IStaticsDollarCoreTypes.StableCollateralProfile memory profile = core.collateralProfile(series.profileId);
        IStaticsDollarCoreTypes.RiskSeries memory successor = core.riskSeries(profile.activeSeriesId);
        IStaticsDollarCoreTypes.RecoveryClaimMode claimMode = profile.mode
                == IStaticsDollarCoreTypes.ProfileMode.Retired
            || successor.status != IStaticsDollarCoreTypes.SeriesStatus.Active
            ? IStaticsDollarCoreTypes.RecoveryClaimMode.CollateralOnly
            : IStaticsDollarCoreTypes.RecoveryClaimMode.NAV;

        uint256 collateralCredit;
        if (migration.returned) {
            IStaticsDollarCoreTypes.RecoveryClaimPreview memory preview =
                core.previewReturnedRiskClaim(address(this), oldSeriesId, claimMode);
            newSeriesId = preview.successorSeriesId;
            if (preview.collateralIn != 0) IERC20(series.collateralToken).forceApprove(ps.pool, preview.collateralIn);
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
        _enforceAuthorized(positionId);
        LibPeriphery.SeriesMigration storage migration = ps.migration[oldSeriesId];
        if (!migration.claimed) revert SeriesMigrationNotReady(oldSeriesId);
        LibPeriphery.PositionLeg storage oldLeg = _leg(ps, positionId, oldSeriesId);
        LibPeriphery.SeriesBook storage oldBook = ps.series[oldSeriesId];
        LibPeriphery.settleLeg(ps, positionId, oldSeriesId);

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
        if (amounts.newPrincipal != 0) {
            _stake(ps, positionId, newSeriesId, address(0), amounts.newPrincipal, false);
        }
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

    function closeRiskLiquidity(uint256 positionId, uint256 seriesId) external nonReentrant {
        LibPeriphery.PS storage ps = LibPeriphery.s();
        _enforceAuthorized(positionId);
        LibPeriphery.PositionLeg storage leg_ = _leg(ps, positionId, seriesId);
        LibPeriphery.settleLeg(ps, positionId, seriesId);
        LibPeriphery.clearZeroValueLiquidity(ps, positionId, seriesId);
        if (
            leg_.stored != 0 || leg_.accruedCollateral != 0 || leg_.accruedStaticsDollar != 0
                || leg_.accruedStatics != 0
        ) {
            revert RiskLiquidityHasValue(positionId, seriesId);
        }
        delete ps.leg[positionId][seriesId];
        LibPeriphery.removeSeries(ps, positionId, seriesId);
        LibPosition.deactivateLeg(positionId, LibPosition.dollarLegKey(seriesId));
        emit RiskLiquidityClosed(positionId, seriesId);
    }

    function riskLiquidity(uint256 positionId, uint256 seriesId)
        external
        view
        override
        returns (RiskLiquidityView memory view_)
    {
        LibPeriphery.PS storage ps = LibPeriphery.s();
        LibPeriphery.PositionLeg storage leg_ = ps.leg[positionId][seriesId];
        LibPeriphery.SeriesBook storage book = ps.series[seriesId];
        (uint256 collateralAmount, uint256 staticsDollarAmount, uint256 staticsAmount) =
            LibPeriphery.pendingProceeds(ps, positionId, seriesId);
        view_ = RiskLiquidityView({
            effectiveShares: leg_.epoch == book.epoch ? LibPeriphery.positionEffective(book, leg_.stored) : 0,
            claimableCollateral: collateralAmount,
            claimableStaticsDollar: staticsDollarAmount,
            claimableStatics: staticsAmount,
            epoch: leg_.epoch,
            exists: leg_.exists
        });
    }

    function totalRiskLiquidity(uint256 seriesId) external view override returns (uint256) {
        return LibPeriphery.s().series[seriesId].effectivePrincipal;
    }

    function riskLiquidityScaleRay(uint256 seriesId) external view returns (uint256) {
        return LibPeriphery.s().series[seriesId].scaleRay;
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

    function reservedBalance(address token) external view returns (uint256) {
        return LibPeriphery.s().reservedByToken[token];
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

    function _stake(
        LibPeriphery.PS storage ps,
        uint256 positionId,
        uint256 seriesId,
        address supplier,
        uint256 amount,
        bool pull
    ) private {
        LibPeriphery.PositionLeg storage leg_ = ps.leg[positionId][seriesId];
        LibPeriphery.SeriesBook storage book = ps.series[seriesId];
        if (!leg_.exists) {
            bytes32 legKey = LibPosition.dollarLegKey(seriesId);
            if (!LibPosition.positionStorage().activeLeg[positionId][legKey]) {
                LibPosition.activateLeg(positionId, legKey);
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
        if (pull) _pullRisk(ps, supplier, seriesId, amount);
        emit RiskSharesStaked(positionId, seriesId, supplier, amount);
    }

    function _requireActive(LibPeriphery.PS storage ps, uint256 seriesId) private view {
        if (IStaticsDollarCore(ps.pool).riskSeries(seriesId).status != IStaticsDollarCoreTypes.SeriesStatus.Active) {
            revert SeriesNotActive(seriesId);
        }
    }

    function _requireIncentiveEligible(LibPeriphery.PS storage ps, uint256 seriesId)
        private
        view
        returns (IStaticsDollarCoreTypes.RiskSeries memory series)
    {
        IStaticsDollarCore core = IStaticsDollarCore(ps.pool);
        series = core.riskSeries(seriesId);
        IStaticsDollarCoreTypes.ProfileMode mode = core.collateralProfile(series.profileId).mode;
        if (
            series.status != IStaticsDollarCoreTypes.SeriesStatus.Active
                || (mode != IStaticsDollarCoreTypes.ProfileMode.Active
                    && mode != IStaticsDollarCoreTypes.ProfileMode.ReduceOnly)
        ) {
            revert SeriesNotIncentiveEligible(seriesId);
        }
    }

    function _finalizeRiskIncentives(
        LibPeriphery.PS storage ps,
        uint256 seriesId,
        IStaticsDollarCoreTypes.RiskSeries memory series
    ) private returns (uint256 destinationSeriesId, bool routedGlobal) {
        LibPeriphery.SeriesBook storage book = ps.series[seriesId];
        if (book.incentivesFinalized) {
            return (book.incentiveDestinationSeriesId, book.incentivesRoutedGlobal);
        }

        IStaticsDollarCore core = IStaticsDollarCore(ps.pool);
        IStaticsDollarCoreTypes.StableCollateralProfile memory profile = core.collateralProfile(series.profileId);
        if (profile.mode != IStaticsDollarCoreTypes.ProfileMode.Retired) {
            destinationSeriesId = profile.activeSeriesId;
            if (
                (series.status != IStaticsDollarCoreTypes.SeriesStatus.Recoverable
                        && series.status != IStaticsDollarCoreTypes.SeriesStatus.Closed)
                    || destinationSeriesId == seriesId
                    || core.riskSeries(destinationSeriesId).status != IStaticsDollarCoreTypes.SeriesStatus.Active
            ) {
                revert SeriesIncentivesNotFinalizable(seriesId);
            }
        } else if (
            series.status != IStaticsDollarCoreTypes.SeriesStatus.Recoverable
                && series.status != IStaticsDollarCoreTypes.SeriesStatus.Retired
                && series.status != IStaticsDollarCoreTypes.SeriesStatus.Closed
        ) {
            revert SeriesIncentivesNotFinalizable(seriesId);
        }

        uint256 collateralAmount = book.collateralIncentiveReserve;
        uint256 staticsDollarAmount = book.staticsDollarIncentiveReserve;
        uint256 staticsAmount = book.staticsIncentiveReserve;
        book.collateralIncentiveReserve = 0;
        book.staticsDollarIncentiveReserve = 0;
        book.staticsIncentiveReserve = 0;
        book.incentiveDestinationSeriesId = destinationSeriesId;
        book.incentivesRoutedGlobal = profile.mode == IStaticsDollarCoreTypes.ProfileMode.Retired;
        book.incentivesFinalized = true;
        routedGlobal = book.incentivesRoutedGlobal;

        if (routedGlobal) {
            _routeRiskIncentiveGlobal(ps, series.collateralToken, collateralAmount);
            _routeRiskIncentiveGlobal(ps, ps.staticsDollar, staticsDollarAmount);
            _routeRiskIncentiveGlobal(ps, ps.staticsToken, staticsAmount);
            emit RiskIncentivesRoutedGlobal(seriesId, collateralAmount, staticsDollarAmount, staticsAmount);
        } else {
            LibPeriphery.SeriesBook storage destination = ps.series[destinationSeriesId];
            destination.collateralIncentiveReserve += collateralAmount;
            destination.staticsDollarIncentiveReserve += staticsDollarAmount;
            destination.staticsIncentiveReserve += staticsAmount;
            emit RiskIncentivesRolledOver(
                seriesId, destinationSeriesId, collateralAmount, staticsDollarAmount, staticsAmount
            );
        }
    }

    function _routeRiskIncentiveGlobal(LibPeriphery.PS storage ps, address token, uint256 amount) private {
        if (amount == 0) return;
        ps.reservedByToken[token] -= amount;
        LibGlobalRewards.accrueNonSwapFee(LibCustody.dollarAccount(), token, amount);
    }

    function _fundRiskIncentives(LibPeriphery.PS storage ps, uint256 seriesId, address token, uint256 amount)
        private
        returns (uint256 received)
    {
        if (amount == 0) revert ZeroAmount();
        received = LibCustody.pull(token, msg.sender, amount);
        if (received == 0) revert ZeroAmount();
        LibPeriphery.reserve(ps, token, received);
        emit RiskIncentivesFunded(seriesId, token, msg.sender, amount, received);
    }

    function _leg(LibPeriphery.PS storage ps, uint256 positionId, uint256 seriesId)
        private
        view
        returns (LibPeriphery.PositionLeg storage leg_)
    {
        leg_ = ps.leg[positionId][seriesId];
        if (!leg_.exists) revert UnknownRiskLiquidity(positionId, seriesId);
    }

    function _enforceAuthorized(uint256 positionId) private view {
        if (!LibPosition.isAuthorized(positionId, msg.sender)) {
            revert NotPositionOwnerOrApproved(positionId, msg.sender);
        }
    }

    function _pullRisk(LibPeriphery.PS storage ps, address from, uint256 seriesId, uint256 amount) private {
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
    ) private {
        if (amount == 0) return;
        if (ps.expectedRiskIngress.active) revert UnexpectedRiskIngressState();
        ps.expectedRiskIngress = LibPeriphery.ExpectedRiskIngress({
            operator: operator, from: from, seriesId: seriesId, amount: amount, active: true
        });
    }

    function _requireRiskIngressConsumed(LibPeriphery.PS storage ps) private view {
        if (ps.expectedRiskIngress.active) revert UnexpectedRiskIngressState();
    }

    function _pushRiskProceeds(
        LibPeriphery.PS storage ps,
        address receiver,
        address collateralToken,
        uint256 collateralAmount,
        address dollarToken,
        uint256 dollarAmount,
        address staticsToken_,
        uint256 staticsAmount
    ) private {
        if (dollarToken == collateralToken) {
            collateralAmount += dollarAmount;
            dollarAmount = 0;
        }
        if (staticsToken_ == collateralToken) {
            collateralAmount += staticsAmount;
            staticsAmount = 0;
        } else if (staticsToken_ == dollarToken) {
            dollarAmount += staticsAmount;
            staticsAmount = 0;
        }
        _pushRiskToken(ps, receiver, collateralToken, collateralAmount);
        _pushRiskToken(ps, receiver, dollarToken, dollarAmount);
        _pushRiskToken(ps, receiver, staticsToken_, staticsAmount);
    }

    function _pushRiskToken(LibPeriphery.PS storage ps, address receiver, address token, uint256 amount) private {
        if (amount == 0) return;
        ps.reservedByToken[token] -= amount;
        LibCustody.pushReserved(LibCustody.dollarAccount(), token, receiver, amount, amount);
    }
}
