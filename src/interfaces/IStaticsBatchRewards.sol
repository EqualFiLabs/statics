// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

/// @notice Bounded, atomic claims across PositionNFTs and reward sources.
interface IStaticsBatchRewards {
    struct GlobalClaim {
        uint256 positionId;
        address[] assets;
        uint256[] minimumAmounts;
    }

    struct PoolClaim {
        uint256 positionId;
        bytes32 poolId;
        uint8[] slots;
        uint256[] minimumAmounts;
    }

    error InvalidBatchReceiver(address receiver);
    error EmptyRewardBatch();
    error EmptyRewardClaim();
    error BatchClaimLimitExceeded(uint256 supplied, uint256 maximum);
    error BatchRewardEntryLimitExceeded(uint256 supplied, uint256 maximum);
    error BatchRewardLengthMismatch();
    error DuplicateGlobalClaim(uint256 positionId);
    error DuplicatePoolClaim(uint256 positionId, bytes32 poolId);
    error DuplicateBatchRewardAsset(address asset);
    error DuplicateBatchRewardSlot(uint8 slot);
    error InvalidBatchRewardSlot(uint8 slot);
    error BatchClaimRouteUnavailable(bytes4 selector);
    error BatchClaimReentrantCall();

    function batchClaimLimits() external pure returns (uint256 maxClaims, uint256 maxRewardEntries);

    /// @dev Results preserve category, group, and asset/slot order. Any failure reverts everything.
    function batchClaimRewards(
        GlobalClaim[] calldata globalClaims,
        PoolClaim[] calldata lpClaims,
        PoolClaim[] calldata allocatorClaims,
        address receiver
    )
        external
        returns (uint256[][] memory globalReceived, uint256[][] memory lpReceived, uint256[][] memory allocatorReceived);
}
