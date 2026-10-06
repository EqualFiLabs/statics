// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

/// @notice Bounded funding cursor; reward ownership still crystallizes at swap generation.
library LibSwapRewardSources {
    bytes32 private constant STORAGE_POSITION = keccak256("statics.storage.swap.reward.sources.v1");
    uint256 internal constant MAX_SETTLEMENT_SOURCES = 32;

    struct SourceQueue {
        address[] hooks;
        uint256 head;
        uint256 total;
        mapping(address hook => uint256 amount) pending;
    }

    struct SourceStorage {
        mapping(address asset => SourceQueue queue) sources;
    }

    function sourceStorage() internal pure returns (SourceStorage storage ss) {
        bytes32 slot = STORAGE_POSITION;
        assembly ("memory-safe") { ss.slot := slot }
    }

    function record(address asset, address hook, uint256 amount) internal {
        if (amount == 0) return;
        SourceQueue storage queue = sourceStorage().sources[asset];
        if (queue.pending[hook] == 0) queue.hooks.push(hook);
        queue.pending[hook] += amount;
        queue.total += amount;
    }

    function consume(SourceQueue storage queue, address hook, uint256 amount) internal {
        queue.pending[hook] -= amount;
        queue.total -= amount;
        if (queue.pending[hook] == 0) ++queue.head;
    }
}
