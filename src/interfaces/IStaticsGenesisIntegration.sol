// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

interface IStaticsGenesisIntegration {
    struct GenesisRewardBookView {
        uint256 indexRay;
        uint256 indexRemainder;
        uint256 indexedAmount;
        uint256 crystallizedAmount;
        uint256 totalClaimable;
        uint256 totalClaimed;
        uint256 treasuryClaimable;
    }

    event GenesisLinked(
        uint256 indexed positionId, uint256 indexed genesisId, address indexed owner, uint16 multiplierBps
    );
    event GenesisUnlinked(
        uint256 indexed positionId, uint256 indexed genesisId, address indexed owner, uint16 previousMultiplierBps
    );
    event GenesisRegistered(uint256 indexed genesisId, uint256 weight, uint256 totalWeight);
    event GenesisWeightChanged(
        uint256 indexed genesisId, uint256 previousWeight, uint256 newWeight, uint256 totalWeight
    );
    event GenesisRevenueAccrued(
        address indexed asset, uint256 amount, uint256 genesisAmount, uint256 treasuryAmount, uint256 indexRay
    );
    event GenesisRewardsClaimed(
        uint256 indexed genesisId, address indexed owner, address indexed asset, address receiver, uint256 amount
    );
    event GenesisOwnerRewardsClaimed(
        address indexed owner, address indexed asset, address indexed receiver, uint256 amount
    );
    event GenesisTreasuryRewardsClaimed(address indexed asset, address indexed receiver, uint256 amount);
    event GenesisRewardShareUpdated(uint16 previousShareBps, uint16 newShareBps);
    event GenesisRecoveryAccrued(uint256 amount, uint256 pendingAmount, uint256 indexRay);
    event PendingGenesisRecoveryIndexed(uint256 amount, uint256 indexRay);
    event PendingGenesisRecoveryMigrated(address indexed successor, uint256 amount);
    event PendingGenesisRecoveryReceived(address indexed predecessor, uint256 amount);

    function linkGenesis(uint256 positionId, uint256 genesisId) external;
    function unlinkGenesis(uint256 positionId, uint256 genesisId) external;
    function linkedGenesis(uint256 positionId) external view returns (uint256 genesisId);
    function linkedPosition(uint256 genesisId) external view returns (uint256 positionId);
    function genesisCollection() external view returns (address);
    function genesisRecoveryVault() external view returns (address);
    function genesisRecoveryAsset() external view returns (address);
    function genesisRecoveryReady() external view returns (bool);
    function genesisIntegrationReady() external view returns (bool);
    function genesisRecoveryCallback() external pure returns (bytes4 acknowledgement);
    function onGenesisRecovery(uint256 genesisId, address previousOwner) external returns (bytes4 acknowledgement);
    function onGenesisTransition(
        uint256 genesisId,
        address previousOwner,
        address nextOwner,
        uint16 previousMultiplierBps,
        uint16 nextMultiplierBps
    ) external;
    function acceptGenesisDistributorRole() external;
    function acceptGenesisConsumerRole() external;
    function registerGenesis(uint256 genesisId) external;
    function accrueGenesisRewards() external returns (uint256 staticsAmount, uint256 numeraireAmount);
    function claimGenesisRewards(uint256 genesisId, address asset, address receiver) external returns (uint256 amount);
    function claimGenesisOwnerRewards(address asset, address receiver) external returns (uint256 amount);
    function claimGenesisTreasuryRewards(address asset, address receiver) external returns (uint256 amount);
    function setGenesisRewardShareBps(uint16 newShareBps) external;
    function checkpointGenesisRecovery(uint256 genesisId, address expectedOwner) external;
    function accrueGenesisRecovery(uint256 amount) external;
    function migratePendingGenesisRecovery(address successor) external returns (uint256 amount);
    function acceptPendingGenesisRecovery(uint256 amount) external;
    function pendingGenesisRewards(uint256 genesisId, address asset) external view returns (uint256 amount);
    function genesisRewardBook(address asset) external view returns (GenesisRewardBookView memory book);
    function genesisRegistered(uint256 genesisId) external view returns (bool);
    function genesisEffectiveWeight(uint256 genesisId) external view returns (uint256);
    function genesisTotalWeight() external view returns (uint256);
    function genesisRewardShareBps() external view returns (uint16);
    function genesisOwnerClaimable(address owner, address asset) external view returns (uint256);
    function pendingGenesisRecovery() external view returns (uint256);
}
