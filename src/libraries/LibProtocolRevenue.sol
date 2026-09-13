// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IStaticsProtocolPools} from "../interfaces/IStaticsProtocolPools.sol";
import {IStaticsProtocolRevenue} from "../interfaces/IStaticsProtocolRevenue.sol";
import {LibBasket} from "./LibBasket.sol";
import {LibBasketRewards} from "./LibBasketRewards.sol";
import {LibCustody} from "./LibCustody.sol";
import {LibGlobalRewards} from "./LibGlobalRewards.sol";
import {LibProtocolPools} from "./LibProtocolPools.sol";

/// @notice Namespaced pull-based creator revenue accounting. Records point credits per creator and
/// aggregate liabilities per asset for custody and invariant reconciliation.
library LibProtocolRevenue {
    bytes32 internal constant PROTOCOL_REVENUE_STORAGE_POSITION = keccak256("statics.storage.protocol.revenue.v1");

    struct ProtocolRevenueStorage {
        mapping(address creator => mapping(address asset => uint256 amount)) creatorCredit;
        mapping(address asset => uint256 amount) totalCreatorCredit;
    }

    error InvalidRewardAsset(PoolId poolId, address asset);
    error GeneralPoolBasketReward(PoolId poolId, uint256 amount);

    function accrueReceived(
        PoolId poolId,
        address asset,
        IStaticsProtocolRevenue.ProtocolFeeDistribution memory distribution
    ) internal {
        (IStaticsProtocolPools.ProtocolPoolKind kind, PoolKey memory key, uint256 basketId,) =
            LibProtocolPools.enforceRegistered(poolId);
        if (asset != Currency.unwrap(key.currency0) && asset != Currency.unwrap(key.currency1)) {
            revert InvalidRewardAsset(poolId, asset);
        }
        if (kind == IStaticsProtocolPools.ProtocolPoolKind.General && distribution.basketStaker != 0) {
            revert GeneralPoolBasketReward(poolId, distribution.basketStaker);
        }
        uint256 total =
            distribution.basketStaker + distribution.staticsStaker + distribution.creator + distribution.treasury;
        if (total == 0) return;
        LibCustody.reserve(LibCustody.feeAccount(), asset, total);
        if (distribution.basketStaker != 0) {
            // The hook normally converts this fallback to POL before redeeming its claim. Recheck
            // after the token pull as a liveness guard against an eligibility-changing token
            // callback between the hook's check and this non-reentrant accounting section.
            if (LibBasketRewards.canAccrue(basketId)) {
                LibBasketRewards.accrueReserved(
                    basketId, LibBasket.basketStorage().baskets[basketId], asset, distribution.basketStaker
                );
            } else {
                distribution.treasury += distribution.basketStaker;
                distribution.basketStaker = 0;
            }
        }
        LibGlobalRewards.accrueReservedSwapStakerFee(asset, distribution.staticsStaker);
        if (distribution.creator != 0) {
            address creator = LibProtocolPools.creatorOf(poolId);
            credit(creator, asset, distribution.creator);
            emit IStaticsProtocolRevenue.CreatorRevenueAccrued(poolId, creator, asset, distribution.creator);
        }
        LibGlobalRewards.accrueReservedTreasuryFee(asset, distribution.treasury);
    }

    function protocolRevenueStorage() internal pure returns (ProtocolRevenueStorage storage rs) {
        bytes32 position = PROTOCOL_REVENUE_STORAGE_POSITION;
        assembly ("memory-safe") {
            rs.slot := position
        }
    }

    function credit(address creator, address asset, uint256 amount) internal {
        if (amount == 0) return;
        ProtocolRevenueStorage storage rs = protocolRevenueStorage();
        rs.creatorCredit[creator][asset] += amount;
        rs.totalCreatorCredit[asset] += amount;
    }

    function clear(address creator, address asset) internal returns (uint256 amount) {
        ProtocolRevenueStorage storage rs = protocolRevenueStorage();
        amount = rs.creatorCredit[creator][asset];
        if (amount == 0) return 0;
        rs.creatorCredit[creator][asset] = 0;
        rs.totalCreatorCredit[asset] -= amount;
    }

    function creditOf(address creator, address asset) internal view returns (uint256 amount) {
        return protocolRevenueStorage().creatorCredit[creator][asset];
    }

    function totalOf(address asset) internal view returns (uint256 amount) {
        return protocolRevenueStorage().totalCreatorCredit[asset];
    }
}
