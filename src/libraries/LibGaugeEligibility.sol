// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IStaticsProtocolPools} from "../interfaces/IStaticsProtocolPools.sol";
import {LibProtocolPools} from "./LibProtocolPools.sol";
import {LibRewardPolicy} from "./LibRewardPolicy.sol";

library LibGaugeEligibility {
    bytes32 internal constant VERSION_DOMAIN = keccak256("statics.gauge.eligibility.version.v1");

    function version(PoolId poolId) internal view returns (bytes32 value) {
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

    function restrictionTimestamp(PoolId poolId, uint64 epoch) internal view returns (uint40 timestamp) {
        (, PoolKey memory key,,) = LibProtocolPools.resolve(poolId);
        uint40 first = LibRewardPolicy.firstRestrictedAt(Currency.unwrap(key.currency0), epoch);
        uint40 second = LibRewardPolicy.firstRestrictedAt(Currency.unwrap(key.currency1), epoch);
        if (first == 0) return second;
        if (second == 0 || first < second) return first;
        return second;
    }

    function latestRestrictionSequence(PoolId poolId, uint64 epoch) internal view returns (uint64 sequence) {
        (, PoolKey memory key,,) = LibProtocolPools.resolve(poolId);
        uint64 first = LibRewardPolicy.restrictionSequenceAt(Currency.unwrap(key.currency0), epoch);
        uint64 second = LibRewardPolicy.restrictionSequenceAt(Currency.unwrap(key.currency1), epoch);
        return first > second ? first : second;
    }

    function _restricted(address asset) private view returns (bool) {
        return asset != address(0) && LibRewardPolicy.isRestricted(asset);
    }
}
