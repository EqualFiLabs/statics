// SPDX-License-Identifier: BUSL-1.1
// ============================================================================
//                              STATICS PROTOCOL
//                         Markets that work for you.
//                       https://staticsprotocol.com
//                              EqualFi Labs
// ============================================================================
pragma solidity 0.8.33;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @notice Funding provenance; reward ownership crystallizes at swap generation.
library LibSwapRewardSources {
    bytes32 private constant STORAGE_POSITION = keccak256("statics.storage.swap.reward.sources.v1");
    uint256 internal constant MAX_SETTLEMENT_SOURCES = 32;

    struct Source {
        address hook;
        PoolId poolId;
        address currency;
    }

    struct SourceQueue {
        Source[] entries;
        uint256 head;
        uint256 total;
        mapping(bytes32 source => uint256 amount) pending;
        /// @dev Keep legacy-liability funding from redeeming claims tracked by this queue.
        mapping(bytes32 hookCurrency => uint256 amount) pendingByHookCurrency;
    }

    struct SourceStorage {
        mapping(address asset => SourceQueue queue) sources;
    }

    function sourceStorage() internal pure returns (SourceStorage storage ss) {
        bytes32 slot = STORAGE_POSITION;
        assembly ("memory-safe") { ss.slot := slot }
    }

    function sourceId(address hook, PoolId poolId, address currency) internal pure returns (bytes32) {
        return keccak256(abi.encode(hook, poolId, currency));
    }

    function hookCurrencyId(address hook, address currency) internal pure returns (bytes32) {
        return keccak256(abi.encode(hook, currency));
    }

    function record(address asset, address hook, PoolId poolId, address currency, uint256 amount) internal {
        if (amount == 0) return;
        SourceQueue storage queue = sourceStorage().sources[asset];
        bytes32 id = sourceId(hook, poolId, currency);
        if (queue.pending[id] == 0) {
            queue.entries.push(Source(hook, poolId, currency));
        }
        queue.pending[id] += amount;
        queue.pendingByHookCurrency[hookCurrencyId(hook, currency)] += amount;
        queue.total += amount;
    }

    function consume(SourceQueue storage queue, Source memory source, bytes32 id, uint256 amount) internal {
        queue.pending[id] -= amount;
        queue.pendingByHookCurrency[hookCurrencyId(source.hook, source.currency)] -= amount;
        queue.total -= amount;
        if (queue.pending[id] == 0) {
            ++queue.head;
        }
    }
}
