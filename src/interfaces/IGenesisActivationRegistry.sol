// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

interface IGenesisActivationConsumer {
    function onGenesisTransition(
        uint256 genesisId,
        address previousOwner,
        address nextOwner,
        uint16 previousMultiplierBps,
        uint16 nextMultiplierBps
    ) external;
}

interface IGenesisActivationRegistry {
    event GenesisCollectionBound(address indexed collection);
    event GenesisActivated(uint256 indexed genesisId, uint8 previousTier, uint8 newTier, uint256 staticsPaid);
    event GenesisActivationReset(uint256 indexed genesisId, address indexed previousOwner, address indexed nextOwner);
    event TierCostUpdated(uint8 indexed tier, uint256 previousCost, uint256 newCost);
    event ConsumerProposed(address indexed currentConsumer, address indexed pendingConsumer);
    event ConsumerAccepted(address indexed previousConsumer, address indexed newConsumer);

    function treasury() external view returns (address);
    function genesisCollection() external view returns (address);
    function tierOf(uint256 genesisId) external view returns (uint8);
    function multiplierBps(uint256 genesisId) external view returns (uint16);
    function tierCost(uint8 tier) external view returns (uint256);
    function activeConsumer() external view returns (address);
    function pendingConsumer() external view returns (address);
    function bindGenesisCollection(address collection) external;
    function activate(uint256 genesisId, uint8 targetTier) external returns (uint256 paid);
    function onGenesisTransfer(uint256 genesisId, address previousOwner, address nextOwner) external;
    function setTierCost(uint8 tier, uint256 newCost) external;
    function proposeConsumer(address consumer) external;
    function acceptConsumer() external;
}
