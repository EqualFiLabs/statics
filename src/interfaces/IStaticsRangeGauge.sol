// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

interface IStaticsRangeGauge {
    struct ProvideLiquidityParams {
        PoolId poolId;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint256 amount0Maximum;
        uint256 amount1Maximum;
        uint256 deadline;
    }

    struct IncreaseLiquidityParams {
        uint128 liquidity;
        uint256 amount0Maximum;
        uint256 amount1Maximum;
        uint256 deadline;
    }

    struct DecreaseLiquidityParams {
        uint128 liquidity;
        uint256 amount0Minimum;
        uint256 amount1Minimum;
        uint256 deadline;
    }

    struct RebalanceLiquidityParams {
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint256 amount0Maximum;
        uint256 amount1Maximum;
        uint256 amount0Minimum;
        uint256 amount1Minimum;
        uint256 deadline;
    }

    struct LiquidityMovement {
        uint256 posmTokenId;
        uint128 liquidity;
        uint256 spent0;
        uint256 received0;
        uint256 spent1;
        uint256 received1;
    }

    struct PoolRewardConfigView {
        bool initialized;
        uint8 slotCount;
        address[5] assets;
        uint16[5] allocatorShareBps;
    }

    struct GaugePoolView {
        bool initialized;
        bool stopped;
        uint40 stoppedAt;
        int24 referenceTick;
        uint128 activeGaugeLiquidity;
        uint64 managedLegCount;
        uint64 unresolvedLegCount;
    }

    struct GaugeRewardStreamView {
        bool assigned;
        uint8 slot;
        address asset;
        uint64 protocolEpoch;
        uint40 periodStart;
        uint40 periodFinish;
        uint40 lastUpdate;
        uint256 periodBudget;
        uint256 periodEmitted;
        uint256 periodRecycled;
        uint256 globalIndexRay;
        uint256 indexRemainder;
        uint256 indexedLiability;
        uint256 claimLiability;
        uint256 indexCapacityUsed;
    }

    struct GaugeBoundaryView {
        uint128 grossLiquidity;
        int128 netLiquidity;
        uint256[5] rewardOutsideRay;
    }

    struct LpLegView {
        address manager;
        uint256 posmTokenId;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint256[5] checkpointInsideRay;
        uint256[5] rewardRemainderRay;
        uint256[5] claimable;
    }

    struct PendingRewardsView {
        uint8 slotCount;
        address[5] assets;
        uint256[5] amounts;
    }

    event GaugeRewardAssetAllowedSet(address indexed asset, bool allowed);
    event GaugeRewardDurationSet(uint40 duration);
    event PoolRewardAssetAppended(PoolId indexed poolId, address indexed asset, uint8 indexed slot);
    event PoolRewardAllocatorShareSet(PoolId indexed poolId, uint8 indexed slot, uint16 allocatorShareBps);
    event PoolRewardFunded(
        PoolId indexed poolId,
        address indexed asset,
        address indexed funder,
        uint8 slot,
        uint256 received,
        uint256 lpAmount,
        uint40 periodFinish
    );
    event PoolAllocatorRewardFunded(
        PoolId indexed poolId,
        address indexed asset,
        address indexed funder,
        uint8 slot,
        uint256 allocatorAmount,
        uint64 allocatorEpoch
    );
    event ManagedLiquidityProvided(
        uint256 indexed positionId,
        PoolId indexed poolId,
        uint256 indexed posmTokenId,
        address manager,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity
    );
    event ManagedLiquidityAttached(
        uint256 indexed positionId,
        PoolId indexed poolId,
        uint256 indexed posmTokenId,
        address manager,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity
    );
    event ManagedLiquidityChanged(
        uint256 indexed positionId, PoolId indexed poolId, uint256 indexed posmTokenId, uint128 liquidity
    );
    event ManagedLiquidityRebalanced(
        uint256 indexed positionId,
        PoolId indexed poolId,
        uint256 indexed oldPosmTokenId,
        uint256 newPosmTokenId,
        address manager,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity
    );
    event ManagedLiquidityExited(uint256 indexed positionId, PoolId indexed poolId, uint256 indexed posmTokenId);
    event LpRewardsClaimed(
        uint256 indexed positionId,
        PoolId indexed poolId,
        address indexed asset,
        uint8 slot,
        address receiver,
        uint256 debited,
        uint256 received
    );
    event LpRewardForfeited(
        uint256 indexed positionId, PoolId indexed poolId, address indexed asset, uint8 slot, uint256 amount
    );
    event UnboundPosmRecovered(address indexed manager, uint256 indexed posmTokenId, address indexed receiver);
    event PoolRewardSurplusReconciled(PoolId indexed poolId, address indexed asset, uint8 indexed slot, uint256 amount);
    event PoolGaugeStopped(PoolId indexed poolId);

