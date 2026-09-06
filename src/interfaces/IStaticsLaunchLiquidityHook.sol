// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @notice Temporary standalone launch-liquidity hook. This interface is intentionally independent
/// from the Statics Diamond and the canonical Statics swap-fee hook.
interface IStaticsLaunchLiquidityHook {
    struct PoolRegistration {
        Currency currency0;
        Currency currency1;
        int24 tickSpacing;
        bool registered;
        bool retired;
    }

    event PoolRegistered(PoolId indexed poolId, Currency indexed currency0, Currency indexed currency1);
    event SwapLegFeeAccrued(
        PoolId indexed poolId,
        Currency indexed currency,
        bool indexed specifiedLeg,
        uint256 realizedAmount,
        uint256 chargedAmount,
        uint256 feeReceiverAmount,
        uint256 polAmount
    );
    event ProtocolLiquiditySeeded(PoolId indexed poolId, uint128 liquidity, uint256 amount0, uint256 amount1);
    event ProtocolLiquidityCompounded(
        PoolId indexed poolId, uint128 liquidity, uint256 amount0, uint256 amount1, uint256 pending0, uint256 pending1
    );
    event ProtocolLiquidityFeesHarvested(PoolId indexed poolId, uint256 amount0, uint256 amount1);
    event ProtocolLiquidityReleased(
        PoolId indexed poolId,
        address indexed receiver,
        uint128 liquidity,
        uint256 principal0,
        uint256 principal1,
        uint256 pending0,
        uint256 pending1
    );
    event FeeReceiverSet(address indexed previousReceiver, address indexed newReceiver);
    event LiquidityReceiverSet(address indexed previousReceiver, address indexed newReceiver);
    event LiquidityAdminSet(address indexed previousAdmin, address indexed newAdmin);

    function registerAndInitialize(PoolKey calldata key, uint160 sqrtPriceX96) external returns (PoolId poolId);
    function seedPOL(PoolKey calldata key, uint128 liquidity, uint256 amount0Max, uint256 amount1Max)
        external
        returns (uint256 amount0, uint256 amount1);
    function compoundPOL(PoolKey calldata key) external returns (uint128 liquidityAdded);
    function harvestPOLFees(PoolKey calldata key) external returns (uint256 amount0, uint256 amount1);
    function retireAndReleasePOL(PoolKey calldata key)
        external
        returns (uint256 principal0, uint256 principal1, uint256 pending0, uint256 pending1);

    function poolRegistration(PoolId poolId) external view returns (PoolRegistration memory registration);
    function pendingPOL(PoolId poolId, Currency currency) external view returns (uint256 amount);
    function totalPendingPOL(Currency currency) external view returns (uint256 amount);
    function polLiquidity(PoolId poolId) external view returns (uint128 liquidity);
    function feeReceiver() external view returns (address);
    function liquidityReceiver() external view returns (address);
    function liquidityAdmin() external view returns (address);
    function setFeeReceiver(address newReceiver) external;
    function setLiquidityReceiver(address newReceiver) external;
    function setLiquidityAdmin(address newAdmin) external;
}
