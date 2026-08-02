// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IStaticsDollarCoreTypes} from "../../interfaces/IStaticsDollarCoreTypes.sol";
import {IStaticsDollarCore} from "../../core/interfaces/IStaticsDollarCore.sol";
import {LibCustody} from "../../../libraries/LibCustody.sol";
import {LibBasket} from "../../../libraries/LibBasket.sol";

library LibPeriphery {
    bytes32 internal constant STORAGE_POSITION = keccak256("statics.dollar.position.periphery.storage.v4");
    uint256 internal constant RAY = 1e27;
    uint256 internal constant REWARD_GATE = 24 hours;
    uint256 internal constant BPS = 10_000;

    uint256 internal constant MAX_REDEMPTION_FEE_BPS = 1_000;
    uint256 internal constant MIN_REDEMPTION_STAKER_SHARE_BPS = 5_000;

    struct RewardIndex {
        uint256 accPerStoredRay;
        uint256 remainderRay;
    }

    struct SeriesBook {
        uint256 eligiblePrincipal;
        RewardIndex collateralPassive;
        RewardIndex staticsDollarPassive;
        uint256 optInTotalStored;
        uint256 optInPrincipal;
        uint256 optInScaleRay;
        uint256 collateralOptInReserve;
        uint256 staticsDollarOptInReserve;
        uint64 optInEpoch;
        mapping(uint64 epoch => RewardIndex index) collateralOptIn;
        mapping(uint64 epoch => RewardIndex index) staticsDollarOptIn;
        bool retiredRewardsFinalized;
    }

    struct PositionLeg {
        uint256 eligiblePrincipal;
        uint256 pendingPrincipal;
        uint256 pendingSince;
        uint256 collateralPassiveCheckpointRay;
        uint256 staticsDollarPassiveCheckpointRay;
        uint256 optInStored;
        uint256 collateralOptInCheckpointRay;
        uint256 staticsDollarOptInCheckpointRay;
        uint256 accruedCollateral;
        uint256 accruedStaticsDollar;
        uint64 optInEpoch;
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
        uint16 passiveRewardBps;
        uint16 redemptionFeeBps;
        uint16 redemptionStakerShareBps;
    }

    struct PS {
        address pool;
        address staticsDollar;
        address staticsDollarRisk;
        address weth;
        // Reserved to preserve the v3 Diamond storage layout after removal of the
        // unsafe external opt-in consumer capability.
        address deprecatedConsumer;
        uint16 baseBps;
        uint16 insuranceBps;
        uint16 redemptionFeeBps;
        uint16 redemptionStakerShareBps;
        uint16 passiveRewardBps;
        mapping(uint256 seriesId => SeriesBook book) series;
        mapping(uint256 positionId => mapping(uint256 seriesId => PositionLeg leg)) leg;
        mapping(uint256 positionId => uint256[] seriesIds) positionSeries;
        mapping(uint256 positionId => mapping(uint256 seriesId => uint256 indexPlusOne)) positionSeriesIndex;
        mapping(address token => uint256 amount) reservedByToken;
        mapping(uint256 profileId => uint256 amount) pendingInsurance;
        mapping(address token => uint256 amount) pendingInsuranceByToken;
        mapping(uint256 profileId => mapping(address token => uint256 amount)) peggedProtocolRevenue;
        mapping(uint256 oldSeriesId => SeriesMigration migration) migration;
        bool initialized;
        ExpectedRiskIngress expectedRiskIngress;
    }

    event SeriesFeesAccrued(uint256 indexed seriesId, address indexed token, uint256 amount, bytes32 source);
    event OptInFeesAccrued(
        uint256 indexed seriesId, uint64 indexed epoch, address indexed token, uint256 amount, bytes32 source
    );
    event LegRewardsSettled(
        uint256 indexed positionId,
        uint256 indexed seriesId,
        uint256 collateralAdded,
        uint256 staticsDollarAdded,
        uint256 accruedCollateral,
        uint256 accruedStaticsDollar
    );
    event OptInDustCleared(uint256 indexed positionId, uint256 indexed seriesId, uint256 storedUnits);
    event RetiredSeriesRewardsFinalized(
        uint256 indexed seriesId, uint256 collateralAmount, uint256 staticsDollarAmount, bool distributedToPassive
    );

    error NoRewardEligiblePrincipal(uint256 seriesId);
    error ConsumeExceedsTier(uint256 requested, uint256 available);
    error OptInScaleExhausted(uint256 storedUnits);
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
        if (args.passiveRewardBps > BPS) revert InvalidSplit();
        if (
            args.redemptionFeeBps > MAX_REDEMPTION_FEE_BPS || args.redemptionStakerShareBps > BPS
                || args.redemptionStakerShareBps < MIN_REDEMPTION_STAKER_SHARE_BPS
        ) revert InvalidRedemptionParams();

        IStaticsDollarCore pool = IStaticsDollarCore(args.pool);
        ps.pool = args.pool;
        ps.staticsDollar = pool.staticsDollar();
        ps.staticsDollarRisk = pool.staticsDollarRisk();
        ps.weth = args.weth;
        ps.baseBps = args.baseBps;
        ps.insuranceBps = args.insuranceBps;
        ps.passiveRewardBps = args.passiveRewardBps;
        ps.redemptionFeeBps = args.redemptionFeeBps;
        ps.redemptionStakerShareBps = args.redemptionStakerShareBps;
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

    function optInEffective(SeriesBook storage book, uint256 stored) internal view returns (uint256) {
        return Math.mulDiv(stored, book.optInScaleRay, RAY);
    }

    function optInPositionEffective(SeriesBook storage book, uint256 stored) internal view returns (uint256) {
        if (stored != 0 && stored == book.optInTotalStored) return book.optInPrincipal;
        return optInEffective(book, stored);
    }

    function storedForEffective(SeriesBook storage book, uint256 effective) internal view returns (uint256) {
        return Math.mulDiv(effective, RAY, book.optInScaleRay, Math.Rounding.Ceil);
    }

    function storedForEffectiveDown(SeriesBook storage book, uint256 effective) internal view returns (uint256) {
        return Math.mulDiv(effective, RAY, book.optInScaleRay);
    }

    function storedAdditionForEffectiveDown(SeriesBook storage book, uint256 currentStored, uint256 maximumEffective)
        internal
        view
        returns (uint256 storedAdded, uint256 effectiveAdded)
    {
        storedAdded = storedForEffectiveDown(book, maximumEffective);
        if (storedAdded == 0) return (0, 0);
        uint256 beforeEffective = optInEffective(book, currentStored);
        effectiveAdded = optInEffective(book, currentStored + storedAdded) - beforeEffective;
        if (effectiveAdded > maximumEffective) {
            unchecked {
                --storedAdded;
            }
            effectiveAdded = optInEffective(book, currentStored + storedAdded) - beforeEffective;
        }
    }

    function ensureLiveOptInScale(SeriesBook storage book) internal {
        if (book.optInTotalStored == 0) {
            if (book.optInScaleRay == 0) book.optInScaleRay = RAY;
            return;
        }
        if (book.optInScaleRay == 0) revert OptInScaleExhausted(book.optInTotalStored);
    }

    function clearZeroEffectiveOptInDust(PS storage ps, uint256 positionId, uint256 seriesId)
        internal
        returns (uint256 clearedStored)
    {
        PositionLeg storage leg = ps.leg[positionId][seriesId];
        SeriesBook storage book = ps.series[seriesId];
        if (
            leg.optInStored == 0 || leg.optInEpoch != book.optInEpoch
                || optInPositionEffective(book, leg.optInStored) != 0
        ) {
            return 0;
        }

        clearedStored = leg.optInStored;
        leg.optInStored = 0;
        book.optInTotalStored -= clearedStored;
        if (book.optInTotalStored == 0) {
            book.optInScaleRay = RAY;
            book.optInEpoch += 1;
            leg.optInEpoch = book.optInEpoch;
            leg.collateralOptInCheckpointRay = book.collateralOptIn[book.optInEpoch].accPerStoredRay;
            leg.staticsDollarOptInCheckpointRay = book.staticsDollarOptIn[book.optInEpoch].accPerStoredRay;
        }
        emit OptInDustCleared(positionId, seriesId, clearedStored);
    }

    function settleLeg(PS storage ps, uint256 positionId, uint256 seriesId) internal {
        PositionLeg storage leg = ps.leg[positionId][seriesId];
        SeriesBook storage book = ps.series[seriesId];
        uint256 collateralAdded;
        uint256 staticsDollarAdded;
        if (book.collateralPassive.accPerStoredRay > leg.collateralPassiveCheckpointRay && leg.eligiblePrincipal != 0) {
            collateralAdded += Math.mulDiv(
                leg.eligiblePrincipal, book.collateralPassive.accPerStoredRay - leg.collateralPassiveCheckpointRay, RAY
            );
        }
        if (
            book.staticsDollarPassive.accPerStoredRay > leg.staticsDollarPassiveCheckpointRay
                && leg.eligiblePrincipal != 0
        ) {
            staticsDollarAdded += Math.mulDiv(
                leg.eligiblePrincipal,
                book.staticsDollarPassive.accPerStoredRay - leg.staticsDollarPassiveCheckpointRay,
                RAY
            );
        }
        RewardIndex storage collateralOpt = book.collateralOptIn[leg.optInEpoch];
        RewardIndex storage staticsDollarOpt = book.staticsDollarOptIn[leg.optInEpoch];
        if (collateralOpt.accPerStoredRay > leg.collateralOptInCheckpointRay && leg.optInStored != 0) {
            collateralAdded += Math.mulDiv(
                leg.optInStored, collateralOpt.accPerStoredRay - leg.collateralOptInCheckpointRay, RAY
            );
        }
        if (staticsDollarOpt.accPerStoredRay > leg.staticsDollarOptInCheckpointRay && leg.optInStored != 0) {
            staticsDollarAdded += Math.mulDiv(
                leg.optInStored, staticsDollarOpt.accPerStoredRay - leg.staticsDollarOptInCheckpointRay, RAY
            );
        }
        leg.collateralPassiveCheckpointRay = book.collateralPassive.accPerStoredRay;
        leg.staticsDollarPassiveCheckpointRay = book.staticsDollarPassive.accPerStoredRay;
        leg.collateralOptInCheckpointRay = collateralOpt.accPerStoredRay;
        leg.staticsDollarOptInCheckpointRay = staticsDollarOpt.accPerStoredRay;
        leg.accruedCollateral += collateralAdded;
        leg.accruedStaticsDollar += staticsDollarAdded;
        if (collateralAdded != 0 || staticsDollarAdded != 0) {
            emit LegRewardsSettled(
                positionId,
                seriesId,
                collateralAdded,
                staticsDollarAdded,
                leg.accruedCollateral,
                leg.accruedStaticsDollar
            );
        }
    }

    function pendingRewards(PS storage ps, uint256 positionId, uint256 seriesId)
        internal
        view
        returns (uint256 collateralAmount, uint256 staticsDollarAmount)
    {
        PositionLeg storage leg = ps.leg[positionId][seriesId];
        SeriesBook storage book = ps.series[seriesId];
        collateralAmount = leg.accruedCollateral;
        staticsDollarAmount = leg.accruedStaticsDollar;
        if (book.collateralPassive.accPerStoredRay > leg.collateralPassiveCheckpointRay && leg.eligiblePrincipal != 0) {
            collateralAmount += Math.mulDiv(
                leg.eligiblePrincipal, book.collateralPassive.accPerStoredRay - leg.collateralPassiveCheckpointRay, RAY
            );
        }
        if (
            book.staticsDollarPassive.accPerStoredRay > leg.staticsDollarPassiveCheckpointRay
                && leg.eligiblePrincipal != 0
        ) {
            staticsDollarAmount += Math.mulDiv(
                leg.eligiblePrincipal,
                book.staticsDollarPassive.accPerStoredRay - leg.staticsDollarPassiveCheckpointRay,
                RAY
            );
        }
        RewardIndex storage collateralOpt = book.collateralOptIn[leg.optInEpoch];
        RewardIndex storage staticsDollarOpt = book.staticsDollarOptIn[leg.optInEpoch];
        if (collateralOpt.accPerStoredRay > leg.collateralOptInCheckpointRay && leg.optInStored != 0) {
            collateralAmount += Math.mulDiv(
                leg.optInStored, collateralOpt.accPerStoredRay - leg.collateralOptInCheckpointRay, RAY
            );
        }
        if (staticsDollarOpt.accPerStoredRay > leg.staticsDollarOptInCheckpointRay && leg.optInStored != 0) {
            staticsDollarAmount += Math.mulDiv(
                leg.optInStored, staticsDollarOpt.accPerStoredRay - leg.staticsDollarOptInCheckpointRay, RAY
            );
        }
    }

    function accruePassive(
        PS storage ps,
        uint256 seriesId,
        address token,
        uint256 amount,
        bytes32 source,
        bool alreadyReserved
    ) internal {
        if (amount == 0) return;
        SeriesBook storage book = ps.series[seriesId];
        if (book.eligiblePrincipal == 0) revert NoRewardEligiblePrincipal(seriesId);
        RewardIndex storage index = token == ps.staticsDollar ? book.staticsDollarPassive : book.collateralPassive;
        if (!alreadyReserved) _reserve(ps, token, amount);
        (uint256 delta, uint256 remainder) = _indexDelta(amount, book.eligiblePrincipal, index.remainderRay);
        index.remainderRay = remainder;
        index.accPerStoredRay += delta;
        emit SeriesFeesAccrued(seriesId, token, amount, source);
    }

    function accrueOptIn(
        PS storage ps,
        uint256 seriesId,
        uint64 epoch,
        uint256 totalStored,
        address token,
        uint256 amount,
        bytes32 source,
        bool alreadyReserved
    ) internal {
        if (amount == 0) return;
        if (totalStored == 0) revert NoRewardEligiblePrincipal(seriesId);
        if (!alreadyReserved) _reserve(ps, token, amount);
        SeriesBook storage book = ps.series[seriesId];
        RewardIndex storage index =
            token == ps.staticsDollar ? book.staticsDollarOptIn[epoch] : book.collateralOptIn[epoch];
        (uint256 delta, uint256 remainder) = _indexDelta(amount, totalStored, index.remainderRay);
        index.remainderRay = remainder;
        index.accPerStoredRay += delta;
        emit OptInFeesAccrued(seriesId, epoch, token, amount, source);
    }

    function reserve(PS storage ps, address token, uint256 amount) internal {
        _reserve(ps, token, amount);
    }

    function finalizeRetiredRewards(PS storage ps, uint256 seriesId, IStaticsDollarCoreTypes.RiskSeries memory series)
        internal
    {
        SeriesBook storage book = ps.series[seriesId];
        book.retiredRewardsFinalized = true;
        uint256 collateralAmount = book.collateralOptInReserve;
        uint256 staticsDollarAmount = book.staticsDollarOptInReserve;
        book.collateralOptInReserve = 0;
        book.staticsDollarOptInReserve = 0;

        bool distributedToPassive = book.eligiblePrincipal != 0;
        if (distributedToPassive) {
            accruePassive(ps, seriesId, series.collateralToken, collateralAmount, "RETIREMENT", true);
            accruePassive(ps, seriesId, ps.staticsDollar, staticsDollarAmount, "RETIREMENT", true);
        } else {
            if (collateralAmount != 0) {
                ps.reservedByToken[series.collateralToken] -= collateralAmount;
                ps.pendingInsurance[series.profileId] += collateralAmount;
                ps.pendingInsuranceByToken[series.collateralToken] += collateralAmount;
            }
            if (staticsDollarAmount != 0) {
                ps.reservedByToken[ps.staticsDollar] -= staticsDollarAmount;
                LibCustody.pushReserved(
                    LibCustody.dollarAccount(),
                    ps.staticsDollar,
                    LibBasket.basketStorage().treasury,
                    staticsDollarAmount,
                    staticsDollarAmount
                );
            }
        }
        emit RetiredSeriesRewardsFinalized(seriesId, collateralAmount, staticsDollarAmount, distributedToPassive);
    }

    function _reserve(PS storage ps, address token, uint256 amount) private {
        LibCustody.reserve(LibCustody.dollarAccount(), token, amount);
        ps.reservedByToken[token] += amount;
    }

    function addPending(PositionLeg storage leg, uint256 amount) internal {
        if (leg.pendingPrincipal == 0) {
            leg.pendingPrincipal = amount;
            leg.pendingSince = block.timestamp;
            return;
        }
        uint256 age = block.timestamp - leg.pendingSince;
        if (age > REWARD_GATE) age = REWARD_GATE;
        uint256 combined = leg.pendingPrincipal + amount;
        uint256 weightedAge = Math.mulDiv(leg.pendingPrincipal, age, combined);
        leg.pendingPrincipal = combined;
        leg.pendingSince = block.timestamp - weightedAge;
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

    function consume(PS storage ps, uint256 seriesId, uint256 effectiveAmount) internal returns (uint256 newScaleRay) {
        SeriesBook storage book = ps.series[seriesId];
        uint256 available = book.optInPrincipal;
        if (effectiveAmount == 0 || effectiveAmount > available) {
            revert ConsumeExceedsTier(effectiveAmount, available);
        }
        uint256 remaining = available - effectiveAmount;
        newScaleRay = remaining == 0 ? RAY : Math.mulDiv(remaining, RAY, book.optInTotalStored);
        if (remaining != 0 && newScaleRay == 0) revert OptInScaleExhausted(book.optInTotalStored);
        if (remaining == 0) {
            book.optInTotalStored = 0;
            book.optInEpoch += 1;
        }
        book.optInPrincipal = remaining;
        book.optInScaleRay = newScaleRay;
    }
}
