// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
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
import {IStaticsLaunchLiquidityHook} from "../interfaces/IStaticsLaunchLiquidityHook.sol";

/// @notice Standalone temporary hook for the pre-protocol WETH/STATICS launch pool.
/// @dev The hook has no Diamond dependency. Ordinary v4 positions remain user-owned and use the
/// pool's native 30-bps fee. The hook charges a separate bilateral 50-bps fee, sends 60% to the
/// fee receiver, and compounds 40% into its own full-range position. Native LP fees earned by that
/// position are harvested to the fee receiver and are never compounded.
contract StaticsLaunchLiquidityHook is BaseHook, IStaticsLaunchLiquidityHook, IUnlockCallback, Ownable2Step {
    using PoolIdLibrary for PoolKey;
    using SafeCast for uint256;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    using SafeERC20 for IERC20;

    uint24 public constant NATIVE_LP_FEE = 3_000;
    uint16 public constant INPUT_FEE_BPS = 50;
    uint16 public constant OUTPUT_FEE_BPS = 50;
    uint16 public constant POL_SHARE_BPS = 4_000;
    uint256 private constant BPS = 10_000;

    uint8 private constant UNLOCK_SEED = 1;
    uint8 private constant UNLOCK_COMPOUND = 2;
    uint8 private constant UNLOCK_HARVEST = 3;
    uint8 private constant UNLOCK_RELEASE = 4;
    bytes32 private constant PROTOCOL_LIQUIDITY_SALT = keccak256("statics.launch.protocol.liquidity");

    struct SeedRequest {
        PoolKey key;
        address payer;
        uint128 liquidity;
        uint256 amount0Max;
        uint256 amount1Max;
    }

    struct LiquidityResult {
        uint256 principal0;
        uint256 principal1;
        uint256 fees0;
        uint256 fees1;
    }

    address public override feeReceiver;
    address public override liquidityReceiver;
    address public override liquidityAdmin;

    mapping(PoolId poolId => PoolRegistration registration) private registrations;
    mapping(PoolId poolId => mapping(Currency currency => uint256 amount)) private polPending;
    mapping(Currency currency => uint256 amount) private totalPending;
    mapping(PoolId poolId => uint128 liquidity) private lockedLiquidity;

    error OnlyLiquidityAdmin(address caller);
    error InvalidReceiver();
    error InvalidLiquidityAdmin();
    error InvalidHook(address hook);
    error NativeCurrencyUnsupported();
    error InvalidNativeLpFee(uint24 fee);
    error PoolAlreadyRegistered(PoolId poolId);
    error PoolNotRegistered(PoolId poolId);
    error PoolIsRetired(PoolId poolId);
    error InvalidUnlockCaller(address caller);
    error InvalidUnlockAction(uint8 action);
    error EmptyLiquiditySeed();
    error ProtocolLiquidityAlreadySeeded(PoolId poolId);
    error LiquidityAmountExceeded(Currency currency, uint256 required, uint256 maximum);
    error ProtocolLiquidityExceedsPending(Currency currency, uint256 required, uint256 available);
    error UnexpectedPrincipalDelta(int256 amount0, int256 amount1);
    error UnexpectedFeeDelta(int128 amount0, int128 amount1);
    error UnexpectedCurrencyDelta(Currency currency, int256 delta);
    error IncompatiblePoolCurrency(Currency currency, uint256 requested, uint256 received);
    error UnexpectedTokenDebit(Currency currency, uint256 expected, uint256 actual);
    error UnexpectedSettlement(Currency currency, uint256 expected, uint256 actual);
    error PendingLiquidityInsolvent(Currency currency, uint256 required, uint256 available);

    constructor(
        IPoolManager manager,
        address initialOwner,
        address initialFeeReceiver,
        address initialLiquidityReceiver,
        address initialLiquidityAdmin
    ) BaseHook(manager) Ownable(initialOwner) {
        _enforceValidReceiver(initialFeeReceiver);
        _enforceValidReceiver(initialLiquidityReceiver);
        _enforceValidLiquidityAdmin(initialLiquidityAdmin);
        feeReceiver = initialFeeReceiver;
        liquidityReceiver = initialLiquidityReceiver;
        liquidityAdmin = initialLiquidityAdmin;
    }

    modifier onlyLiquidityAdmin() {
        if (msg.sender != liquidityAdmin) revert OnlyLiquidityAdmin(msg.sender);
        _;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory permissions) {
        permissions.afterInitialize = true;
        permissions.beforeSwap = true;
        permissions.beforeSwapReturnDelta = true;
        permissions.afterSwap = true;
        permissions.afterSwapReturnDelta = true;
    }

    function setFeeReceiver(address newReceiver) external override onlyOwner {
        _enforceValidReceiver(newReceiver);
        address previous = feeReceiver;
        feeReceiver = newReceiver;
        emit FeeReceiverSet(previous, newReceiver);
    }

    function setLiquidityReceiver(address newReceiver) external override onlyOwner {
        _enforceValidReceiver(newReceiver);
        address previous = liquidityReceiver;
        liquidityReceiver = newReceiver;
        emit LiquidityReceiverSet(previous, newReceiver);
    }

    function setLiquidityAdmin(address newAdmin) external override onlyOwner {
        _enforceValidLiquidityAdmin(newAdmin);
        address previous = liquidityAdmin;
        liquidityAdmin = newAdmin;
        emit LiquidityAdminSet(previous, newAdmin);
    }

    /// @dev Registration is written before initialize so the hook callback rejects initialization
    /// squatting while this function remains atomic if PoolManager initialization fails.
    function registerAndInitialize(PoolKey calldata key, uint160 sqrtPriceX96)
        external
        override
        onlyLiquidityAdmin
        returns (PoolId poolId)
    {
        if (address(key.hooks) != address(this)) revert InvalidHook(address(key.hooks));
        if (key.currency0.isAddressZero() || key.currency1.isAddressZero()) revert NativeCurrencyUnsupported();
        if (key.fee != NATIVE_LP_FEE) revert InvalidNativeLpFee(key.fee);
        poolId = key.toId();
        if (registrations[poolId].registered) revert PoolAlreadyRegistered(poolId);
        registrations[poolId] = PoolRegistration({
            currency0: key.currency0,
            currency1: key.currency1,
            tickSpacing: key.tickSpacing,
            registered: true,
            retired: false
        });
        poolManager.initialize(key, sqrtPriceX96);
        emit PoolRegistered(poolId, key.currency0, key.currency1);
    }

    function poolRegistration(PoolId poolId) external view override returns (PoolRegistration memory registration) {
        return registrations[poolId];
    }

    function pendingPOL(PoolId poolId, Currency currency) external view override returns (uint256 amount) {
        return polPending[poolId][currency];
    }

    function polLiquidity(PoolId poolId) external view override returns (uint128 liquidity) {
        return lockedLiquidity[poolId];
    }

    function totalPendingPOL(Currency currency) external view override returns (uint256 amount) {
        return totalPending[currency];
    }

    function seedPOL(PoolKey calldata key, uint128 liquidity, uint256 amount0Max, uint256 amount1Max)
        external
        override
        onlyLiquidityAdmin
        returns (uint256 amount0, uint256 amount1)
    {
        PoolId poolId = key.toId();
        _enforceActive(poolId);
        if (liquidity == 0) revert EmptyLiquiditySeed();
        if (lockedLiquidity[poolId] != 0) revert ProtocolLiquidityAlreadySeeded(poolId);
        bytes memory result = poolManager.unlock(
            abi.encode(
                UNLOCK_SEED,
                abi.encode(
                    SeedRequest({
                        key: key,
                        payer: msg.sender,
                        liquidity: liquidity,
                        amount0Max: amount0Max,
                        amount1Max: amount1Max
                    })
                )
            )
        );
        (amount0, amount1) = abi.decode(result, (uint256, uint256));
        emit ProtocolLiquiditySeeded(poolId, liquidity, amount0, amount1);
    }

    function compoundPOL(PoolKey calldata key) external override returns (uint128 liquidityAdded) {
        PoolId poolId = key.toId();
        _enforceActive(poolId);
        return abi.decode(poolManager.unlock(abi.encode(UNLOCK_COMPOUND, abi.encode(key))), (uint128));
    }

    function harvestPOLFees(PoolKey calldata key) external override returns (uint256 amount0, uint256 amount1) {
        PoolId poolId = key.toId();
        _enforceRegistered(poolId);
        if (lockedLiquidity[poolId] == 0) return (0, 0);
        return abi.decode(poolManager.unlock(abi.encode(UNLOCK_HARVEST, abi.encode(key))), (uint256, uint256));
    }

    function retireAndReleasePOL(PoolKey calldata key)
        external
        override
        onlyLiquidityAdmin
        returns (uint256 principal0, uint256 principal1, uint256 pending0, uint256 pending1)
    {
        PoolId poolId = key.toId();
        _enforceActive(poolId);
        uint128 liquidity = lockedLiquidity[poolId];
        registrations[poolId].retired = true;
        (principal0, principal1) =
            abi.decode(poolManager.unlock(abi.encode(UNLOCK_RELEASE, abi.encode(key))), (uint256, uint256));

        pending0 = _releasePending(poolId, key.currency0);
        pending1 = _releasePending(poolId, key.currency1);
        emit ProtocolLiquidityReleased(poolId, liquidityReceiver, liquidity, principal0, principal1, pending0, pending1);
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert InvalidUnlockCaller(msg.sender);
        (uint8 action, bytes memory payload) = abi.decode(data, (uint8, bytes));
        if (action == UNLOCK_SEED) return _seed(abi.decode(payload, (SeedRequest)));
        PoolKey memory key = abi.decode(payload, (PoolKey));
        if (action == UNLOCK_COMPOUND) return abi.encode(_compound(key, key.toId()));
        if (action == UNLOCK_HARVEST) return _harvest(key, key.toId());
        if (action == UNLOCK_RELEASE) return _release(key, key.toId());
        revert InvalidUnlockAction(action);
    }

    function _afterInitialize(address, PoolKey calldata key, uint160, int24) internal view override returns (bytes4) {
        _enforceRegistered(key.toId());
        return IHooks.afterInitialize.selector;
    }

    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId poolId = key.toId();
        _enforceRegistered(poolId);
        bool exactInput = params.amountSpecified < 0;
        uint256 realized = _absolute(params.amountSpecified);
        uint256 charged = Math.mulDiv(realized, exactInput ? INPUT_FEE_BPS : OUTPUT_FEE_BPS, BPS, Math.Rounding.Ceil);
        if (charged == 0) return (IHooks.beforeSwap.selector, toBeforeSwapDelta(0, 0), 0);
        Currency specified = (params.zeroForOne == exactInput) ? key.currency0 : key.currency1;
        _allocateFee(poolId, specified, realized, charged, true);
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
        uint256 charged = Math.mulDiv(realized, exactInput ? OUTPUT_FEE_BPS : INPUT_FEE_BPS, BPS, Math.Rounding.Ceil);
        if (charged != 0) _allocateFee(poolId, unspecified, realized, charged, false);
        if (!registrations[poolId].retired) _compound(key, poolId);
        return (IHooks.afterSwap.selector, charged.toInt128());
    }

    function _allocateFee(PoolId poolId, Currency currency, uint256 realized, uint256 charged, bool specifiedLeg)
        private
    {
        uint256 polAmount;
        if (!registrations[poolId].retired) {
            polAmount = Math.mulDiv(charged, POL_SHARE_BPS, BPS);
            if (polAmount != 0) {
                _takeExact(currency, address(this), polAmount);
                polPending[poolId][currency] += polAmount;
                totalPending[currency] += polAmount;
            }
        }
        uint256 receiverAmount = charged - polAmount;
        _takeExact(currency, feeReceiver, receiverAmount);
        _assertPendingSolvency(currency);
        emit SwapLegFeeAccrued(poolId, currency, specifiedLeg, realized, charged, receiverAmount, polAmount);
    }

    function _seed(SeedRequest memory request) private returns (bytes memory) {
        PoolId poolId = request.key.toId();
        LiquidityResult memory result = _modify(request.key, int256(uint256(request.liquidity)));
        if (result.principal0 > request.amount0Max) {
            revert LiquidityAmountExceeded(request.key.currency0, result.principal0, request.amount0Max);
        }
        if (result.principal1 > request.amount1Max) {
            revert LiquidityAmountExceeded(request.key.currency1, result.principal1, request.amount1Max);
        }
        _routeNativeFees(request.key, result);
        _settleFrom(request.key.currency0, request.payer, result.principal0);
        _settleFrom(request.key.currency1, request.payer, result.principal1);
        lockedLiquidity[poolId] = request.liquidity;
        _assertSettled(request.key);
        return abi.encode(result.principal0, result.principal1);
    }

    function _compound(PoolKey memory key, PoolId poolId) private returns (uint128 liquidityAdded) {
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
        LiquidityResult memory result = _modify(key, int256(uint256(liquidityAdded)));
        _routeNativeFees(key, result);
        _consumePending(poolId, key.currency0, result.principal0, available0);
        _consumePending(poolId, key.currency1, result.principal1, available1);
        lockedLiquidity[poolId] += liquidityAdded;
        _emitCompound(poolId, key, liquidityAdded, result);
    }

    function _emitCompound(PoolId poolId, PoolKey memory key, uint128 liquidityAdded, LiquidityResult memory result)
        private
    {
        emit ProtocolLiquidityCompounded(
            poolId,
            liquidityAdded,
            result.principal0,
            result.principal1,
            polPending[poolId][key.currency0],
            polPending[poolId][key.currency1]
        );
    }

    function _harvest(PoolKey memory key, PoolId poolId) private returns (bytes memory) {
        LiquidityResult memory result = _modify(key, 0);
        _routeNativeFees(key, result);
        _assertSettled(key);
        emit ProtocolLiquidityFeesHarvested(poolId, result.fees0, result.fees1);
        return abi.encode(result.fees0, result.fees1);
    }

    function _release(PoolKey memory key, PoolId poolId) private returns (bytes memory) {
        uint128 liquidity = lockedLiquidity[poolId];
        if (liquidity == 0) return abi.encode(uint256(0), uint256(0));
        LiquidityResult memory result = _modify(key, -int256(uint256(liquidity)));
        _routeNativeFees(key, result);
        _takeExact(key.currency0, liquidityReceiver, result.principal0);
        _takeExact(key.currency1, liquidityReceiver, result.principal1);
        lockedLiquidity[poolId] = 0;
        _assertSettled(key);
        return abi.encode(result.principal0, result.principal1);
    }

    function _modify(PoolKey memory key, int256 liquidityDelta) private returns (LiquidityResult memory result) {
        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: TickMath.minUsableTick(key.tickSpacing),
            tickUpper: TickMath.maxUsableTick(key.tickSpacing),
            liquidityDelta: liquidityDelta,
            salt: PROTOCOL_LIQUIDITY_SALT
        });
        (BalanceDelta callerDelta, BalanceDelta feesAccrued) = poolManager.modifyLiquidity(key, params, "");
        if (feesAccrued.amount0() < 0 || feesAccrued.amount1() < 0) {
            revert UnexpectedFeeDelta(feesAccrued.amount0(), feesAccrued.amount1());
        }
        int256 principal0 = int256(callerDelta.amount0()) - int256(feesAccrued.amount0());
        int256 principal1 = int256(callerDelta.amount1()) - int256(feesAccrued.amount1());
        if (liquidityDelta >= 0) {
            if (principal0 > 0 || principal1 > 0) revert UnexpectedPrincipalDelta(principal0, principal1);
            result.principal0 = _absolute(principal0);
            result.principal1 = _absolute(principal1);
        } else {
            if (principal0 < 0 || principal1 < 0) revert UnexpectedPrincipalDelta(principal0, principal1);
            result.principal0 = uint256(principal0);
            result.principal1 = uint256(principal1);
        }
        result.fees0 = uint256(uint128(feesAccrued.amount0()));
        result.fees1 = uint256(uint128(feesAccrued.amount1()));
    }

    function _routeNativeFees(PoolKey memory key, LiquidityResult memory result) private {
        _takeExact(key.currency0, feeReceiver, result.fees0);
        _takeExact(key.currency1, feeReceiver, result.fees1);
    }

    function _consumePending(PoolId poolId, Currency currency, uint256 amount, uint256 available) private {
        if (amount > available) revert ProtocolLiquidityExceedsPending(currency, amount, available);
        polPending[poolId][currency] = available - amount;
        totalPending[currency] -= amount;
        _settleFrom(currency, address(this), amount);
        _assertPendingSolvency(currency);
    }

    function _releasePending(PoolId poolId, Currency currency) private returns (uint256 amount) {
        amount = polPending[poolId][currency];
        if (amount == 0) return 0;
        polPending[poolId][currency] = 0;
        totalPending[currency] -= amount;
        _transferExact(currency, liquidityReceiver, amount);
        _assertPendingSolvency(currency);
    }

    function _settleFrom(Currency currency, address payer, uint256 amount) private {
        if (amount == 0) return;
        poolManager.sync(currency);
        uint256 payerBefore = currency.balanceOf(payer);
        uint256 managerBefore = currency.balanceOf(address(poolManager));
        IERC20 token = IERC20(Currency.unwrap(currency));
        if (payer == address(this)) {
            token.safeTransfer(address(poolManager), amount);
        } else {
            token.safeTransferFrom(payer, address(poolManager), amount);
        }
        uint256 payerAfter = currency.balanceOf(payer);
        uint256 managerAfter = currency.balanceOf(address(poolManager));
        _enforceExactDebit(currency, payerBefore, payerAfter, amount);
        uint256 received = managerAfter >= managerBefore ? managerAfter - managerBefore : 0;
        if (received != amount) revert IncompatiblePoolCurrency(currency, amount, received);
        uint256 settled = poolManager.settle();
        if (settled != amount) revert UnexpectedSettlement(currency, amount, settled);
    }

    function _takeExact(Currency currency, address receiver, uint256 amount) private {
        if (amount == 0) return;
        uint256 managerBefore = currency.balanceOf(address(poolManager));
        uint256 receiverBefore = currency.balanceOf(receiver);
        poolManager.take(currency, receiver, amount);
        uint256 managerAfter = currency.balanceOf(address(poolManager));
        uint256 receiverAfter = currency.balanceOf(receiver);
        _enforceExactDebit(currency, managerBefore, managerAfter, amount);
        uint256 received = receiverAfter >= receiverBefore ? receiverAfter - receiverBefore : 0;
        if (received != amount) revert IncompatiblePoolCurrency(currency, amount, received);
    }

    function _transferExact(Currency currency, address receiver, uint256 amount) private {
        uint256 senderBefore = currency.balanceOf(address(this));
        uint256 receiverBefore = currency.balanceOf(receiver);
        IERC20(Currency.unwrap(currency)).safeTransfer(receiver, amount);
        uint256 senderAfter = currency.balanceOf(address(this));
        uint256 receiverAfter = currency.balanceOf(receiver);
        _enforceExactDebit(currency, senderBefore, senderAfter, amount);
        uint256 received = receiverAfter >= receiverBefore ? receiverAfter - receiverBefore : 0;
        if (received != amount) revert IncompatiblePoolCurrency(currency, amount, received);
    }

    function _assertSettled(PoolKey memory key) private view {
        int256 delta0 = poolManager.currencyDelta(address(this), key.currency0);
        int256 delta1 = poolManager.currencyDelta(address(this), key.currency1);
        if (delta0 != 0) revert UnexpectedCurrencyDelta(key.currency0, delta0);
        if (delta1 != 0) revert UnexpectedCurrencyDelta(key.currency1, delta1);
    }

    function _assertPendingSolvency(Currency currency) private view {
        uint256 required = totalPending[currency];
        uint256 available = currency.balanceOf(address(this));
        if (available < required) revert PendingLiquidityInsolvent(currency, required, available);
    }

    function _enforceExactDebit(Currency currency, uint256 beforeBalance, uint256 afterBalance, uint256 expected)
        private
        pure
    {
        uint256 actual = beforeBalance >= afterBalance ? beforeBalance - afterBalance : 0;
        if (actual != expected) revert UnexpectedTokenDebit(currency, expected, actual);
    }

    function _enforceRegistered(PoolId poolId) private view {
        if (!registrations[poolId].registered) revert PoolNotRegistered(poolId);
    }

    function _enforceValidReceiver(address receiver) private view {
        if (receiver == address(0) || receiver == address(this) || receiver == address(poolManager)) {
            revert InvalidReceiver();
        }
    }

    function _enforceValidLiquidityAdmin(address admin) private view {
        if (admin == address(0) || admin == address(this) || admin == address(poolManager)) {
            revert InvalidLiquidityAdmin();
        }
    }

    function _enforceActive(PoolId poolId) private view {
        _enforceRegistered(poolId);
        if (registrations[poolId].retired) revert PoolIsRetired(poolId);
    }

    function _absolute(int256 value) private pure returns (uint256) {
        return value < 0 ? uint256(-(value + 1)) + 1 : uint256(value);
    }
}
