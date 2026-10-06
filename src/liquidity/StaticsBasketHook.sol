// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IStaticsBasketSettlement} from "../interfaces/IStaticsBasketSettlement.sol";
import {IStaticsSwapFeeHook} from "../interfaces/IStaticsSwapFeeHook.sol";
import {LibProtocolPoolFee} from "../libraries/LibProtocolPoolFee.sol";
import {StaticsSwapFeeHook} from "./StaticsSwapFeeHook.sol";

/// @notice Immutable one-pool hook, constructor-registered; there is no initializer or replacement binding.
contract StaticsBasketHook is StaticsSwapFeeHook {
    using PoolIdLibrary for PoolKey;
    using SafeCast for uint256;

    struct Binding {
        Currency currency0;
        Currency currency1;
        uint24 lpFee;
        int24 tickSpacing;
        address creator;
        uint256 version;
    }

    // forge-lint: disable-start(screaming-snake-case-immutable)
    PoolId public immutable boundPoolId;
    address public immutable boundCreator;
    uint256 public immutable version;
    IStaticsSwapFeeHook public immutable feePolicy;
    // forge-lint: disable-end(screaming-snake-case-immutable)

    error InvalidBinding();
    error ImmutablePoolBinding();

    constructor(IPoolManager manager, address diamond, IStaticsSwapFeeHook policy, Binding memory binding)
        StaticsSwapFeeHook(manager, diamond, 0, 0)
    {
        if (
            binding.version == 0 || Currency.unwrap(binding.currency0) >= Currency.unwrap(binding.currency1)
                || !LibProtocolPoolFee.isValidTickSpacing(binding.tickSpacing) || policy.staticsDiamond() != diamond
        ) revert InvalidBinding();
        feePolicy = policy;
        boundCreator = binding.creator;
        version = binding.version;
        PoolKey memory key =
            PoolKey(binding.currency0, binding.currency1, binding.lpFee, binding.tickSpacing, IHooks(address(this)));
        boundPoolId = _registerPool(key, PoolKind.BasketCanonical, binding.creator);
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory permissions) {
        permissions = super.getHookPermissions();
        permissions.beforeAddLiquidity = true;
        permissions.afterAddLiquidity = true;
        permissions.beforeRemoveLiquidity = true;
        permissions.afterRemoveLiquidity = true;
    }

    function registerPool(PoolKey calldata, PoolKind, address) external pure override returns (PoolId) {
        revert ImmutablePoolBinding();
    }

    function _afterInitialize(address, PoolKey calldata key, uint160, int24) internal view override returns (bytes4) {
        _validate(key, 3);
        return IHooks.afterInitialize.selector;
    }

    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata data)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        _validate(key, 0);
        return super._beforeSwap(sender, key, params, data);
    }

    function _beforeAddLiquidity(address, PoolKey calldata key, ModifyLiquidityParams calldata, bytes calldata)
        internal
        view
        override
        returns (bytes4)
    {
        _validate(key, 1);
        return IHooks.beforeAddLiquidity.selector;
    }

    function _beforeRemoveLiquidity(address, PoolKey calldata key, ModifyLiquidityParams calldata, bytes calldata)
        internal
        view
        override
        returns (bytes4)
    {
        _validate(key, 2);
        return IHooks.beforeRemoveLiquidity.selector;
    }

    function _afterAddLiquidity(
        address,
        PoolKey calldata key,
        ModifyLiquidityParams calldata,
        BalanceDelta delta,
        BalanceDelta,
        bytes calldata
    ) internal override returns (bytes4, BalanceDelta) {
        _enforceRegistered(key.toId());
        IStaticsBasketSettlement(staticsDiamond).authorizeBasketPoolSettlement(boundPoolId, delta, 1);
        return (IHooks.afterAddLiquidity.selector, BalanceDelta.wrap(0));
    }

    function _afterRemoveLiquidity(
        address,
        PoolKey calldata key,
        ModifyLiquidityParams calldata,
        BalanceDelta delta,
        BalanceDelta,
        bytes calldata
    ) internal override returns (bytes4, BalanceDelta) {
        _enforceRegistered(key.toId());
        // v4 passes principal plus fees, including zero-liquidity collection.
        IStaticsBasketSettlement(staticsDiamond).authorizeBasketPoolSettlement(boundPoolId, delta, 2);
        return (IHooks.afterRemoveLiquidity.selector, BalanceDelta.wrap(0));
    }

    function _afterStaticsPoolSwap(PoolId id, BalanceDelta delta, uint256 fees, uint256 stakerFees, uint8 flags)
        internal
        override
    {
        BalanceDelta callerDelta = delta - toBalanceDelta(uint256(uint128(fees)).toInt128(), (fees >> 128).toInt128());
        IStaticsBasketSettlement(staticsDiamond).authorizeBasketPoolSettlement(id, callerDelta, 0);
        super._afterStaticsPoolSwap(id, delta, fees, stakerFees, flags);
    }

    function _beforeClaimTransfer(Currency currency, address receiver, uint256 amount) internal override {
        IStaticsBasketSettlement(staticsDiamond).authorizeBasketPoolClaim(boundPoolId, currency, receiver, amount);
    }

    function _validate(PoolKey calldata key, uint8 action) private view {
        _enforceRegistered(key.toId());
        IStaticsBasketSettlement(staticsDiamond).validateBasketPool(boundPoolId, action);
    }

    function _enforceRegistered(PoolId id) internal view override {
        if (PoolId.unwrap(id) != PoolId.unwrap(boundPoolId)) revert InvalidBinding();
        super._enforceRegistered(id);
    }

    // Every pool reads live bounded policy; governance never iterates deployed hooks.
    function _defaultFeeRate() internal view override returns (uint16 inputFeeBps, uint16 outputFeeBps) {
        return feePolicy.defaultFeeRate();
    }

    function _basketFeeAllocation() internal view override returns (BasketFeeAllocation memory) {
        return feePolicy.basketFeeAllocation();
    }

    function _generalFeeAllocation() internal view override returns (GeneralFeeAllocation memory) {
        return feePolicy.generalFeeAllocation();
    }
}
