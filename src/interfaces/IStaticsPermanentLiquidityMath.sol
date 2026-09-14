// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

interface IStaticsPermanentLiquidityMath {
    function fullRangeLiquidity(uint160 sqrtPriceX96, int24 tickSpacing, uint256 amount0, uint256 amount1)
        external
        pure
        returns (uint128 liquidity, int24 tickLower, int24 tickUpper);
}
