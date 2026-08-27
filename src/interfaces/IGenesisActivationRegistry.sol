// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

interface IGenesisActivationConsumer {
    /// @notice Receives a Genesis ownership or activation-weight transition.
    /// @param genesisId Genesis token ID.
    /// @param previousOwner Previous token owner.
    /// @param nextOwner New token owner.
    /// @param previousMultiplierBps Previous activation multiplier in basis points.
    /// @param nextMultiplierBps New activation multiplier in basis points.
    function onGenesisTransition(
        uint256 genesisId,
        address previousOwner,
        address nextOwner,
        uint16 previousMultiplierBps,
        uint16 nextMultiplierBps
    ) external;
}

/// @notice Tier, pricing, and consumer-callback interface for Genesis activation.
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
    /// @notice Permanently binds the Genesis ERC-721 collection during bootstrap.
    /// @param collection Genesis collection address.
    function bindGenesisCollection(address collection) external;
    /// @notice Raises a caller-owned Genesis to a higher tier and transfers the cumulative cost.
    /// @param genesisId Genesis token ID.
    /// @param targetTier Desired tier, greater than the current tier.
    /// @return paid Total STATICS paid for all intermediate tiers.
    function activate(uint256 genesisId, uint8 targetTier) external returns (uint256 paid);
    /// @notice Called by the Genesis collection before an ownership-changing transfer.
    /// @param genesisId Genesis token ID.
    /// @param previousOwner Previous token owner.
    /// @param nextOwner New token owner.
    function onGenesisTransfer(uint256 genesisId, address previousOwner, address nextOwner) external;
    /// @notice Updates one cumulative tier cost within its configured bounds.
    /// @param tier Tier number (nonzero).
    /// @param newCost New cumulative STATICS cost.
    function setTierCost(uint8 tier, uint256 newCost) external;
    /// @notice Proposes a consumer for two-step acceptance.
    /// @param consumer Proposed activation consumer contract.
    function proposeConsumer(address consumer) external;
    /// @notice Accepts the caller's pending activation consumer appointment.
    function acceptConsumer() external;
}
