// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
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
/// Hook fees accrue as PoolManager ERC-6909 claims to a mutable receiver. Liquidity remains in
/// ordinary, externally owned PositionManager NFTs and can be managed without calling this hook.
contract StaticsLaunchLiquidityHook is BaseHook, IStaticsLaunchLiquidityHook, Ownable2Step {
    using LPFeeLibrary for uint24;
    using PoolIdLibrary for PoolKey;
    using SafeCast for uint256;

    uint16 public constant MAX_HOOK_FEE_BPS = 1_000;
    uint256 private constant BPS = 10_000;
    bytes32 private constant TIMELOCK_PROPOSER_ROLE = keccak256("PROPOSER_ROLE");

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
    error UnauthorizedPoolRegistration(address sender);
    error InvalidLaunchOperator(address launchOperator);
    error UnauthorizedInitializer(address sender);
    error UnauthorizedActivator(address sender);
    error PoolNotInitialized(PoolId poolId);
    error PoolAlreadyActive(PoolId poolId);
    error PoolNotActive(PoolId poolId);
    error InitialPriceMismatch(uint160 expected, uint160 actual);
    error IncompleteSpecifiedFill(int256 expected, int256 actual);
    error OwnershipRenunciationDisabled();

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
        _positionManager = positionManager_;
        _enforceValidReceiver(initialFeeReceiver);
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

    function registerPool(
        PoolKey calldata key,
        uint160 expectedSqrtPriceX96,
        uint16 inputFeeBps,
        uint16 outputFeeBps,
        address launchOperator
    ) external override returns (PoolId poolId) {
        _checkPoolRegistrationAuthority();
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
        _enforceValidLaunchOperator(launchOperator);

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
            launchOperator: launchOperator,
            initialized: false,
            active: false,
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
            outputFeeBps,
            launchOperator
        );
    }

    function activatePool(PoolId poolId) external override {
        _activatePool(poolId);
    }

    function _activatePool(PoolId poolId) internal {
        PoolRegistration storage registration = _registration(poolId);
        if (msg.sender != registration.launchOperator && msg.sender != owner()) {
            revert UnauthorizedActivator(msg.sender);
        }
        if (!registration.initialized) revert PoolNotInitialized(poolId);
        if (registration.active) revert PoolAlreadyActive(poolId);
        registration.active = true;
        emit PoolActivated(poolId, msg.sender);
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

    function renounceOwnership() public pure override {
        revert OwnershipRenunciationDisabled();
    }

    function poolRegistration(PoolId poolId) external view override returns (PoolRegistration memory registration) {
        return registrations[poolId];
    }

    function _afterInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96, int24)
        internal
        override
        returns (bytes4)
    {
        PoolRegistration storage registration = _registration(key.toId());
        if (sender != address(_positionManager)) revert UnauthorizedInitializer(sender);
        if (sqrtPriceX96 != registration.expectedSqrtPriceX96) {
            revert InitialPriceMismatch(registration.expectedSqrtPriceX96, sqrtPriceX96);
        }
        registration.initialized = true;
        emit PoolInitialized(key.toId());
        return IHooks.afterInitialize.selector;
    }

    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId poolId = key.toId();
        PoolRegistration storage registration = _registration(poolId);
        if (!registration.active) revert PoolNotActive(poolId);
        bool exactInput = params.amountSpecified < 0;
        uint256 realized = _absolute(params.amountSpecified);
        uint16 feeBps = exactInput ? registration.inputFeeBps : registration.outputFeeBps;
        uint256 charged = exactInput ? _feeFromGross(realized, feeBps) : _feeFromNet(realized, feeBps);
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
        int128 specifiedDelta = specifiedCurrencyIs0 ? delta.amount0() : delta.amount1();
        uint16 specifiedFeeBps = exactInput ? registration.inputFeeBps : registration.outputFeeBps;
        uint256 specifiedFee = exactInput
            ? _feeFromGross(_absolute(params.amountSpecified), specifiedFeeBps)
            : _feeFromNet(_absolute(params.amountSpecified), specifiedFeeBps);
        int256 expectedSpecifiedDelta = params.amountSpecified + int256(specifiedFee);
        if (int256(specifiedDelta) != expectedSpecifiedDelta) {
            revert IncompleteSpecifiedFill(expectedSpecifiedDelta, int256(specifiedDelta));
        }
        Currency unspecified = specifiedCurrencyIs0 ? key.currency1 : key.currency0;
        int128 unspecifiedDelta = specifiedCurrencyIs0 ? delta.amount1() : delta.amount0();
        uint256 realized = _absolute(int256(unspecifiedDelta));
        uint16 feeBps = exactInput ? registration.outputFeeBps : registration.inputFeeBps;
        uint256 charged = exactInput ? _feeFromGross(realized, feeBps) : _feeFromNet(realized, feeBps);
        if (charged != 0) _routeFee(poolId, unspecified, realized, charged, false);
        return (IHooks.afterSwap.selector, charged.toInt128());
    }

    function _routeFee(PoolId poolId, Currency currency, uint256 realized, uint256 charged, bool specifiedLeg) private {
        address receiver = feeReceiver;
        poolManager.mint(receiver, currency.toId(), charged);
        emit SwapLegFeeRouted(poolId, currency, specifiedLeg, realized, charged, receiver);
    }

    function _registration(PoolId poolId) private view returns (PoolRegistration storage registration) {
        registration = registrations[poolId];
        if (!registration.registered) revert PoolNotRegistered(poolId);
    }

    /// @dev The hook owner may register directly. When the owner is a TimelockController, its
    /// existing proposer Safe may also register immediately without a second authority or role.
    function _checkPoolRegistrationAuthority() private view {
        address hookOwner = owner();
        if (msg.sender == hookOwner) return;
        (bool success, bytes memory result) =
            hookOwner.staticcall(abi.encodeCall(IAccessControl.hasRole, (TIMELOCK_PROPOSER_ROLE, msg.sender)));
        if (!success || result.length != 32 || !abi.decode(result, (bool))) {
            revert UnauthorizedPoolRegistration(msg.sender);
        }
    }

    function _enforceValidReceiver(address receiver) private view {
        if (
            receiver == address(0) || receiver == address(this) || receiver == address(poolManager)
                || receiver == address(_positionManager)
        ) {
            revert InvalidReceiver();
        }
    }

    function _enforceValidLaunchOperator(address launchOperator) private view {
        if (
            launchOperator == address(0) || launchOperator == address(this) || launchOperator == address(poolManager)
                || launchOperator == address(_positionManager) || launchOperator == address(1)
                || launchOperator == address(2)
        ) {
            revert InvalidLaunchOperator(launchOperator);
        }
    }

    function _enforceHookFee(uint16 feeBps) private pure {
        if (feeBps > MAX_HOOK_FEE_BPS) revert HookFeeTooLarge(feeBps);
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
}
