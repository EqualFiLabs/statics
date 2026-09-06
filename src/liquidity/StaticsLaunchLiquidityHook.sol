// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IStaticsLaunchLiquidityHook} from "../interfaces/IStaticsLaunchLiquidityHook.sol";

/// @notice Standalone fee hook for temporary Statics launch pools.
/// @dev Each registered PoolKey selects its own static native LP fee and bilateral hook fees.
/// Hook fees route directly from PoolManager to a mutable receiver. Liquidity remains in ordinary,
/// externally owned PositionManager NFTs and can be managed without calling this hook.
contract StaticsLaunchLiquidityHook is BaseHook, IStaticsLaunchLiquidityHook, Ownable2Step {
    using LPFeeLibrary for uint24;
    using PoolIdLibrary for PoolKey;
    using SafeCast for uint256;

    uint16 public constant MAX_HOOK_FEE_BPS = 1_000;
    uint256 private constant BPS = 10_000;

    IPositionManager private immutable _positionManager;
    address public override feeReceiver;

    mapping(PoolId poolId => PoolRegistration registration) private registrations;

    error InvalidReceiver();
    error InvalidPositionManager(address positionManager);
    error InvalidPositionManagerBinding(address expected, address actual);
    error InvalidHook(address hook);
    error NativeCurrencyUnsupported();
    error InvalidCurrencyOrder(address currency0, address currency1);
    error DynamicNativeLpFeeUnsupported();
    error InvalidNativeLpFee(uint24 fee);
    error InvalidTickSpacing(int24 tickSpacing);
    error InvalidInitialPrice(uint160 sqrtPriceX96);
    error HookFeeTooLarge(uint16 feeBps);
    error PoolAlreadyRegistered(PoolId poolId);
    error PoolNotRegistered(PoolId poolId);
    error UnauthorizedInitializer(address sender);
    error InitialPriceMismatch(uint160 expected, uint160 actual);
    error IncompatiblePoolCurrency(Currency currency, uint256 requested, uint256 received);
    error UnexpectedTokenDebit(Currency currency, uint256 expected, uint256 actual);

    constructor(
        IPoolManager manager,
        IPositionManager positionManager_,
        address initialOwner,
        address initialFeeReceiver
    ) BaseHook(manager) Ownable(initialOwner) {
        if (address(positionManager_) == address(0) || address(positionManager_).code.length == 0) {
            revert InvalidPositionManager(address(positionManager_));
        }
        address boundManager = address(positionManager_.poolManager());
        if (boundManager != address(manager)) {
            revert InvalidPositionManagerBinding(address(manager), boundManager);
        }
        _enforceValidReceiver(initialFeeReceiver);
        _positionManager = positionManager_;
        feeReceiver = initialFeeReceiver;
    }

    function positionManager() external view override returns (address) {
        return address(_positionManager);
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory permissions) {
        permissions.afterInitialize = true;
        permissions.beforeSwap = true;
        permissions.beforeSwapReturnDelta = true;
        permissions.afterSwap = true;
        permissions.afterSwapReturnDelta = true;
    }

    function registerPool(PoolKey calldata key, uint160 expectedSqrtPriceX96, uint16 inputFeeBps, uint16 outputFeeBps)
        external
        override
        onlyOwner
        returns (PoolId poolId)
    {
        if (address(key.hooks) != address(this)) revert InvalidHook(address(key.hooks));
        address currency0 = Currency.unwrap(key.currency0);
        address currency1 = Currency.unwrap(key.currency1);
        if (currency0 == address(0) || currency1 == address(0)) revert NativeCurrencyUnsupported();
        if (currency0 >= currency1) revert InvalidCurrencyOrder(currency0, currency1);
        if (key.fee.isDynamicFee()) revert DynamicNativeLpFeeUnsupported();
        if (!key.fee.isValid()) revert InvalidNativeLpFee(key.fee);
        if (key.tickSpacing < TickMath.MIN_TICK_SPACING || key.tickSpacing > TickMath.MAX_TICK_SPACING) {
            revert InvalidTickSpacing(key.tickSpacing);
        }
        if (expectedSqrtPriceX96 < TickMath.MIN_SQRT_PRICE || expectedSqrtPriceX96 >= TickMath.MAX_SQRT_PRICE) {
            revert InvalidInitialPrice(expectedSqrtPriceX96);
        }
        _enforceHookFee(inputFeeBps);
        _enforceHookFee(outputFeeBps);

        poolId = key.toId();
        if (registrations[poolId].registered) revert PoolAlreadyRegistered(poolId);
        registrations[poolId] = PoolRegistration({
            currency0: key.currency0,
            currency1: key.currency1,
            nativeLpFee: key.fee,
            tickSpacing: key.tickSpacing,
            expectedSqrtPriceX96: expectedSqrtPriceX96,
            inputFeeBps: inputFeeBps,
            outputFeeBps: outputFeeBps,
            registered: true
        });
        emit PoolRegistered(
            poolId,
            key.currency0,
            key.currency1,
            key.fee,
            key.tickSpacing,
            expectedSqrtPriceX96,
            inputFeeBps,
            outputFeeBps
        );
    }

    function setHookFees(PoolId poolId, uint16 inputFeeBps, uint16 outputFeeBps) external override onlyOwner {
        PoolRegistration storage registration = registrations[poolId];
        if (!registration.registered) revert PoolNotRegistered(poolId);
        _enforceHookFee(inputFeeBps);
        _enforceHookFee(outputFeeBps);
        uint16 previousInputFeeBps = registration.inputFeeBps;
        uint16 previousOutputFeeBps = registration.outputFeeBps;
        registration.inputFeeBps = inputFeeBps;
        registration.outputFeeBps = outputFeeBps;
        emit HookFeesSet(poolId, previousInputFeeBps, inputFeeBps, previousOutputFeeBps, outputFeeBps);
    }

    function setFeeReceiver(address newReceiver) external override onlyOwner {
        _enforceValidReceiver(newReceiver);
        address previous = feeReceiver;
        feeReceiver = newReceiver;
        emit FeeReceiverSet(previous, newReceiver);
    }

    function poolRegistration(PoolId poolId) external view override returns (PoolRegistration memory registration) {
        return registrations[poolId];
    }

    function _afterInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96, int24)
        internal
        view
        override
        returns (bytes4)
    {
        PoolRegistration storage registration = _registration(key.toId());
        if (sender != address(_positionManager)) revert UnauthorizedInitializer(sender);
        if (sqrtPriceX96 != registration.expectedSqrtPriceX96) {
            revert InitialPriceMismatch(registration.expectedSqrtPriceX96, sqrtPriceX96);
        }
        return IHooks.afterInitialize.selector;
    }

    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId poolId = key.toId();
        PoolRegistration storage registration = _registration(poolId);
        bool exactInput = params.amountSpecified < 0;
        uint256 realized = _absolute(params.amountSpecified);
        uint16 feeBps = exactInput ? registration.inputFeeBps : registration.outputFeeBps;
        uint256 charged = Math.mulDiv(realized, feeBps, BPS, Math.Rounding.Ceil);
        if (charged == 0) return (IHooks.beforeSwap.selector, toBeforeSwapDelta(0, 0), 0);
        Currency specified = (params.zeroForOne == exactInput) ? key.currency0 : key.currency1;
        _routeFee(poolId, specified, realized, charged, true);
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(charged.toInt128(), 0), 0);
    }

    function _afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        PoolId poolId = key.toId();
        PoolRegistration storage registration = _registration(poolId);
        bool exactInput = params.amountSpecified < 0;
        bool specifiedCurrencyIs0 = exactInput == params.zeroForOne;
        Currency unspecified = specifiedCurrencyIs0 ? key.currency1 : key.currency0;
        int128 unspecifiedDelta = specifiedCurrencyIs0 ? delta.amount1() : delta.amount0();
        uint256 realized = _absolute(int256(unspecifiedDelta));
        uint16 feeBps = exactInput ? registration.outputFeeBps : registration.inputFeeBps;
        uint256 charged = Math.mulDiv(realized, feeBps, BPS, Math.Rounding.Ceil);
        if (charged != 0) _routeFee(poolId, unspecified, realized, charged, false);
        return (IHooks.afterSwap.selector, charged.toInt128());
    }

    function _routeFee(PoolId poolId, Currency currency, uint256 realized, uint256 charged, bool specifiedLeg) private {
        address receiver = feeReceiver;
        uint256 managerBefore = currency.balanceOf(address(poolManager));
        uint256 receiverBefore = currency.balanceOf(receiver);
        poolManager.take(currency, receiver, charged);
        uint256 managerAfter = currency.balanceOf(address(poolManager));
        uint256 receiverAfter = currency.balanceOf(receiver);
        uint256 debited = managerBefore >= managerAfter ? managerBefore - managerAfter : 0;
        if (debited != charged) revert UnexpectedTokenDebit(currency, charged, debited);
        uint256 received = receiverAfter >= receiverBefore ? receiverAfter - receiverBefore : 0;
        if (received != charged) revert IncompatiblePoolCurrency(currency, charged, received);
        emit SwapLegFeeRouted(poolId, currency, specifiedLeg, realized, charged, receiver);
    }

    function _registration(PoolId poolId) private view returns (PoolRegistration storage registration) {
        registration = registrations[poolId];
        if (!registration.registered) revert PoolNotRegistered(poolId);
    }

    function _enforceValidReceiver(address receiver) private view {
        if (receiver == address(0) || receiver == address(this) || receiver == address(poolManager)) {
            revert InvalidReceiver();
        }
    }

    function _enforceHookFee(uint16 feeBps) private pure {
        if (feeBps > MAX_HOOK_FEE_BPS) revert HookFeeTooLarge(feeBps);
    }

    function _absolute(int256 value) private pure returns (uint256) {
        return value < 0 ? uint256(-(value + 1)) + 1 : uint256(value);
    }
}
