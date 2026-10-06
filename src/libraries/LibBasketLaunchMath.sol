// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IStaticsBasket} from "../interfaces/IStaticsBasket.sol";
import {LibBasket} from "./LibBasket.sol";
import {LibBasketLiquidityMath} from "./LibBasketLiquidityMath.sol";
import {LibProtocolPoolFee} from "./LibProtocolPoolFee.sol";

/// @dev The same seed geometry is used before deployment and when opening POL.
library LibBasketLaunchMath {
    error InvalidPoolLaunchLpFee(address asset, uint24 lpFee);
    error InvalidPoolLaunchTickSpacing(address asset, int24 tickSpacing);
    error InvalidPoolLaunchPrice(address asset, uint160 sqrtPriceAssetPerBasketX96);
    error InvalidPoolLaunchLiquidity(address asset, uint256 pairedAssetAmount);
    error InvalidPoolLaunchParameters();

    struct Requirements {
        uint256 basketShares;
        uint256[] backing;
        uint256[] mintFees;
        uint256[] pairedAmounts;
        uint256[] totalAmounts;
        uint256 nativeCreationFee;
    }

    function sqrtPrice(address basketToken, address asset, int24 spacing, uint160 semantic)
        internal
        pure
        returns (uint160 price)
    {
        if (semantic < TickMath.MIN_SQRT_PRICE || semantic >= TickMath.MAX_SQRT_PRICE) {
            revert InvalidPoolLaunchPrice(asset, semantic);
        }
        uint256 sorted = basketToken < asset ? semantic : Math.mulDiv(1 << 96, 1 << 96, semantic);
        if (sorted < TickMath.MIN_SQRT_PRICE || sorted >= TickMath.MAX_SQRT_PRICE) {
            revert InvalidPoolLaunchPrice(asset, semantic);
        }
        price = uint160(sorted);
        if (
            price <= TickMath.getSqrtPriceAtTick(TickMath.minUsableTick(spacing))
                || price >= TickMath.getSqrtPriceAtTick(TickMath.maxUsableTick(spacing))
        ) revert InvalidPoolLaunchPrice(asset, semantic);
    }

    function seed(address token, address asset, IStaticsBasket.PoolLaunchParams calldata launch)
        internal
        pure
        returns (uint160 price, uint128 liquidity, uint256 shares, uint256 paired)
    {
        if (!LibProtocolPoolFee.isValidStaticLpFee(launch.lpFee)) {
            revert InvalidPoolLaunchLpFee(asset, launch.lpFee);
        }
        if (!LibProtocolPoolFee.isValidTickSpacing(launch.tickSpacing)) {
            revert InvalidPoolLaunchTickSpacing(asset, launch.tickSpacing);
        }
        price = sqrtPrice(token, asset, launch.tickSpacing, launch.sqrtPriceAssetPerBasketX96);
        (liquidity, shares, paired) =
            LibBasketLiquidityMath.fullRangeAmounts(price, asset < token, launch.pairedAssetAmount, launch.tickSpacing);
        if (liquidity == 0 || shares == 0 || paired == 0) {
            revert InvalidPoolLaunchLiquidity(asset, launch.pairedAssetAmount);
        }
    }

    function preview(
        address token,
        IStaticsBasket.CreateBasketParams calldata params,
        IStaticsBasket.PoolLaunchParams[] calldata pools,
        uint256 nativeFee
    ) internal pure returns (Requirements memory result) {
        uint256 length = params.assets.length;
        if (length == 0 || length > 16 || pools.length != length || params.bundleAmounts.length != length) {
            revert InvalidPoolLaunchParameters();
        }
        result.backing = new uint256[](length);
        result.mintFees = new uint256[](length);
        result.pairedAmounts = new uint256[](length);
        result.totalAmounts = new uint256[](length);
        result.nativeCreationFee = nativeFee;
        for (uint256 i; i < length; ++i) {
            (,, uint256 shares, uint256 paired) = seed(token, params.assets[i], pools[i]);
            result.basketShares += shares;
            result.pairedAmounts[i] = paired;
        }
        uint256 feeShares;
        uint256 threshold;
        bool found;
        for (uint256 i; i < params.mintFeeTiers.length; ++i) {
            IStaticsBasket.FeeTier calldata tier = params.mintFeeTiers[i];
            if (tier.minActionShares <= result.basketShares && (!found || tier.minActionShares >= threshold)) {
                feeShares = tier.feeShares;
                threshold = tier.minActionShares;
                found = true;
            }
        }
        for (uint256 i; i < length; ++i) {
            result.backing[i] = LibBasket.backingIncrease(params.bundleAmounts[i], 0, result.basketShares);
            result.mintFees[i] = LibBasket.convertFeeShares(params.bundleAmounts[i], feeShares);
            result.totalAmounts[i] = result.backing[i] + result.mintFees[i] + result.pairedAmounts[i];
        }
    }
}
