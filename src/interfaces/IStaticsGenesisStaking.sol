// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

interface IStaticsGenesisStaking {
    struct GenesisState {
        uint8 tier;
        uint16 multiplierBps;
        uint256 linkedPositionId;
    }

    event GenesisLinked(uint256 indexed genesisId, uint256 indexed positionId, address indexed owner);
    event GenesisUnlinked(uint256 indexed genesisId, uint256 indexed positionId, address indexed owner);
    event GenesisActivated(
        uint256 indexed genesisId, uint8 previousTier, uint8 newTier, uint256 burnedAmount, uint16 multiplierBps
    );
    event GenesisActivationReset(uint256 indexed genesisId, address indexed previousOwner, address indexed newOwner);
    event GenesisActivationCostSet(uint8 indexed tier, uint256 previousCost, uint256 newCost);

    function linkGenesis(uint256 genesisId, uint256 positionId) external;
    function unlinkGenesis(uint256 genesisId) external;
    function activateGenesis(uint256 genesisId, uint8 targetTier, uint256 maxBurn) external;
    function setGenesisActivationCost(uint8 tier, uint256 cost) external;
    function onGenesisTransfer(uint256 genesisId, address previousOwner, address newOwner) external;

    function genesisCollection() external view returns (address);
    function genesisState(uint256 genesisId) external view returns (GenesisState memory state);
    function genesisTier(uint256 genesisId) external view returns (uint8);
    function genesisActivationCost(uint8 tier) external view returns (uint256);
    function linkedPosition(uint256 genesisId) external view returns (uint256);
    function linkedGenesis(uint256 positionId) external view returns (uint256);
    function positionRewardMultiplierBps(uint256 positionId) external view returns (uint16);
}
