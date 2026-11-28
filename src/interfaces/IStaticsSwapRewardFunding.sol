// SPDX-License-Identifier: BUSL-1.1
// ============================================================================
//                              STATICS PROTOCOL
//                         Markets that work for you.
//                       https://staticsprotocol.com
//                              EqualFi Labs
// ============================================================================
pragma solidity 0.8.33;

interface IStaticsSwapRewardFunding {
    function fundPublicSwapRewards(address asset, uint256 amount) external returns (uint256 funded);
}
