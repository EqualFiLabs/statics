// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

interface IStaticsProtocolRevenue {
    struct ProtocolFeeDistribution {
        uint256 basketStaker;
        uint256 staticsStaker;
        uint256 creator;
        uint256 treasury;
    }

    event CreatorRevenueAccrued(PoolId indexed poolId, address indexed creator, address indexed asset, uint256 amount);
    event CreatorRevenueClaimed(
        PoolId indexed poolId,
        address indexed creator,
        address indexed asset,
        address receiver,
        uint256 amount,
        uint256 received
    );

    event PoolCreatorProposed(PoolId indexed poolId, address indexed creator, address indexed proposedCreator);
    event PoolCreatorProposalCancelled(PoolId indexed poolId, address indexed creator, address indexed proposedCreator);
    event PoolCreatorTransferred(PoolId indexed poolId, address indexed previousCreator, address indexed creator);
    event CreatorRevenueRecipientSet(PoolId indexed poolId, address indexed creator, address indexed recipient);

    function proposePoolCreator(PoolId poolId, address newCreator) external;
    function acceptPoolCreator(PoolId poolId) external;
    /// @notice Zero restores the current creator as the effective recipient.
    function setCreatorRevenueRecipient(PoolId poolId, address recipient) external;
    function poolCreatorConfiguration(PoolId poolId)
        external
        view
        returns (address creator, address pendingCreator, address revenueRecipient);

    function routeProtocolSwapFees(PoolId poolId, address asset, ProtocolFeeDistribution calldata distribution) external;
    /// @notice General-pool collection is permissionless and pays only the effective recipient.
    function claimCreatorRevenue(PoolId poolId, address asset, address receiver, uint256 minReceived)
        external
        returns (uint256 amount, uint256 received);
    function creatorRevenue(PoolId poolId, address asset) external view returns (uint256 amount);
    function totalCreatorRevenue(address asset) external view returns (uint256 amount);
    function canAccrueBasketRewards(PoolId poolId) external view returns (bool eligible);
    function protocolPolFundingConfig(PoolId poolId)
        external
        view
        returns (bool activated, bool overridden, uint16 shareBps);
}
