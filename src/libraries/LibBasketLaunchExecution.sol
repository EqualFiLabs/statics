// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @dev Only the pool being initialized or seeded may use pending-basket callbacks.
library LibBasketLaunchExecution {
    bytes32 private constant SLOT = keccak256("statics.transient.basket.launch.pool.v1");

    function setPool(PoolId id) internal {
        bytes32 slot = SLOT;
        bytes32 value = PoolId.unwrap(id);
        assembly ("memory-safe") { tstore(slot, value) }
    }

    function clear() internal {
        setPool(PoolId.wrap(bytes32(0)));
    }

    function permits(PoolId id) internal view returns (bool) {
        bytes32 slot = SLOT;
        bytes32 value;
        assembly ("memory-safe") { value := tload(slot) }
        return value != bytes32(0) && value == PoolId.unwrap(id);
    }
}
