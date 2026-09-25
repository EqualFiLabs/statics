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
        uint16 releaseBps;
        uint16 pendingReleaseBps;
        uint64 pendingReleaseEpoch;
        uint64 deferredMaturityEpoch;
        uint256 available;
        uint256 deferred;
        uint256 committed;
    }

    struct PoolWeightView {
        uint256 scheduledWeight;
        bytes32 storedVersion;
        bytes32 currentVersion;
        bool stale;
    }

    struct EpochView {
        bool finalized;
        bool closed;
        uint16 releaseBps;
        uint40 activatedAt;
        uint40 finish;
        uint40 activationDeadline;
        uint256 nominalBudget;
        uint256 committedBudget;
        uint256 unactivatedBudget;
        uint256 totalWeight;
    }

    struct PoolEpochView {
        uint256 weight;
        bytes32 eligibilityVersion;
        uint64 restrictionSequence;
        uint256 budget;
        bool resolved;
        bool streamStarted;
    }

    struct AllocatorRewardView {
        address asset;
        bytes32 eligibilityVersion;
        bool finalized;
        bool expired;
        uint40 fundedAt;
        uint40 expiresAt;
        uint256 funded;
        uint256 totalWeight;
        uint256 distributable;
        uint256 remainingLiability;
    }

    struct AllocatorClaimPreview {
        uint8 slot;
        address asset;
        uint256 allocation;
        uint256 amount;
        bool finalized;
        bool claimed;
        bool expired;
    }

    event GaugeReserveFunded(address indexed funder, uint256 amount, uint64 indexed maturityEpoch);
    event GaugeReleaseBpsScheduled(uint16 releaseBps, uint64 indexed effectiveEpoch);
    event PositionGaugeAllocationsScheduled(
        uint256 indexed positionId, uint64 indexed effectiveEpoch, uint256 totalAllocated
    );
    event PositionGaugeAllocationsClearedByStakeLoss(uint256 indexed positionId, uint256 remainingStake);
    event GaugeEpochFinalized(
        uint64 indexed epoch,
        uint40 activatedAt,
        uint40 finish,
        uint16 releaseBps,
        uint256 nominalBudget,
        uint256 committedBudget,
        uint256 totalWeight
    );
    event ProtocolGaugeRewardCommitted(uint64 indexed epoch, PoolId indexed poolId, uint256 weight, uint256 budget);
    event ProtocolGaugeRewardRecycled(uint64 indexed epoch, PoolId indexed poolId, uint256 weight, uint256 budget);
    event GaugeEpochClosed(uint64 indexed epoch, uint256 recycled);
    event GaugeAllocatorRewardFinalized(
        PoolId indexed poolId,
        uint8 indexed slot,
        uint64 indexed epoch,
        address asset,
        uint256 distributable,
        uint256 totalWeight,
        uint40 expiresAt
    );
    event GaugeAllocatorRewardClaimed(
        uint256 indexed positionId,
        PoolId indexed poolId,
        uint64 indexed epoch,
        uint8 slot,
        address asset,
        address receiver,
        uint256 debited,
        uint256 received
    );
    event GaugeAllocatorRewardExpired(
        PoolId indexed poolId, uint8 indexed slot, uint64 indexed epoch, address asset, uint256 amount
    );

    error InvalidGaugeFundingAmount();
    error IncompatibleGaugeTokenTransfer(uint256 requested, uint256 received);
    error GaugeAllocationLengthMismatch();
    error GaugeAllocationLimitExceeded(uint256 count, uint256 maximum);
    error InvalidGaugeAllocation(PoolId poolId, uint256 amount);
    error DuplicateGaugeAllocation(PoolId poolId);
    error GaugeAllocationExceedsStake(uint256 allocated, uint256 staked);
    error GaugeEpochNotFinalized(uint64 epoch);
    error GaugeEpochActivationClosed(uint64 epoch, uint40 deadline, uint40 currentTime);
    error GaugeEpochActivationActive(uint64 epoch, uint40 deadline, uint40 currentTime);
    error GaugeEpochBudgetUnderflow(uint64 epoch, uint256 requested, uint256 available);
    error GaugeSelfCallOnly(address caller);
    error InvalidGaugeAllocatorSlot(PoolId poolId, uint8 slot);
    error GaugeAllocatorRewardNotFound(PoolId poolId, uint8 slot, uint64 epoch);
    error GaugeAllocatorEpochActive(uint64 epoch, uint40 finish, uint40 currentTime);
    error GaugeAllocatorRewardNotFinalized(PoolId poolId, uint8 slot, uint64 epoch);
    error GaugeAllocatorRewardAlreadyClaimed(uint256 positionId, PoolId poolId, uint8 slot, uint64 epoch);
    error GaugeAllocatorClaimExpired(PoolId poolId, uint8 slot, uint64 epoch, uint40 expiresAt);
    error GaugeAllocatorClaimWindowActive(
        PoolId poolId, uint8 slot, uint64 epoch, uint40 expiresAt, uint40 currentTime
    );
    error GaugeAllocatorLiabilityUnderflow(PoolId poolId, uint8 slot, uint64 epoch, uint256 liability, uint256 amount);
    error GaugeAllocatorClaimLengthMismatch();
    error DuplicateGaugeAllocatorSlot(uint8 slot);
    error InvalidGaugeAllocatorReceiver(address receiver);
    error GaugeAllocatorAmountBelowMinimum(address asset, uint256 received, uint256 minimum);

    function fundGaugeReserve(uint256 amount) external returns (uint256 received);
    function setGaugeAllocations(uint256 positionId, PoolId[] calldata poolIds, uint256[] calldata amounts) external;
    function checkpointGaugeEpoch() external returns (uint64 epoch, uint256 committedBudget, bool finalized);
    function checkpointGaugePool(PoolId poolId) external returns (uint256 committed, uint256 recycled);
    function closeGaugeEpoch(uint64 epoch) external returns (uint256 recycled);
    function scheduleGaugeReleaseBps(uint16 releaseBps) external;
    function syncGaugeAllocationsAfterStakeLoss(uint256 positionId, uint256 remainingStake) external;
    function finalizeGaugeAllocatorReward(PoolId poolId, uint8 slot, uint64 epoch)
        external
        returns (uint256 distributable);
    function claimGaugeAllocatorRewards(
        uint256 positionId,
        PoolId poolId,
        uint64 epoch,
        uint8[] calldata slots,
        uint256[] calldata minimumAmounts,
        address receiver
    ) external returns (uint256[] memory received);
    function expireGaugeAllocatorReward(PoolId poolId, uint8 slot, uint64 epoch) external returns (uint256 amount);

    function currentGaugeEpoch() external view returns (uint64 epoch);
    function gaugeEpochAt(uint256 timestamp) external pure returns (uint64 epoch);
    function gaugeReserve() external view returns (ReserveView memory state);
    function gaugePoolWeight(PoolId poolId) external view returns (PoolWeightView memory state);
    function gaugePositionAllocations(uint256 positionId)
        external
        view
        returns (
            uint64 activeEpoch,
            AllocationView[] memory active,
            uint64 pendingEpoch,
            AllocationView[] memory pending,
            uint256 lockedStake
        );
    function gaugeEpoch(uint64 epoch) external view returns (EpochView memory state);
    function previewGaugePoolReward(PoolId poolId, uint64 epoch) external view returns (PoolEpochView memory state);
    function maxGaugeAllocationsPerPosition() external pure returns (uint256);
    function maxWeeklyGaugeReleaseBps() external pure returns (uint16);
    function gaugeAllocatorReward(PoolId poolId, uint8 slot, uint64 epoch)
        external
        view
        returns (AllocatorRewardView memory state);
    function gaugePositionAllocationAt(uint256 positionId, PoolId poolId, uint64 epoch)
        external
        view
        returns (uint256 amount, bytes32 eligibilityVersion);
    function previewGaugeAllocatorRewards(uint256 positionId, PoolId poolId, uint64 epoch, uint8[] calldata slots)
        external
        view
        returns (AllocatorClaimPreview[] memory rewards);
    function gaugeAllocatorClaimWindow() external pure returns (uint64 epochs);
}
