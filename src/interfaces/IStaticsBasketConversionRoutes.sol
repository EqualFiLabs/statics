// SPDX-License-Identifier: BUSL-1.1
// ============================================================================
//                              STATICS PROTOCOL
//                         Markets that work for you.
//                       https://staticsprotocol.com
//                              EqualFi Labs
// ============================================================================
pragma solidity 0.8.33;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @dev Paths always run quote -> constituent; sells traverse them backwards.
struct BasketConversionRoute {
    address[] currencies;
    PoolKey[] pools;
    bytes[] hookData;
}

struct BasketConversionRequest {
    uint256 deadline;
    uint256 limit;
    uint256[] routeLimits;
    bool preset;
    BasketConversionRoute[] routes;
}

interface IStaticsBasketConversionRoutes {
    event BasketConversionPresetSet(PoolId indexed poolId, bool indexed buying, bytes32 routesHash);
    function setPreset(PoolId poolId, bool buying, BasketConversionRoute[] calldata routes) external;
    function preset(PoolId poolId, bool buying) external view returns (BasketConversionRoute[] memory);
}
