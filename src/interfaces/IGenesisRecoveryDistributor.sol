// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

/// @notice Recovery-reward capability required of every active Genesis fee distributor.
interface IGenesisRecoveryDistributor {
    event GenesisRecoveryAccrued(uint256 amount, uint256 pendingAmount, uint256 indexRay);
    event PendingGenesisRecoveryIndexed(uint256 amount, uint256 indexRay);
    event PendingGenesisRecoveryMigrated(address indexed successor, uint256 amount);
    event PendingGenesisRecoveryReceived(address indexed predecessor, uint256 amount);

    function checkpointGenesisRecovery(uint256 genesisId, address expectedOwner) external;
    function accrueGenesisRecovery(uint256 amount) external;
    function migratePendingGenesisRecovery(address successor) external returns (uint256 amount);
    function acceptPendingGenesisRecovery(uint256 amount) external;
    function genesisRecoveryVault() external view returns (address);
    function genesisRecoveryAsset() external view returns (address);
    function genesisRecoveryReady() external view returns (bool);
    function pendingGenesisRecovery() external view returns (uint256);
}
