// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {LibGaugeHeap} from "../../src/libraries/LibGaugeHeap.sol";

contract GaugeHeapHarness {
    using LibGaugeHeap for LibGaugeHeap.Heap;

    LibGaugeHeap.Heap private heap;

    function set(PoolId poolId, uint256 weight) external {
        heap.set(poolId, weight);
    }

    function remove(PoolId poolId) external {
        heap.remove(poolId);
    }

    function top(uint256 count) external view returns (LibGaugeHeap.Node[] memory) {
        return heap.top(count);
    }

    function length() external view returns (uint256) {
        return heap.length();
    }

    function nodeAt(uint256 index) external view returns (LibGaugeHeap.Node memory) {
        return heap.nodeAt(index);
    }
}
