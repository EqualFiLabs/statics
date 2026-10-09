// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

interface IStaticsGaugeIncentives {
    struct AllocationView {
        PoolId poolId;
        uint256 amount;
        bytes32 eligibilityVersion;
    }

    struct ReserveView {
        bool activated;
        uint16 releaseBps;
        uint16 pendingReleaseBps;
        uint40 pendingReleaseAt;
        uint40 deferredMaturityAt;
        uint40 scheduleStart;
        uint40 lastCheckpoint;
        uint40 periodStart;
        uint40 periodFinish;
        uint64 currentPeriod;
        uint40 allocationCooldown;
        uint256 available;
        uint256 deferred;
        uint256 committed;
        uint256 periodBudget;
        uint256 periodAccounted;
        uint256 totalAllocatedWeight;
        uint256 globalIndexX160;
        uint256 unsettledRoutingLiability;
    }

    struct PoolWeightView {
        uint256 weight;
        bytes32 storedVersion;
        bytes32 currentVersion;
        uint64 restrictionSequence;
        uint256 indexCursorX160;
        uint256 pendingReward;
        bool stale;
    }

    struct AllocatorRewardView {
        address asset;
        bytes32 eligibilityVersion;
        uint64 fundingRestrictionSequence;
        uint40 periodStart;
        uint40 periodFinish;
        uint40 lastUpdate;
        uint256 periodBudget;
        uint256 periodEmitted;
        uint256 globalIndexX160;
        uint256 indexedLiability;
        uint256 claimLiability;
        bool terminated;
    }

    struct AllocatorClaimPreview {
        uint8 slot;
        address asset;
        uint256 allocation;
        uint256 amount;
    }

    event GaugeReserveFunded(address indexed funder, uint256 amount, uint40 indexed maturityAt);
    event GaugeScheduleActivated(uint40 indexed scheduleStart, uint40 indexed firstPeriodFinish, uint256 budget);
    event GaugeReleaseBpsScheduled(uint16 releaseBps, uint40 indexed effectiveAt);
    event GaugeAllocationCooldownSet(uint40 cooldown);
    event PositionGaugeAllocationsSet(
        uint256 indexed positionId,
        uint40 indexed nextAllocationAt,
        uint256 totalAllocated,
        PoolId[] poolIds,
        uint256[] amounts
    );
    event PositionGaugeAllocationCooldownExtended(uint256 indexed positionId, uint40 indexed nextAllocationAt);
    event PositionGaugeAllocationsClearedByStakeLoss(uint256 indexed positionId, uint256 remainingStake);
    event GaugePeriodStarted(
        uint64 indexed period,
        uint40 indexed start,
        uint40 indexed finish,
        uint16 releaseBps,
        uint256 budget,
        uint256 totalAllocatedWeight
    );
    event ProtocolGaugeRewardCredited(PoolId indexed poolId, uint256 amount);
    event ProtocolGaugeRewardRecycled(PoolId indexed poolId, uint256 amount);
    event GaugeAllocatorRewardClaimed(
        uint256 indexed positionId,
        PoolId indexed poolId,
        uint8 indexed slot,
        address asset,
        address receiver,
        uint256 debited,
        uint256 received
    );
    event GaugeAllocatorRewardForfeited(
        uint256 indexed positionId, PoolId indexed poolId, uint8 indexed slot, address asset, uint256 amount
    );

    error InvalidGaugeFundingAmount();
    error IncompatibleGaugeTokenTransfer(uint256 requested, uint256 received);
    error GaugeAllocationLengthMismatch();
    error GaugeAllocationLimitExceeded(uint256 count, uint256 maximum);
    error InvalidGaugeAllocation(PoolId poolId, uint256 amount);
    error DuplicateGaugeAllocation(PoolId poolId);
    error GaugeAllocationExceedsStake(uint256 allocated, uint256 staked);
    error GaugeSelfCallOnly(address caller);
    error InvalidGaugeAllocatorSlot(PoolId poolId, uint8 slot);
    error GaugeAllocatorClaimLengthMismatch();
    error DuplicateGaugeAllocatorSlot(uint8 slot);
    error InvalidGaugeAllocatorReceiver(address receiver);
    error GaugeAllocatorAmountBelowMinimum(address asset, uint256 received, uint256 minimum);
    error GaugeAllocatorLiabilityUnderflow(PoolId poolId, uint8 slot, uint256 liability, uint256 amount);
    error InvalidGaugeTimestamp(uint256 timestamp);
    error InvalidGaugeAllocatorPoolPageSize(uint256 requested, uint256 maximum);
    error GaugeAllocatorPoolIndexCorrupted(uint256 positionId, PoolId poolId);

    function fundGaugeReserve(uint256 amount) external returns (uint256 received);
    function activateGaugeSchedule() external returns (uint256 budget);
    function setGaugeAllocations(uint256 positionId, PoolId[] calldata poolIds, uint256[] calldata amounts) external;
    function checkpointGaugeSchedule(uint16 maxPeriods)
        external
        returns (uint64 period, uint16 periodsProcessed, uint256 newlyAccounted);
    function checkpointGaugePool(PoolId poolId) external returns (uint256 credited, uint256 recycled);
    function scheduleGaugeReleaseBps(uint16 releaseBps) external;
    function setGaugeAllocationCooldown(uint40 cooldown) external;
    function syncGaugeAllocationsAfterStakeLoss(uint256 positionId, uint256 remainingStake) external;
    function claimGaugeAllocatorRewards(
        uint256 positionId,
        PoolId poolId,
        uint8[] calldata slots,
        uint256[] calldata minimumAmounts,
        address receiver
    ) external returns (uint256[] memory received);
    function forfeitGaugeAllocatorReward(uint256 positionId, PoolId poolId, uint8 slot)
        external
        returns (uint256 amount);

    function currentGaugePeriod() external view returns (uint64 period);
    function gaugePeriodAt(uint256 timestamp) external view returns (uint64 period, bool active);
    function gaugeReserve() external view returns (ReserveView memory state);
    function gaugePoolWeight(PoolId poolId) external view returns (PoolWeightView memory state);
    function gaugePositionAllocations(uint256 positionId)
        external
        view
        returns (uint40 nextAllocationAt, uint256 totalAllocated, AllocationView[] memory active, uint256 lockedStake);
    function previewGaugePoolReward(PoolId poolId) external view returns (uint256 amount, bool eligible);
    function maxGaugeAllocationsPerPosition() external pure returns (uint256);
    function maxWeeklyGaugeReleaseBps() external pure returns (uint16);
    function maxGaugeCatchupPeriods() external pure returns (uint16);
    function gaugeAllocationCooldown() external view returns (uint40 cooldown);
    function gaugeAllocatorReward(PoolId poolId, uint8 slot) external view returns (AllocatorRewardView memory state);
    function previewGaugeAllocatorRewards(uint256 positionId, PoolId poolId, uint8[] calldata slots)
        external
        view
        returns (AllocatorClaimPreview[] memory rewards);
    function positionGaugeAllocatorPools(uint256 positionId, uint256 cursor, uint256 limit)
        external
        view
        returns (PoolId[] memory poolIds, uint256 nextCursor);
}
