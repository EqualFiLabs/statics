// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IStaticsProtocolPools} from "../interfaces/IStaticsProtocolPools.sol";
import {IStaticsProtocolRevenue} from "../interfaces/IStaticsProtocolRevenue.sol";
import {LibBasketLiquidity} from "../libraries/LibBasketLiquidity.sol";
import {LibBasketRewards} from "../libraries/LibBasketRewards.sol";
import {LibCustody} from "../libraries/LibCustody.sol";
import {LibGlobalRewards} from "../libraries/LibGlobalRewards.sol";
import {LibProtocolPools} from "../libraries/LibProtocolPools.sol";
import {LibProtocolRevenue} from "../libraries/LibProtocolRevenue.sol";

/// @notice Hook-only protocol swap-fee routing and pull-based creator revenue claims. The complete
/// non-POL distribution is pulled from the hook and reserved once under the shared fee account. Creator
/// credit is one liability within that reservation, tracked separately from basket-staker,
/// Statics-staker, and treasury liabilities.
contract ProtocolRevenueFacet is IStaticsProtocolRevenue, ReentrancyGuard {
    using PoolIdLibrary for PoolKey;

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
        uint256 total =
            distribution.basketStaker + distribution.staticsStaker + distribution.creator + distribution.treasury;
        if (total == 0) return;
        uint256 received = LibCustody.pull(asset, msg.sender, total);
        if (received != total) revert IncompatibleRevenueAsset(asset, total, received);
        LibProtocolRevenue.accrueReceived(poolId, asset, distribution);
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

    function canAccrueBasketRewards(PoolId poolId) external view returns (bool eligible) {
        (IStaticsProtocolPools.ProtocolPoolKind kind,, uint256 basketId,) = LibProtocolPools.resolve(poolId);
        if (kind != IStaticsProtocolPools.ProtocolPoolKind.BasketCanonical) return false;
        return LibBasketRewards.canAccrue(basketId);
    }
}
