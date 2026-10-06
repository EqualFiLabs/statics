// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IStaticsGlobalRewards} from "../interfaces/IStaticsGlobalRewards.sol";
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
/// Diamond maintenance calls settle revenue, staker rewards, and protocol-owned liquidity inventory.
contract StaticsSwapFeeHook is BaseHook, IStaticsSwapFeeHook, IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using SafeCast for uint256;

    uint256 private constant BPS = 10_000;
    uint256 private constant CREATOR_SHARE_BPS = LibProtocolPoolFee.CREATOR_SHARE_BPS;
    uint8 private constant UNLOCK_SETTLE = 1;
    uint8 private constant UNLOCK_STAKER = 2;
    uint8 private constant UNLOCK_POL = 3;
    uint8 private constant MARKET_FLAG_ZERO_FOR_ONE = 1 << 0;
    uint8 private constant MARKET_FLAG_EXACT_OUTPUT = 1 << 1;
    bytes32 private constant SPECIFIED_STAKER_SLOT_DOMAIN = keccak256("statics.swap.specified.staker.v1");

    struct SettleRequest {
        PoolKey key;
        Currency currency;
        address receiver;
    }

    struct PolSettleRequest {
        PoolId poolId;
        Currency currency;
        address receiver;
        uint256 amount;
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
    mapping(PoolId poolId => bool decommissioned) public poolDecommissioned;

    error OnlyStaticsDiamond(address caller);
    error InvalidFeeRate();
    error InvalidAllocation();
    error PoolAlreadyRegistered();
    error PoolNotRegistered();
    error InvalidPoolKind();
    error InvalidCreator();
    error PoolIsDecommissioned();
    error NativeCurrencyUnsupported();
    error IncompatiblePoolCurrency();
    error UnexpectedTokenDebit(Currency currency, uint256 expected, uint256 actual);
    error ClaimLiabilityInsolvent(Currency currency, uint256 required, uint256 available);
    error AmountExceedsPending(Currency currency, uint256 required, uint256 available);
    error InvalidSettlementReceiver();
    error InvalidUnlockCaller(address caller);
    error CanonicalPoolDonationForbidden();
    error IncompleteSpecifiedFill();
    error InvalidNativeLpFee();
    error SwapsQuarantined(PoolId poolId);
    error InvalidSettlementCurrency(Currency currency);

    constructor(IPoolManager manager, address diamond, uint16 inputFeeBps, uint16 outputFeeBps) BaseHook(manager) {
        staticsDiamond = diamond;
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

    function getHookPermissions() public pure virtual override returns (Hooks.Permissions memory permissions) {
        permissions.afterInitialize = true;
        permissions.beforeSwap = true;
        permissions.beforeSwapReturnDelta = true;
        permissions.afterSwap = true;
        permissions.afterSwapReturnDelta = true;
        permissions.beforeDonate = true;
    }

    /// @dev Registration must precede initialization so a third party cannot squat a predictable canonical PoolKey.
    function _afterInitialize(address, PoolKey calldata key, uint160, int24)
        internal
        view
        virtual
        override
        returns (bytes4)
    {
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
        return _defaultFeeRate();
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
        (uint16 inputFeeBps, uint16 outputFeeBps) = _defaultFeeRate();
        emit PoolFeeRateSet(poolId, inputFeeBps, outputFeeBps, false);
    }

    function poolFeeRate(PoolId poolId) external view returns (PoolFeeRate memory rate) {
        _enforceRegistered(poolId);
        PoolFeeRate storage stored = poolRates[poolId];
        if (stored.overridden) return stored;
        (uint16 inputFeeBps, uint16 outputFeeBps) = _defaultFeeRate();
        return PoolFeeRate({inputFeeBps: inputFeeBps, outputFeeBps: outputFeeBps, overridden: false});
    }

    // --- Allocation profile administration ---

    function basketFeeAllocation() external view returns (BasketFeeAllocation memory allocation) {
        return _basketFeeAllocation();
    }

    function generalFeeAllocation() external view returns (GeneralFeeAllocation memory allocation) {
        return _generalFeeAllocation();
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

    function registerPool(PoolKey calldata key, PoolKind kind, address creator)
        external
        virtual
        returns (PoolId poolId)
    {
        _enforceDiamond();
        return _registerPool(key, kind, creator);
    }

    function _registerPool(PoolKey memory key, PoolKind kind, address creator) internal returns (PoolId poolId) {
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

    function pendingProtocolPol(PoolId poolId, Currency currency) external view returns (uint256 amount) {
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

    function settleFeeDistribution(PoolKey calldata key, Currency currency, address receiver)
        external
        returns (FeeDistribution memory distribution)
    {
        _enforceDiamond();
        PoolId poolId = key.toId();
        _enforceRegistered(poolId);
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
        if (receiver == address(0)) revert InvalidSettlementReceiver();
        uint256 pending = stakerPending[currency];
        if (amount > pending) revert AmountExceedsPending(currency, amount, pending);
        if (amount == 0) return 0;
        poolManager.unlock(abi.encode(UNLOCK_STAKER, abi.encode(currency, receiver, amount)));
        return amount;
    }

    function settleProtocolPol(PoolKey calldata key, Currency currency, address receiver, uint256 maximumAmount)
        external
        returns (uint256 amount)
    {
        _enforceDiamond();
        if (receiver == address(0)) revert InvalidSettlementReceiver();
        PoolId poolId = key.toId();
        _enforceRegistered(poolId);
        address rawCurrency = Currency.unwrap(currency);
        if (rawCurrency != Currency.unwrap(key.currency0) && rawCurrency != Currency.unwrap(key.currency1)) {
            revert InvalidSettlementCurrency(currency);
        }
        uint256 pending = polPending[poolId][currency];
        amount = maximumAmount < pending ? maximumAmount : pending;
        if (amount == 0) return 0;
        poolManager.unlock(
            abi.encode(
                UNLOCK_POL,
                abi.encode(PolSettleRequest({poolId: poolId, currency: currency, receiver: receiver, amount: amount}))
            )
        );
        emit ProtocolPolSettled(poolId, currency, receiver, amount);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert InvalidUnlockCaller(msg.sender);
        (uint8 action, bytes memory payload) = abi.decode(data, (uint8, bytes));
        if (action == UNLOCK_SETTLE) {
            return _settleFeeDistribution(abi.decode(payload, (SettleRequest)));
        }
        if (action == UNLOCK_STAKER) {
            (Currency currency, address receiver, uint256 amount) = abi.decode(payload, (Currency, address, uint256));
            stakerPending[currency] -= amount;
            _redeemClaims(currency, receiver, amount);
            return "";
        }
        if (action != UNLOCK_POL) revert();
        PolSettleRequest memory request = abi.decode(payload, (PolSettleRequest));
        polPending[request.poolId][request.currency] -= request.amount;
        _redeemClaims(request.currency, request.receiver, request.amount);
        return "";
    }

    function _settleFeeDistribution(SettleRequest memory request) private returns (bytes memory) {
        return abi.encode(_redeemDistribution(request.key.toId(), request.currency, request.receiver));
    }

    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        virtual
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
    ) internal virtual {
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
        (bool polActivated, bool polOverridden, uint16 polOverrideBps) =
            IStaticsProtocolRevenue(staticsDiamond).protocolPolFundingConfig(poolId);
        if (kind == PoolKind.BasketCanonical) {
            BasketFeeAllocation memory a = _basketFeeAllocation();
            uint16 polShareBps = _effectivePolShare(kind, polActivated, polOverridden, polOverrideBps);
            shares.pol = Math.mulDiv(charged, polShareBps, BPS);
            shares.basketStaker = Math.mulDiv(charged, a.basketStakerShareBps, BPS);
            shares.staticsStaker = Math.mulDiv(charged, a.staticsStakerShareBps, BPS);
        } else {
            GeneralFeeAllocation memory a = _generalFeeAllocation();
            uint16 polShareBps = _effectivePolShare(kind, polActivated, polOverridden, polOverrideBps);
            shares.pol = Math.mulDiv(charged, polShareBps, BPS);
            shares.basketStaker = 0;
            shares.staticsStaker = Math.mulDiv(charged, a.staticsStakerShareBps, BPS);
        }
        shares.treasury = charged - shares.pol - shares.basketStaker - shares.staticsStaker - shares.creator;

        if (shares.basketStaker != 0 && !_canAccrueBasketRewards(poolId, currency)) {
            if (_effectivePolShare(kind, polActivated, polOverridden, polOverrideBps) != 0) {
                shares.pol += shares.basketStaker;
            } else {
                shares.treasury += shares.basketStaker;
            }
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
        (uint16 inputFeeBps, uint16 outputFeeBps) = _defaultFeeRate();
        return EffectiveRate({inputFeeBps: inputFeeBps, outputFeeBps: outputFeeBps});
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
        _beforeClaimTransfer(currency, receiver, amount);
        _takeExact(currency, receiver, amount);
    }

    function _beforeClaimTransfer(Currency, address, uint256) internal virtual {}

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
    /// routing boundary. Apply the same documented fallback again without changing the aggregate
    /// claim liability. Basket rewards become POL only while POL funding remains active, otherwise
    /// they become treasury revenue.
    function _canAccrueBasketRewards(PoolId poolId, Currency) internal view virtual returns (bool) {
        return IStaticsProtocolRevenue(staticsDiamond).canAccrueBasketRewards(poolId);
    }

    function _normalizePendingDistribution(PoolId poolId, Currency currency) private {
        FeeDistribution storage pending = distributions[poolId][currency];
        uint256 basketStakerToPol;
        uint256 basketStakerToTreasury;
        if (pending.basketStaker != 0 && !_canAccrueBasketRewards(poolId, currency)) {
            (bool activated, bool overridden, uint16 overrideBps) =
                IStaticsProtocolRevenue(staticsDiamond).protocolPolFundingConfig(poolId);
            uint16 polShareBps = _effectivePolShare(registrations[poolId].kind, activated, overridden, overrideBps);
            if (activated && polShareBps != 0) {
                basketStakerToPol = pending.basketStaker;
                polPending[poolId][currency] += basketStakerToPol;
            } else {
                basketStakerToTreasury = pending.basketStaker;
                pending.treasury += basketStakerToTreasury;
            }
            pending.basketStaker = 0;
        }
        if (basketStakerToPol != 0 || basketStakerToTreasury != 0) {
            emit PendingFeeDistributionReallocated(poolId, currency, basketStakerToPol, basketStakerToTreasury);
        }
    }

    /// @dev A per-pool override is an absolute desired POL share. A later global profile change can
    /// reduce the POL-plus-Treasury bucket without iterating every pool, so cap the effective share
    /// at the bucket available under the current profile. This preserves swap liveness while the
    /// current global profile continues to fix every non-POL share.
    function _effectivePolShare(PoolKind kind, bool activated, bool overridden, uint16 overrideBps)
        private
        view
        returns (uint16 shareBps)
    {
        if (!activated) return 0;
        uint16 availableBps;
        if (kind == PoolKind.BasketCanonical) {
            BasketFeeAllocation memory allocation = _basketFeeAllocation();
            if (!overridden) return allocation.polShareBps;
            availableBps = allocation.polShareBps + allocation.treasuryShareBps;
        } else {
            GeneralFeeAllocation memory allocation = _generalFeeAllocation();
            if (!overridden) return allocation.polShareBps;
            availableBps = allocation.polShareBps + allocation.treasuryShareBps;
        }
        return overrideBps < availableBps ? overrideBps : availableBps;
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

    function _defaultFeeRate() internal view virtual returns (uint16 inputFeeBps, uint16 outputFeeBps) {
        return (defaultInputFeeBps, defaultOutputFeeBps);
    }

    function _basketFeeAllocation() internal view virtual returns (BasketFeeAllocation memory) {
        return basketAllocation;
    }

    function _generalFeeAllocation() internal view virtual returns (GeneralFeeAllocation memory) {
        return generalAllocation;
    }

    function _enforceRegistered(PoolId poolId) internal view virtual {
        if (!registrations[poolId].registered) revert PoolNotRegistered();
    }

    function _enforceDiamond() private view {
        if (msg.sender != staticsDiamond) revert OnlyStaticsDiamond(msg.sender);
    }
}
