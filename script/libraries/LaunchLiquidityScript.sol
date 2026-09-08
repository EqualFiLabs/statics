// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";

/// @notice Shared validation and sizing helpers for launch-liquidity scripts.
library LaunchLiquidityScript {
    enum FundingMode {
        StaticsOnly,
        PairedTokenOnly,
        TwoSided
    }

    error InvalidFundingMode();
    error InvalidFundingPosition();
    error InvalidLiquidity();

    function parseFundingMode(string memory value) internal pure returns (FundingMode mode) {
        bytes32 valueHash = keccak256(bytes(value));
        if (valueHash == keccak256("STATICS_ONLY")) return FundingMode.StaticsOnly;
        if (valueHash == keccak256("PAIRED_TOKEN_ONLY")) return FundingMode.PairedTokenOnly;
        if (valueHash == keccak256("TWO_SIDED")) return FundingMode.TwoSided;
        revert InvalidFundingMode();
    }

    function fundingModeName(FundingMode mode) internal pure returns (string memory) {
        if (mode == FundingMode.StaticsOnly) return "STATICS_ONLY";
        if (mode == FundingMode.PairedTokenOnly) return "PAIRED_TOKEN_ONLY";
        if (mode == FundingMode.TwoSided) return "TWO_SIDED";
        revert InvalidFundingMode();
    }

    function validateFundingPosition(
        FundingMode mode,
        address statics,
        PoolKey memory key,
        uint160 sqrtPriceX96,
        int24 tickLower,
        int24 tickUpper,
        uint128 amount0Max,
        uint128 amount1Max
    ) internal pure {
        uint160 sqrtPriceLowerX96 = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtPriceUpperX96 = TickMath.getSqrtPriceAtTick(tickUpper);
        bool staticsIsCurrency0 = Currency.unwrap(key.currency0) == statics;

        if (mode == FundingMode.TwoSided) {
            if (
                sqrtPriceX96 <= sqrtPriceLowerX96 || sqrtPriceX96 >= sqrtPriceUpperX96 || amount0Max == 0
                    || amount1Max == 0
            ) revert InvalidFundingPosition();
            return;
        }

        bool fundsCurrency0 = mode == FundingMode.StaticsOnly ? staticsIsCurrency0 : !staticsIsCurrency0;
        if (fundsCurrency0) {
            if (sqrtPriceX96 > sqrtPriceLowerX96 || amount0Max == 0 || amount1Max != 0) {
                revert InvalidFundingPosition();
            }
        } else if (sqrtPriceX96 < sqrtPriceUpperX96 || amount0Max != 0 || amount1Max == 0) {
            revert InvalidFundingPosition();
        }
    }

    function liquidityForAmounts(
        uint160 sqrtPriceX96,
        int24 tickLower,
        int24 tickUpper,
        uint128 amount0Max,
        uint128 amount1Max
    ) internal pure returns (uint128 liquidity) {
        liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            amount0Max,
            amount1Max
        );
        if (liquidity == 0 || liquidity > uint128(type(int128).max)) revert InvalidLiquidity();
    }
}
