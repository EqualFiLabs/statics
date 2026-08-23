// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

/// @notice Recovery-reward capability required of every active Genesis fee distributor.
interface IGenesisRecoveryDistributor {
    event GenesisRecoveryAccrued(uint256 amount, uint256 pendingAmount, uint256 indexRay);
    event PendingGenesisRecoveryIndexed(uint256 amount, uint256 indexRay);

    function accrueGenesisRecovery(uint256 amount) external;
    function genesisRecoveryVault() external view returns (address);
    function genesisRecoveryAsset() external view returns (address);
    function pendingGenesisRecovery() external view returns (uint256);
}
