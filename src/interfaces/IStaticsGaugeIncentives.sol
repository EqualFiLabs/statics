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
        uint16 releaseBps;
        uint8 winnerCount;
        uint40 activatedAt;
        uint40 finish;
        uint256 nominalBudget;
        uint256 committedBudget;
        uint256 totalWeight;
        PoolId[10] pools;
        uint256[10] weights;
        uint256[10] budgets;
    }

    event GaugeReserveFunded(address indexed funder, uint256 amount, uint64 indexed maturityEpoch);
    event GaugeReleaseBpsScheduled(uint16 releaseBps, uint64 indexed effectiveEpoch);
    event PositionGaugeAllocationsScheduled(
        uint256 indexed positionId, uint64 indexed effectiveEpoch, uint256 totalAllocated
    );
    event PositionGaugeAllocationsClearedByStakeLoss(uint256 indexed positionId, uint256 remainingStake);
    event GaugePoolWeightRefreshed(
        PoolId indexed poolId, bytes32 previousVersion, bytes32 currentVersion, uint256 removedWeight
    );
    event GaugeEpochFinalized(
        uint64 indexed epoch,
        uint40 activatedAt,
        uint40 finish,
        uint16 releaseBps,
        uint256 nominalBudget,
        uint256 committedBudget,
        uint256 totalWeight,
        uint8 winnerCount
    );
    event ProtocolGaugeRewardCommitted(uint64 indexed epoch, PoolId indexed poolId, uint256 weight, uint256 budget);

    error InvalidGaugeFundingAmount();
    error IncompatibleGaugeTokenTransfer(uint256 requested, uint256 received);
    error GaugeAllocationLengthMismatch();
    error GaugeAllocationLimitExceeded(uint256 count, uint256 maximum);
    error InvalidGaugeAllocation(PoolId poolId, uint256 amount);
    error DuplicateGaugeAllocation(PoolId poolId);
    error GaugeAllocationExceedsStake(uint256 allocated, uint256 staked);
    error GaugeEpochNotFinalized(uint64 epoch);
    error StaleGaugePoolWeight(PoolId poolId, bytes32 storedVersion, bytes32 currentVersion);
    error GaugePoolWeightCurrent(PoolId poolId);

    function fundGaugeReserve(uint256 amount) external returns (uint256 received);
    function setGaugeAllocations(uint256 positionId, PoolId[] calldata poolIds, uint256[] calldata amounts) external;
    function checkpointGaugeEpoch() external returns (uint64 epoch, uint256 committedBudget, bool finalized);
    function refreshGaugePoolWeight(PoolId poolId) external returns (uint256 removedWeight);
    function scheduleGaugeReleaseBps(uint16 releaseBps) external;

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
    function previewGaugeTopTen()
        external
        view
        returns (PoolId[] memory pools, uint256[] memory weights, bool stale, PoolId stalePool);
    function maxGaugeAllocationsPerPosition() external pure returns (uint256);
    function maxWeeklyGaugeReleaseBps() external pure returns (uint16);
}
