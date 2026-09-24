// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @notice Indexed max heap ordered by weight descending and PoolId ascending.
library LibGaugeHeap {
    struct Node {
        PoolId poolId;
        uint256 weight;
    }

    struct Heap {
        Node[] nodes;
        mapping(PoolId poolId => uint256 indexPlusOne) indexPlusOne;
    }

    error HeapEntryMissing(PoolId poolId);

    function set(Heap storage heap, PoolId poolId, uint256 weight) internal {
        uint256 indexPlusOne = heap.indexPlusOne[poolId];
        if (weight == 0) {
            if (indexPlusOne != 0) remove(heap, poolId);
            return;
        }
        if (indexPlusOne == 0) {
            heap.nodes.push(Node({poolId: poolId, weight: weight}));
            uint256 index = heap.nodes.length - 1;
            heap.indexPlusOne[poolId] = index + 1;
            _bubbleUp(heap, index);
            return;
        }

        uint256 existingIndex = indexPlusOne - 1;
        Node memory previous = heap.nodes[existingIndex];
        heap.nodes[existingIndex].weight = weight;
        if (_higher(heap.nodes[existingIndex], previous)) {
            _bubbleUp(heap, existingIndex);
        } else {
            _bubbleDown(heap, existingIndex);
        }
    }

    function remove(Heap storage heap, PoolId poolId) internal {
        uint256 indexPlusOne = heap.indexPlusOne[poolId];
        if (indexPlusOne == 0) revert HeapEntryMissing(poolId);
        uint256 index = indexPlusOne - 1;
        uint256 last = heap.nodes.length - 1;
        delete heap.indexPlusOne[poolId];
        if (index == last) {
            heap.nodes.pop();
            return;
        }

        Node memory moved = heap.nodes[last];
        heap.nodes[index] = moved;
        heap.nodes.pop();
        heap.indexPlusOne[moved.poolId] = index + 1;
        if (index != 0 && _higher(moved, heap.nodes[(index - 1) / 2])) {
            _bubbleUp(heap, index);
        } else {
            _bubbleDown(heap, index);
        }
    }

    /// @dev Visits at most `count` winning nodes plus their bounded frontier. It never copies or
    /// mutates the full heap.
    function top(Heap storage heap, uint256 count) internal view returns (Node[] memory winners) {
        uint256 length_ = heap.nodes.length;
        if (count > length_) count = length_;
        winners = new Node[](count);
        if (count == 0) return winners;

        uint256[] memory frontier = new uint256[](count + 1);
        uint256 frontierLength = 1;
        for (uint256 outputIndex; outputIndex < count; ++outputIndex) {
            uint256 bestPosition;
            for (uint256 candidate = 1; candidate < frontierLength; ++candidate) {
                if (_higher(heap.nodes[frontier[candidate]], heap.nodes[frontier[bestPosition]])) {
                    bestPosition = candidate;
                }
            }

            uint256 heapIndex = frontier[bestPosition];
            winners[outputIndex] = heap.nodes[heapIndex];
            frontier[bestPosition] = frontier[frontierLength - 1];
            --frontierLength;

            uint256 left = heapIndex * 2 + 1;
            if (left < length_) frontier[frontierLength++] = left;
            uint256 right = left + 1;
            if (right < length_) frontier[frontierLength++] = right;
        }
    }

    function length(Heap storage heap) internal view returns (uint256) {
        return heap.nodes.length;
    }

    function nodeAt(Heap storage heap, uint256 index) internal view returns (Node memory) {
        return heap.nodes[index];
    }

    function _bubbleUp(Heap storage heap, uint256 index) private {
        while (index != 0) {
            uint256 parent = (index - 1) / 2;
            if (!_higher(heap.nodes[index], heap.nodes[parent])) return;
            _swap(heap, index, parent);
            index = parent;
        }
    }

    function _bubbleDown(Heap storage heap, uint256 index) private {
        uint256 length_ = heap.nodes.length;
        while (true) {
            uint256 left = index * 2 + 1;
            if (left >= length_) return;
            uint256 right = left + 1;
            uint256 best = right < length_ && _higher(heap.nodes[right], heap.nodes[left]) ? right : left;
            if (!_higher(heap.nodes[best], heap.nodes[index])) return;
            _swap(heap, index, best);
            index = best;
        }
    }

    function _swap(Heap storage heap, uint256 first, uint256 second) private {
        Node memory firstNode = heap.nodes[first];
        Node memory secondNode = heap.nodes[second];
        heap.nodes[first] = secondNode;
        heap.nodes[second] = firstNode;
        heap.indexPlusOne[firstNode.poolId] = second + 1;
        heap.indexPlusOne[secondNode.poolId] = first + 1;
    }

    function _higher(Node memory first, Node memory second) private pure returns (bool) {
        if (first.weight != second.weight) return first.weight > second.weight;
        return uint256(PoolId.unwrap(first.poolId)) < uint256(PoolId.unwrap(second.poolId));
    }
}
