// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @notice Standalone fee hook for temporary Statics launch pools.
/// @dev Liquidity positions are ordinary externally owned Uniswap v4 PositionManager NFTs. The
/// hook neither owns nor accounts for liquidity.
interface IStaticsLaunchLiquidityHook {
    struct PoolRegistration {
        Currency currency0;
        Currency currency1;
        uint24 nativeLpFee;
        int24 tickSpacing;
        uint160 expectedSqrtPriceX96;
        uint16 inputFeeBps;
        uint16 outputFeeBps;
        bool registered;
    }

    event PoolRegistered(
        PoolId indexed poolId,
        Currency indexed currency0,
        Currency indexed currency1,
        uint24 nativeLpFee,
        int24 tickSpacing,
        uint160 expectedSqrtPriceX96,
        uint16 inputFeeBps,
        uint16 outputFeeBps
    );
    event HookFeesSet(
        PoolId indexed poolId,
        uint16 previousInputFeeBps,
        uint16 newInputFeeBps,
        uint16 previousOutputFeeBps,
        uint16 newOutputFeeBps
    );
    event SwapLegFeeRouted(
        PoolId indexed poolId,
        Currency indexed currency,
        bool indexed specifiedLeg,
        uint256 realizedAmount,
        uint256 chargedAmount,
        address receiver
    );
    event FeeReceiverSet(address indexed previousReceiver, address indexed newReceiver);

    function registerPool(PoolKey calldata key, uint160 expectedSqrtPriceX96, uint16 inputFeeBps, uint16 outputFeeBps)
        external
        returns (PoolId poolId);
    function setHookFees(PoolId poolId, uint16 inputFeeBps, uint16 outputFeeBps) external;
    function setFeeReceiver(address newReceiver) external;

    function poolRegistration(PoolId poolId) external view returns (PoolRegistration memory registration);
    function feeReceiver() external view returns (address);
    function positionManager() external view returns (address);
}
