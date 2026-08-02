// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IStaticsDollarCore} from "../../core/interfaces/IStaticsDollarCore.sol";
import {LibCustody} from "../../../libraries/LibCustody.sol";
import {LibGlobalRewards} from "../../../libraries/LibGlobalRewards.sol";

library LibPeriphery {
    bytes32 internal constant STORAGE_POSITION = keccak256("statics.dollar.position.periphery.storage.v6");
    uint256 internal constant RAY = 1e27;
    uint256 internal constant BPS = 10_000;

    uint256 internal constant MAX_REDEMPTION_FEE_BPS = 1_000;
    uint256 internal constant MIN_REDEMPTION_SUPPLIER_SHARE_BPS = 5_000;

    enum IncentiveKind {
        Collateral,
        StaticsDollar,
        Statics
    }

    struct ProceedsIndex {
        uint256 accPerStoredRay;
        uint256 remainderRay;
    }

    struct SeriesBook {
        uint256 totalStored;
        uint256 effectivePrincipal;
        uint256 scaleRay;
        uint64 epoch;
        mapping(uint64 epoch => ProceedsIndex index) collateralProceeds;
        mapping(uint64 epoch => ProceedsIndex index) staticsDollarProceeds;
        mapping(uint64 epoch => ProceedsIndex index) staticsProceeds;
        uint256 collateralIncentiveReserve;
        uint256 staticsDollarIncentiveReserve;
        uint256 staticsIncentiveReserve;
        uint256 incentiveDestinationSeriesId;
        bool incentivesRoutedGlobal;
        bool incentivesFinalized;
    }

    struct PositionLeg {
        uint256 stored;
        uint256 collateralCheckpointRay;
        uint256 staticsDollarCheckpointRay;
        uint256 staticsCheckpointRay;
        uint256 accruedCollateral;
        uint256 accruedStaticsDollar;
        uint256 accruedStatics;
        uint64 epoch;
        bool exists;
    }

    struct SeriesMigration {
        uint256 newSeriesId;
        uint256 oldPrincipal;
        uint256 remainingOldPrincipal;
        uint256 remainingNewPrincipal;
        uint256 remainingStaticsDollar;
        uint256 remainingCollateral;
        bool returned;
        bool claimed;
    }

    struct ExpectedRiskIngress {
        address operator;
        address from;
        uint256 seriesId;
        uint256 amount;
        bool active;
    }

    struct InitArgs {
        address pool;
        address weth;
        uint16 baseBps;
        uint16 insuranceBps;
        uint16 redemptionFeeBps;
        uint16 redemptionSupplierShareBps;
    }

    struct PS {
        address pool;
        address staticsDollar;
        address staticsDollarRisk;
        address staticsToken;
        address weth;
        uint16 baseBps;
        uint16 insuranceBps;
        uint16 redemptionFeeBps;
        uint16 redemptionSupplierShareBps;
        mapping(uint256 seriesId => SeriesBook book) series;
        mapping(uint256 positionId => mapping(uint256 seriesId => PositionLeg leg)) leg;
        mapping(uint256 positionId => uint256[] seriesIds) positionSeries;
        mapping(uint256 positionId => mapping(uint256 seriesId => uint256 indexPlusOne)) positionSeriesIndex;
        mapping(address token => uint256 amount) reservedByToken;
        mapping(uint256 profileId => uint256 amount) pendingInsurance;
        mapping(address token => uint256 amount) pendingInsuranceByToken;
        mapping(uint256 oldSeriesId => SeriesMigration migration) migration;
        bool initialized;
        ExpectedRiskIngress expectedRiskIngress;
    }

    event RiskProceedsAccrued(
        uint256 indexed seriesId, uint64 indexed epoch, address indexed token, uint256 amount, bytes32 source
    );
    event RiskProceedsSettled(
        uint256 indexed positionId,
        uint256 indexed seriesId,
        uint256 collateralAdded,
        uint256 staticsDollarAdded,
        uint256 staticsAdded,
        uint256 accruedCollateral,
        uint256 accruedStaticsDollar,
        uint256 accruedStatics
    );
    event RiskLiquidityDustCleared(uint256 indexed positionId, uint256 indexed seriesId, uint256 storedUnits);

    error NoRiskLiquidity(uint256 seriesId);
    error ConsumeExceedsLiquidity(uint256 requested, uint256 available);
    error RiskLiquidityScaleExhausted(uint256 storedUnits);
    error RiskLiquidityAmountTooSmall(uint256 requested);
    error AlreadyInitialized();
    error InvalidSplit();
    error InvalidRedemptionParams();
    error ZeroAddress();

    function s() internal pure returns (PS storage ps) {
        bytes32 slot = STORAGE_POSITION;
        assembly {
            ps.slot := slot
        }
    }

    function initialize(InitArgs memory args) internal {
        PS storage ps = s();
        if (ps.initialized) revert AlreadyInitialized();
        if (args.pool == address(0) || args.weth == address(0)) revert ZeroAddress();
        if (uint256(args.baseBps) + uint256(args.insuranceBps) != BPS) revert InvalidSplit();
        if (
            args.redemptionFeeBps > MAX_REDEMPTION_FEE_BPS || args.redemptionSupplierShareBps > BPS
                || args.redemptionSupplierShareBps < MIN_REDEMPTION_SUPPLIER_SHARE_BPS
        ) revert InvalidRedemptionParams();

        IStaticsDollarCore pool = IStaticsDollarCore(args.pool);
        ps.pool = args.pool;
        ps.staticsDollar = pool.staticsDollar();
        ps.staticsDollarRisk = pool.staticsDollarRisk();
        ps.staticsToken = LibGlobalRewards.rewardStorage().stakingToken;
        ps.weth = args.weth;
        ps.baseBps = args.baseBps;
        ps.insuranceBps = args.insuranceBps;
        ps.redemptionFeeBps = args.redemptionFeeBps;
        ps.redemptionSupplierShareBps = args.redemptionSupplierShareBps;
        ps.initialized = true;
    }

    function addSeries(PS storage ps, uint256 positionId, uint256 seriesId) internal {
        if (ps.positionSeriesIndex[positionId][seriesId] != 0) return;
        ps.positionSeries[positionId].push(seriesId);
        ps.positionSeriesIndex[positionId][seriesId] = ps.positionSeries[positionId].length;
    }

    function removeSeries(PS storage ps, uint256 positionId, uint256 seriesId) internal {
        uint256 indexPlusOne = ps.positionSeriesIndex[positionId][seriesId];
        if (indexPlusOne == 0) return;
        uint256 index = indexPlusOne - 1;
        uint256 lastIndex = ps.positionSeries[positionId].length - 1;
        if (index != lastIndex) {
            uint256 lastSeriesId = ps.positionSeries[positionId][lastIndex];
            ps.positionSeries[positionId][index] = lastSeriesId;
            ps.positionSeriesIndex[positionId][lastSeriesId] = index + 1;
        }
        ps.positionSeries[positionId].pop();
        delete ps.positionSeriesIndex[positionId][seriesId];
    }

    function effective(SeriesBook storage book, uint256 stored) internal view returns (uint256) {
        return Math.mulDiv(stored, book.scaleRay, RAY);
    }

    function positionEffective(SeriesBook storage book, uint256 stored) internal view returns (uint256) {
        if (stored != 0 && stored == book.totalStored) return book.effectivePrincipal;
        return effective(book, stored);
    }

    function addLiquidity(SeriesBook storage book, uint256 amount) internal returns (uint256 storedAdded) {
        if (amount == 0) return 0;
        if (book.totalStored == 0) {
            book.scaleRay = RAY;
            storedAdded = amount;
        } else {
            if (book.effectivePrincipal == 0 || book.scaleRay == 0) {
                revert RiskLiquidityScaleExhausted(book.totalStored);
            }
            storedAdded = Math.mulDiv(amount, book.totalStored, book.effectivePrincipal);
            if (storedAdded == 0) revert RiskLiquidityAmountTooSmall(amount);
        }
        book.totalStored += storedAdded;
        book.effectivePrincipal += amount;
        book.scaleRay = Math.mulDiv(book.effectivePrincipal, RAY, book.totalStored);
        if (book.scaleRay == 0) revert RiskLiquidityScaleExhausted(book.totalStored);
    }

    function removeLiquidity(SeriesBook storage book, uint256 legStored, uint256 maximumAmount)
        internal
        returns (uint256 storedRemoved, uint256 principalOut)
    {
        uint256 available = positionEffective(book, legStored);
        if (maximumAmount == 0 || maximumAmount > available) {
            revert ConsumeExceedsLiquidity(maximumAmount, available);
        }
        storedRemoved = Math.mulDiv(maximumAmount, book.totalStored, book.effectivePrincipal, Math.Rounding.Ceil);
        if (storedRemoved > legStored) storedRemoved = legStored;
        principalOut = storedRemoved == book.totalStored
            ? book.effectivePrincipal
            : available - effective(book, legStored - storedRemoved);
        book.totalStored -= storedRemoved;
        book.effectivePrincipal -= principalOut;
        if (book.totalStored == 0) {
            book.scaleRay = RAY;
            book.epoch += 1;
        } else {
            book.scaleRay = Math.mulDiv(book.effectivePrincipal, RAY, book.totalStored);
            if (book.scaleRay == 0) revert RiskLiquidityScaleExhausted(book.totalStored);
        }
    }

    function settleLeg(PS storage ps, uint256 positionId, uint256 seriesId) internal {
        PositionLeg storage leg = ps.leg[positionId][seriesId];
        SeriesBook storage book = ps.series[seriesId];
        ProceedsIndex storage collateralIndex = book.collateralProceeds[leg.epoch];
        ProceedsIndex storage staticsDollarIndex = book.staticsDollarProceeds[leg.epoch];
        ProceedsIndex storage staticsIndex = book.staticsProceeds[leg.epoch];
        uint256 collateralAdded;
        uint256 staticsDollarAdded;
        uint256 staticsAdded;
        if (collateralIndex.accPerStoredRay > leg.collateralCheckpointRay && leg.stored != 0) {
            collateralAdded =
                Math.mulDiv(leg.stored, collateralIndex.accPerStoredRay - leg.collateralCheckpointRay, RAY);
        }
        if (staticsDollarIndex.accPerStoredRay > leg.staticsDollarCheckpointRay && leg.stored != 0) {
            staticsDollarAdded =
                Math.mulDiv(leg.stored, staticsDollarIndex.accPerStoredRay - leg.staticsDollarCheckpointRay, RAY);
        }
        if (staticsIndex.accPerStoredRay > leg.staticsCheckpointRay && leg.stored != 0) {
            staticsAdded = Math.mulDiv(leg.stored, staticsIndex.accPerStoredRay - leg.staticsCheckpointRay, RAY);
        }
        leg.collateralCheckpointRay = collateralIndex.accPerStoredRay;
        leg.staticsDollarCheckpointRay = staticsDollarIndex.accPerStoredRay;
        leg.staticsCheckpointRay = staticsIndex.accPerStoredRay;
        leg.accruedCollateral += collateralAdded;
        leg.accruedStaticsDollar += staticsDollarAdded;
        leg.accruedStatics += staticsAdded;
        if (collateralAdded != 0 || staticsDollarAdded != 0 || staticsAdded != 0) {
            emit RiskProceedsSettled(
                positionId,
                seriesId,
                collateralAdded,
                staticsDollarAdded,
                staticsAdded,
                leg.accruedCollateral,
                leg.accruedStaticsDollar,
                leg.accruedStatics
            );
        }
    }

    function pendingProceeds(PS storage ps, uint256 positionId, uint256 seriesId)
        internal
        view
        returns (uint256 collateralAmount, uint256 staticsDollarAmount, uint256 staticsAmount)
    {
        PositionLeg storage leg = ps.leg[positionId][seriesId];
        collateralAmount = leg.accruedCollateral;
        staticsDollarAmount = leg.accruedStaticsDollar;
        staticsAmount = leg.accruedStatics;
        SeriesBook storage book = ps.series[seriesId];
        ProceedsIndex storage collateralIndex = book.collateralProceeds[leg.epoch];
        ProceedsIndex storage staticsDollarIndex = book.staticsDollarProceeds[leg.epoch];
        ProceedsIndex storage staticsIndex = book.staticsProceeds[leg.epoch];
        if (collateralIndex.accPerStoredRay > leg.collateralCheckpointRay && leg.stored != 0) {
            collateralAmount += Math.mulDiv(
                leg.stored, collateralIndex.accPerStoredRay - leg.collateralCheckpointRay, RAY
            );
        }
        if (staticsDollarIndex.accPerStoredRay > leg.staticsDollarCheckpointRay && leg.stored != 0) {
            staticsDollarAmount += Math.mulDiv(
                leg.stored, staticsDollarIndex.accPerStoredRay - leg.staticsDollarCheckpointRay, RAY
            );
        }
        if (staticsIndex.accPerStoredRay > leg.staticsCheckpointRay && leg.stored != 0) {
            staticsAmount += Math.mulDiv(leg.stored, staticsIndex.accPerStoredRay - leg.staticsCheckpointRay, RAY);
        }
    }

    function accrueRiskProceeds(
        PS storage ps,
        uint256 seriesId,
        uint64 epoch,
        uint256 totalStored,
        address collateralToken,
        uint256 amount,
        bytes32 source
    ) internal {
        if (amount == 0) return;
        if (totalStored == 0) revert NoRiskLiquidity(seriesId);
        reserve(ps, collateralToken, amount);
        ProceedsIndex storage index = ps.series[seriesId].collateralProceeds[epoch];
        (uint256 delta, uint256 remainder) = _indexDelta(amount, totalStored, index.remainderRay);
        index.remainderRay = remainder;
        index.accPerStoredRay += delta;
        emit RiskProceedsAccrued(seriesId, epoch, collateralToken, amount, source);
    }

    function accrueReservedRiskIncentive(
        PS storage ps,
        uint256 seriesId,
        uint64 epoch,
        uint256 totalStored,
        address token,
        uint256 amount,
        IncentiveKind incentiveKind,
        bytes32 source
    ) internal {
        if (amount == 0) return;
        if (totalStored == 0) revert NoRiskLiquidity(seriesId);
        SeriesBook storage book = ps.series[seriesId];
        ProceedsIndex storage index;
        if (incentiveKind == IncentiveKind.Collateral) {
            index = book.collateralProceeds[epoch];
        } else if (incentiveKind == IncentiveKind.StaticsDollar) {
            index = book.staticsDollarProceeds[epoch];
        } else {
            index = book.staticsProceeds[epoch];
        }
        (uint256 delta, uint256 remainder) = _indexDelta(amount, totalStored, index.remainderRay);
        index.remainderRay = remainder;
        index.accPerStoredRay += delta;
        emit RiskProceedsAccrued(seriesId, epoch, token, amount, source);
    }

    function proportionalRelease(uint256 incentiveReserve, uint256 fill, uint256 availableBefore)
        internal
        pure
        returns (uint256)
    {
        if (incentiveReserve == 0) return 0;
        if (fill == availableBefore) return incentiveReserve;
        return Math.mulDiv(incentiveReserve, fill, availableBefore);
    }

    function reserve(PS storage ps, address token, uint256 amount) internal {
        LibCustody.reserve(LibCustody.dollarAccount(), token, amount);
        ps.reservedByToken[token] += amount;
    }

    function clearZeroValueLiquidity(PS storage ps, uint256 positionId, uint256 seriesId)
        internal
        returns (uint256 clearedStored)
    {
        PositionLeg storage leg = ps.leg[positionId][seriesId];
        SeriesBook storage book = ps.series[seriesId];
        if (leg.stored == 0) return 0;
        if (leg.epoch == book.epoch) {
            if (positionEffective(book, leg.stored) != 0) return 0;
            book.totalStored -= leg.stored;
            book.scaleRay = Math.mulDiv(book.effectivePrincipal, RAY, book.totalStored);
        }
        clearedStored = leg.stored;
        leg.stored = 0;
        leg.epoch = book.epoch;
        leg.collateralCheckpointRay = book.collateralProceeds[book.epoch].accPerStoredRay;
        leg.staticsDollarCheckpointRay = book.staticsDollarProceeds[book.epoch].accPerStoredRay;
        leg.staticsCheckpointRay = book.staticsProceeds[book.epoch].accPerStoredRay;
        emit RiskLiquidityDustCleared(positionId, seriesId, clearedStored);
    }

    function consume(PS storage ps, uint256 seriesId, uint256 effectiveAmount) internal returns (uint256 newScaleRay) {
        SeriesBook storage book = ps.series[seriesId];
        uint256 available = book.effectivePrincipal;
        if (effectiveAmount == 0 || effectiveAmount > available) {
            revert ConsumeExceedsLiquidity(effectiveAmount, available);
        }
        uint256 remaining = available - effectiveAmount;
        newScaleRay = remaining == 0 ? RAY : Math.mulDiv(remaining, RAY, book.totalStored);
        if (remaining != 0 && newScaleRay == 0) revert RiskLiquidityScaleExhausted(book.totalStored);
        if (remaining == 0) {
            book.totalStored = 0;
            book.epoch += 1;
        }
        book.effectivePrincipal = remaining;
        book.scaleRay = newScaleRay;
    }

    function _indexDelta(uint256 amount, uint256 denominator, uint256 priorRemainder)
        private
        pure
        returns (uint256 delta, uint256 remainder)
    {
        delta = Math.mulDiv(amount, RAY, denominator);
        remainder = mulmod(amount, RAY, denominator);
        delta += priorRemainder / denominator;
        uint256 normalizedPrior = priorRemainder % denominator;
        uint256 room = denominator - normalizedPrior;
        if (remainder >= room) {
            ++delta;
            remainder -= room;
        } else {
            remainder += normalizedPrior;
        }
    }
}
