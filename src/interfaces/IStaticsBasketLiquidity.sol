// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

interface IStaticsBasketLiquidity {
    enum CanonicalPoolStatus {
        Unconfigured,
        Warming,
        Active
    }

    struct PrimaryFeeTotals {
        uint256 holderAmount;
        uint256 liquidityAmount;
        uint256 protocolAmount;
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

    struct HookSettlementTotals {
        uint256 constituentHookDebit;
        uint256 constituentRevenue;
        uint256 basketTokenHookDebit;
        uint256 basketTokensBurned;
    }

    struct BasketLiquidityStateView {
        uint40 lastCompoundAt;
        uint40 nextCompoundAt;
        uint256 cumulativeSharesMinted;
    }

    struct ProtocolLpFeeTotals {
        uint256 constituentCollected;
        uint256 constituentPolRetained;
        uint256 constituentRevenueDebit;
        uint256 constituentRevenue;
        uint256 basketTokenCollected;
        uint256 basketTokenPolRetained;
        uint256 basketTokenRevenueDebit;
        uint256 basketTokensBurned;
    }

    event LiquidityIntegrationInstalled(address indexed poolManager, address indexed hook);
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
    event CanonicalHookFeesSettled(
        uint256 indexed basketId,
        address indexed asset,
        PoolId indexed poolId,
        uint256 constituentHookDebit,
        uint256 constituentRevenue,
        uint256 basketTokenHookDebit,
        uint256 basketTokensBurned
    );
    event HookBasketTokenRevenueReclassified(
        uint256 indexed basketId, address indexed sourcePoolAsset, address indexed revenueAsset, uint256 amount
    );
    event LiquidityManagerInstalled(address indexed manager);
    event CanonicalPoolSyncedToManager(
        uint256 indexed basketId, address indexed asset, PoolId indexed poolId, address manager
    );
    event BasketLiquidityPoolFunded(
        uint256 indexed basketId,
        address indexed asset,
        uint256 indexed positionTokenId,
        uint256 backingAdded,
        uint256 assetSpent,
        uint256 assetReceived,
        uint256 basketTokenLimit,
        uint256 assetLimit,
        uint256 liquidity
    );
    event BasketLiquidityCompounded(
        uint256 indexed basketId, uint256 sharesMinted, uint40 nextCompoundAt, bool youngPoolCapApplied
    );
    event ProtocolLpFeesCollected(
        uint256 indexed basketId, address indexed asset, uint256 indexed positionTokenId, ProtocolLpFeeTotals fees
    );
    event LpBasketTokenRevenueReclassified(
        uint256 indexed basketId, address indexed sourcePoolAsset, address indexed revenueAsset, uint256 amount
    );
    event BasketLiquidityUnwound(
        uint256 indexed basketId,
        address indexed asset,
        uint256 indexed positionTokenId,
        uint256 reserveReclassified,
        uint256 constituentInventoryDebit,
        uint256 constituentRevenue,
        uint256 basketTokenInventoryDebit,
        uint256 basketTokensBurned
    );

    function installCanonicalPoolIntegration(address poolManager, address hook) external;
    function initializeCanonicalPool(uint256 basketId, address asset, uint160 sqrtPriceX96)
        external
        returns (PoolId poolId, int24 tick);
    function checkpointCanonicalPool(uint256 basketId, address asset) external returns (bool observationStored);
    function activateCanonicalPool(uint256 basketId, address asset)
        external
        returns (int24 referenceTick, int24 spotTick);
    function liquidityIntegration() external view returns (address poolManager, address hook, bool installed);
    function liquiditySafetyParameters()
        external
        pure
        returns (uint24 lpFee, int24 tickSpacing, uint40 warmup, uint32 referenceWindow, uint16 maxDeviationBps);
    function canonicalPool(uint256 basketId, address asset) external view returns (CanonicalPoolView memory pool);
    function settleCanonicalHookFees(uint256 basketId, address asset)
        external
        returns (HookSettlementTotals memory settled);
    function pendingCanonicalHookFees(uint256 basketId, address asset)
        external
        view
        returns (uint256 basketTokenAmount, uint256 constituentAmount);
    function cumulativeCanonicalHookSettlement(uint256 basketId, address asset)
        external
        view
        returns (HookSettlementTotals memory totals);
    function cumulativeHookRevenue(uint256 basketId, address revenueAsset) external view returns (uint256 amount);
    function installLiquidityManager(address manager) external;
    function syncCanonicalPoolToManager(uint256 basketId, address asset) external returns (bool synced);
    function compoundBasketLiquidity(uint256 basketId) external returns (uint256 sharesMinted);
    function liquidityManager() external view returns (address manager, bool installed);
    function basketLiquidityState(uint256 basketId) external view returns (BasketLiquidityStateView memory state);
    function cumulativeLiquidityFunding(uint256 basketId, address asset)
        external
        view
        returns (uint256 assetSpent, uint256 assetReceived);
    function liquidityEpochParameters()
        external
        pure
        returns (uint40 interval, uint40 youngPoolPeriod, uint16 youngPoolCapBps, uint256 minimumShares);
    function collectProtocolLpFees(uint256 basketId, address asset) external returns (ProtocolLpFeeTotals memory fees);
    function cumulativeProtocolLpFees(uint256 basketId, address asset)
        external
        view
        returns (ProtocolLpFeeTotals memory totals);
    function protocolLpFeeAllocation() external pure returns (uint16 polShareBps, uint16 revenueShareBps);
    function unwindBasketLiquidity(uint256 basketId, address asset) external;
    function basketLiquidityUnwound(uint256 basketId, address asset) external view returns (bool unwound);

    function liquidityReserve(uint256 basketId, address asset) external view returns (uint256 amount);

    function cumulativePrimaryFees(uint256 basketId, address asset)
        external
        view
        returns (PrimaryFeeTotals memory totals);
}
