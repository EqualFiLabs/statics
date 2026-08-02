// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IStaticsSwapFeeHook} from "../interfaces/IStaticsSwapFeeHook.sol";

contract StaticsSwapFeeHook is BaseHook, IStaticsSwapFeeHook {
    using PoolIdLibrary for PoolKey;
    using SafeCast for uint256;
    using StateLibrary for IPoolManager;

    uint256 private constant BPS = 10_000;
    uint40 private constant OBSERVATION_INTERVAL = 1 minutes;
    uint8 private constant MAX_OBSERVATIONS = 64;

    struct Observation {
        uint40 timestamp;
        int56 tickCumulative;
    }

    struct OracleState {
        uint40 initializedAt;
        uint40 lastCheckpointAt;
        int24 lastTick;
        int56 tickCumulative;
        uint8 observationIndex;
        uint8 observationCardinality;
    }

    address public immutable staticsDiamond;
    uint16 public immutable hookFeeBps;

    mapping(PoolId poolId => PoolRegistration registration) private registrations;
    mapping(PoolId poolId => mapping(Currency currency => uint256 amount)) private poolLiabilities;
    mapping(Currency currency => uint256 amount) private currencyLiabilities;
    mapping(PoolId poolId => OracleState state) private oracleStates;
    mapping(PoolId poolId => Observation[64] observations) private poolObservations;

    error OnlyStaticsDiamond(address caller);
    error InvalidHookFee(uint16 feeBps);
    error PoolAlreadyRegistered(PoolId poolId);
    error PoolNotRegistered(PoolId poolId);
    error HookBalanceDecreased(Currency currency, uint256 beforeBalance, uint256 afterBalance);
    error HookBalanceIncreased(Currency currency, uint256 beforeBalance, uint256 afterBalance);
    error HookLiabilityInsolvent(Currency currency, uint256 liability, uint256 balance);
    error WithdrawalExceedsPoolLiability(PoolId poolId, Currency currency, uint256 spent, uint256 available);
    error ReceiverBalanceDecreased(Currency currency, uint256 beforeBalance, uint256 afterBalance);
    error PoolAlreadyInitialized(PoolId poolId);
    error InvalidOracleWindow(uint32 window);
    error InsufficientOracleHistory(PoolId poolId, uint40 targetTimestamp, uint40 oldestTimestamp);

    constructor(IPoolManager manager, address diamond, uint16 feeBps) BaseHook(manager) {
        if (feeBps > BPS) revert InvalidHookFee(feeBps);
        staticsDiamond = diamond;
        hookFeeBps = feeBps;
    }

    receive() external payable {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory permissions) {
        permissions.afterInitialize = true;
        permissions.afterSwap = true;
        permissions.afterSwapReturnDelta = true;
    }

    function registerPool(PoolKey calldata key) external returns (PoolId poolId) {
        _enforceDiamond();
        poolId = key.toId();
        if (registrations[poolId].registered) revert PoolAlreadyRegistered(poolId);
        registrations[poolId] = PoolRegistration({currency0: key.currency0, currency1: key.currency1, registered: true});
        emit PoolRegistered(poolId, key.currency0, key.currency1);
    }

    function poolRegistration(PoolId poolId) external view returns (PoolRegistration memory registration) {
        return registrations[poolId];
    }

    function accruedFees(PoolId poolId, Currency currency) external view returns (uint256 amount) {
        return poolLiabilities[poolId][currency];
    }

    function totalLiability(Currency currency) external view returns (uint256 amount) {
        return currencyLiabilities[currency];
    }

    function checkpoint(PoolKey calldata key) external returns (bool observationStored) {
        PoolId poolId = key.toId();
        if (!registrations[poolId].registered) revert PoolNotRegistered(poolId);
        (, int24 tick,,) = poolManager.getSlot0(poolId);
        return _checkpoint(poolId, tick);
    }

    function oracleState(PoolId poolId) external view returns (OracleStateView memory state) {
        OracleState storage stored = oracleStates[poolId];
        uint40 latestObservationAt;
        if (stored.observationCardinality != 0) {
            latestObservationAt = poolObservations[poolId][stored.observationIndex].timestamp;
        }
        state = OracleStateView({
            initializedAt: stored.initializedAt,
            lastCheckpointAt: stored.lastCheckpointAt,
            latestObservationAt: latestObservationAt,
            lastTick: stored.lastTick,
            tickCumulative: stored.tickCumulative,
            observationIndex: stored.observationIndex,
            observationCardinality: stored.observationCardinality
        });
    }

    function observationAt(PoolId poolId, uint8 index) external view returns (uint40 timestamp, int56 tickCumulative) {
        Observation storage observation = poolObservations[poolId][index];
        return (observation.timestamp, observation.tickCumulative);
    }

    function consult(PoolId poolId, uint32 window)
        external
        view
        returns (int24 referenceTick, int24 spotTick, uint40 oldestObservationAt)
    {
        if (window == 0) revert InvalidOracleWindow(window);
        OracleState storage state = oracleStates[poolId];
        uint40 nowTimestamp = uint40(block.timestamp);
        if (state.initializedAt == 0 || nowTimestamp < window) {
            revert InsufficientOracleHistory(poolId, 0, state.initializedAt);
        }
        uint40 targetTimestamp = nowTimestamp - window;
        (int56 currentCumulative,) = _currentCumulative(state, nowTimestamp);
        (int56 targetCumulative, uint40 oldest) = _cumulativeAt(poolId, state, targetTimestamp, currentCumulative);
        int256 delta = int256(currentCumulative) - int256(targetCumulative);
        int256 averageTick = delta / int256(uint256(window));
        if (delta < 0 && delta % int256(uint256(window)) != 0) --averageTick;
        referenceTick = int24(averageTick);
        (, spotTick,,) = poolManager.getSlot0(poolId);
        oldestObservationAt = oldest;
    }

    function withdrawPoolFees(PoolId poolId)
        external
        returns (uint256 spent0, uint256 received0, uint256 spent1, uint256 received1)
    {
        _enforceDiamond();
        PoolRegistration memory registration = registrations[poolId];
        if (!registration.registered) revert PoolNotRegistered(poolId);
        (spent0, received0) = _withdraw(poolId, registration.currency0);
        (spent1, received1) = _withdraw(poolId, registration.currency1);
    }

    function _afterInitialize(address, PoolKey calldata key, uint160, int24 tick) internal override returns (bytes4) {
        PoolId poolId = key.toId();
        if (!registrations[poolId].registered) revert PoolNotRegistered(poolId);
        OracleState storage state = oracleStates[poolId];
        if (state.initializedAt != 0) revert PoolAlreadyInitialized(poolId);
        uint40 timestamp = uint40(block.timestamp);
        state.initializedAt = timestamp;
        state.lastCheckpointAt = timestamp;
        state.lastTick = tick;
        state.observationCardinality = 1;
        poolObservations[poolId][0] = Observation({timestamp: timestamp, tickCumulative: 0});
        emit TickObservationRecorded(poolId, timestamp, tick, 0, 1);
        return IHooks.afterInitialize.selector;
    }

    function _afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        PoolId poolId = key.toId();
        if (!registrations[poolId].registered) revert PoolNotRegistered(poolId);

        bool specifiedCurrencyIs0 = (params.amountSpecified < 0) == params.zeroForOne;
        Currency feeCurrency = specifiedCurrencyIs0 ? key.currency1 : key.currency0;
        int128 unspecifiedDelta = specifiedCurrencyIs0 ? delta.amount1() : delta.amount0();
        uint256 realizedAmount = _absolute(unspecifiedDelta);
        uint256 chargedAmount = Math.mulDiv(realizedAmount, hookFeeBps, BPS, Math.Rounding.Ceil);
        if (chargedAmount == 0) return (IHooks.afterSwap.selector, 0);

        uint256 balanceBefore = feeCurrency.balanceOfSelf();
        poolManager.take(feeCurrency, address(this), chargedAmount);
        uint256 balanceAfter = feeCurrency.balanceOfSelf();
        if (balanceAfter < balanceBefore) revert HookBalanceDecreased(feeCurrency, balanceBefore, balanceAfter);
        uint256 receivedAmount = balanceAfter - balanceBefore;
        poolLiabilities[poolId][feeCurrency] += receivedAmount;
        currencyLiabilities[feeCurrency] += receivedAmount;
        _enforceLiabilityCoverage(feeCurrency);
        emit SwapFeeAccrued(poolId, feeCurrency, realizedAmount, chargedAmount, receivedAmount);

        (, int24 currentTick,,) = poolManager.getSlot0(poolId);
        _checkpoint(poolId, currentTick);

        return (IHooks.afterSwap.selector, chargedAmount.toInt128());
    }

    function _withdraw(PoolId poolId, Currency currency) private returns (uint256 spent, uint256 received) {
        _enforceLiabilityCoverage(currency);
        uint256 available = poolLiabilities[poolId][currency];
        if (available == 0) return (0, 0);

        uint256 hookBalanceBefore = currency.balanceOfSelf();
        uint256 receiverBalanceBefore = currency.balanceOf(staticsDiamond);
        currency.transfer(staticsDiamond, available);
        uint256 hookBalanceAfter = currency.balanceOfSelf();
        uint256 receiverBalanceAfter = currency.balanceOf(staticsDiamond);
        if (hookBalanceAfter > hookBalanceBefore) {
            revert HookBalanceIncreased(currency, hookBalanceBefore, hookBalanceAfter);
        }
        if (receiverBalanceAfter < receiverBalanceBefore) {
            revert ReceiverBalanceDecreased(currency, receiverBalanceBefore, receiverBalanceAfter);
        }
        spent = hookBalanceBefore - hookBalanceAfter;
        received = receiverBalanceAfter - receiverBalanceBefore;
        if (spent > available) revert WithdrawalExceedsPoolLiability(poolId, currency, spent, available);
        poolLiabilities[poolId][currency] = available - spent;
        currencyLiabilities[currency] -= spent;
        _enforceLiabilityCoverage(currency);
        emit PoolFeesWithdrawn(poolId, currency, spent, received, available - spent);
    }

    function _enforceLiabilityCoverage(Currency currency) private view {
        uint256 liability = currencyLiabilities[currency];
        uint256 balance = currency.balanceOfSelf();
        if (liability > balance) revert HookLiabilityInsolvent(currency, liability, balance);
    }

    function _absolute(int128 value) private pure returns (uint256) {
        return value < 0 ? uint256(-int256(value)) : uint256(uint128(value));
    }

    function _checkpoint(PoolId poolId, int24 tick) private returns (bool observationStored) {
        OracleState storage state = oracleStates[poolId];
        if (state.initializedAt == 0) revert PoolNotRegistered(poolId);
        uint40 timestamp = uint40(block.timestamp);
        (int56 currentCumulative, uint40 elapsed) = _currentCumulative(state, timestamp);
        state.tickCumulative = currentCumulative;
        state.lastCheckpointAt = timestamp;
        state.lastTick = tick;

        Observation storage latest = poolObservations[poolId][state.observationIndex];
        if (elapsed == 0 || timestamp - latest.timestamp < OBSERVATION_INTERVAL) return false;
        uint8 nextIndex = state.observationIndex == MAX_OBSERVATIONS - 1 ? 0 : state.observationIndex + 1;
        state.observationIndex = nextIndex;
        if (state.observationCardinality < MAX_OBSERVATIONS) ++state.observationCardinality;
        poolObservations[poolId][nextIndex] = Observation({timestamp: timestamp, tickCumulative: currentCumulative});
        emit TickObservationRecorded(poolId, timestamp, tick, currentCumulative, state.observationCardinality);
        return true;
    }

    function _currentCumulative(OracleState storage state, uint40 timestamp)
        private
        view
        returns (int56 cumulative, uint40 elapsed)
    {
        elapsed = timestamp - state.lastCheckpointAt;
        int256 accumulated = int256(state.tickCumulative) + int256(state.lastTick) * int256(uint256(elapsed));
        cumulative = int56(accumulated);
    }

    function _cumulativeAt(PoolId poolId, OracleState storage state, uint40 targetTimestamp, int56 currentCumulative)
        private
        view
        returns (int56 targetCumulative, uint40 oldestTimestamp)
    {
        uint8 cardinality = state.observationCardinality;
        if (cardinality == 0) revert InsufficientOracleHistory(poolId, targetTimestamp, 0);

        Observation memory beforeOrAt;
        Observation memory afterOrAt =
            Observation({timestamp: uint40(block.timestamp), tickCumulative: currentCumulative});
        oldestTimestamp = type(uint40).max;
        bool foundBefore;
        for (uint8 i; i < cardinality; ++i) {
            Observation memory candidate = poolObservations[poolId][i];
            if (candidate.timestamp < oldestTimestamp) oldestTimestamp = candidate.timestamp;
            if (candidate.timestamp <= targetTimestamp && candidate.timestamp >= beforeOrAt.timestamp) {
                beforeOrAt = candidate;
                foundBefore = true;
            }
            if (candidate.timestamp >= targetTimestamp && candidate.timestamp <= afterOrAt.timestamp) {
                afterOrAt = candidate;
            }
        }
        if (!foundBefore) {
            revert InsufficientOracleHistory(poolId, targetTimestamp, oldestTimestamp);
        }
        if (beforeOrAt.timestamp == targetTimestamp) return (beforeOrAt.tickCumulative, oldestTimestamp);

        uint256 span = afterOrAt.timestamp - beforeOrAt.timestamp;
        uint256 targetOffset = targetTimestamp - beforeOrAt.timestamp;
        int256 cumulativeDelta = int256(afterOrAt.tickCumulative) - int256(beforeOrAt.tickCumulative);
        int256 interpolated = int256(beforeOrAt.tickCumulative) + cumulativeDelta * int256(targetOffset) / int256(span);
        targetCumulative = int56(interpolated);
    }

    function _enforceDiamond() private view {
        if (msg.sender != staticsDiamond) revert OnlyStaticsDiamond(msg.sender);
    }
}
