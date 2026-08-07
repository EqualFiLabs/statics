// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IStaticsBasketLiquidity} from "./IStaticsBasketLiquidity.sol";

interface IStaticsProtocolPools {
    enum ProtocolPoolKind {
        None,
        BasketCanonical,
        Governance
    }

    struct CreateGovernancePoolParams {
        address tokenA;
        address tokenB;
        uint160 sqrtPriceBPerAX96;
        uint256 amountAMax;
        uint256 amountBMax;
        uint128 minLiquidity;
        address payer;
        uint256 deadline;
    }

    struct ProtocolPoolView {
        PoolId poolId;
        PoolKey key;
        ProtocolPoolKind kind;
        bool decommissioned;
        uint256 basketId;
        address basketAsset;
        uint128 permanentLiquidity;
    }

    event GovernancePoolCreated(
        PoolId indexed poolId,
        address indexed tokenA,
        address indexed tokenB,
        address payer,
        address currency0,
        address currency1,
        uint160 sqrtPriceX96,
        int24 tick,
        uint128 liquidity,
        uint256 amountA,
        uint256 amountB
    );
    event ProtocolPoolFeeConfigurationSet(PoolId indexed poolId);
    event ProtocolPoolFeeConfigurationCleared(PoolId indexed poolId);
    event GovernancePoolDecommissioned(
        PoolId indexed poolId, address indexed currency0, address indexed currency1, uint256 amount0, uint256 amount1
    );
    event LiquidityManagerReplaced(address indexed oldManager, address indexed newManager);

    function quoteGovernancePool(CreateGovernancePoolParams calldata params)
        external
        view
        returns (
            PoolKey memory key,
            PoolId poolId,
            uint160 sqrtPriceX96,
            uint128 liquidity,
            uint256 amountA,
            uint256 amountB
        );
    function createGovernancePool(CreateGovernancePoolParams calldata params)
        external
        returns (PoolId poolId, uint128 liquidity, uint256 amountA, uint256 amountB);
    function setProtocolPoolFeeConfiguration(
        PoolId poolId,
        IStaticsBasketLiquidity.SwapFeeConfiguration calldata configuration
    ) external;
    function clearProtocolPoolFeeConfiguration(PoolId poolId) external;
    function protocolPoolFeeConfiguration(PoolId poolId)
        external
        view
        returns (IStaticsBasketLiquidity.PoolFeeConfigurationView memory configuration);
    function decommissionGovernancePool(PoolId poolId) external returns (uint256 amount0, uint256 amount1);
    function replaceLiquidityManager(address newManager) external;
    function protocolPool(PoolId poolId) external view returns (ProtocolPoolView memory pool);
    function isProtocolPool(PoolId poolId) external view returns (bool registered);
}
