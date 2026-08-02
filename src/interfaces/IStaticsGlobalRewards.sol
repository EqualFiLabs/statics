// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.26 <0.9.0;

interface IStaticsGlobalRewards {
    enum RewardAssetStatus {
        None,
        Active,
        Retiring
    }

    struct RewardAssetView {
        address asset;
        RewardAssetStatus status;
        uint64 generation;
        uint256 indexRay;
        uint256 indexRemainder;
        uint256 indexedReserve;
        uint256 totalClaimable;
        uint256 retirementCursor;
        uint256 retirementHighWater;
    }

    struct StakePositionView {
        uint256 stakedBalance;
        uint256 unstakeAvailableAt;
        uint256 claimAssetCount;
    }

    event StakingPositionCreated(uint256 indexed positionId, address indexed owner, uint256 amount);
    event Staked(uint256 indexed positionId, address indexed payer, uint256 amount, uint256 totalPositionStake);
    event Unstaked(uint256 indexed positionId, address indexed receiver, uint256 amount, uint256 totalPositionStake);
    event RewardAssetActivated(uint8 indexed slot, address indexed asset, uint64 generation);
    event RewardAssetQueued(address indexed asset);
    event RewardAssetRetirementStarted(
        uint8 indexed slot, address indexed asset, uint64 generation, uint256 positionHighWater
    );
    event RewardAssetRetirementProgress(uint8 indexed slot, uint256 fromPositionId, uint256 throughPositionId);
    event RewardAssetRetired(uint8 indexed slot, address indexed asset, uint64 generation);
    event GlobalFeeAccrued(
        address indexed asset, uint256 grossFee, uint256 stakerAmount, uint256 treasuryAmount, uint256 indexRay
    );
    event PositionRewardSettled(uint256 indexed positionId, address indexed asset, uint64 generation, uint256 amount);
    event RewardClaimed(uint256 indexed positionId, address indexed receiver, address indexed asset, uint256 amount);
    event TreasuryFeesDistributed(address indexed asset, address indexed treasury, uint256 amount);

    function createAndStake(uint256 amount, address receiver) external returns (uint256 positionId);

    function stake(uint256 positionId, uint256 amount) external;

    function unstake(uint256 positionId, uint256 amount, address receiver) external;

    function claimRewards(uint256 positionId, address[] calldata assets, address receiver, uint256[] calldata minAmountsOut)
        external
        returns (uint256[] memory amountsOut);

    function distributeTreasuryFees(address asset) external returns (uint256 amount);

    function routeSwapFees(address asset, uint256 stakerAmount, uint256 treasuryAmount) external;

    function beginRewardAssetRetirement(uint256 slot) external;

    function settleRetiringRewardAsset(uint256 slot, uint256 maxPositions)
        external
        returns (uint256 nextPositionId, bool complete);

    function finalizeRewardAssetRetirement(uint256 slot, address replacement) external;

    function pendingRewards(uint256 positionId, address[] calldata assets)
        external
        view
        returns (uint256[] memory amounts);

    function stakePosition(uint256 positionId) external view returns (StakePositionView memory position);

    function rewardAsset(uint256 slot) external view returns (RewardAssetView memory state);

    function rewardAssetSlot(address asset) external view returns (uint256 slot, bool activeOrRetiring);

    function queuedRewardAsset(address asset) external view returns (bool queued);

    function rewardAssetQueue(uint256 offset, uint256 limit)
        external
        view
        returns (address[] memory assets, bool[] memory queued, uint256 totalLength);

    function stakingToken() external view returns (address);

    function totalStaked() external view returns (uint256);

    function treasuryAccrued(address asset) external view returns (uint256);

    function canAccrueStakerRewards(address asset) external view returns (bool);
}
