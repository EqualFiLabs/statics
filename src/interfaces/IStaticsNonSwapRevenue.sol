// SPDX-License-Identifier: BUSL-1.1
// ============================================================================
//                              STATICS PROTOCOL
//                         Markets that work for you.
//                       https://staticsprotocol.com
//                              EqualFi Labs
// ============================================================================
pragma solidity 0.8.33;

/// @notice Governance configuration for future non-swap fee accrual.
interface IStaticsNonSwapRevenue {
    event NonSwapStakerShareBpsSet(uint16 previousShareBps, uint16 newShareBps);

    /// @notice Defaults to 9,000; treasury receives the remainder of 10,000 bps.
    function nonSwapStakerShareBps() external view returns (uint16);
    /// @notice Owner-only. Accepts 0..10,000 and preserves already accrued balances.
    function setNonSwapStakerShareBps(uint16 shareBps) external;
}
