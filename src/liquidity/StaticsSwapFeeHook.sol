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
import {IStaticsSwapFeeHook} from "../interfaces/IStaticsSwapFeeHook.sol";
import {LibProtocolPoolFee} from "../libraries/LibProtocolPoolFee.sol";

interface IStaticsSwapQuarantine {
    function protocolPoolSwapsBlocked(PoolId poolId) external view returns (bool blocked);
}

/// @notice Canonical Statics bilateral swap-fee hook. The hook holds PoolId-local fee rates and two
/// global allocation profiles (basket canonical and general). The fixed 500-bps creator allocation is
/// carved from the fee before applying the configurable profile shares, so every profile plus the
/// creator share totals 10,000 bps. Collected fees remain as PoolManager claims until the next
/// routing boundary, when non-POL claims are redeemed and routed to the Diamond.
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
    uint8 private constant UNLOCK_HARVEST = 3;
    bytes32 private constant PERMANENT_LIQUIDITY_SALT = keccak256("statics.permanent.swap.fee.liquidity");

    struct ReleaseRequest {
        PoolKey key;
        address receiver;
    }

    struct HarvestRequest {
        PoolKey key;
        address receiver;
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
    mapping(PoolId poolId => mapping(Currency currency => FeeDistribution amount)) private distributions;
    mapping(PoolId poolId => uint128 liquidity) public lockedLiquidity;
    mapping(PoolId poolId => bool decommissioned) public poolDecommissioned;

    error OnlyStaticsDiamond(address caller);
    error InvalidFeeRate();
    error InvalidAllocation();
    error PoolAlreadyRegistered(PoolId poolId);
    error PoolNotRegistered(PoolId poolId);
    error InvalidPoolKind();
    error InvalidCreator(address creator);
    error PoolIsDecommissioned(PoolId poolId);
    error PoolNotDecommissioned(PoolId poolId);
    error NativeCurrencyUnsupported();
    error IncompatiblePoolCurrency(Currency currency, uint256 requested, uint256 received);
    error UnexpectedTokenDebit(Currency currency, uint256 expected, uint256 actual);
    error UnexpectedTokenAllowance(Currency currency, uint256 remaining);
    error UnexpectedSettlement(Currency currency, uint256 expected, uint256 actual);
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
    error IncompleteSpecifiedFill(int256 expected, int256 actual);
    error InvalidNativeLpFee(uint24 fee);
    error InvalidPermanentLiquidityMath(address target);
    error SwapsQuarantined(PoolId poolId);

    constructor(
        IPoolManager manager,
        address diamond,
        uint16 inputFeeBps,
        uint16 outputFeeBps,
        IStaticsPermanentLiquidityMath permanentLiquidityMath_
    ) BaseHook(manager) {
        if (address(permanentLiquidityMath_).code.length == 0) {
            revert InvalidPermanentLiquidityMath(address(permanentLiquidityMath_));
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
        if (!LibProtocolPoolFee.isValidStaticLpFee(key.fee)) revert InvalidNativeLpFee(key.fee);
        if (kind != PoolKind.BasketCanonical && kind != PoolKind.General) revert InvalidPoolKind();
        if (creator == address(0)) revert InvalidCreator(creator);
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
        if (poolDecommissioned[poolId]) revert PoolIsDecommissioned(poolId);
        poolDecommissioned[poolId] = true;
        emit PoolDecommissioned(poolId);
    }

    function poolRegistration(PoolId poolId) external view returns (PoolRegistration memory registration) {
        return registrations[poolId];
    }

    function pendingPermanentLiquidity(PoolId poolId, Currency currency) external view returns (uint256 amount) {
        return polPending[poolId][currency];
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
            if (poolDecommissioned[poolId]) revert PoolIsDecommissioned(poolId);
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

    function harvestPermanentLiquidityFees(PoolKey calldata key)
        external
        returns (FeeDistribution memory distribution0, FeeDistribution memory distribution1)
    {
        _enforceDiamond();
        PoolId poolId = key.toId();
        _enforceRegistered(poolId);
        if (poolDecommissioned[poolId]) revert PoolIsDecommissioned(poolId);
        bytes memory result = poolManager.unlock(
            abi.encode(UNLOCK_HARVEST, abi.encode(HarvestRequest({key: key, receiver: staticsDiamond})))
        );
        (distribution0, distribution1) = abi.decode(result, (FeeDistribution, FeeDistribution));
        emit PermanentLiquidityFeesHarvested(
            poolId, _distributionTotal(distribution0), _distributionTotal(distribution1), staticsDiamond
        );
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
        if (action == UNLOCK_HARVEST) {
            return _harvestPermanentLiquidity(abi.decode(payload, (HarvestRequest)));
        }
        if (action != UNLOCK_RELEASE) revert();
        return _releasePermanentLiquidity(abi.decode(payload, (ReleaseRequest)));
    }

    function _harvestPermanentLiquidity(HarvestRequest memory request) private returns (bytes memory) {
        PoolId poolId = request.key.toId();
        if (lockedLiquidity[poolId] != 0) _collectNativeFees(request.key, poolId);
        FeeDistribution memory distribution0 = _redeemDistribution(poolId, request.key.currency0, request.receiver);
        FeeDistribution memory distribution1 = _redeemDistribution(poolId, request.key.currency1, request.receiver);
        return abi.encode(distribution0, distribution1);
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
        if (received != amount) revert IncompatiblePoolCurrency(currency, amount, received);
        uint256 settled = poolManager.settle();
        if (settled != amount) revert UnexpectedSettlement(currency, amount, settled);
        uint256 remainingAllowance = token.allowance(staticsDiamond, address(this));
        if (remainingAllowance != 0) revert UnexpectedTokenAllowance(currency, remainingAllowance);
        _assertClaimSolvency(currency);
    }

    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId poolId = key.toId();
        _enforceRegistered(poolId);
        if (poolDecommissioned[poolId]) revert PoolIsDecommissioned(poolId);
        if (IStaticsSwapQuarantine(staticsDiamond).protocolPoolSwapsBlocked(poolId)) revert SwapsQuarantined(poolId);
        _routeDistribution(poolId, key.currency0);
        _routeDistribution(poolId, key.currency1);
        bool exactInput = params.amountSpecified < 0;
        EffectiveRate memory rate = _effectiveRate(poolId);
        uint16 feeBps = exactInput ? rate.inputFeeBps : rate.outputFeeBps;
        uint256 realized = _absolute(params.amountSpecified);
        uint256 charged = exactInput ? _feeFromGross(realized, feeBps) : _feeFromNet(realized, feeBps);
        if (charged == 0) return (IHooks.beforeSwap.selector, toBeforeSwapDelta(0, 0), 0);
        Currency specified = (params.zeroForOne == exactInput) ? key.currency0 : key.currency1;
        _accrueSwapLegFee(poolId, specified, realized, charged, true);
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(charged.toInt128(), 0), 0);
    }

    function _afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        PoolId poolId = key.toId();
        uint256 charged = _chargeUnspecifiedLeg(poolId, key, params, delta);
        _compound(key, poolId);
        return (IHooks.afterSwap.selector, charged.toInt128());
    }

    function _chargeUnspecifiedLeg(PoolId poolId, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta)
        private
        returns (uint256 charged)
    {
        bool exactInput = params.amountSpecified < 0;
        bool specifiedCurrencyIs0 = exactInput == params.zeroForOne;
        EffectiveRate memory rate = _effectiveRate(poolId);
        uint16 specifiedFeeBps = exactInput ? rate.inputFeeBps : rate.outputFeeBps;
        uint16 unspecifiedFeeBps = exactInput ? rate.outputFeeBps : rate.inputFeeBps;
        _enforceCompleteSpecifiedFill(
            params.amountSpecified,
            specifiedCurrencyIs0 ? delta.amount0() : delta.amount1(),
            specifiedFeeBps,
            exactInput
        );
        Currency unspecified = specifiedCurrencyIs0 ? key.currency1 : key.currency0;
        int128 unspecifiedDelta = specifiedCurrencyIs0 ? delta.amount1() : delta.amount0();
        uint256 realized = _absolute(int256(unspecifiedDelta));
        charged = exactInput ? _feeFromGross(realized, unspecifiedFeeBps) : _feeFromNet(realized, unspecifiedFeeBps);
        if (charged != 0) {
            _accrueSwapLegFee(poolId, unspecified, realized, charged, false);
        }
    }

    /// @dev Keep claim issuance and its matching liability allocation inseparable for both swap legs.
    function _accrueSwapLegFee(PoolId poolId, Currency currency, uint256 realized, uint256 charged, bool specifiedLeg)
        internal
    {
        _mintClaim(currency, charged);
        _allocate(poolId, currency, realized, charged, specifiedLeg);
    }

    function _enforceCompleteSpecifiedFill(
        int256 amountSpecified,
        int128 specifiedDelta,
        uint16 feeBps,
        bool exactInput
    ) private pure {
        uint256 specifiedFee = exactInput
            ? _feeFromGross(_absolute(amountSpecified), feeBps)
            : _feeFromNet(_absolute(amountSpecified), feeBps);
        int256 expectedSpecifiedDelta = amountSpecified + int256(specifiedFee);
        if (int256(specifiedDelta) != expectedSpecifiedDelta) {
            revert IncompleteSpecifiedFill(expectedSpecifiedDelta, int256(specifiedDelta));
        }
    }

    function _allocate(PoolId poolId, Currency currency, uint256 realized, uint256 charged, bool specifiedLeg) private {
        AllocationShares memory shares = _computeShares(poolId, currency, charged);
        polPending[poolId][currency] += shares.pol;
        FeeDistribution storage pending = distributions[poolId][currency];
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
            shares.basketStaker,
            shares.staticsStaker,
            shares.creator,
            shares.treasury
        );
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

    function _routeDistribution(PoolId poolId, Currency currency) private {
        FeeDistribution memory pending = _redeemDistribution(poolId, currency, address(this));
        uint256 total = _distributionTotal(pending);
        if (total == 0) return;
        IERC20 token = IERC20(Currency.unwrap(currency));
        uint256 beforeBalance = currency.balanceOfSelf();
        token.forceApprove(staticsDiamond, total);
        IStaticsProtocolRevenue(staticsDiamond)
            .routeProtocolSwapFees(
                poolId,
                Currency.unwrap(currency),
                IStaticsProtocolRevenue.ProtocolFeeDistribution({
                    basketStaker: pending.basketStaker,
                    staticsStaker: pending.staticsStaker,
                    creator: pending.creator,
                    treasury: pending.treasury
                })
            );
        uint256 afterBalance = currency.balanceOfSelf();
        _enforceExactDebit(currency, beforeBalance, afterBalance, total);
        uint256 remainingAllowance = token.allowance(address(this), staticsDiamond);
        if (remainingAllowance != 0) revert UnexpectedTokenAllowance(currency, remainingAllowance);
        _assertClaimSolvency(currency);
    }

    function _compound(PoolKey calldata key, PoolId poolId) private returns (uint128 liquidityAdded) {
        uint256 available0 = polPending[poolId][key.currency0];
        uint256 available1 = polPending[poolId][key.currency1];
        if (available0 == 0 || available1 == 0) return 0;
        CompoundPrepared memory prepared = _addPermanentLiquidity(key, poolId, available0, available1);
        if (prepared.liquidityAdded == 0) return 0;
        _recordNativeFees(poolId, key.currency0, prepared.fees0);
        _recordNativeFees(poolId, key.currency1, prepared.fees1);
        uint256 amount0 = _applyCompoundDelta(poolId, key.currency0, prepared.principal0, available0);
        uint256 amount1 = _applyCompoundDelta(poolId, key.currency1, prepared.principal1, available1);
        lockedLiquidity[poolId] += prepared.liquidityAdded;
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
        if (received != amount) revert IncompatiblePoolCurrency(currency, amount, received);
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
        uint256 staticsStakerToTreasury;
        if (pending.basketStaker != 0 && !IStaticsProtocolRevenue(staticsDiamond).canAccrueBasketRewards(poolId)) {
            basketStakerToPol = pending.basketStaker;
            pending.basketStaker = 0;
            polPending[poolId][currency] += basketStakerToPol;
        }
        if (
            pending.staticsStaker != 0
                && !IStaticsGlobalRewards(staticsDiamond).canAccrueStakerRewards(Currency.unwrap(currency))
        ) {
            staticsStakerToTreasury = pending.staticsStaker;
            pending.staticsStaker = 0;
            pending.treasury += staticsStakerToTreasury;
        }
        if (basketStakerToPol != 0 || staticsStakerToTreasury != 0) {
            emit PendingFeeDistributionReallocated(poolId, currency, basketStakerToPol, staticsStakerToTreasury);
        }
    }

    function _distributionTotal(FeeDistribution memory distribution) private pure returns (uint256) {
        return distribution.basketStaker + distribution.staticsStaker + distribution.creator + distribution.treasury;
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
        if (!registrations[poolId].registered) revert PoolNotRegistered(poolId);
    }

    function _enforceDiamond() private view {
        if (msg.sender != staticsDiamond) revert OnlyStaticsDiamond(msg.sender);
    }

    function permanentLiquidityMath() external view returns (IStaticsPermanentLiquidityMath) {
        return permanentLiquidityCalc;
    }
}
