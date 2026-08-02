// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

// Keep the pinned concrete PoolManager in Foundry's compilation graph. Statics
// contracts depend only on its interface; local live-flow tests and deployment
// scripts need its creation artifact without weakening either compiler pin.
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {PositionManager} from "@uniswap/v4-periphery/src/PositionManager.sol";

abstract contract V4PoolManagerCompilation {
    function _poolManagerCreationCode() internal pure returns (bytes memory) {
        return type(PoolManager).creationCode;
    }

    function _positionManagerCreationCode() internal pure returns (bytes memory) {
        return type(PositionManager).creationCode;
    }
}
