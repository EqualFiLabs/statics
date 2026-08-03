// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IStaticsGlobalRewards} from "../interfaces/IStaticsGlobalRewards.sol";
import {IStaticsLiquidityRewards} from "../interfaces/IStaticsLiquidityRewards.sol";
import {IStaticsSwapFeeHook} from "../interfaces/IStaticsSwapFeeHook.sol";

contract StaticsSwapFeeHook is BaseHook, IStaticsSwapFeeHook, IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using SafeCast for uint256;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    using SafeERC20 for IERC20;

    uint256 private constant BPS = 10_000;
    uint256 private constant MAX_COMBINED_FEE_BPS = 200;
    uint8 private constant UNLOCK_RELEASE = 1;
    uint8 private constant UNLOCK_SEED = 2;
    bytes32 private constant PERMANENT_LIQUIDITY_SALT = keccak256("statics.permanent.swap.fee.liquidity");

    struct PendingDistribution {
        uint256 liquidityProvider;
        uint256 basketStaker;
        uint256 staticsStaker;
        uint256 treasury;
    }

    struct ReleaseRequest {
        PoolKey key;
        address receiver;
    }

    struct StoredPoolFeeConfiguration {
        uint16 inputFeeBps;
        uint16 outputFeeBps;
        uint16 polShareBps;
        uint16 liquidityProviderShareBps;
        uint16 basketStakerShareBps;
        uint16 staticsStakerShareBps;
        uint16 treasuryShareBps;
        bool enabled;
    }

    address public immutable staticsDiamond;
    FeeConfiguration private fees;

    mapping(PoolId poolId => PoolRegistration registration) private registrations;
    mapping(PoolId poolId => mapping(Currency currency => uint256 amount)) private polPending;
    mapping(Currency currency => uint256 amount) private totalPending;
    mapping(PoolId poolId => mapping(Currency currency => PendingDistribution amount)) private distributions;
    mapping(PoolId poolId => uint128 liquidity) private permanentLiquidity;
    mapping(PoolId poolId => bool decommissioned) private decommissionedPools;
    mapping(PoolId poolId => StoredPoolFeeConfiguration configuration) private poolFeeConfigurations;

    error OnlyStaticsDiamond(address caller);
    error InvalidFeeConfiguration();
    error PoolAlreadyRegistered(PoolId poolId);
    error PoolNotRegistered(PoolId poolId);
    error PoolIsDecommissioned(PoolId poolId);
    error PoolNotDecommissioned(PoolId poolId);
    error NativeCurrencyUnsupported();
    error NonzeroNativeLpFee(uint24 fee);
    error IncompatiblePoolCurrency(Currency currency, uint256 requested, uint256 received);
    error UnexpectedTokenDebit(Currency currency, uint256 expected, uint256 actual);
    error UnexpectedTokenAllowance(Currency currency, uint256 remaining);
    error UnexpectedSettlement(Currency currency, uint256 expected, uint256 actual);
    error PendingLiquidityInsolvent(Currency currency, uint256 required, uint256 available);
    error PermanentLiquidityExceedsPending(Currency currency, uint256 required, uint256 available);
    error UnexpectedLiquidityDelta(int128 amount0, int128 amount1);
    error InvalidUnlockCaller(address caller);
    error InvalidReleaseReceiver();
    error EmptyPermanentLiquiditySeed();
    error InvalidPermanentLiquiditySeed(PoolId poolId);
    error PermanentLiquidityAlreadySeeded(PoolId poolId);
    error DuplicatePermanentLiquiditySeed(PoolId poolId);
    error UnexpectedCurrencyDelta(Currency currency, int256 delta);

    constructor(IPoolManager manager, address diamond, uint16 inputFeeBps, uint16 outputFeeBps) BaseHook(manager) {
        staticsDiamond = diamond;
        _setFeeConfiguration(inputFeeBps, outputFeeBps, 1_000, 2_500, 2_500, 1_500, 2_500);
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory permissions) {
        permissions.afterInitialize = true;
        permissions.beforeSwap = true;
        permissions.beforeSwapReturnDelta = true;
        permissions.afterSwap = true;
        permissions.afterSwapReturnDelta = true;
    }

    /// @dev Registration must precede initialization so a third party cannot squat a predictable canonical PoolKey.
    function _afterInitialize(address, PoolKey calldata key, uint160, int24) internal view override returns (bytes4) {
        _enforceRegistered(key.toId());
        return IHooks.afterInitialize.selector;
    }

    function feeConfiguration() external view returns (FeeConfiguration memory config) {
        return fees;
    }

    function setFeeConfiguration(
        uint16 inputFeeBps,
        uint16 outputFeeBps,
        uint16 polShareBps,
        uint16 liquidityProviderShareBps,
        uint16 basketStakerShareBps,
        uint16 staticsStakerShareBps,
        uint16 treasuryShareBps
    ) external {
        _enforceDiamond();
        _setFeeConfiguration(
            inputFeeBps,
            outputFeeBps,
            polShareBps,
            liquidityProviderShareBps,
            basketStakerShareBps,
            staticsStakerShareBps,
            treasuryShareBps
        );
    }

    function setPoolFeeConfiguration(PoolId poolId, FeeConfiguration calldata configuration) external {
        _enforceDiamond();
        _enforceRegistered(poolId);
        _validateFeeConfiguration(configuration);
        poolFeeConfigurations[poolId] = StoredPoolFeeConfiguration({
            inputFeeBps: configuration.inputFeeBps,
            outputFeeBps: configuration.outputFeeBps,
            polShareBps: configuration.polShareBps,
            liquidityProviderShareBps: configuration.liquidityProviderShareBps,
            basketStakerShareBps: configuration.basketStakerShareBps,
            staticsStakerShareBps: configuration.staticsStakerShareBps,
            treasuryShareBps: configuration.treasuryShareBps,
            enabled: true
        });
        emit PoolFeeConfigurationSet(
            poolId,
            configuration.inputFeeBps,
            configuration.outputFeeBps,
            configuration.polShareBps,
            configuration.liquidityProviderShareBps,
            configuration.basketStakerShareBps,
            configuration.staticsStakerShareBps,
            configuration.treasuryShareBps
        );
    }

    function clearPoolFeeConfiguration(PoolId poolId) external {
        _enforceDiamond();
        _enforceRegistered(poolId);
        delete poolFeeConfigurations[poolId];
        emit PoolFeeConfigurationCleared(poolId);
    }

    function poolFeeConfiguration(PoolId poolId) external view returns (PoolFeeConfigurationView memory configuration) {
        _enforceRegistered(poolId);
        return _effectiveFeeConfiguration(poolId);
    }

    function registerPool(PoolKey calldata key) external returns (PoolId poolId) {
        _enforceDiamond();
        if (key.currency0.isAddressZero() || key.currency1.isAddressZero()) revert NativeCurrencyUnsupported();
        if (key.fee != 0) revert NonzeroNativeLpFee(key.fee);
        poolId = key.toId();
        if (registrations[poolId].registered) revert PoolAlreadyRegistered(poolId);
        registrations[poolId] = PoolRegistration({currency0: key.currency0, currency1: key.currency1, registered: true});
        emit PoolRegistered(poolId, key.currency0, key.currency1);
    }

    function decommissionPool(PoolKey calldata key) external {
        _enforceDiamond();
        PoolId poolId = key.toId();
        _enforceRegistered(poolId);
        if (decommissionedPools[poolId]) revert PoolIsDecommissioned(poolId);
        decommissionedPools[poolId] = true;
        emit PoolDecommissioned(poolId);
    }

    function poolDecommissioned(PoolId poolId) external view returns (bool decommissioned) {
        return decommissionedPools[poolId];
    }

    function poolRegistration(PoolId poolId) external view returns (PoolRegistration memory registration) {
        return registrations[poolId];
    }

    function pendingPermanentLiquidity(PoolId poolId, Currency currency) external view returns (uint256 amount) {
        return polPending[poolId][currency];
    }

    function lockedLiquidity(PoolId poolId) external view returns (uint128 liquidity) {
        return permanentLiquidity[poolId];
    }

    function seedPermanentLiquidity(PermanentLiquiditySeed[] calldata seeds) external {
        _enforceDiamond();
        uint256 length = seeds.length;
        if (length == 0) revert EmptyPermanentLiquiditySeed();
        for (uint256 i; i < length; ++i) {
            PoolId poolId = seeds[i].key.toId();
            _enforceRegistered(poolId);
            if (decommissionedPools[poolId]) revert PoolIsDecommissioned(poolId);
            if (seeds[i].liquidity == 0) revert InvalidPermanentLiquiditySeed(poolId);
            if (permanentLiquidity[poolId] != 0) revert PermanentLiquidityAlreadySeeded(poolId);
            for (uint256 j; j < i; ++j) {
                if (PoolId.unwrap(seeds[j].key.toId()) == PoolId.unwrap(poolId)) {
                    revert DuplicatePermanentLiquiditySeed(poolId);
                }
            }
        }
        poolManager.unlock(abi.encode(UNLOCK_SEED, abi.encode(seeds)));
    }

    function compoundPermanentLiquidity(PoolKey calldata key) external returns (uint128 liquidityAdded) {
        PoolId poolId = key.toId();
        _enforceRegistered(poolId);
        if (decommissionedPools[poolId]) revert PoolIsDecommissioned(poolId);
        return _compound(key, poolId);
    }

    function releasePermanentLiquidity(PoolKey calldata key, address receiver)
        external
        returns (uint256 amount0, uint256 amount1)
    {
        _enforceDiamond();
        if (receiver == address(0)) revert InvalidReleaseReceiver();
        PoolId poolId = key.toId();
        _enforceRegistered(poolId);
        if (!decommissionedPools[poolId]) revert PoolNotDecommissioned(poolId);
        uint128 liquidity = permanentLiquidity[poolId];
        bytes memory result =
            poolManager.unlock(abi.encode(UNLOCK_RELEASE, abi.encode(ReleaseRequest({key: key, receiver: receiver}))));
        (amount0, amount1) = abi.decode(result, (uint256, uint256));

        uint256 pending0 = polPending[poolId][key.currency0];
        uint256 pending1 = polPending[poolId][key.currency1];
        if (pending0 != 0) {
            polPending[poolId][key.currency0] = 0;
            totalPending[key.currency0] -= pending0;
            _transferExact(key.currency0, receiver, pending0);
            _assertPendingSolvency(key.currency0);
            amount0 += pending0;
        }
        if (pending1 != 0) {
            polPending[poolId][key.currency1] = 0;
            totalPending[key.currency1] -= pending1;
            _transferExact(key.currency1, receiver, pending1);
            _assertPendingSolvency(key.currency1);
            amount1 += pending1;
        }
        emit PermanentLiquidityReleased(poolId, receiver, liquidity, amount0, amount1);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert InvalidUnlockCaller(msg.sender);
        (uint8 action, bytes memory payload) = abi.decode(data, (uint8, bytes));
        if (action == UNLOCK_SEED) {
            _seedPermanentLiquidity(abi.decode(payload, (PermanentLiquiditySeed[])));
            return "";
        }
        if (action != UNLOCK_RELEASE) revert();
        ReleaseRequest memory request = abi.decode(payload, (ReleaseRequest));
        PoolId poolId = request.key.toId();
        uint128 liquidity = permanentLiquidity[poolId];
        if (liquidity == 0) return abi.encode(uint256(0), uint256(0));
        permanentLiquidity[poolId] = 0;
        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: TickMath.minUsableTick(request.key.tickSpacing),
            tickUpper: TickMath.maxUsableTick(request.key.tickSpacing),
            liquidityDelta: -int256(uint256(liquidity)),
            salt: PERMANENT_LIQUIDITY_SALT
        });
        (BalanceDelta delta,) = poolManager.modifyLiquidity(request.key, params, "");
        if (delta.amount0() < 0 || delta.amount1() < 0) {
            revert UnexpectedLiquidityDelta(delta.amount0(), delta.amount1());
        }
        uint256 amount0 = uint256(uint128(delta.amount0()));
        uint256 amount1 = uint256(uint128(delta.amount1()));
        _takeExact(request.key.currency0, request.receiver, amount0);
        _takeExact(request.key.currency1, request.receiver, amount1);
        return abi.encode(amount0, amount1);
    }

    function _seedPermanentLiquidity(PermanentLiquiditySeed[] memory seeds) private {
        uint256 length = seeds.length;
        Currency[] memory currencies = new Currency[](length * 2);
        uint256 currencyCount;
        uint256[] memory amount0 = new uint256[](length);
        uint256[] memory amount1 = new uint256[](length);

        for (uint256 i; i < length; ++i) {
            PermanentLiquiditySeed memory seed = seeds[i];
            PoolId poolId = seed.key.toId();
            ModifyLiquidityParams memory params = ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(seed.key.tickSpacing),
                tickUpper: TickMath.maxUsableTick(seed.key.tickSpacing),
                liquidityDelta: int256(uint256(seed.liquidity)),
                salt: PERMANENT_LIQUIDITY_SALT
            });
            (BalanceDelta delta,) = poolManager.modifyLiquidity(seed.key, params, "");
            if (delta.amount0() >= 0 || delta.amount1() >= 0) revert InvalidPermanentLiquiditySeed(poolId);
            amount0[i] = _absolute(int256(delta.amount0()));
            amount1[i] = _absolute(int256(delta.amount1()));
            permanentLiquidity[poolId] = seed.liquidity;
            currencyCount = _appendUniqueCurrency(currencies, currencyCount, seed.key.currency0);
            currencyCount = _appendUniqueCurrency(currencies, currencyCount, seed.key.currency1);
        }

        for (uint256 i; i < currencyCount; ++i) {
            Currency currency = currencies[i];
            int256 delta = poolManager.currencyDelta(address(this), currency);
            if (delta >= 0) revert UnexpectedCurrencyDelta(currency, delta);
            _settleFromDiamond(currency, uint256(-delta));
        }

        for (uint256 i; i < length; ++i) {
            PermanentLiquiditySeed memory seed = seeds[i];
            emit PermanentLiquiditySeeded(seed.key.toId(), seed.liquidity, amount0[i], amount1[i]);
        }
    }

    function _appendUniqueCurrency(Currency[] memory currencies, uint256 length, Currency currency)
        private
        pure
        returns (uint256)
    {
        for (uint256 i; i < length; ++i) {
            if (currencies[i] == currency) return length;
        }
        currencies[length] = currency;
        return length + 1;
    }

    function _settleFromDiamond(Currency currency, uint256 amount) private {
        poolManager.sync(currency);
        uint256 senderBefore = currency.balanceOf(staticsDiamond);
        uint256 receiverBefore = currency.balanceOf(address(poolManager));
        IERC20 token = IERC20(Currency.unwrap(currency));
        token.safeTransferFrom(staticsDiamond, address(poolManager), amount);
        uint256 senderAfter = currency.balanceOf(staticsDiamond);
        uint256 receiverAfter = currency.balanceOf(address(poolManager));
        _enforceExactDebit(currency, senderBefore, senderAfter, amount);
        uint256 received = receiverAfter >= receiverBefore ? receiverAfter - receiverBefore : 0;
        if (received != amount) revert IncompatiblePoolCurrency(currency, amount, received);
        uint256 settled = poolManager.settle();
        if (settled != amount) revert UnexpectedSettlement(currency, amount, settled);
        uint256 remainingAllowance = token.allowance(staticsDiamond, address(this));
        if (remainingAllowance != 0) revert UnexpectedTokenAllowance(currency, remainingAllowance);
        _assertPendingSolvency(currency);
    }

    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId poolId = key.toId();
        _enforceRegistered(poolId);
        if (decommissionedPools[poolId]) revert PoolIsDecommissioned(poolId);
        bool exactInput = params.amountSpecified < 0;
        PoolFeeConfigurationView memory configuration = _effectiveFeeConfiguration(poolId);
        uint16 feeBps = exactInput ? configuration.inputFeeBps : configuration.outputFeeBps;
        uint256 realized = _absolute(params.amountSpecified);
        uint256 charged = Math.mulDiv(realized, feeBps, BPS, Math.Rounding.Ceil);
        if (charged == 0) return (IHooks.beforeSwap.selector, toBeforeSwapDelta(0, 0), 0);
        Currency specified = (params.zeroForOne == exactInput) ? key.currency0 : key.currency1;
        _takeExact(specified, charged);
        _allocate(poolId, specified, realized, charged, true, configuration);
        _routeDistribution(poolId, specified);
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(charged.toInt128(), 0), 0);
    }

    function _afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        PoolId poolId = key.toId();
        bool exactInput = params.amountSpecified < 0;
        bool specifiedCurrencyIs0 = exactInput == params.zeroForOne;
        Currency unspecified = specifiedCurrencyIs0 ? key.currency1 : key.currency0;
        int128 unspecifiedDelta = specifiedCurrencyIs0 ? delta.amount1() : delta.amount0();
        uint256 realized = _absolute(int256(unspecifiedDelta));
        PoolFeeConfigurationView memory configuration = _effectiveFeeConfiguration(poolId);
        uint16 feeBps = exactInput ? configuration.outputFeeBps : configuration.inputFeeBps;
        uint256 charged = Math.mulDiv(realized, feeBps, BPS, Math.Rounding.Ceil);
        if (charged != 0) {
            _takeExact(unspecified, charged);
            _allocate(poolId, unspecified, realized, charged, false, configuration);
        }

        _routeDistribution(poolId, key.currency0);
        _routeDistribution(poolId, key.currency1);
        _compound(key, poolId);
        return (IHooks.afterSwap.selector, charged.toInt128());
    }

    function _allocate(
        PoolId poolId,
        Currency currency,
        uint256 realized,
        uint256 charged,
        bool specifiedLeg,
        PoolFeeConfigurationView memory configuration
    ) private {
        uint256 polAmount = Math.mulDiv(charged, configuration.polShareBps, BPS);
        uint256 liquidityProviderAmount = Math.mulDiv(charged, configuration.liquidityProviderShareBps, BPS);
        uint256 basketStakerAmount = Math.mulDiv(charged, configuration.basketStakerShareBps, BPS);
        uint256 staticsStakerAmount = Math.mulDiv(charged, configuration.staticsStakerShareBps, BPS);
        uint256 treasuryAmount =
            charged - polAmount - liquidityProviderAmount - basketStakerAmount - staticsStakerAmount;
        if (!IStaticsLiquidityRewards(staticsDiamond).canAccrueLiquidityRewards(poolId)) {
            polAmount += liquidityProviderAmount;
            liquidityProviderAmount = 0;
        }
        if (!IStaticsLiquidityRewards(staticsDiamond).canAccrueBasketRewards(poolId)) {
            polAmount += basketStakerAmount;
            basketStakerAmount = 0;
        }
        if (!IStaticsGlobalRewards(staticsDiamond).canAccrueStakerRewards(Currency.unwrap(currency))) {
            polAmount += staticsStakerAmount;
            staticsStakerAmount = 0;
        }
        polPending[poolId][currency] += polAmount;
        totalPending[currency] += polAmount;
        PendingDistribution storage pending = distributions[poolId][currency];
        pending.liquidityProvider += liquidityProviderAmount;
        pending.basketStaker += basketStakerAmount;
        pending.staticsStaker += staticsStakerAmount;
        pending.treasury += treasuryAmount;
        emit SwapLegFeeAccrued(
            poolId,
            currency,
            specifiedLeg,
            realized,
            charged,
            polAmount,
            liquidityProviderAmount,
            basketStakerAmount,
            staticsStakerAmount,
            treasuryAmount
        );
    }

    function _effectiveFeeConfiguration(PoolId poolId)
        private
        view
        returns (PoolFeeConfigurationView memory configuration)
    {
        StoredPoolFeeConfiguration storage overrideConfiguration = poolFeeConfigurations[poolId];
        if (overrideConfiguration.enabled) {
            return PoolFeeConfigurationView({
                inputFeeBps: overrideConfiguration.inputFeeBps,
                outputFeeBps: overrideConfiguration.outputFeeBps,
                polShareBps: overrideConfiguration.polShareBps,
                liquidityProviderShareBps: overrideConfiguration.liquidityProviderShareBps,
                basketStakerShareBps: overrideConfiguration.basketStakerShareBps,
                staticsStakerShareBps: overrideConfiguration.staticsStakerShareBps,
                treasuryShareBps: overrideConfiguration.treasuryShareBps,
                overridden: true
            });
        }
        return PoolFeeConfigurationView({
            inputFeeBps: fees.inputFeeBps,
            outputFeeBps: fees.outputFeeBps,
            polShareBps: fees.polShareBps,
            liquidityProviderShareBps: fees.liquidityProviderShareBps,
            basketStakerShareBps: fees.basketStakerShareBps,
            staticsStakerShareBps: fees.staticsStakerShareBps,
            treasuryShareBps: fees.treasuryShareBps,
            overridden: false
        });
    }

    function _routeDistribution(PoolId poolId, Currency currency) private {
        PendingDistribution storage pending = distributions[poolId][currency];
        uint256 liquidityProviderAmount = pending.liquidityProvider;
        uint256 basketStakerAmount = pending.basketStaker;
        uint256 staticsStakerAmount = pending.staticsStaker;
        uint256 treasuryAmount = pending.treasury;
        if (liquidityProviderAmount == 0 && basketStakerAmount == 0 && staticsStakerAmount == 0 && treasuryAmount == 0) return;
        pending.liquidityProvider = 0;
        pending.basketStaker = 0;
        pending.staticsStaker = 0;
        pending.treasury = 0;
        IERC20 token = IERC20(Currency.unwrap(currency));
        uint256 total = liquidityProviderAmount + basketStakerAmount + staticsStakerAmount + treasuryAmount;
        uint256 beforeBalance = currency.balanceOfSelf();
        token.forceApprove(staticsDiamond, total);
        IStaticsLiquidityRewards(staticsDiamond)
            .routeCanonicalSwapFees(
                poolId,
                Currency.unwrap(currency),
                liquidityProviderAmount,
                basketStakerAmount,
                staticsStakerAmount,
                treasuryAmount
            );
        uint256 afterBalance = currency.balanceOfSelf();
        _enforceExactDebit(currency, beforeBalance, afterBalance, total);
        uint256 remainingAllowance = token.allowance(address(this), staticsDiamond);
        if (remainingAllowance != 0) revert UnexpectedTokenAllowance(currency, remainingAllowance);
        _assertPendingSolvency(currency);
    }

    function _compound(PoolKey calldata key, PoolId poolId) private returns (uint128 liquidityAdded) {
        uint256 available0 = polPending[poolId][key.currency0];
        uint256 available1 = polPending[poolId][key.currency1];
        if (available0 == 0 || available1 == 0) return 0;
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        int24 tickLower = TickMath.minUsableTick(key.tickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(key.tickSpacing);
        liquidityAdded = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            available0,
            available1
        );
        if (liquidityAdded == 0) return 0;
        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidityDelta: int256(uint256(liquidityAdded)),
            salt: PERMANENT_LIQUIDITY_SALT
        });
        (BalanceDelta delta,) = poolManager.modifyLiquidity(key, params, "");
        uint256 amount0 = _applyCompoundDelta(poolId, key.currency0, delta.amount0(), available0);
        uint256 amount1 = _applyCompoundDelta(poolId, key.currency1, delta.amount1(), available1);
        permanentLiquidity[poolId] += liquidityAdded;
        emit PermanentLiquidityAdded(
            poolId,
            liquidityAdded,
            amount0,
            amount1,
            polPending[poolId][key.currency0],
            polPending[poolId][key.currency1]
        );
    }

    function _applyCompoundDelta(PoolId poolId, Currency currency, int128 delta, uint256 available)
        private
        returns (uint256 amountPaid)
    {
        if (delta < 0) {
            amountPaid = _absolute(int256(delta));
            if (amountPaid > available) {
                revert PermanentLiquidityExceedsPending(currency, amountPaid, available);
            }
            polPending[poolId][currency] = available - amountPaid;
            totalPending[currency] -= amountPaid;
            _settle(currency, amountPaid);
        } else if (delta > 0) {
            uint256 amountCollected = uint256(uint128(delta));
            _takeExact(currency, address(this), amountCollected);
            uint256 pendingAmount = available + amountCollected;
            polPending[poolId][currency] = pendingAmount;
            totalPending[currency] += amountCollected;
            emit PermanentLiquidityFeesCollected(poolId, currency, amountCollected, pendingAmount);
        }
        _assertPendingSolvency(currency);
    }

    function _takeExact(Currency currency, uint256 amount) private {
        _takeExact(currency, address(this), amount);
    }

    function _takeExact(Currency currency, address receiver, uint256 amount) private {
        if (amount == 0) return;
        uint256 senderBefore = currency.balanceOf(address(poolManager));
        uint256 receiverBefore = currency.balanceOf(receiver);
        poolManager.take(currency, receiver, amount);
        uint256 senderAfter = currency.balanceOf(address(poolManager));
        uint256 receiverAfter = currency.balanceOf(receiver);
        _enforceExactDebit(currency, senderBefore, senderAfter, amount);
        uint256 received = receiverAfter >= receiverBefore ? receiverAfter - receiverBefore : 0;
        if (received != amount) revert IncompatiblePoolCurrency(currency, amount, received);
    }

    function _settle(Currency currency, uint256 amount) private {
        if (amount == 0) return;
        poolManager.sync(currency);
        uint256 senderBefore = currency.balanceOfSelf();
        uint256 receiverBefore = currency.balanceOf(address(poolManager));
        IERC20(Currency.unwrap(currency)).safeTransfer(address(poolManager), amount);
        uint256 senderAfter = currency.balanceOfSelf();
        uint256 receiverAfter = currency.balanceOf(address(poolManager));
        _enforceExactDebit(currency, senderBefore, senderAfter, amount);
        uint256 received = receiverAfter >= receiverBefore ? receiverAfter - receiverBefore : 0;
        if (received != amount) revert IncompatiblePoolCurrency(currency, amount, received);
        uint256 settled = poolManager.settle();
        if (settled != amount) revert UnexpectedSettlement(currency, amount, settled);
        _assertPendingSolvency(currency);
    }

    function _transferExact(Currency currency, address receiver, uint256 amount) private {
        uint256 senderBefore = currency.balanceOfSelf();
        uint256 receiverBefore = currency.balanceOf(receiver);
        IERC20(Currency.unwrap(currency)).safeTransfer(receiver, amount);
        uint256 senderAfter = currency.balanceOfSelf();
        uint256 receiverAfter = currency.balanceOf(receiver);
        _enforceExactDebit(currency, senderBefore, senderAfter, amount);
        uint256 received = receiverAfter >= receiverBefore ? receiverAfter - receiverBefore : 0;
        if (received != amount) revert IncompatiblePoolCurrency(currency, amount, received);
    }

    function _enforceExactDebit(Currency currency, uint256 beforeBalance, uint256 afterBalance, uint256 expected)
        private
        pure
    {
        uint256 actual = beforeBalance >= afterBalance ? beforeBalance - afterBalance : 0;
        if (actual != expected) revert UnexpectedTokenDebit(currency, expected, actual);
    }

    function _assertPendingSolvency(Currency currency) private view {
        uint256 required = totalPending[currency];
        uint256 available = currency.balanceOfSelf();
        if (available < required) revert PendingLiquidityInsolvent(currency, required, available);
    }

    function _setFeeConfiguration(
        uint16 inputFeeBps,
        uint16 outputFeeBps,
        uint16 polShareBps,
        uint16 liquidityProviderShareBps,
        uint16 basketStakerShareBps,
        uint16 staticsStakerShareBps,
        uint16 treasuryShareBps
    ) private {
        FeeConfiguration memory configuration = FeeConfiguration({
            inputFeeBps: inputFeeBps,
            outputFeeBps: outputFeeBps,
            polShareBps: polShareBps,
            liquidityProviderShareBps: liquidityProviderShareBps,
            basketStakerShareBps: basketStakerShareBps,
            staticsStakerShareBps: staticsStakerShareBps,
            treasuryShareBps: treasuryShareBps
        });
        _validateFeeConfiguration(configuration);
        fees = configuration;
        emit FeeConfigurationSet(
            inputFeeBps,
            outputFeeBps,
            polShareBps,
            liquidityProviderShareBps,
            basketStakerShareBps,
            staticsStakerShareBps,
            treasuryShareBps
        );
    }

    function _validateFeeConfiguration(FeeConfiguration memory configuration) private pure {
        if (
            uint256(configuration.inputFeeBps) + uint256(configuration.outputFeeBps) > MAX_COMBINED_FEE_BPS
                || uint256(configuration.polShareBps) + uint256(configuration.liquidityProviderShareBps)
                        + uint256(configuration.basketStakerShareBps) + uint256(configuration.staticsStakerShareBps)
                        + uint256(configuration.treasuryShareBps) != BPS
        ) revert InvalidFeeConfiguration();
    }

    function _absolute(int256 value) private pure returns (uint256) {
        return value < 0 ? uint256(-(value + 1)) + 1 : uint256(value);
    }

    function _enforceRegistered(PoolId poolId) private view {
        if (!registrations[poolId].registered) revert PoolNotRegistered(poolId);
    }

    function _enforceDiamond() private view {
        if (msg.sender != staticsDiamond) revert OnlyStaticsDiamond(msg.sender);
    }
}
