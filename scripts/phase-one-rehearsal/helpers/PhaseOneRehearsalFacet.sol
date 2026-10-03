// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

/// @notice Ephemeral facet used only by the fork rehearsal to exercise the
/// production Diamond upgrade surface. It is added and removed in one scenario.
contract PhaseOneRehearsalFacet {
    function rehearsalPing() external pure returns (bytes32) {
        return keccak256("statics-phase-one-rehearsal");
    }
}
