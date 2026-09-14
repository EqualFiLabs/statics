// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IStaticsPermanentLiquidityMath} from "../../../src/interfaces/IStaticsPermanentLiquidityMath.sol";
import {StaticsSwapFeeHook} from "../../../src/liquidity/StaticsSwapFeeHook.sol";

contract FormalPermanentToken {}

contract FormalPermanentLiquidityMath is IStaticsPermanentLiquidityMath {
    function fullRangeLiquidity(uint160, int24, uint256 amount0, uint256 amount1)
        external
        pure
        override
        returns (uint128 liquidity, int24 tickLower, int24 tickUpper)
    {
        uint256 minimum = amount0 < amount1 ? amount0 : amount1;
        liquidity = uint128(minimum);
        tickLower = -887270;
        tickUpper = 887270;
    }
}

contract FormalPermanentPoolManager {
    mapping(address owner => mapping(uint256 id => uint256 amount)) public balanceOf;
    mapping(uint256 id => uint256 amount) public totalBurned;

    uint128 private debit0;
    uint128 private debit1;

    function setModifyDebits(uint128 amount0, uint128 amount1) external {
        debit0 = amount0;
        debit1 = amount1;
    }

    function mint(address receiver, uint256 id, uint256 amount) external {
        balanceOf[receiver][id] += amount;
    }

    function burn(address owner, uint256 id, uint256 amount) external {
        balanceOf[owner][id] -= amount;
        totalBurned[id] += amount;
    }

    function extsload(bytes32) external pure returns (bytes32 value) {
        value = bytes32(uint256(1 << 96));
    }

    function modifyLiquidity(PoolKey memory, ModifyLiquidityParams memory params, bytes calldata)
        external
        view
        returns (BalanceDelta callerDelta, BalanceDelta feesAccrued)
    {
        require(params.liquidityDelta > 0, "addition only");
        callerDelta = toBalanceDelta(-int128(debit0), -int128(debit1));
        feesAccrued = toBalanceDelta(0, 0);
    }

    function unlock(bytes calldata data) external returns (bytes memory result) {
        (bool success, bytes memory returned) = msg.sender.call(abi.encodeWithSignature("unlockCallback(bytes)", data));
        require(success, "unlock callback");
        return abi.decode(returned, (bytes));
    }

    function callBeforeSwap(IHooks hook, PoolKey calldata key, SwapParams calldata params)
        external
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        return hook.beforeSwap(address(this), key, params, "");
    }

    function callSwapHooks(IHooks hook, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta)
        external
        returns (BeforeSwapDelta beforeDelta, int128 afterDelta)
    {
        (, beforeDelta,) = hook.beforeSwap(address(this), key, params, "");
        (, afterDelta) = hook.afterSwap(address(this), key, params, delta, "");
    }
}

contract FormalPermanentSwapFeeHook is StaticsSwapFeeHook {
    constructor(
        IPoolManager manager,
        address diamond,
        uint16 inputFeeBps,
        uint16 outputFeeBps,
        IStaticsPermanentLiquidityMath permanentLiquidityMath
    ) StaticsSwapFeeHook(manager, diamond, inputFeeBps, outputFeeBps, permanentLiquidityMath) {}

    function formalAccrueSwapLegFee(
        PoolId poolId,
        Currency currency,
        uint256 realized,
        uint256 charged,
        bool specifiedLeg
    ) external {
        _accrueSwapLegFee(poolId, currency, realized, charged, specifiedLeg);
    }

    function validateHookAddress(BaseHook) internal pure override {}
}
