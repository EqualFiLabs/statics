// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IStaticsProtocolPools} from "../interfaces/IStaticsProtocolPools.sol";
import {IStaticsRangeGauge} from "../interfaces/IStaticsRangeGauge.sol";
import {IStaticsSwapFeeHook} from "../interfaces/IStaticsSwapFeeHook.sol";
import {LibBasketLiquidity} from "../libraries/LibBasketLiquidity.sol";
import {LibCustody} from "../libraries/LibCustody.sol";
import {LibDiamond} from "../libraries/LibDiamond.sol";
import {LibGovernance} from "../libraries/LibGovernance.sol";
import {LibProtocolPools} from "../libraries/LibProtocolPools.sol";
import {LibRangeGauge} from "../libraries/LibRangeGauge.sol";
import {LibRewardPolicy} from "../libraries/LibRewardPolicy.sol";

/// @notice Governance, creator configuration, and permissionless funding for public range gauges.
contract RangeGaugeFacet is ReentrancyGuard {
    function setGaugeRewardAssetAllowed(address asset, bool allowed) external {
        LibDiamond.enforceIsContractOwner();
        LibRangeGauge.setRewardAssetAllowed(asset, allowed);
        emit IStaticsRangeGauge.GaugeRewardAssetAllowedSet(asset, allowed);
    }

    function setGaugeRewardDuration(uint40 duration) external {
        LibDiamond.enforceIsContractOwner();
        LibRangeGauge.setRewardDuration(duration);
        emit IStaticsRangeGauge.GaugeRewardDurationSet(duration);
    }

    function appendPoolRewardAsset(PoolId poolId, address asset) external returns (uint8 slot) {
        _enforceLiquidityAvailable();
        _enforceActivePublicGauge(poolId);
        address creator = LibProtocolPools.creatorOf(poolId);
        if (msg.sender != creator) revert IStaticsRangeGauge.NotPoolCreator(poolId, msg.sender, creator);
        _enforceRewardAssetAvailable(asset);
        slot = LibRangeGauge.appendRewardAsset(poolId, asset);
        emit IStaticsRangeGauge.PoolRewardAssetAppended(poolId, asset, slot);
    }

    function fundPoolReward(PoolId poolId, address asset, uint256 amount, uint40 minRemainingDuration)
        external
        nonReentrant
        returns (uint256 received)
    {
        _enforceLiquidityAvailable();
        _enforceActivePublicGauge(poolId);
        _enforceRewardAssetAvailable(asset);

        LibRangeGauge.RangeGaugeStorage storage rgs = LibRangeGauge.rangeGaugeStorage();
        (uint8 slot, bool assigned) = LibRangeGauge.rewardSlot(poolId, asset);
        if (!assigned) revert IStaticsRangeGauge.GaugeRewardAssetNotAssigned(poolId, asset);
        LibRangeGauge.GaugePool storage gauge = rgs.gauges[poolId];
        uint40 currentTime = LibRangeGauge.timestamp40(block.timestamp);
        LibRangeGauge.GaugeRewardStream storage stream = gauge.streams[slot];
        LibRangeGauge.checkpointStream(stream, currentTime, gauge.activeGaugeLiquidity);

        uint256 remainingBudget = stream.periodBudget - stream.periodEmitted;
        uint40 availableDuration = remainingBudget == 0 ? rgs.gaugeRewardDuration : stream.periodFinish - currentTime;
        if (minRemainingDuration != 0 && availableDuration < minRemainingDuration) {
            revert IStaticsRangeGauge.MinimumRemainingDurationNotMet(availableDuration, minRemainingDuration);
        }

        received = _pullReward(poolId, slot, asset, amount);
        LibRangeGauge.fundStream(
            stream, gauge.capacities[slot], received, currentTime, rgs.gaugeRewardDuration, gauge.activeGaugeLiquidity
        );
        emit IStaticsRangeGauge.PoolRewardFunded(poolId, asset, msg.sender, slot, amount, received, stream.periodFinish);
    }

    function _pullReward(PoolId poolId, uint8 slot, address asset, uint256 amount) private returns (uint256 received) {
        uint256 funderBalanceBefore = IERC20(asset).balanceOf(msg.sender);
        received = LibCustody.pullAndReserve(LibRangeGauge.rewardAccount(poolId, slot), asset, msg.sender, amount);
        uint256 funderBalanceAfter = IERC20(asset).balanceOf(msg.sender);
        uint256 funderDebit = funderBalanceBefore > funderBalanceAfter ? funderBalanceBefore - funderBalanceAfter : 0;
        if (funderDebit > amount) {
            revert IStaticsRangeGauge.InputDebitExceedsMaximum(asset, funderDebit, amount);
        }
    }

    function _enforceActivePublicGauge(PoolId poolId) private view {
        (IStaticsProtocolPools.ProtocolPoolKind kind, PoolKey memory key,,) = LibProtocolPools.enforceRegistered(poolId);
        if (
            kind != IStaticsProtocolPools.ProtocolPoolKind.General
                && kind != IStaticsProtocolPools.ProtocolPoolKind.BasketCanonical
        ) revert IStaticsRangeGauge.InvalidPublicPool(poolId);

        LibBasketLiquidity.LiquidityStorage storage ls = LibBasketLiquidity.liquidityStorage();
        if (address(key.hooks) != ls.hook) revert IStaticsRangeGauge.InvalidPublicPool(poolId);
        LibRangeGauge.GaugePool storage gauge = LibRangeGauge.rangeGaugeStorage().gauges[poolId];
        if (!gauge.initialized) revert IStaticsRangeGauge.InvalidPublicPool(poolId);
        if (gauge.stopped) revert IStaticsRangeGauge.GaugeStopped(poolId);
        if (IStaticsSwapFeeHook(ls.hook).poolDecommissioned(poolId)) {
            revert IStaticsRangeGauge.PublicPoolDecommissioned(poolId);
        }
    }

    function _enforceRewardAssetAvailable(address asset) private view {
        if (!LibRangeGauge.rangeGaugeStorage().rewardAssetAllowed[asset]) {
            revert IStaticsRangeGauge.GaugeRewardAssetNotAllowed(asset);
        }
        if (LibRewardPolicy.isRestricted(asset)) revert IStaticsRangeGauge.GaugeRewardAssetRestricted(asset);
    }

    function _enforceLiquidityAvailable() private view {
        if (LibGovernance.governanceStorage().pausedActions & LibGovernance.PAUSE_LIQUIDITY != 0) {
            revert IStaticsRangeGauge.ActionPaused(LibGovernance.PAUSE_LIQUIDITY);
        }
    }
}
