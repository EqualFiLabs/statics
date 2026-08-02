// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

library LibGovernance {
    bytes32 internal constant GOVERNANCE_STORAGE_POSITION = keccak256("statics.storage.governance");

    uint256 internal constant PAUSE_MINT = 1 << 0;
    uint256 internal constant PAUSE_BORROW = 1 << 1;
    uint256 internal constant PAUSE_EXTEND = 1 << 2;
    uint256 internal constant PAUSE_FLASH = 1 << 3;
    uint256 internal constant PAUSE_REDEEM = 1 << 4;
    uint256 internal constant PAUSE_LIQUIDITY = 1 << 5;
    uint256 internal constant GUARDIAN_ACTIONS =
        PAUSE_MINT | PAUSE_BORROW | PAUSE_EXTEND | PAUSE_FLASH | PAUSE_LIQUIDITY;
    uint256 internal constant ALL_ACTIONS = GUARDIAN_ACTIONS | PAUSE_REDEEM;

    struct GovernanceStorage {
        address guardian;
        uint256 pausedActions;
    }

    function governanceStorage() internal pure returns (GovernanceStorage storage gs) {
        bytes32 position = GOVERNANCE_STORAGE_POSITION;
        assembly ("memory-safe") {
            gs.slot := position
        }
    }
}
