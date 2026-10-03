// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

interface IStaticsProtocolPools {
    enum ProtocolPoolKind {
        None,
        BasketCanonical,
        General,
        PermissionedGeneral
    }

    struct PoolSwapFeeRate {
        uint16 inputFeeBps;
        uint16 outputFeeBps;
    }

    struct PoolFeeRateView {
        uint16 inputFeeBps;
        uint16 outputFeeBps;
        bool overridden;
    }

    struct BasketFeeAllocation {
        uint16 polShareBps;
        uint16 basketStakerShareBps;
        uint16 staticsStakerShareBps;
        uint16 treasuryShareBps;
    }

    struct GeneralFeeAllocation {
        uint16 polShareBps;
        uint16 staticsStakerShareBps;
        uint16 treasuryShareBps;
    }

    struct ProtocolPoolMaintenanceConfig {
        uint16 revenueTipBps;
    }

    struct ProtocolPolPositionView {
        uint256 positionId;
        PoolId poolId;
        address manager;
        uint256 posmTokenId;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        bool active;
    }

    struct ProtocolPolOpenParams {
        PoolId poolId;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint256 amount0Maximum;
        uint256 amount1Maximum;
        uint256 deadline;
    }

    struct ProtocolPolLiquidityParams {
        uint256 positionId;
        uint128 liquidity;
        uint256 amount0Limit;
        uint256 amount1Limit;
        uint256 deadline;
    }

    struct CreatePoolParams {
        address tokenA;
        address tokenB;
        uint24 lpFee;
        int24 tickSpacing;
        uint160 sqrtPriceBPerAX96;
        PoolSwapFeeRate initialFeeRate;
        address creator;
        bool activateManagedPol;
        uint256 nonce;
        uint256 deadline;
    }

    struct GeneralPoolQuote {
        PoolKey key;
        PoolId poolId;
        uint160 sqrtPriceX96;
        uint256 creationFee;
        uint256 polActivationFee;
        uint256 totalNativeFee;
        bytes32 authorizationDigest;
    }

    struct ProtocolPoolView {
        PoolId poolId;
        PoolKey key;
        ProtocolPoolKind kind;
        bool decommissioned;
        uint256 basketId;
        address basketAsset;
        address creator;
        bool polActivated;
        bool polShareOverridden;
        /// @notice Effective share after applying the current class POL-plus-Treasury cap.
        uint16 polShareBps;
        uint256 activePolPositions;
    }

    event ProtocolPoolCreated(
        PoolId indexed poolId,
        address indexed creator,
        address indexed currency0,
        address currency1,
        uint24 lpFee,
        int24 tickSpacing,
        uint160 sqrtPriceX96,
        int24 tick
    );
    event PoolCreationFeeSet(uint256 amount);
    event PoolCreationNonceInvalidated(address indexed creator, uint256 indexed nonce);
    event DefaultProtocolPoolFeeRateSet(uint16 inputFeeBps, uint16 outputFeeBps);
    event ProtocolPoolFeeRateSet(PoolId indexed poolId, uint16 inputFeeBps, uint16 outputFeeBps);
    event ProtocolPoolFeeRateCleared(PoolId indexed poolId);
    event BasketFeeAllocationSet(
        uint16 polShareBps, uint16 basketStakerShareBps, uint16 staticsStakerShareBps, uint16 treasuryShareBps
    );
    event GeneralFeeAllocationSet(uint16 polShareBps, uint16 staticsStakerShareBps, uint16 treasuryShareBps);
    event GeneralPoolDecommissionStarted(PoolId indexed poolId);
    event GeneralPoolDecommissionFinalized(
        PoolId indexed poolId, address indexed currency0, address indexed currency1, uint256 amount0, uint256 amount1
    );
    event LiquidityManagerReplaced(address indexed oldManager, address indexed newManager);
    event ProtocolPoolMaintenanceConfigSet(uint16 revenueTipBps);
    event ProtocolPoolRevenueSettled(
        PoolId indexed poolId, address indexed asset, address indexed caller, uint256 grossAmount, uint256 callerTip
    );
    event ProtocolPolOperatorSet(address indexed operator);
    event ProtocolPolActivationFeeSet(uint256 amount);
    event ProtocolPolActivated(PoolId indexed poolId, address indexed creator, uint256 feePaid);
    event ProtocolPolShareSet(PoolId indexed poolId, uint16 shareBps, bool overridden);
    event ProtocolPolInventorySettled(PoolId indexed poolId, address indexed asset, uint256 amount);
    event ProtocolPolPositionOpened(
        PoolId indexed poolId,
        uint256 indexed positionId,
        address indexed manager,
        uint256 posmTokenId,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        uint256 amount0,
        uint256 amount1
    );
    event ProtocolPolPositionIncreased(
        PoolId indexed poolId, uint256 indexed positionId, uint128 liquidityAdded, uint256 amount0, uint256 amount1
    );
    event ProtocolPolPositionDecreased(
        PoolId indexed poolId, uint256 indexed positionId, uint128 liquidityRemoved, uint256 amount0, uint256 amount1
    );
    event ProtocolPolFeesCollected(PoolId indexed poolId, uint256 indexed positionId, uint256 amount0, uint256 amount1);
    event ProtocolPolPositionClosed(
        PoolId indexed poolId, uint256 indexed positionId, uint256 amount0, uint256 amount1
    );

