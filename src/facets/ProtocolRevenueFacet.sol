// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IStaticsProtocolPools} from "../interfaces/IStaticsProtocolPools.sol";
import {IStaticsProtocolRevenue} from "../interfaces/IStaticsProtocolRevenue.sol";
import {LibBasket} from "../libraries/LibBasket.sol";
import {LibBasketLiquidity} from "../libraries/LibBasketLiquidity.sol";
import {LibBasketRewards} from "../libraries/LibBasketRewards.sol";
import {LibCustody} from "../libraries/LibCustody.sol";
import {LibGlobalRewards} from "../libraries/LibGlobalRewards.sol";
import {LibLiquidityRewards} from "../libraries/LibLiquidityRewards.sol";
import {LibProtocolPools} from "../libraries/LibProtocolPools.sol";
import {LibProtocolRevenue} from "../libraries/LibProtocolRevenue.sol";

/// @notice Hook-only protocol swap-fee routing and pull-based creator revenue claims. The complete
/// non-POL distribution is pulled from the hook and reserved once under the shared fee account. Creator
/// credit is one liability within that reservation, tracked separately from LP, basket-staker,
/// Statics-staker, and treasury liabilities.
contract ProtocolRevenueFacet is IStaticsProtocolRevenue, ReentrancyGuard {
    using PoolIdLibrary for PoolKey;

    event LiquidityRewardAccrued(PoolId indexed poolId, address indexed asset, uint256 amount, uint256 indexRay);

    error OnlySwapFeeHook(address caller, address expected);
    error InvalidRewardAsset(PoolId poolId, address asset);
    error GeneralPoolBasketReward(PoolId poolId, uint256 amount);
    error IncompatibleRevenueAsset(address asset, uint256 expected, uint256 actual);
    error InvalidReceiver();
    error NoCreatorRevenue(address creator, address asset);
    error MinimumOutputNotMet(address asset, uint256 actual, uint256 minimum);

    function routeProtocolSwapFees(PoolId poolId, address asset, ProtocolFeeDistribution calldata distribution)
        external
        nonReentrant
    {
        LibBasketLiquidity.LiquidityStorage storage ls = LibBasketLiquidity.liquidityStorage();
        if (msg.sender != ls.hook) revert OnlySwapFeeHook(msg.sender, ls.hook);
        (IStaticsProtocolPools.ProtocolPoolKind kind, PoolKey memory key, uint256 basketId,) =
            LibProtocolPools.enforceRegistered(poolId);
        address currency0 = Currency.unwrap(key.currency0);
        address currency1 = Currency.unwrap(key.currency1);
        if (asset != currency0 && asset != currency1) revert InvalidRewardAsset(poolId, asset);
        if (kind == IStaticsProtocolPools.ProtocolPoolKind.General && distribution.basketStaker != 0) {
            revert GeneralPoolBasketReward(poolId, distribution.basketStaker);
        }
        uint256 total = distribution.liquidityProvider + distribution.basketStaker + distribution.staticsStaker
            + distribution.creator + distribution.treasury;
        if (total == 0) return;
        uint256 received = LibCustody.pull(asset, msg.sender, total);
        if (received != total) revert IncompatibleRevenueAsset(asset, total, received);
        LibCustody.reserve(LibCustody.feeAccount(), asset, total);

        if (distribution.liquidityProvider != 0) {
            uint256 indexRay = LibLiquidityRewards.accrue(poolId, asset, distribution.liquidityProvider);
            emit LiquidityRewardAccrued(poolId, asset, distribution.liquidityProvider, indexRay);
        }
        if (distribution.basketStaker != 0) {
            LibBasketRewards.accrueReserved(
                basketId, LibBasket.basketStorage().baskets[basketId], asset, distribution.basketStaker
            );
        }
        LibGlobalRewards.accrueReservedSwapStakerFee(asset, distribution.staticsStaker);
        if (distribution.creator != 0) {
            address creator = LibProtocolPools.creatorOf(poolId);
            LibProtocolRevenue.credit(creator, asset, distribution.creator);
            emit CreatorRevenueAccrued(poolId, creator, asset, distribution.creator);
        }
        LibGlobalRewards.accrueReservedTreasuryFee(asset, distribution.treasury);
    }

    function claimCreatorRevenue(address asset, address receiver, uint256 minReceived)
        external
        nonReentrant
        returns (uint256 amount, uint256 received)
    {
        if (receiver == address(0)) revert InvalidReceiver();
        address creator = msg.sender;
        amount = LibProtocolRevenue.clear(creator, asset);
        if (amount == 0) revert NoCreatorRevenue(creator, asset);
        (, received) = LibCustody.pushReserved(LibCustody.feeAccount(), asset, receiver, amount, amount);
        if (received < minReceived) revert MinimumOutputNotMet(asset, received, minReceived);
        emit CreatorRevenueClaimed(creator, asset, receiver, amount, received);
    }

    function creatorRevenue(address creator, address asset) external view returns (uint256 amount) {
        return LibProtocolRevenue.creditOf(creator, asset);
    }

    function totalCreatorRevenue(address asset) external view returns (uint256 amount) {
        return LibProtocolRevenue.totalOf(asset);
    }
}
