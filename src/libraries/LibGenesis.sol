// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

library LibGenesis {
    bytes32 internal constant STORAGE_POSITION = keccak256("statics.storage.genesis.v1");
    uint16 internal constant BASE_MULTIPLIER_BPS = 10_000;
    uint8 internal constant MAX_TIER = 4;
    uint256 internal constant MIN_ACTIVATION_COST = 1_000 ether;
    uint256 internal constant MAX_ACTIVATION_COST = 100_000 ether;

    struct GenesisStorage {
        address collection;
        address staticsToken;
        mapping(uint256 genesisId => uint8 tier) tiers;
        mapping(uint256 genesisId => uint256 positionId) linkedPosition;
        mapping(uint256 positionId => uint256 genesisId) linkedGenesis;
        mapping(uint8 tier => uint256 transitionCost) activationCosts;
    }

    error InvalidGenesisCollection();
    error InvalidStaticsToken();
    error GenesisAlreadyLinked(uint256 genesisId, uint256 positionId);
    error PositionAlreadyLinked(uint256 positionId, uint256 genesisId);
    error GenesisNotLinked(uint256 genesisId);
    error GenesisLinkedOnTransfer(uint256 genesisId, uint256 positionId);
    error InvalidActivationTier(uint8 currentTier, uint8 targetTier);
    error InvalidActivationCost(uint256 cost);

    function genesisStorage() internal pure returns (GenesisStorage storage gs) {
        bytes32 slot = STORAGE_POSITION;
        assembly ("memory-safe") {
            gs.slot := slot
        }
    }

    function initialize(address collection, address staticsToken) internal {
        if (collection == address(0) || collection.code.length == 0) revert InvalidGenesisCollection();
        if (staticsToken == address(0) || staticsToken.code.length == 0) revert InvalidStaticsToken();
        GenesisStorage storage gs = genesisStorage();
        if (gs.collection != address(0)) revert InvalidGenesisCollection();
        gs.collection = collection;
        gs.staticsToken = staticsToken;
        gs.activationCosts[1] = 10_000 ether;
        gs.activationCosts[2] = 20_000 ether;
        gs.activationCosts[3] = 30_000 ether;
        gs.activationCosts[4] = 40_000 ether;
    }

    function multiplierForTier(uint8 tier) internal pure returns (uint16) {
        if (tier == 0) return BASE_MULTIPLIER_BPS;
        if (tier == 1) return 11_000;
        if (tier == 2) return 11_500;
        if (tier == 3) return 12_000;
        if (tier == 4) return 12_500;
        revert InvalidActivationTier(MAX_TIER, tier);
    }

    function positionMultiplier(uint256 positionId) internal view returns (uint16) {
        GenesisStorage storage gs = genesisStorage();
        uint256 genesisId = gs.linkedGenesis[positionId];
        return genesisId == 0 ? BASE_MULTIPLIER_BPS : multiplierForTier(gs.tiers[genesisId]);
    }

    function cumulativeActivationCost(uint8 currentTier, uint8 targetTier) internal view returns (uint256 total) {
        if (targetTier <= currentTier || targetTier > MAX_TIER) {
            revert InvalidActivationTier(currentTier, targetTier);
        }
        GenesisStorage storage gs = genesisStorage();
        for (uint8 tier = currentTier + 1; tier <= targetTier; ++tier) {
            total += gs.activationCosts[tier];
        }
    }

    function setActivationCost(uint8 tier, uint256 cost) internal returns (uint256 previousCost) {
        if (tier == 0 || tier > MAX_TIER) revert InvalidActivationTier(0, tier);
        if (cost < MIN_ACTIVATION_COST || cost > MAX_ACTIVATION_COST) revert InvalidActivationCost(cost);
        GenesisStorage storage gs = genesisStorage();
        previousCost = gs.activationCosts[tier];
        gs.activationCosts[tier] = cost;
    }

    function link(uint256 genesisId, uint256 positionId) internal {
        GenesisStorage storage gs = genesisStorage();
        uint256 existingPosition = gs.linkedPosition[genesisId];
        if (existingPosition != 0) revert GenesisAlreadyLinked(genesisId, existingPosition);
        uint256 existingGenesis = gs.linkedGenesis[positionId];
        if (existingGenesis != 0) revert PositionAlreadyLinked(positionId, existingGenesis);
        gs.linkedPosition[genesisId] = positionId;
        gs.linkedGenesis[positionId] = genesisId;
    }

    function unlink(uint256 genesisId) internal returns (uint256 positionId) {
        GenesisStorage storage gs = genesisStorage();
        positionId = gs.linkedPosition[genesisId];
        if (positionId == 0) revert GenesisNotLinked(genesisId);
        delete gs.linkedPosition[genesisId];
        delete gs.linkedGenesis[positionId];
    }

    function clearPositionLink(uint256 positionId) internal returns (uint256 genesisId) {
        GenesisStorage storage gs = genesisStorage();
        genesisId = gs.linkedGenesis[positionId];
        if (genesisId == 0) return 0;
        delete gs.linkedGenesis[positionId];
        delete gs.linkedPosition[genesisId];
    }
}
