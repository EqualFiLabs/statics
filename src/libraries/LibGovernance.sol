// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

library LibGovernance {
    bytes32 internal constant GOVERNANCE_STORAGE_POSITION = keccak256("statics.storage.governance");
    bytes32 private constant POL_SWAP_BLOCK_DOMAIN = keccak256("statics.transient.pol.swap.block.v1");

    uint256 internal constant PAUSE_MINT = 1 << 0;
    uint256 internal constant PAUSE_BORROW = 1 << 1;
    uint256 internal constant PAUSE_EXTEND = 1 << 2;
    uint256 internal constant PAUSE_FLASH = 1 << 3;
    uint256 internal constant PAUSE_REDEEM = 1 << 4;
    uint256 internal constant PAUSE_LIQUIDITY = 1 << 5;
    uint256 internal constant PAUSE_TREASURY = 1 << 6;
    uint256 internal constant PAUSE_STAKE = 1 << 7;
    uint256 internal constant GUARDIAN_ACTIONS =
        PAUSE_MINT | PAUSE_BORROW | PAUSE_EXTEND | PAUSE_FLASH | PAUSE_LIQUIDITY | PAUSE_TREASURY | PAUSE_STAKE;
    uint256 internal constant ALL_ACTIONS = GUARDIAN_ACTIONS | PAUSE_REDEEM;

    struct GovernanceStorage {
        address guardian;
        uint256 pausedActions;
        mapping(PoolId poolId => bool quarantined) swapQuarantined;
    }

    error ProtocolPolSwapBlockAlreadyActive(PoolId poolId);

    function governanceStorage() internal pure returns (GovernanceStorage storage gs) {
        bytes32 position = GOVERNANCE_STORAGE_POSITION;
        assembly ("memory-safe") {
            gs.slot := position
        }
    }

    function blockProtocolPolSwaps(PoolId poolId) internal {
        bytes32 slot = _polSwapBlockSlot(poolId);
        uint256 active;
        assembly ("memory-safe") { active := tload(slot) }
        if (active != 0) revert ProtocolPolSwapBlockAlreadyActive(poolId);
        assembly ("memory-safe") { tstore(slot, 1) }
    }

    function unblockProtocolPolSwaps(PoolId poolId) internal {
        bytes32 slot = _polSwapBlockSlot(poolId);
        assembly ("memory-safe") { tstore(slot, 0) }
    }

    function protocolPolSwapsBlocked(PoolId poolId) internal view returns (bool blocked) {
        bytes32 slot = _polSwapBlockSlot(poolId);
        uint256 active;
        assembly ("memory-safe") { active := tload(slot) }
        return active != 0;
    }

    function _polSwapBlockSlot(PoolId poolId) private pure returns (bytes32) {
        return keccak256(abi.encode(POL_SWAP_BLOCK_DOMAIN, PoolId.unwrap(poolId)));
    }
}
