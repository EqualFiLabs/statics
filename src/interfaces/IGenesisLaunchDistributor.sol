// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

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

    function registerGenesis(uint256 genesisId) external;
    function accrue() external returns (uint256 staticsAmount, uint256 numeraireAmount);
    function claimGenesis(uint256 genesisId, address asset, address receiver) external returns (uint256 amount);
    function claimOwnerRewards(address asset, address receiver) external returns (uint256 amount);
    function claimTreasuryRewards(address asset, address receiver) external returns (uint256 amount);
    function acceptFeeReceiverRole() external;
    function acceptActivationConsumer() external;
    function setGenesisRewardShareBps(uint16 newShareBps) external;
    function finalizeLaunchRewards() external;
    function recoverSurplus(address asset, address receiver, uint256 amount) external;
    function pendingGenesis(uint256 genesisId, address asset) external view returns (uint256 amount);
    function rewardBook(address asset) external view returns (RewardBookView memory book);
}