    error ActionPaused(uint256 action);
    error InvalidPublicPool(PoolId poolId);
    error PublicPoolDecommissioned(PoolId poolId);
    error GaugeStopped(PoolId poolId);
    error NotPoolCreator(PoolId poolId, address caller, address creator);
    error GaugeRewardAssetNotAllowed(address asset);
    error GaugeRewardAssetRestricted(address asset);
    error GaugeRewardAssetNotAssigned(PoolId poolId, address asset);
    error GaugeRewardSlotNotAssigned(PoolId poolId, uint8 slot);
    error ProtocolRewardSlotReserved(PoolId poolId);
    error InvalidAllocatorShareBps(uint256 allocatorShareBps);
    error AllocatorShareChanged(uint16 expectedAllocatorShareBps, uint16 actualAllocatorShareBps);
    error GaugeAllocatorPoolIneligible(PoolId poolId);
    error MinimumRemainingDurationNotMet(uint40 available, uint40 minimum);
    error RewardBudgetExceedsIndexCapacity(uint256 committedBudget, uint256 received, uint256 maximumBudget);
    error InvalidReceiver(address receiver);
    error ArrayLengthMismatch();
    error DuplicateRewardSlot(uint8 slot);
    error ManagedLegAlreadyExists(uint256 positionId, PoolId poolId);
    error ManagedLegNotFound(uint256 positionId, PoolId poolId);
    error UnauthorizedPositionActor(uint256 positionId, address caller);
    error LiquidityManagerNotInstalled();
    error LiquidityManagerBindingMismatch(address manager, address expected, address actual);
    error NotPosmOwner(uint256 posmTokenId, address caller, address owner);
    error PositionMutationMismatch(uint256 posmTokenId);
    error InputDebitExceedsMaximum(address asset, uint256 debit, uint256 maximum);
    error ManagerAssetTransferMismatch(address asset, uint256 expected, uint256 actual);
    error InvalidPositionState(uint256 positionId, PoolId poolId);
    error RewardAmountBelowMinimum(address asset, uint256 received, uint256 minimum);
    error PoolRewardReconciliationUnavailable(PoolId poolId, uint8 slot);
    error ClaimLiabilityUnderflow(PoolId poolId, uint8 slot, uint256 liability, uint256 amount);

    function setGaugeRewardAssetAllowed(address asset, bool allowed) external;
    function setGaugeRewardDuration(uint40 duration) external;
    function appendPoolRewardAsset(PoolId poolId, address asset) external returns (uint8 slot);
    function setPoolRewardAllocatorShare(PoolId poolId, uint8 slot, uint16 allocatorShareBps) external;
    function fundPoolReward(
        PoolId poolId,
        uint8 slot,
        uint256 amount,
        uint40 minRemainingDuration,
        uint16 expectedAllocatorShareBps
    ) external returns (uint256 received);

    function installLiquidityManager(address manager) external;
    function replaceLiquidityManager(address newManager) external;
    function provideLiquidity(uint256 positionId, ProvideLiquidityParams calldata params)
        external
        returns (LiquidityMovement memory movement);
    function attachLiquidity(uint256 positionId, PoolId poolId, uint256 posmTokenId)
        external
        returns (LiquidityMovement memory movement);
    function increaseLiquidity(uint256 positionId, PoolId poolId, IncreaseLiquidityParams calldata params)
        external
        returns (LiquidityMovement memory movement);
    function decreaseLiquidity(uint256 positionId, PoolId poolId, DecreaseLiquidityParams calldata params)
        external
        returns (LiquidityMovement memory movement);
    function collectNativeFees(
        uint256 positionId,
        PoolId poolId,
        uint256 amount0Minimum,
        uint256 amount1Minimum,
        uint256 deadline
    ) external returns (LiquidityMovement memory movement);
    function rebalanceLiquidity(uint256 positionId, PoolId poolId, RebalanceLiquidityParams calldata params)
        external
        returns (LiquidityMovement memory movement);
    function exitLiquidity(
        uint256 positionId,
        PoolId poolId,
        uint256 amount0Minimum,
        uint256 amount1Minimum,
        uint256 deadline
    ) external returns (LiquidityMovement memory movement);
    function claimLpRewards(
        uint256 positionId,
        PoolId poolId,
        uint8[] calldata slots,
        uint256[] calldata minimumAmounts,
        address receiver
    ) external returns (uint256[] memory received);
    function forfeitLpReward(uint256 positionId, PoolId poolId, uint8 slot) external returns (uint256 amount);
    function recoverUnboundPosm(address manager, uint256 posmTokenId, address receiver) external;
    function reconcilePoolRewardSurplus(PoolId poolId, uint8 slot) external returns (uint256 amount);

    function gaugeRewardDuration() external view returns (uint40 duration);
    function gaugeRewardAssetAllowed(address asset) external view returns (bool allowed);
    function poolRewardConfig(PoolId poolId) external view returns (PoolRewardConfigView memory config);
    function gaugePool(PoolId poolId) external view returns (GaugePoolView memory pool);
    function poolRewardStream(PoolId poolId, uint8 slot) external view returns (GaugeRewardStreamView memory stream);
    function poolRewardCustodyAccount(PoolId poolId, uint8 slot) external view returns (bytes32 account, bool assigned);
    function gaugeBoundary(PoolId poolId, int24 tick) external view returns (GaugeBoundaryView memory boundary);
    function lpLeg(uint256 positionId, PoolId poolId) external view returns (LpLegView memory leg);
    function positionGaugePools(uint256 positionId, uint256 cursor, uint256 size)
        external
        view
        returns (PoolId[] memory poolIds, uint256 nextCursor);
    function posmBinding(uint256 posmTokenId) external view returns (bytes32 binding);
    function liquidityManager() external view returns (address manager, bool installed);
    function recordedLiquidityManager(uint256 positionId, PoolId poolId) external view returns (address manager);
    function previewLpRewards(uint256 positionId, PoolId poolId)
        external
        view
        returns (PendingRewardsView memory pending);
}