    // --- Creation facet ---
    function quotePool(CreatePoolParams calldata params) external view returns (GeneralPoolQuote memory quote);
    function createPool(CreatePoolParams calldata params, bytes calldata creatorAuthorization)
        external
        payable
        returns (PoolId poolId);
    function invalidatePoolCreationNonce(uint256 nonce) external;

    // --- Admin facet ---
    function setPoolCreationFee(uint256 amount) external;
    function setDefaultProtocolPoolFeeRate(PoolSwapFeeRate calldata feeRate) external;
    function setProtocolPoolFeeRate(PoolId poolId, PoolSwapFeeRate calldata feeRate) external;
    function clearProtocolPoolFeeRate(PoolId poolId) external;
    function setBasketFeeAllocation(BasketFeeAllocation calldata allocation) external;
    function setGeneralFeeAllocation(GeneralFeeAllocation calldata allocation) external;
    function beginGeneralPoolDecommission(PoolId poolId) external;
    function finalizeGeneralPoolDecommission(PoolId poolId) external returns (uint256 amount0, uint256 amount1);
    function replaceLiquidityManager(address newManager) external;
    function setProtocolPoolMaintenanceConfig(ProtocolPoolMaintenanceConfig calldata config) external;
    function settleProtocolPoolRevenue(PoolId poolId, address asset)
        external
        returns (uint256 grossAmount, uint256 callerTip);
    function setProtocolPolOperator(address operator) external;
    function setProtocolPolActivationFee(uint256 amount) external;
    function activateProtocolPoolPol(PoolId poolId) external payable;
    function setProtocolPoolPolShare(PoolId poolId, uint16 shareBps) external;
    function clearProtocolPoolPolShare(PoolId poolId) external;
    function settleProtocolPoolPol(PoolId poolId, address asset, uint256 maximumAmount)
        external
        returns (uint256 amount);
    function openProtocolPolPosition(ProtocolPolOpenParams calldata params) external returns (uint256 positionId);
    function increaseProtocolPolPosition(ProtocolPolLiquidityParams calldata params) external;
    function decreaseProtocolPolPosition(ProtocolPolLiquidityParams calldata params) external;
    function collectProtocolPolFees(uint256 positionId, uint256 deadline) external;
    function closeProtocolPolPosition(
        uint256 positionId,
        uint256 amount0Minimum,
        uint256 amount1Minimum,
        uint256 deadline
    ) external;

    // --- View facet ---
    function protocolPool(PoolId poolId) external view returns (ProtocolPoolView memory pool);
    function isProtocolPool(PoolId poolId) external view returns (bool registered);
    function poolCreationFee() external view returns (uint256 amount);
    function protocolPolActivationFee() external view returns (uint256 amount);
    function protocolPolOperator() external view returns (address operator);
    function isPoolCreationNonceUsed(address creator, uint256 nonce) external view returns (bool used);
    function basketFeeAllocation() external view returns (BasketFeeAllocation memory allocation);
    function generalFeeAllocation() external view returns (GeneralFeeAllocation memory allocation);
    function defaultProtocolPoolFeeRate() external view returns (PoolSwapFeeRate memory feeRate);
    function protocolPoolFeeRate(PoolId poolId) external view returns (PoolFeeRateView memory feeRate);
    function protocolPoolCreator(PoolId poolId) external view returns (address creator);
    function protocolPoolMaintenanceConfig() external view returns (ProtocolPoolMaintenanceConfig memory config);
    function protocolPolPosition(uint256 positionId) external view returns (ProtocolPolPositionView memory position);
    function protocolPolPositionIds(PoolId poolId) external view returns (uint256[] memory positionIds);
}
