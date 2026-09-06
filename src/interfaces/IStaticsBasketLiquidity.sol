// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

interface IStaticsBasketLiquidity {
    struct CanonicalPoolView {
        PoolId poolId;
        address basketToken;
        address asset;
        address currency0;
        address currency1;
        address hook;
        uint24 lpFee;
        int24 tickSpacing;
        int24 spotTick;
    }

    struct SwapFeeConfiguration {
        uint16 inputFeeBps;
        uint16 outputFeeBps;
        uint16 polShareBps;
        uint16 liquidityProviderShareBps;
        uint16 basketStakerShareBps;
        uint16 staticsStakerShareBps;
        uint16 treasuryShareBps;
    }

    struct PoolFeeRateView {
        uint16 inputFeeBps;
        uint16 outputFeeBps;
        bool overridden;
    }

    event LiquidityIntegrationInstalled(address indexed poolManager, address indexed hook);
    event LiquidityManagerInstalled(address indexed manager);
    event CanonicalPoolInitialized(
        uint256 indexed basketId,
        address indexed asset,
        PoolId indexed poolId,
        address currency0,
        address currency1,
        uint160 sqrtPriceX96,
        int24 tick
    );
    event CanonicalPoolSyncedToManager(
        uint256 indexed basketId, address indexed asset, PoolId indexed poolId, address manager
    );
    event SwapFeeConfigurationChanged(SwapFeeConfiguration configuration);
    event CanonicalPoolFeeRateSet(
        uint256 indexed basketId, address indexed asset, PoolId indexed poolId, uint16 inputFeeBps, uint16 outputFeeBps
    );
    event CanonicalPoolFeeRateCleared(uint256 indexed basketId, address indexed asset, PoolId indexed poolId);
    event PermanentLiquidityTreasuryAccrued(
        uint256 indexed basketId, address indexed sourcePoolAsset, address indexed rewardAsset, uint256 amount
    );
    event BasketLiquidityUnwound(
        uint256 indexed basketId,
        address indexed asset,
        PoolId indexed poolId,
        uint256 constituentReleased,
        uint256 basketTokensBurned
    );

    function installCanonicalPoolIntegration(address poolManager, address hook) external;
    function installLiquidityManager(address manager) external;
    function setSwapFeeConfiguration(SwapFeeConfiguration calldata configuration) external;
    function setCanonicalPoolFeeRate(uint256 basketId, address asset, uint16 inputFeeBps, uint16 outputFeeBps) external;
    function clearCanonicalPoolFeeRate(uint256 basketId, address asset) external;
    function unwindBasketLiquidity(uint256 basketId, address asset) external;

    function liquidityIntegration() external view returns (address poolManager, address hook, bool installed);
    function liquidityManager() external view returns (address manager, bool installed);
    function canonicalPool(uint256 basketId, address asset) external view returns (CanonicalPoolView memory pool);
    function swapFeeConfiguration() external view returns (SwapFeeConfiguration memory configuration);
    function canonicalPoolFeeRate(uint256 basketId, address asset) external view returns (PoolFeeRateView memory rate);
    function basketLiquidityUnwound(uint256 basketId, address asset) external view returns (bool unwound);
}
