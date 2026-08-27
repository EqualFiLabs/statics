// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

/// @notice Temporary launch reward index for registered Genesis NFTs.
interface IGenesisLaunchDistributor {
    struct RewardBookView {
        uint256 indexRay;
        uint256 indexRemainder;
        uint256 indexedAmount;
        uint256 crystallizedAmount;
        uint256 totalClaimable;
        uint256 totalClaimed;
        uint256 treasuryClaimable;
    }

    event GenesisRegistered(uint256 indexed genesisId, uint256 weight, uint256 totalWeight);
    event GenesisWeightChanged(
        uint256 indexed genesisId, uint256 previousWeight, uint256 newWeight, uint256 totalWeight
    );
    event RevenueAccrued(
        address indexed asset, uint256 amount, uint256 genesisAmount, uint256 treasuryAmount, uint256 indexRay
    );
    event GenesisRewardsClaimed(
        uint256 indexed genesisId, address indexed owner, address indexed asset, address receiver, uint256 amount
    );
    event OwnerRewardsClaimed(address indexed owner, address indexed asset, address indexed receiver, uint256 amount);
    event TreasuryRewardsClaimed(address indexed asset, address indexed receiver, uint256 amount);
    event GenesisRewardShareUpdated(uint16 previousShareBps, uint16 newShareBps);
    event LaunchRewardsFinalized(uint256 staticsIndexRay, uint256 numeraireIndexRay);
    event SurplusRecovered(address indexed asset, address indexed receiver, uint256 amount);

    /// @notice Registers a caller-owned Genesis and snapshots its current weight.
    /// @param genesisId Genesis token ID; vault-held Genesis cannot be registered.
    function registerGenesis(uint256 genesisId) external;
    /// @notice Harvests and indexes fee-receiver-attributed STATICS and numeraire revenue.
    function accrue() external returns (uint256 staticsAmount, uint256 numeraireAmount);
    /// @notice Claims one Genesis owner's rewards for one asset.
    /// @param genesisId Genesis token ID.
    /// @param asset STATICS or configured numeraire.
    /// @param receiver Recipient of the reward.
    function claimGenesis(uint256 genesisId, address asset, address receiver) external returns (uint256 amount);
    /// @notice Claims rewards crystallized for the caller as an owner.
    function claimOwnerRewards(address asset, address receiver) external returns (uint256 amount);
    /// @notice Claims the treasury's share of one asset's launch rewards.
    function claimTreasuryRewards(address asset, address receiver) external returns (uint256 amount);
    /// @notice Claims rewards for a caller-supplied list of caller-owned Genesis IDs.
    /// @dev The array is caller-bounded; callers should paginate large holdings.
    function claimAllGenesisRewards(uint256[] calldata genesisIds, address receiver)
        external
        returns (uint256 staticsAmount, uint256 numeraireAmount);
    /// @notice Claims both assets owed to the treasury.
    function claimAllGenesisTreasuryRewards(address receiver)
        external
        returns (uint256 staticsAmount, uint256 numeraireAmount);
    /// @notice Accepts the distributor's pending fee-receiver role.
    function acceptFeeReceiverRole() external;
    /// @notice Accepts the distributor's pending activation-consumer role.
    function acceptActivationConsumer() external;
    /// @notice Updates the Genesis reward share before finalization.
    function setGenesisRewardShareBps(uint16 newShareBps) external;
    /// @notice Stops new accrual and freezes the launch reward indexes.
    function finalizeLaunchRewards() external;
    /// @notice Recovers only assets exceeding indexed liabilities.
    function recoverSurplus(address asset, address receiver, uint256 amount) external;
    function finalized() external view returns (bool);
    function pendingGenesis(uint256 genesisId, address asset) external view returns (uint256 amount);
    function rewardBook(address asset) external view returns (RewardBookView memory book);
}
