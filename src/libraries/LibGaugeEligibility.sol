// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IStaticsProtocolPools} from "../interfaces/IStaticsProtocolPools.sol";
import {LibProtocolPools} from "./LibProtocolPools.sol";
import {LibRangeGauge} from "./LibRangeGauge.sol";
import {LibRewardPolicy} from "./LibRewardPolicy.sol";

library LibGaugeEligibility {
    bytes32 internal constant VERSION_DOMAIN = keccak256("statics.gauge.eligibility.version.v1");

    function version(PoolId poolId) internal view returns (bytes32 value) {
        LibRangeGauge.GaugePool storage gauge = LibRangeGauge.rangeGaugeStorage().gauges[poolId];
        if (!gauge.initialized || gauge.stopped) return bytes32(0);
        (IStaticsProtocolPools.ProtocolPoolKind kind, PoolKey memory key,,) = LibProtocolPools.resolve(poolId);
        if (
            kind != IStaticsProtocolPools.ProtocolPoolKind.General
                && kind != IStaticsProtocolPools.ProtocolPoolKind.BasketCanonical
        ) return bytes32(0);

        address asset0 = Currency.unwrap(key.currency0);
        address asset1 = Currency.unwrap(key.currency1);
        if (_restricted(asset0) || _restricted(asset1)) return bytes32(0);
        value = keccak256(
            abi.encode(
                VERSION_DOMAIN,
                PoolId.unwrap(poolId),
                LibRewardPolicy.restrictionNonce(asset0),
                LibRewardPolicy.restrictionNonce(asset1)
            )
        );
    }

    function firstRestrictionAfter(PoolId poolId, uint64 sequence)
        internal
        view
        returns (bool found, uint40 timestamp, uint256 routingIndexX160)
    {
        (, PoolKey memory key,,) = LibProtocolPools.resolve(poolId);
        (bool found0,, uint40 timestamp0, uint256 index0) =
            LibRewardPolicy.firstRestrictionAfter(Currency.unwrap(key.currency0), sequence);
        (bool found1,, uint40 timestamp1, uint256 index1) =
            LibRewardPolicy.firstRestrictionAfter(Currency.unwrap(key.currency1), sequence);
        if (!found0) return (found1, timestamp1, index1);
        if (!found1 || timestamp0 <= timestamp1) return (true, timestamp0, index0);
        return (true, timestamp1, index1);
    }

    function _restricted(address asset) private view returns (bool) {
        return asset != address(0) && LibRewardPolicy.isRestricted(asset);
    }
}
