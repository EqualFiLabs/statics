// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.26 <0.9.0;

interface IStaticsGlobalRewards {
    struct RewardAssetView {
        uint256 actualEligibleStake;
        uint256 actualPendingStake;
        uint256 effectiveEligibleWeight;
        uint256 effectivePendingWeight;
        uint256 indexRay;
        uint256 indexedReserve;
        uint256 totalClaimable;
    }

    struct StakePositionView {
        uint256 stakedBalance;
        uint256 claimAssetCount;
        uint256 optedInAssetCount;
    }

    struct RewardSelectionView {
        bool selected;
        uint256 actualEligibleStake;
        uint256 actualPendingStake;
        uint256 effectiveEligibleWeight;
        uint256 effectivePendingWeight;
        uint40 eligibleAt;
    }

    event StakingPositionCreated(uint256 indexed positionId, address indexed owner, uint256 amount);
    event Staked(uint256 indexed positionId, address indexed payer, uint256 amount, uint256 totalPositionStake);
    event Unstaked(uint256 indexed positionId, address indexed receiver, uint256 amount, uint256 totalPositionStake);
    event RewardAssetOptedIn(
        uint256 indexed positionId,
        address indexed asset,
        uint256 actualPendingStake,
        uint256 effectivePendingWeight,
        uint40 eligibleAt
    );
    event RewardStakeScheduled(
        uint256 indexed positionId,
        address indexed asset,
        uint256 actualPendingStake,
        uint256 effectivePendingWeight,
        uint40 eligibleAt
    );
    event RewardBucketMatured(
        address indexed asset,
        uint40 indexed eligibleAt,
        uint256 actualStake,
        uint256 effectiveWeight,
        uint256 totalActualEligibleStake,
        uint256 totalEffectiveEligibleWeight,
        uint256 indexRay
    );
    event PositionRewardEligibilityActivated(
        uint256 indexed positionId,
        address indexed asset,
        uint256 actualStake,
        uint256 effectiveWeight,
        uint40 eligibleAt,
        uint256 activationIndexRay
    );
    event RewardAssetOptedOut(
        uint256 indexed positionId,
        address indexed asset,
        uint256 removedActualEligibleStake,
        uint256 removedActualPendingStake,
        uint256 removedEffectiveEligibleWeight,
        uint256 removedEffectivePendingWeight
    );
    event PositionRewardWeightChanged(
        uint256 indexed positionId,
        address indexed asset,
        uint16 previousMultiplierBps,
        uint16 newMultiplierBps,
        uint256 effectiveEligibleWeight,
        uint256 effectivePendingWeight
    );
    event RewardAssetDustRouted(address indexed asset, uint256 amount);
    event RewardBookCheckpointed(address indexed asset);
    event GlobalFeeAccrued(
        address indexed asset, uint256 grossFee, uint256 stakerAmount, uint256 treasuryAmount, uint256 indexRay
    );
    event PositionRewardSettled(uint256 indexed positionId, address indexed asset, uint256 amount);
    event RewardClaimed(uint256 indexed positionId, address indexed receiver, address indexed asset, uint256 amount);
    event TreasuryFeesDistributed(address indexed asset, address indexed treasury, uint256 amount);

    function createAndStake(uint256 amount, address receiver, address[] calldata rewardAssets)
        external
        payable
        returns (uint256 positionId);

    function stake(uint256 positionId, uint256 amount) external;

    function unstake(uint256 positionId, uint256 amount, address receiver) external;

    function optInRewardAssets(uint256 positionId, address[] calldata assets) external;

    function optOutRewardAssets(uint256 positionId, address[] calldata assets) external;

    function claimRewards(
        uint256 positionId,
        address[] calldata assets,
        address receiver,
        uint256[] calldata minAmountsOut
    ) external returns (uint256[] memory amountsOut);

    function distributeTreasuryFees(address asset) external returns (uint256 amount);

    function pendingRewards(uint256 positionId, address[] calldata assets)
        external
        view
        returns (uint256[] memory amounts);

    function stakePosition(uint256 positionId) external view returns (StakePositionView memory position);

    function rewardAsset(address asset) external view returns (RewardAssetView memory state);

    function positionRewardAssets(uint256 positionId) external view returns (address[] memory assets);

    function isRewardAssetOptedIn(uint256 positionId, address asset) external view returns (bool);

    function rewardSelection(uint256 positionId, address asset)
        external
        view
        returns (RewardSelectionView memory selection);

    function maxRewardAssetsPerPosition() external pure returns (uint256);

    function rewardEligibilityDelay() external pure returns (uint256);

    function rewardEligibilityBucketSize() external pure returns (uint256);

    function stakingToken() external view returns (address);

    function totalStaked() external view returns (uint256);

    function treasuryAccrued(address asset) external view returns (uint256);

    function canAccrueStakerRewards(address asset) external view returns (bool);
    function checkpointRewardAssets(address[] calldata assets) external;
    function rewardBookNeedsCheckpoint(address asset) external view returns (bool);
}
