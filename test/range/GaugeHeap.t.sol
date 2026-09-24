// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {LibGaugeHeap} from "../../src/libraries/LibGaugeHeap.sol";
import {GaugeHeapHarness} from "../helpers/GaugeHeapHarness.sol";

contract GaugeHeapTest is Test {
    GaugeHeapHarness private heap;

    function setUp() public {
        heap = new GaugeHeapHarness();
    }

    function testOrdersByWeightThenPoolIdAndSupportsUpdates() public {
        heap.set(_pool(3), 10);
        heap.set(_pool(2), 20);
        heap.set(_pool(1), 20);
        heap.set(_pool(4), 5);

        LibGaugeHeap.Node[] memory winners = heap.top(10);
        assertEq(winners.length, 4);
        _assertNode(winners[0], 1, 20);
        _assertNode(winners[1], 2, 20);
        _assertNode(winners[2], 3, 10);
        _assertNode(winners[3], 4, 5);

        heap.set(_pool(4), 30);
        heap.set(_pool(2), 1);
        winners = heap.top(3);
        _assertNode(winners[0], 4, 30);
        _assertNode(winners[1], 1, 20);
        _assertNode(winners[2], 3, 10);

        heap.set(_pool(1), 0);
        assertEq(heap.length(), 3);
        winners = heap.top(3);
        _assertNode(winners[0], 4, 30);
        _assertNode(winners[1], 3, 10);
        _assertNode(winners[2], 2, 1);
    }

    function testFuzzTopTenMatchesSortedOracle(uint256 seed, uint8 rawCount) public {
        uint256 count = bound(rawCount, 1, 32);
        uint256[] memory weights = new uint256[](count);
        for (uint256 i; i < count; ++i) {
            weights[i] = uint256(keccak256(abi.encode(seed, i))) % 1_000 + 1;
            heap.set(_pool(i + 1), weights[i]);
        }

        LibGaugeHeap.Node[] memory winners = heap.top(10);
        uint256 expectedCount = count < 10 ? count : 10;
        assertEq(winners.length, expectedCount);
        bool[] memory selected = new bool[](count);
        for (uint256 rank; rank < expectedCount; ++rank) {
            uint256 expected;
            bool found;
            for (uint256 i; i < count; ++i) {
                if (selected[i]) continue;
                if (!found || weights[i] > weights[expected] || (weights[i] == weights[expected] && i < expected)) {
                    expected = i;
                    found = true;
                }
            }
            selected[expected] = true;
            _assertNode(winners[rank], expected + 1, weights[expected]);
        }
    }

    function _pool(uint256 value) private pure returns (PoolId) {
        return PoolId.wrap(bytes32(value));
    }

    function _assertNode(LibGaugeHeap.Node memory node, uint256 pool, uint256 weight) private pure {
        assertEq(uint256(PoolId.unwrap(node.poolId)), pool);
        assertEq(node.weight, weight);
    }
}
