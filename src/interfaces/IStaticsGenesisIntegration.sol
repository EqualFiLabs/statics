// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

interface IStaticsGenesisIntegration {
    event GenesisLinked(
        uint256 indexed positionId, uint256 indexed genesisId, address indexed owner, uint16 multiplierBps
    );
    event GenesisUnlinked(
        uint256 indexed positionId, uint256 indexed genesisId, address indexed owner, uint16 previousMultiplierBps
    );

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
}
