// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

interface IStaticsBasketLiquidity {
    enum CanonicalPoolStatus {
        Unconfigured,
        Warming,
        Active
    }

    struct CanonicalPoolView {
        PoolId poolId;
        address basketToken;
        address asset;
        address currency0;
        address currency1;
        address hook;
        uint24 lpFee;
        int24 tickSpacing;
        CanonicalPoolStatus status;
        uint40 initializedAt;
        uint40 activatedAt;
        int24 spotTick;
        int24 referenceTick;
        uint8 observationCardinality;
        bool referenceAvailable;
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

    struct PoolFeeConfigurationView {
        uint16 inputFeeBps;
        uint16 outputFeeBps;
        uint16 polShareBps;
        uint16 liquidityProviderShareBps;
        uint16 basketStakerShareBps;
        uint16 staticsStakerShareBps;
        uint16 treasuryShareBps;
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
    event CanonicalPoolCheckpointed(
        uint256 indexed basketId, address indexed asset, PoolId indexed poolId, bool observationStored
    );
    event CanonicalPoolActivated(
        uint256 indexed basketId, address indexed asset, PoolId indexed poolId, int24 referenceTick, int24 spotTick
    );
    event CanonicalPoolSyncedToManager(
        uint256 indexed basketId, address indexed asset, PoolId indexed poolId, address manager
    );
    event SwapFeeConfigurationChanged(SwapFeeConfiguration configuration);
    event CanonicalPoolFeeConfigurationSet(
        uint256 indexed basketId,
        address indexed asset,
        PoolId indexed poolId,
        uint16 inputFeeBps,
        uint16 outputFeeBps,
        uint16 polShareBps,
        uint16 liquidityProviderShareBps,
        uint16 basketStakerShareBps,
        uint16 staticsStakerShareBps,
        uint16 treasuryShareBps
    );
    event CanonicalPoolFeeConfigurationCleared(uint256 indexed basketId, address indexed asset, PoolId indexed poolId);
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
    function initializeCanonicalPool(uint256 basketId, address asset, uint160 sqrtPriceX96)
        external
        returns (PoolId poolId, int24 tick);
    function checkpointCanonicalPool(uint256 basketId, address asset) external returns (bool observationStored);
    function activateCanonicalPool(uint256 basketId, address asset)
        external
        returns (int24 referenceTick, int24 spotTick);
    function syncCanonicalPoolToManager(uint256 basketId, address asset) external returns (bool synced);
    function setSwapFeeConfiguration(SwapFeeConfiguration calldata configuration) external;
    function setCanonicalPoolFeeConfiguration(
        uint256 basketId,
        address asset,
        SwapFeeConfiguration calldata configuration
    ) external;
    function clearCanonicalPoolFeeConfiguration(uint256 basketId, address asset) external;
    function unwindBasketLiquidity(uint256 basketId, address asset) external;

    function liquidityIntegration() external view returns (address poolManager, address hook, bool installed);
    function liquidityManager() external view returns (address manager, bool installed);
    function liquiditySafetyParameters()
        external
        pure
        returns (uint24 lpFee, int24 tickSpacing, uint40 warmup, uint32 referenceWindow, uint16 maxDeviationBps);
    function canonicalPool(uint256 basketId, address asset) external view returns (CanonicalPoolView memory pool);
    function swapFeeConfiguration() external view returns (SwapFeeConfiguration memory configuration);
    function canonicalPoolFeeConfiguration(uint256 basketId, address asset)
        external
        view
        returns (PoolFeeConfigurationView memory configuration);
    function basketLiquidityUnwound(uint256 basketId, address asset) external view returns (bool unwound);
}
