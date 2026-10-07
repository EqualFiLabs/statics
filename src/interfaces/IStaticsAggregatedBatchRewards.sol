// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IStaticsBatchRewards} from "./IStaticsBatchRewards.sol";

/// @notice Exact-transfer batch claims with one payout per distinct reward token.
interface IStaticsAggregatedBatchRewards {
    error IncompatibleAggregatedRewardTransfer(address asset, uint256 expected, uint256 debited, uint256 received);
    error AggregatedClaimRouteIncompatible(bytes4 selector);
    error InvalidAggregatedClaimContext();
    event AggregatedRewardPaid(address indexed receiver, address indexed asset, uint256 amount);

    function batchClaimRewardsAggregated(
        IStaticsBatchRewards.GlobalClaim[] calldata globalClaims,
        IStaticsBatchRewards.PoolClaim[] calldata lpClaims,
        IStaticsBatchRewards.PoolClaim[] calldata allocatorClaims,
        address receiver
    )
        external
        returns (uint256[][] memory globalReceived, uint256[][] memory lpReceived, uint256[][] memory allocatorReceived);
}
