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
import {IStaticsProtocolRevenue} from "../interfaces/IStaticsProtocolRevenue.sol";
import {IStaticsSwapFeeHook} from "../interfaces/IStaticsSwapFeeHook.sol";
import {LibProtocolPoolFee} from "../libraries/LibProtocolPoolFee.sol";

/// @notice Canonical Statics bilateral swap-fee hook. The hook holds PoolId-local fee rates and two
/// global allocation profiles (basket canonical and general). The fixed 500-bps creator allocation is
/// carved from the fee before applying the configurable profile shares, so every profile plus the
/// creator share totals 10,000 bps. Collected fees are routed to the Diamond through
/// `routeProtocolSwapFees`.
contract StaticsSwapFeeHook is BaseHook, IStaticsSwapFeeHook, IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using SafeCast for uint256;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    using SafeERC20 for IERC20;

    uint256 private constant BPS = 10_000;
    uint256 private constant CREATOR_SHARE_BPS = LibProtocolPoolFee.CREATOR_SHARE_BPS;
    uint8 private constant UNLOCK_RELEASE = 1;
    uint8 private constant UNLOCK_SEED = 2;
    bytes32 private constant PERMANENT_LIQUIDITY_SALT = keccak256("statics.permanent.swap.fee.liquidity");

    struct PendingDistribution {
        uint256 liquidityProvider;
        uint256 basketStaker;
        uint256 staticsStaker;
        uint256 creator;
        uint256 treasury;
    }

    struct ReleaseRequest {
        PoolKey key;
        address receiver;
    }

    struct CompoundPrepared {
        uint128 liquidityAdded;
        int128 delta0;
        int128 delta1;
    }

    struct EffectiveRate {
        uint16 inputFeeBps;
        uint16 outputFeeBps;
    }

    struct AllocationShares {
        uint256 pol;
        uint256 liquidityProvider;
        uint256 basketStaker;
        uint256 staticsStaker;
        uint256 creator;
        uint256 treasury;
    }

    address public immutable staticsDiamond;

    uint16 private defaultInputFeeBps;
    uint16 private defaultOutputFeeBps;
    BasketFeeAllocation private basketAllocation;
    GeneralFeeAllocation private generalAllocation;

    mapping(PoolId poolId => PoolRegistration registration) private registrations;
    mapping(PoolId poolId => PoolFeeRate rate) private poolRates;
    mapping(PoolId poolId => mapping(Currency currency => uint256 amount)) private polPending;
    mapping(Currency currency => uint256 amount) private totalPending;
    mapping(PoolId poolId => mapping(Currency currency => PendingDistribution amount)) private distributions;
    mapping(PoolId poolId => uint128 liquidity) private permanentLiquidity;
    mapping(PoolId poolId => bool decommissioned) private decommissionedPools;

    error OnlyStaticsDiamond(address caller);
    error InvalidFeeRate();
    error InvalidAllocation();
    error PoolAlreadyRegistered(PoolId poolId);
    error PoolNotRegistered(PoolId poolId);
    error InvalidPoolKind();
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
    error CanonicalPoolDonationForbidden();

    constructor(IPoolManager manager, address diamond, uint16 inputFeeBps, uint16 outputFeeBps) BaseHook(manager) {
        staticsDiamond = diamond;
        _setDefaultFeeRate(inputFeeBps, outputFeeBps);
        _setBasketFeeAllocation(
            BasketFeeAllocation({
                polShareBps: 1_000,
                liquidityProviderShareBps: 2_500,
                basketStakerShareBps: 2_500,
                staticsStakerShareBps: 1_500,
                treasuryShareBps: 2_000
            })
        );
        _setGeneralFeeAllocation(
            GeneralFeeAllocation({
                polShareBps: 3_500,
                liquidityProviderShareBps: 2_500,
                staticsStakerShareBps: 1_500,
                treasuryShareBps: 2_000
            })
        );
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory permissions) {
        permissions.afterInitialize = true;
        permissions.beforeSwap = true;
        permissions.beforeSwapReturnDelta = true;
        permissions.afterSwap = true;
        permissions.afterSwapReturnDelta = true;
        permissions.beforeDonate = true;
    }

    /// @dev Registration must precede initialization so a third party cannot squat a predictable canonical PoolKey.
    function _afterInitialize(address, PoolKey calldata key, uint160, int24) internal view override returns (bytes4) {
        _enforceRegistered(key.toId());
        return IHooks.afterInitialize.selector;
    }

    function _beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        internal
        pure
        override
        returns (bytes4)
    {
        revert CanonicalPoolDonationForbidden();
    }

    // --- Fee rate administration ---

    function defaultFeeRate() external view returns (uint16 inputFeeBps, uint16 outputFeeBps) {
        return (defaultInputFeeBps, defaultOutputFeeBps);
    }

    function setDefaultFeeRate(uint16 inputFeeBps, uint16 outputFeeBps) external {
        _enforceDiamond();
        _setDefaultFeeRate(inputFeeBps, outputFeeBps);
    }

    function setPoolFeeRate(PoolId poolId, uint16 inputFeeBps, uint16 outputFeeBps) external {
        _enforceDiamond();
        _enforceRegistered(poolId);
        if (!LibProtocolPoolFee.isValidFeeRate(inputFeeBps, outputFeeBps)) revert InvalidFeeRate();
        poolRates[poolId] = PoolFeeRate({inputFeeBps: inputFeeBps, outputFeeBps: outputFeeBps, overridden: true});
        emit PoolFeeRateSet(poolId, inputFeeBps, outputFeeBps, true);
    }

    function clearPoolFeeRate(PoolId poolId) external {
        _enforceDiamond();
        _enforceRegistered(poolId);
        delete poolRates[poolId];
        emit PoolFeeRateSet(poolId, defaultInputFeeBps, defaultOutputFeeBps, false);
    }

    function poolFeeRate(PoolId poolId) external view returns (PoolFeeRate memory rate) {
        _enforceRegistered(poolId);
        PoolFeeRate storage stored = poolRates[poolId];
        if (stored.overridden) return stored;
        return PoolFeeRate({inputFeeBps: defaultInputFeeBps, outputFeeBps: defaultOutputFeeBps, overridden: false});
    }

    // --- Allocation profile administration ---

    function basketFeeAllocation() external view returns (BasketFeeAllocation memory allocation) {
        return basketAllocation;
    }

    function generalFeeAllocation() external view returns (GeneralFeeAllocation memory allocation) {
        return generalAllocation;
    }

    function setBasketFeeAllocation(BasketFeeAllocation calldata allocation) external {
        _enforceDiamond();
        _setBasketFeeAllocation(allocation);
    }

    function setGeneralFeeAllocation(GeneralFeeAllocation calldata allocation) external {
        _enforceDiamond();
        _setGeneralFeeAllocation(allocation);
    }

    // --- Registration and lifecycle ---

    function registerPool(PoolKey calldata key, PoolKind kind, address creator) external returns (PoolId poolId) {
        _enforceDiamond();
        if (key.currency0.isAddressZero() || key.currency1.isAddressZero()) revert NativeCurrencyUnsupported();
        if (key.fee != 0) revert NonzeroNativeLpFee(key.fee);
        if (kind != PoolKind.BasketCanonical && kind != PoolKind.General) revert InvalidPoolKind();
        poolId = key.toId();
        if (registrations[poolId].registered) revert PoolAlreadyRegistered(poolId);
        registrations[poolId] = PoolRegistration({
            currency0: key.currency0, currency1: key.currency1, kind: kind, creator: creator, registered: true
        });
        emit PoolRegistered(poolId, key.currency0, key.currency1, kind, creator);
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
        EffectiveRate memory rate = _effectiveRate(poolId);
        uint16 feeBps = exactInput ? rate.inputFeeBps : rate.outputFeeBps;
        uint256 realized = _absolute(params.amountSpecified);
        uint256 charged = Math.mulDiv(realized, feeBps, BPS, Math.Rounding.Ceil);
        if (charged == 0) return (IHooks.beforeSwap.selector, toBeforeSwapDelta(0, 0), 0);
        Currency specified = (params.zeroForOne == exactInput) ? key.currency0 : key.currency1;
        _takeExact(specified, charged);
        _allocate(poolId, specified, realized, charged, true);
        _routeDistribution(poolId, specified);
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(charged.toInt128(), 0), 0);
    }

    function _afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        PoolId poolId = key.toId();
        uint256 charged;
        {
            bool exactInput = params.amountSpecified < 0;
            bool specifiedCurrencyIs0 = exactInput == params.zeroForOne;
            Currency unspecified = specifiedCurrencyIs0 ? key.currency1 : key.currency0;
            int128 unspecifiedDelta = specifiedCurrencyIs0 ? delta.amount1() : delta.amount0();
            uint256 realized = _absolute(int256(unspecifiedDelta));
            EffectiveRate memory rate = _effectiveRate(poolId);
            uint16 feeBps = exactInput ? rate.outputFeeBps : rate.inputFeeBps;
            charged = Math.mulDiv(realized, feeBps, BPS, Math.Rounding.Ceil);
            if (charged != 0) {
                _takeExact(unspecified, charged);
                _allocate(poolId, unspecified, realized, charged, false);
            }
        }

        _routeDistribution(poolId, key.currency0);
        _routeDistribution(poolId, key.currency1);
        _compound(key, poolId);
        return (IHooks.afterSwap.selector, charged.toInt128());
    }

    function _allocate(PoolId poolId, Currency currency, uint256 realized, uint256 charged, bool specifiedLeg) private {
        AllocationShares memory shares = _computeShares(poolId, currency, charged);
        polPending[poolId][currency] += shares.pol;
        totalPending[currency] += shares.pol;
        PendingDistribution storage pending = distributions[poolId][currency];
        pending.liquidityProvider += shares.liquidityProvider;
        pending.basketStaker += shares.basketStaker;
        pending.staticsStaker += shares.staticsStaker;
        pending.creator += shares.creator;
        pending.treasury += shares.treasury;
        emit SwapLegFeeAccrued(
            poolId,
            currency,
            specifiedLeg,
            realized,
            charged,
            shares.pol,
            shares.liquidityProvider,
            shares.basketStaker,
            shares.staticsStaker,
            shares.creator,
            shares.treasury
        );
    }

    /// @dev Carves the fixed creator share first, then applies the class allocation profile. Fallback
    /// policy: unavailable LP and basket-staker shares route to POL; unavailable Statics-staker share
    /// routes to treasury; the creator share never falls back.
    function _computeShares(PoolId poolId, Currency currency, uint256 charged)
        private
        view
        returns (AllocationShares memory shares)
    {
        PoolKind kind = registrations[poolId].kind;
        shares.creator = Math.mulDiv(charged, CREATOR_SHARE_BPS, BPS);
        if (kind == PoolKind.BasketCanonical) {
            BasketFeeAllocation storage a = basketAllocation;
            shares.pol = Math.mulDiv(charged, a.polShareBps, BPS);
            shares.liquidityProvider = Math.mulDiv(charged, a.liquidityProviderShareBps, BPS);
            shares.basketStaker = Math.mulDiv(charged, a.basketStakerShareBps, BPS);
            shares.staticsStaker = Math.mulDiv(charged, a.staticsStakerShareBps, BPS);
        } else {
            GeneralFeeAllocation storage a = generalAllocation;
            shares.pol = Math.mulDiv(charged, a.polShareBps, BPS);
            shares.liquidityProvider = Math.mulDiv(charged, a.liquidityProviderShareBps, BPS);
            shares.basketStaker = 0;
            shares.staticsStaker = Math.mulDiv(charged, a.staticsStakerShareBps, BPS);
        }
        shares.treasury = charged - shares.pol - shares.liquidityProvider - shares.basketStaker - shares.staticsStaker
            - shares.creator;

        if (!IStaticsLiquidityRewards(staticsDiamond).canAccrueLiquidityRewards(poolId)) {
            shares.pol += shares.liquidityProvider;
            shares.liquidityProvider = 0;
        }
        if (shares.basketStaker != 0 && !IStaticsLiquidityRewards(staticsDiamond).canAccrueBasketRewards(poolId)) {
            shares.pol += shares.basketStaker;
            shares.basketStaker = 0;
        }
        if (!IStaticsGlobalRewards(staticsDiamond).canAccrueStakerRewards(Currency.unwrap(currency))) {
            shares.treasury += shares.staticsStaker;
            shares.staticsStaker = 0;
        }
    }

    function _effectiveRate(PoolId poolId) private view returns (EffectiveRate memory rate) {
        PoolFeeRate storage stored = poolRates[poolId];
        if (stored.overridden) {
            return EffectiveRate({inputFeeBps: stored.inputFeeBps, outputFeeBps: stored.outputFeeBps});
        }
        return EffectiveRate({inputFeeBps: defaultInputFeeBps, outputFeeBps: defaultOutputFeeBps});
    }

    function _routeDistribution(PoolId poolId, Currency currency) private {
        PendingDistribution storage pending = distributions[poolId][currency];
        IStaticsProtocolRevenue.ProtocolFeeDistribution memory distribution =
            IStaticsProtocolRevenue.ProtocolFeeDistribution({
                liquidityProvider: pending.liquidityProvider,
                basketStaker: pending.basketStaker,
                staticsStaker: pending.staticsStaker,
                creator: pending.creator,
                treasury: pending.treasury
            });
        uint256 total = distribution.liquidityProvider + distribution.basketStaker + distribution.staticsStaker
            + distribution.creator + distribution.treasury;
        if (total == 0) return;
        pending.liquidityProvider = 0;
        pending.basketStaker = 0;
        pending.staticsStaker = 0;
        pending.creator = 0;
        pending.treasury = 0;
        IERC20 token = IERC20(Currency.unwrap(currency));
        uint256 beforeBalance = currency.balanceOfSelf();
        token.forceApprove(staticsDiamond, total);
        IStaticsProtocolRevenue(staticsDiamond).routeProtocolSwapFees(poolId, Currency.unwrap(currency), distribution);
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
        CompoundPrepared memory prepared = _addPermanentLiquidity(key, poolId, available0, available1);
        if (prepared.liquidityAdded == 0) return 0;
        uint256 amount0 = _applyCompoundDelta(poolId, key.currency0, prepared.delta0, available0);
        uint256 amount1 = _applyCompoundDelta(poolId, key.currency1, prepared.delta1, available1);
        permanentLiquidity[poolId] += prepared.liquidityAdded;
        emit PermanentLiquidityAdded(
            poolId,
            prepared.liquidityAdded,
            amount0,
            amount1,
            polPending[poolId][key.currency0],
            polPending[poolId][key.currency1]
        );
        return prepared.liquidityAdded;
    }

    function _addPermanentLiquidity(PoolKey calldata key, PoolId poolId, uint256 available0, uint256 available1)
        private
        returns (CompoundPrepared memory prepared)
    {
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        int24 tickLower = TickMath.minUsableTick(key.tickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(key.tickSpacing);
        prepared.liquidityAdded = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            available0,
            available1
        );
        if (prepared.liquidityAdded == 0) return prepared;
        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidityDelta: int256(uint256(prepared.liquidityAdded)),
            salt: PERMANENT_LIQUIDITY_SALT
        });
        (BalanceDelta delta,) = poolManager.modifyLiquidity(key, params, "");
        prepared.delta0 = delta.amount0();
        prepared.delta1 = delta.amount1();
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

    function _setDefaultFeeRate(uint16 inputFeeBps, uint16 outputFeeBps) private {
        if (!LibProtocolPoolFee.isValidFeeRate(inputFeeBps, outputFeeBps)) revert InvalidFeeRate();
        defaultInputFeeBps = inputFeeBps;
        defaultOutputFeeBps = outputFeeBps;
        emit DefaultFeeRateSet(inputFeeBps, outputFeeBps);
    }

    function _setBasketFeeAllocation(BasketFeeAllocation memory allocation) private {
        if (!LibProtocolPoolFee.isValidConfigurableShares(
                allocation.polShareBps,
                allocation.liquidityProviderShareBps,
                allocation.basketStakerShareBps,
                allocation.staticsStakerShareBps,
                allocation.treasuryShareBps
            )) revert InvalidAllocation();
        basketAllocation = allocation;
        emit BasketFeeAllocationSet(
            allocation.polShareBps,
            allocation.liquidityProviderShareBps,
            allocation.basketStakerShareBps,
            allocation.staticsStakerShareBps,
            allocation.treasuryShareBps
        );
    }

    function _setGeneralFeeAllocation(GeneralFeeAllocation memory allocation) private {
        if (!LibProtocolPoolFee.isValidConfigurableShares(
                allocation.polShareBps,
                allocation.liquidityProviderShareBps,
                0,
                allocation.staticsStakerShareBps,
                allocation.treasuryShareBps
            )) revert InvalidAllocation();
        generalAllocation = allocation;
        emit GeneralFeeAllocationSet(
            allocation.polShareBps,
            allocation.liquidityProviderShareBps,
            allocation.staticsStakerShareBps,
            allocation.treasuryShareBps
        );
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
