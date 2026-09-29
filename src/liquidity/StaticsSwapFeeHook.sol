// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
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
import {IStaticsPermanentLiquidityMath} from "../interfaces/IStaticsPermanentLiquidityMath.sol";
import {IStaticsProtocolRevenue} from "../interfaces/IStaticsProtocolRevenue.sol";
import {IStaticsSwapCallback} from "../interfaces/IStaticsSwapCallback.sol";
import {IStaticsSwapFeeHook} from "../interfaces/IStaticsSwapFeeHook.sol";
import {LibProtocolPoolFee} from "../libraries/LibProtocolPoolFee.sol";

interface IStaticsSwapQuarantine {
    function protocolPoolSwapsBlocked(PoolId poolId) external view returns (bool blocked);
}

/// @notice Canonical Statics bilateral swap-fee hook. The hook holds PoolId-local fee rates and two
/// global allocation profiles (basket canonical and general). The fixed 500-bps creator allocation is
/// carved from the fee before applying the configurable profile shares, so every profile plus the
/// creator share totals 10,000 bps. Collected fees remain as PoolManager claims until a permissionless
/// Diamond maintenance call settles revenue or compounds protocol-owned liquidity.
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
    uint8 private constant UNLOCK_SETTLE = 3;
    uint8 private constant UNLOCK_COMPOUND = 4;
    uint8 private constant UNLOCK_STAKER = 5;
    uint8 private constant MARKET_FLAG_ZERO_FOR_ONE = 1 << 0;
    uint8 private constant MARKET_FLAG_EXACT_OUTPUT = 1 << 1;
    bytes32 private constant PERMANENT_LIQUIDITY_SALT = keccak256("statics.permanent.swap.fee.liquidity");
    bytes32 private constant SPECIFIED_STAKER_SLOT_DOMAIN = keccak256("statics.swap.specified.staker.v1");

    struct ReleaseRequest {
        PoolKey key;
        address receiver;
    }

    struct SettleRequest {
        PoolKey key;
        Currency currency;
        address receiver;
    }

    struct CompoundRequest {
        PoolKey key;
        uint16 tipBps;
        address tipReceiver;
    }

    struct CompoundPrepared {
        uint128 liquidityAdded;
        int128 principal0;
        int128 principal1;
        uint128 fees0;
        uint128 fees1;
    }

    struct EffectiveRate {
        uint16 inputFeeBps;
        uint16 outputFeeBps;
    }

    struct UnspecifiedCharge {
        bool exactInput;
        bool specifiedCurrencyIs0;
        uint16 specifiedFeeBps;
        uint16 unspecifiedFeeBps;
        uint256 specifiedCharged;
        Currency currency;
        uint256 realized;
    }

    struct AllocationShares {
        uint256 pol;
        uint256 basketStaker;
        uint256 staticsStaker;
        uint256 creator;
        uint256 treasury;
    }

    address public immutable staticsDiamond;
    IStaticsPermanentLiquidityMath private immutable permanentLiquidityCalc;

    uint16 private defaultInputFeeBps;
    uint16 private defaultOutputFeeBps;
    BasketFeeAllocation private basketAllocation;
    GeneralFeeAllocation private generalAllocation;

    mapping(PoolId poolId => PoolRegistration registration) private registrations;
    mapping(PoolId poolId => PoolFeeRate rate) private poolRates;
    mapping(PoolId poolId => mapping(Currency currency => uint256 amount)) private polPending;
    mapping(Currency currency => uint256 amount) private totalClaimLiability;
    mapping(Currency currency => uint256 amount) private stakerPending;
    mapping(PoolId poolId => mapping(Currency currency => FeeDistribution amount)) private distributions;
    mapping(PoolId poolId => uint128 liquidity) public lockedLiquidity;
    mapping(PoolId poolId => bool decommissioned) public poolDecommissioned;

    error OnlyStaticsDiamond(address caller);
    error InvalidFeeRate();
    error InvalidAllocation();
    error PoolAlreadyRegistered();
    error PoolNotRegistered();
    error InvalidPoolKind();
    error InvalidCreator();
    error PoolIsDecommissioned();
    error PoolNotDecommissioned(PoolId poolId);
    error NativeCurrencyUnsupported();
    error IncompatiblePoolCurrency();
    error UnexpectedTokenDebit(Currency currency, uint256 expected, uint256 actual);
    error UnexpectedTokenAllowance();
    error UnexpectedSettlement();
    error ClaimLiabilityInsolvent(Currency currency, uint256 required, uint256 available);
    error PermanentLiquidityExceedsPending(Currency currency, uint256 required, uint256 available);
    error UnexpectedLiquidityDelta(int128 amount0, int128 amount1);
    error UnexpectedCompoundDelta(Currency currency, int128 amount);
    error UnexpectedNativeFeeDelta(int128 amount0, int128 amount1);
    error InvalidUnlockCaller(address caller);
    error InvalidReleaseReceiver();
    error EmptyPermanentLiquiditySeed();
    error InvalidPermanentLiquiditySeed(PoolId poolId);
    error PermanentLiquidityAlreadySeeded(PoolId poolId);
    error DuplicatePermanentLiquiditySeed(PoolId poolId);
    error UnexpectedCurrencyDelta(Currency currency, int256 delta);
    error CanonicalPoolDonationForbidden();
    error IncompleteSpecifiedFill();
    error InvalidNativeLpFee();
    error InvalidPermanentLiquidityMath();
    error SwapsQuarantined(PoolId poolId);
    error InvalidSettlementCurrency(Currency currency);

    constructor(
        IPoolManager manager,
        address diamond,
        uint16 inputFeeBps,
        uint16 outputFeeBps,
        IStaticsPermanentLiquidityMath permanentLiquidityMath_
    ) BaseHook(manager) {
        if (address(permanentLiquidityMath_).code.length == 0) {
            revert InvalidPermanentLiquidityMath();
        }
        staticsDiamond = diamond;
        permanentLiquidityCalc = permanentLiquidityMath_;
        _setDefaultFeeRate(inputFeeBps, outputFeeBps);
        _setBasketFeeAllocation(
            BasketFeeAllocation({
                polShareBps: 1_500, basketStakerShareBps: 3_000, staticsStakerShareBps: 3_000, treasuryShareBps: 2_000
            })
        );
        _setGeneralFeeAllocation(
            GeneralFeeAllocation({polShareBps: 4_000, staticsStakerShareBps: 3_500, treasuryShareBps: 2_000})
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
        if (!LibProtocolPoolFee.isValidStaticLpFee(key.fee)) revert InvalidNativeLpFee();
        if (kind != PoolKind.BasketCanonical && kind != PoolKind.General) revert InvalidPoolKind();
        if (creator == address(0)) revert InvalidCreator();
        poolId = key.toId();
        if (registrations[poolId].registered) revert PoolAlreadyRegistered();
        registrations[poolId] = PoolRegistration({
            currency0: key.currency0, currency1: key.currency1, kind: kind, creator: creator, registered: true
        });
        emit PoolRegistered(poolId, key.currency0, key.currency1, kind, creator);
    }

    function decommissionPool(PoolKey calldata key) external {
        _enforceDiamond();
        PoolId poolId = key.toId();
        _enforceRegistered(poolId);
        if (poolDecommissioned[poolId]) revert PoolIsDecommissioned();
        poolDecommissioned[poolId] = true;
        emit PoolDecommissioned(poolId);
    }

    function poolRegistration(PoolId poolId) external view returns (PoolRegistration memory registration) {
        return registrations[poolId];
    }

    function pendingPermanentLiquidity(PoolId poolId, Currency currency) external view returns (uint256 amount) {
        return polPending[poolId][currency];
    }

    function pendingStakerRewards(Currency currency) external view returns (uint256 amount) {
        return stakerPending[currency];
    }

    function pendingFeeDistribution(PoolId poolId, Currency currency)
        external
        view
        returns (FeeDistribution memory distribution)
    {
        return distributions[poolId][currency];
    }

    function claimLiability(Currency currency) external view returns (uint256 amount) {
        return totalClaimLiability[currency];
    }

    function seedPermanentLiquidity(PermanentLiquiditySeed[] calldata seeds) external {
        _enforceDiamond();
        uint256 length = seeds.length;
        if (length == 0) revert EmptyPermanentLiquiditySeed();
        for (uint256 i; i < length; ++i) {
            PoolId poolId = seeds[i].key.toId();
            _enforceRegistered(poolId);
            if (poolDecommissioned[poolId]) revert PoolIsDecommissioned();
            if (seeds[i].liquidity == 0) revert InvalidPermanentLiquiditySeed(poolId);
            if (lockedLiquidity[poolId] != 0) revert PermanentLiquidityAlreadySeeded(poolId);
            for (uint256 j; j < i; ++j) {
                if (PoolId.unwrap(seeds[j].key.toId()) == PoolId.unwrap(poolId)) {
                    revert DuplicatePermanentLiquiditySeed(poolId);
                }
            }
        }
        poolManager.unlock(abi.encode(UNLOCK_SEED, abi.encode(seeds)));
    }

    function settleFeeDistribution(PoolKey calldata key, Currency currency, address receiver)
        external
        returns (FeeDistribution memory distribution)
    {
        _enforceDiamond();
        PoolId poolId = key.toId();
        _enforceRegistered(poolId);
        if (poolDecommissioned[poolId]) revert PoolIsDecommissioned();
        address settlementAsset = Currency.unwrap(currency);
        if (settlementAsset != Currency.unwrap(key.currency0) && settlementAsset != Currency.unwrap(key.currency1)) {
            revert InvalidSettlementCurrency(currency);
        }
        bytes memory result = poolManager.unlock(
            abi.encode(UNLOCK_SETTLE, abi.encode(SettleRequest({key: key, currency: currency, receiver: receiver})))
        );
        distribution = abi.decode(result, (FeeDistribution));
    }

    function settleStakerRewards(Currency currency, address receiver, uint256 amount)
        external
        returns (uint256 settled)
    {
        _enforceDiamond();
        if (receiver == address(0)) revert InvalidReleaseReceiver();
        uint256 pending = stakerPending[currency];
        if (amount > pending) revert PermanentLiquidityExceedsPending(currency, amount, pending);
        if (amount == 0) return 0;
        poolManager.unlock(abi.encode(UNLOCK_STAKER, abi.encode(currency, receiver, amount)));
        return amount;
    }

    function compoundPermanentLiquidity(PoolKey calldata key, uint16 tipBps, address tipReceiver)
        external
        returns (PermanentLiquidityCompound memory result)
    {
        _enforceDiamond();
        PoolId poolId = key.toId();
        _enforceRegistered(poolId);
        if (poolDecommissioned[poolId]) revert PoolIsDecommissioned();
        _normalizePendingDistribution(poolId, key.currency0);
        _normalizePendingDistribution(poolId, key.currency1);
        bytes memory encoded = poolManager.unlock(
            abi.encode(
                UNLOCK_COMPOUND, abi.encode(CompoundRequest({key: key, tipBps: tipBps, tipReceiver: tipReceiver}))
            )
        );
        result = abi.decode(encoded, (PermanentLiquidityCompound));
    }

    function releasePermanentLiquidity(PoolKey calldata key, address receiver)
        external
        returns (PermanentLiquidityRelease memory released)
    {
        _enforceDiamond();
        if (receiver == address(0)) revert InvalidReleaseReceiver();
        PoolId poolId = key.toId();
        _enforceRegistered(poolId);
        if (!poolDecommissioned[poolId]) revert PoolNotDecommissioned(poolId);
        uint128 liquidity = lockedLiquidity[poolId];
        bytes memory result =
            poolManager.unlock(abi.encode(UNLOCK_RELEASE, abi.encode(ReleaseRequest({key: key, receiver: receiver}))));
        released = abi.decode(result, (PermanentLiquidityRelease));
        emit PermanentLiquidityReleased(
            poolId,
            receiver,
            liquidity,
            released.principal0 + released.pendingPol0 + _distributionTotal(released.distribution0),
            released.principal1 + released.pendingPol1 + _distributionTotal(released.distribution1)
        );
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert InvalidUnlockCaller(msg.sender);
        (uint8 action, bytes memory payload) = abi.decode(data, (uint8, bytes));
        if (action == UNLOCK_SEED) {
            _seedPermanentLiquidity(abi.decode(payload, (PermanentLiquiditySeed[])));
            return "";
        }
        if (action == UNLOCK_SETTLE) {
            return _settleFeeDistribution(abi.decode(payload, (SettleRequest)));
        }
        if (action == UNLOCK_COMPOUND) {
            return _compoundPermanentLiquidity(abi.decode(payload, (CompoundRequest)));
        }
        if (action == UNLOCK_RELEASE) return _releasePermanentLiquidity(abi.decode(payload, (ReleaseRequest)));
        if (action != UNLOCK_STAKER) revert();
        (Currency currency, address receiver, uint256 amount) = abi.decode(payload, (Currency, address, uint256));
        stakerPending[currency] -= amount;
        _redeemClaims(currency, receiver, amount);
        return "";
    }

    function _settleFeeDistribution(SettleRequest memory request) private returns (bytes memory) {
        PoolId poolId = request.key.toId();
        if (lockedLiquidity[poolId] != 0) _collectNativeFees(request.key, poolId);
        return abi.encode(_redeemDistribution(poolId, request.currency, request.receiver));
    }

    function _compoundPermanentLiquidity(CompoundRequest memory request) private returns (bytes memory) {
        PoolId poolId = request.key.toId();
        PermanentLiquidityCompound memory result;
        (result.liquidityAdded, result.amount0Consumed, result.amount1Consumed) = _compound(request.key, poolId);
        if (result.liquidityAdded != 0) {
            result.tip0 = _compoundTip(poolId, request.key.currency0, result.amount0Consumed, request.tipBps);
            result.tip1 = _compoundTip(poolId, request.key.currency1, result.amount1Consumed, request.tipBps);
            _redeemClaims(request.key.currency0, request.tipReceiver, result.tip0);
            _redeemClaims(request.key.currency1, request.tipReceiver, result.tip1);
        }
        return abi.encode(result);
    }

    function _releasePermanentLiquidity(ReleaseRequest memory request) private returns (bytes memory) {
        PoolId poolId = request.key.toId();
        uint128 liquidity = lockedLiquidity[poolId];
        PermanentLiquidityRelease memory released;
        if (liquidity != 0) {
            lockedLiquidity[poolId] = 0;
            ModifyLiquidityParams memory params = ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(request.key.tickSpacing),
                tickUpper: TickMath.maxUsableTick(request.key.tickSpacing),
                liquidityDelta: -int256(uint256(liquidity)),
                salt: PERMANENT_LIQUIDITY_SALT
            });
            (BalanceDelta callerDelta, BalanceDelta feesAccrued) = poolManager.modifyLiquidity(request.key, params, "");
            (int128 principal0, int128 principal1, uint128 fees0, uint128 fees1) =
                _separateLiquidityDelta(callerDelta, feesAccrued);
            if (principal0 < 0 || principal1 < 0) {
                revert UnexpectedLiquidityDelta(principal0, principal1);
            }
            _recordNativeFees(poolId, request.key.currency0, fees0);
            _recordNativeFees(poolId, request.key.currency1, fees1);
            released.principal0 = uint256(uint128(principal0));
            released.principal1 = uint256(uint128(principal1));
            _takeExact(request.key.currency0, request.receiver, released.principal0);
            _takeExact(request.key.currency1, request.receiver, released.principal1);
        }

        released.distribution0 = _redeemDistribution(poolId, request.key.currency0, request.receiver);
        released.distribution1 = _redeemDistribution(poolId, request.key.currency1, request.receiver);
        // Distribution normalization can move a no-longer-eligible basket-staker share into POL.
        // Redeem POL after both distributions so no decommission fallback remains stranded.
        released.pendingPol0 = _redeemPendingPol(poolId, request.key.currency0, request.receiver);
        released.pendingPol1 = _redeemPendingPol(poolId, request.key.currency1, request.receiver);
        return abi.encode(released);
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
            (BalanceDelta callerDelta, BalanceDelta feesAccrued) = poolManager.modifyLiquidity(seed.key, params, "");
            (int128 principal0, int128 principal1, uint128 fees0, uint128 fees1) =
                _separateLiquidityDelta(callerDelta, feesAccrued);
            if (principal0 >= 0 || principal1 >= 0) revert InvalidPermanentLiquiditySeed(poolId);
            amount0[i] = _absolute(int256(principal0));
            amount1[i] = _absolute(int256(principal1));
            _recordNativeFees(poolId, seed.key.currency0, fees0);
            _recordNativeFees(poolId, seed.key.currency1, fees1);
            lockedLiquidity[poolId] = seed.liquidity;
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
        if (received != amount) revert IncompatiblePoolCurrency();
        uint256 settled = poolManager.settle();
        if (settled != amount) revert UnexpectedSettlement();
        uint256 remainingAllowance = token.allowance(staticsDiamond, address(this));
        if (remainingAllowance != 0) revert UnexpectedTokenAllowance();
        _assertClaimSolvency(currency);
    }

    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId poolId = key.toId();
        _enforceRegistered(poolId);
        if (poolDecommissioned[poolId]) revert PoolIsDecommissioned();
        if (IStaticsSwapQuarantine(staticsDiamond).protocolPoolSwapsBlocked(poolId)) revert SwapsQuarantined(poolId);
        uint256 charged = _chargeSpecifiedLeg(poolId, key, params);
        if (charged == 0) return (IHooks.beforeSwap.selector, toBeforeSwapDelta(0, 0), 0);
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(charged.toInt128(), 0), 0);
    }

    function _chargeSpecifiedLeg(PoolId poolId, PoolKey calldata key, SwapParams calldata params)
        private
        returns (uint256 charged)
    {
        bool exactInput = params.amountSpecified < 0;
        EffectiveRate memory rate = _effectiveRate(poolId);
        uint16 feeBps = exactInput ? rate.inputFeeBps : rate.outputFeeBps;
        uint256 realized = _absolute(params.amountSpecified);
        charged = exactInput ? _feeFromGross(realized, feeBps) : _feeFromNet(realized, feeBps);
        Currency specified = (params.zeroForOne == exactInput) ? key.currency0 : key.currency1;
        uint256 stakerAmount;
        if (charged != 0) stakerAmount = _accrueSwapLegFee(poolId, specified, realized, charged, true);
        _storeSpecifiedStaker(poolId, specified == key.currency1 ? stakerAmount << 128 : stakerAmount);
    }

    function _afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        PoolId poolId = key.toId();
        (uint256 charged, uint256 packedFees, uint256 packedStakerFees) =
            _chargeUnspecifiedLeg(poolId, key, params, delta);
        packedStakerFees |= _takeSpecifiedStaker(poolId);
        uint8 flags = params.zeroForOne ? MARKET_FLAG_ZERO_FOR_ONE : 0;
        if (params.amountSpecified >= 0) flags |= MARKET_FLAG_EXACT_OUTPUT;
        _afterStaticsPoolSwap(poolId, delta, packedFees, packedStakerFees, flags);
        return (IHooks.afterSwap.selector, charged.toInt128());
    }

    function _afterStaticsPoolSwap(
        PoolId poolId,
        BalanceDelta delta,
        uint256 staticsFeesPacked,
        uint256 staticsStakerFeesPacked,
        uint8 flags
    ) private {
        address diamond = staticsDiamond;
        bytes4 selector = IStaticsSwapCallback.afterStaticsPoolSwap.selector;
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr, selector)
            mstore(add(ptr, 4), poolId)
            mstore(add(ptr, 36), delta)
            mstore(add(ptr, 68), staticsFeesPacked)
            mstore(add(ptr, 100), staticsStakerFeesPacked)
            mstore(add(ptr, 132), flags)
            if iszero(call(gas(), diamond, 0, ptr, 164, 0, 0)) {
                returndatacopy(ptr, 0, returndatasize())
                revert(ptr, returndatasize())
            }
        }
    }

    function _chargeUnspecifiedLeg(PoolId poolId, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta)
        private
        returns (uint256 charged, uint256 packedFees, uint256 packedStakerFees)
    {
        UnspecifiedCharge memory context;
        context.exactInput = params.amountSpecified < 0;
        context.specifiedCurrencyIs0 = context.exactInput == params.zeroForOne;
        EffectiveRate memory rate = _effectiveRate(poolId);
        context.specifiedFeeBps = context.exactInput ? rate.inputFeeBps : rate.outputFeeBps;
        context.unspecifiedFeeBps = context.exactInput ? rate.outputFeeBps : rate.inputFeeBps;
        context.specifiedCharged = context.exactInput
            ? _feeFromGross(_absolute(params.amountSpecified), context.specifiedFeeBps)
            : _feeFromNet(_absolute(params.amountSpecified), context.specifiedFeeBps);
        _enforceCompleteSpecifiedFill(
            params.amountSpecified,
            context.specifiedCurrencyIs0 ? delta.amount0() : delta.amount1(),
            context.specifiedCharged
        );
        context.currency = context.specifiedCurrencyIs0 ? key.currency1 : key.currency0;
        context.realized = _absolute(int256(context.specifiedCurrencyIs0 ? delta.amount1() : delta.amount0()));
        charged = context.exactInput
            ? _feeFromGross(context.realized, context.unspecifiedFeeBps)
            : _feeFromNet(context.realized, context.unspecifiedFeeBps);
        if (charged != 0) {
            uint256 stakerAmount = _accrueSwapLegFee(poolId, context.currency, context.realized, charged, false);
            packedStakerFees = context.specifiedCurrencyIs0 ? stakerAmount << 128 : stakerAmount;
        }
        packedFees = context.specifiedCurrencyIs0
            ? context.specifiedCharged | charged << 128
            : charged | context.specifiedCharged << 128;
    }

    /// @dev Keep claim issuance and its matching liability allocation inseparable for both swap legs.
    function _accrueSwapLegFee(PoolId poolId, Currency currency, uint256 realized, uint256 charged, bool specifiedLeg)
        internal
        returns (uint256 staticsStakerAmount)
    {
        _mintClaim(currency, charged);
        return _allocate(poolId, currency, realized, charged, specifiedLeg);
    }

    function _enforceCompleteSpecifiedFill(int256 amountSpecified, int128 specifiedDelta, uint256 specifiedFee)
        private
        pure
    {
        int256 expectedSpecifiedDelta = amountSpecified + int256(specifiedFee);
        if (int256(specifiedDelta) != expectedSpecifiedDelta) {
            revert IncompleteSpecifiedFill();
        }
    }

    function _allocate(PoolId poolId, Currency currency, uint256 realized, uint256 charged, bool specifiedLeg)
        private
        returns (uint256 staticsStakerAmount)
    {
        AllocationShares memory shares = _computeShares(poolId, currency, charged);
        polPending[poolId][currency] += shares.pol;
        stakerPending[currency] += shares.staticsStaker;
        FeeDistribution storage pending = distributions[poolId][currency];
        pending.basketStaker += shares.basketStaker;
        pending.creator += shares.creator;
        pending.treasury += shares.treasury;
        emit SwapLegFeeAccrued(
            poolId,
            currency,
            specifiedLeg,
            realized,
            charged,
            shares.pol,
            shares.basketStaker,
            shares.staticsStaker,
            shares.creator,
            shares.treasury
        );
        return shares.staticsStaker;
    }

    /// @dev Carves the fixed creator share first, then applies the class allocation profile. Fallback
    /// policy: an unavailable basket-staker share routes to POL; an unavailable Statics-staker share
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
            shares.basketStaker = Math.mulDiv(charged, a.basketStakerShareBps, BPS);
            shares.staticsStaker = Math.mulDiv(charged, a.staticsStakerShareBps, BPS);
        } else {
            GeneralFeeAllocation storage a = generalAllocation;
            shares.pol = Math.mulDiv(charged, a.polShareBps, BPS);
            shares.basketStaker = 0;
            shares.staticsStaker = Math.mulDiv(charged, a.staticsStakerShareBps, BPS);
        }
        shares.treasury = charged - shares.pol - shares.basketStaker - shares.staticsStaker - shares.creator;

        if (shares.basketStaker != 0 && !IStaticsProtocolRevenue(staticsDiamond).canAccrueBasketRewards(poolId)) {
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

    function _compound(PoolKey memory key, PoolId poolId)
        private
        returns (uint128 liquidityAdded, uint256 amount0, uint256 amount1)
    {
        uint256 available0 = polPending[poolId][key.currency0];
        uint256 available1 = polPending[poolId][key.currency1];
        if (available0 == 0 || available1 == 0) return (0, 0, 0);
        CompoundPrepared memory prepared = _addPermanentLiquidity(key, poolId, available0, available1);
        if (prepared.liquidityAdded == 0) return (0, 0, 0);
        _recordNativeFees(poolId, key.currency0, prepared.fees0);
        _recordNativeFees(poolId, key.currency1, prepared.fees1);
        amount0 = _applyCompoundDelta(poolId, key.currency0, prepared.principal0, available0);
        amount1 = _applyCompoundDelta(poolId, key.currency1, prepared.principal1, available1);
        lockedLiquidity[poolId] += prepared.liquidityAdded;
        emit PermanentLiquidityAdded(
            poolId,
            prepared.liquidityAdded,
            amount0,
            amount1,
            polPending[poolId][key.currency0],
            polPending[poolId][key.currency1]
        );
        return (prepared.liquidityAdded, amount0, amount1);
    }

    function _addPermanentLiquidity(PoolKey memory key, PoolId poolId, uint256 available0, uint256 available1)
        private
        returns (CompoundPrepared memory prepared)
    {
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        int24 tickLower;
        int24 tickUpper;
        (prepared.liquidityAdded, tickLower, tickUpper) =
            permanentLiquidityCalc.fullRangeLiquidity(sqrtPriceX96, key.tickSpacing, available0, available1);
        if (prepared.liquidityAdded == 0) return prepared;
        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidityDelta: int256(uint256(prepared.liquidityAdded)),
            salt: PERMANENT_LIQUIDITY_SALT
        });
        (BalanceDelta callerDelta, BalanceDelta feesAccrued) = poolManager.modifyLiquidity(key, params, "");
        (prepared.principal0, prepared.principal1, prepared.fees0, prepared.fees1) =
            _separateLiquidityDelta(callerDelta, feesAccrued);
    }

    function _compoundTip(PoolId poolId, Currency currency, uint256 consumed, uint16 tipBps)
        private
        returns (uint256 tip)
    {
        if (consumed == 0 || tipBps == 0) return 0;
        FeeDistribution storage pending = distributions[poolId][currency];
        tip = Math.mulDiv(consumed, tipBps, BPS);
        if (tip > pending.treasury) tip = pending.treasury;
        pending.treasury -= tip;
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
            _burnClaim(currency, amountPaid);
        } else if (delta > 0) {
            revert UnexpectedCompoundDelta(currency, delta);
        }
        _assertClaimSolvency(currency);
    }

    function _collectNativeFees(PoolKey memory key, PoolId poolId) private {
        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: TickMath.minUsableTick(key.tickSpacing),
            tickUpper: TickMath.maxUsableTick(key.tickSpacing),
            liquidityDelta: 0,
            salt: PERMANENT_LIQUIDITY_SALT
        });
        (BalanceDelta callerDelta, BalanceDelta feesAccrued) = poolManager.modifyLiquidity(key, params, "");
        (int128 principal0, int128 principal1, uint128 fees0, uint128 fees1) =
            _separateLiquidityDelta(callerDelta, feesAccrued);
        if (principal0 != 0 || principal1 != 0) revert UnexpectedLiquidityDelta(principal0, principal1);
        _recordNativeFees(poolId, key.currency0, fees0);
        _recordNativeFees(poolId, key.currency1, fees1);
    }

    function _separateLiquidityDelta(BalanceDelta callerDelta, BalanceDelta feesAccrued)
        private
        pure
        returns (int128 principal0, int128 principal1, uint128 fees0, uint128 fees1)
    {
        int128 fee0 = feesAccrued.amount0();
        int128 fee1 = feesAccrued.amount1();
        if (fee0 < 0 || fee1 < 0) revert UnexpectedNativeFeeDelta(fee0, fee1);
        principal0 = callerDelta.amount0() - fee0;
        principal1 = callerDelta.amount1() - fee1;
        fees0 = uint128(fee0);
        fees1 = uint128(fee1);
    }

    function _recordNativeFees(PoolId poolId, Currency currency, uint128 amount) private {
        if (amount == 0) return;
        _mintClaim(currency, amount);
        distributions[poolId][currency].treasury += amount;
        emit PermanentLiquidityFeesAccrued(poolId, currency, amount);
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
        if (received != amount) revert IncompatiblePoolCurrency();
    }

    function _mintClaim(Currency currency, uint256 amount) private {
        if (amount == 0) return;
        poolManager.mint(address(this), currency.toId(), amount);
        totalClaimLiability[currency] += amount;
        _assertClaimSolvency(currency);
    }

    function _burnClaim(Currency currency, uint256 amount) private {
        if (amount == 0) return;
        totalClaimLiability[currency] -= amount;
        poolManager.burn(address(this), currency.toId(), amount);
        _assertClaimSolvency(currency);
    }

    function _redeemClaims(Currency currency, address receiver, uint256 amount) private {
        if (amount == 0) return;
        _burnClaim(currency, amount);
        _takeExact(currency, receiver, amount);
    }

    function _redeemPendingPol(PoolId poolId, Currency currency, address receiver) private returns (uint256 amount) {
        amount = polPending[poolId][currency];
        if (amount == 0) return 0;
        polPending[poolId][currency] = 0;
        _redeemClaims(currency, receiver, amount);
    }

    function _redeemDistribution(PoolId poolId, Currency currency, address receiver)
        private
        returns (FeeDistribution memory distribution)
    {
        _normalizePendingDistribution(poolId, currency);
        distribution = distributions[poolId][currency];
        uint256 total = _distributionTotal(distribution);
        if (total == 0) return distribution;
        delete distributions[poolId][currency];
        _redeemClaims(currency, receiver, total);
    }

    /// @dev Eligibility can disappear after a callback fee was classified but before its next
    /// routing boundary. Apply the same documented fallbacks again without changing the aggregate
    /// claim liability: basket rewards become POL and Statics-staker rewards become treasury.
    function _normalizePendingDistribution(PoolId poolId, Currency currency) private {
        FeeDistribution storage pending = distributions[poolId][currency];
        uint256 basketStakerToPol;
        if (pending.basketStaker != 0 && !IStaticsProtocolRevenue(staticsDiamond).canAccrueBasketRewards(poolId)) {
            basketStakerToPol = pending.basketStaker;
            pending.basketStaker = 0;
            polPending[poolId][currency] += basketStakerToPol;
        }
        if (basketStakerToPol != 0) {
            emit PendingFeeDistributionReallocated(poolId, currency, basketStakerToPol, 0);
        }
    }

    function _distributionTotal(FeeDistribution memory distribution) private pure returns (uint256) {
        return distribution.basketStaker + distribution.staticsStaker + distribution.creator + distribution.treasury;
    }

    function _specifiedStakerSlot(PoolId poolId) private pure returns (bytes32 slot) {
        return keccak256(abi.encode(SPECIFIED_STAKER_SLOT_DOMAIN, PoolId.unwrap(poolId)));
    }

    function _storeSpecifiedStaker(PoolId poolId, uint256 packedAmount) private {
        bytes32 slot = _specifiedStakerSlot(poolId);
        assembly ("memory-safe") {
            tstore(slot, packedAmount)
        }
    }

    function _takeSpecifiedStaker(PoolId poolId) private returns (uint256 packedAmount) {
        bytes32 slot = _specifiedStakerSlot(poolId);
        assembly ("memory-safe") {
            packedAmount := tload(slot)
            tstore(slot, 0)
        }
    }

    function _enforceExactDebit(Currency currency, uint256 beforeBalance, uint256 afterBalance, uint256 expected)
        private
        pure
    {
        uint256 actual = beforeBalance >= afterBalance ? beforeBalance - afterBalance : 0;
        if (actual != expected) revert UnexpectedTokenDebit(currency, expected, actual);
    }

    function _assertClaimSolvency(Currency currency) private view {
        uint256 required = totalClaimLiability[currency];
        uint256 available = poolManager.balanceOf(address(this), currency.toId());
        if (available < required) revert ClaimLiabilityInsolvent(currency, required, available);
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
                allocation.basketStakerShareBps,
                allocation.staticsStakerShareBps,
                allocation.treasuryShareBps
            )) revert InvalidAllocation();
        basketAllocation = allocation;
        emit BasketFeeAllocationSet(
            allocation.polShareBps,
            allocation.basketStakerShareBps,
            allocation.staticsStakerShareBps,
            allocation.treasuryShareBps
        );
    }

    function _setGeneralFeeAllocation(GeneralFeeAllocation memory allocation) private {
        if (!LibProtocolPoolFee.isValidConfigurableShares(
                allocation.polShareBps, 0, allocation.staticsStakerShareBps, allocation.treasuryShareBps
            )) revert InvalidAllocation();
        generalAllocation = allocation;
        emit GeneralFeeAllocationSet(
            allocation.polShareBps, allocation.staticsStakerShareBps, allocation.treasuryShareBps
        );
    }

    function _feeFromGross(uint256 amount, uint16 feeBps) private pure returns (uint256) {
        return Math.mulDiv(amount, feeBps, BPS, Math.Rounding.Ceil);
    }

    function _feeFromNet(uint256 amount, uint16 feeBps) private pure returns (uint256) {
        if (feeBps == 0) return 0;
        return Math.mulDiv(amount, feeBps, BPS - feeBps, Math.Rounding.Ceil);
    }

    function _absolute(int256 value) private pure returns (uint256) {
        return value < 0 ? uint256(-(value + 1)) + 1 : uint256(value);
    }

    function _enforceRegistered(PoolId poolId) private view {
        if (!registrations[poolId].registered) revert PoolNotRegistered();
    }

    function _enforceDiamond() private view {
        if (msg.sender != staticsDiamond) revert OnlyStaticsDiamond(msg.sender);
    }

    function permanentLiquidityMath() external view returns (IStaticsPermanentLiquidityMath) {
        return permanentLiquidityCalc;
    }
}
