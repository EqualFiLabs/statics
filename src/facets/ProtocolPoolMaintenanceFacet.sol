// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IStaticsProtocolPools} from "../interfaces/IStaticsProtocolPools.sol";
import {IStaticsProtocolRevenue} from "../interfaces/IStaticsProtocolRevenue.sol";
import {IStaticsSwapFeeHook} from "../interfaces/IStaticsSwapFeeHook.sol";
import {LibBasketLiquidity} from "../libraries/LibBasketLiquidity.sol";
import {LibCustody} from "../libraries/LibCustody.sol";
import {LibDiamond} from "../libraries/LibDiamond.sol";
import {LibGovernance} from "../libraries/LibGovernance.sol";
import {LibMarketTape} from "../libraries/LibMarketTape.sol";
import {LibProtocolPoolFee} from "../libraries/LibProtocolPoolFee.sol";
import {LibProtocolPools} from "../libraries/LibProtocolPools.sol";
import {LibProtocolRevenue} from "../libraries/LibProtocolRevenue.sol";

/// @notice Permissionless, treasury-tipped settlement and POL compounding for public protocol pools.
contract ProtocolPoolMaintenanceFacet is ReentrancyGuard {
    using StateLibrary for IPoolManager;

    error LiquidityIntegrationNotInstalled();
    error IncompatibleTokenTransfer(address token, uint256 expected, uint256 observed);
    error InvalidMaintenanceConfig();
    error ActionPaused(uint256 action);
    error PublicProtocolPoolRequired(PoolId poolId);
    error InsufficientMarketHistory(PoolId poolId, uint256 target);
    error ExcessiveSpotTickDeviation(PoolId poolId, int24 spotTick, int24 twapTick, uint24 maximum);
    error EmptyMaintenanceResult();

    function setProtocolPoolMaintenanceConfig(IStaticsProtocolPools.ProtocolPoolMaintenanceConfig calldata config)
        external
    {
        LibDiamond.enforceIsContractOwner();
        if (
            config.revenueTipBps > LibProtocolPoolFee.MAX_REVENUE_TIP_BPS
                || config.compoundTipBps > LibProtocolPoolFee.MAX_COMPOUND_TIP_BPS
                || config.twapWindow < LibProtocolPoolFee.MIN_MAINTENANCE_TWAP_WINDOW
                || config.twapWindow > LibProtocolPoolFee.MAX_MAINTENANCE_TWAP_WINDOW
                || config.maxTickDeviation < LibProtocolPoolFee.MIN_MAINTENANCE_TICK_DEVIATION
                || config.maxTickDeviation > LibProtocolPoolFee.MAX_MAINTENANCE_TICK_DEVIATION
        ) revert InvalidMaintenanceConfig();

        LibProtocolPools.ProtocolPoolStorage storage ps = LibProtocolPools.protocolPoolStorage();
        ps.revenueTipBps = config.revenueTipBps;
        ps.compoundTipBps = config.compoundTipBps;
        ps.twapWindow = config.twapWindow;
        ps.maxTickDeviation = config.maxTickDeviation;
        emit IStaticsProtocolPools.ProtocolPoolMaintenanceConfigSet(
            config.revenueTipBps, config.compoundTipBps, config.twapWindow, config.maxTickDeviation
        );
    }

    function settleProtocolPoolRevenue(PoolId poolId, address asset)
        external
        nonReentrant
        returns (uint256 grossAmount, uint256 callerTip)
    {
        if (LibGovernance.governanceStorage().pausedActions & LibGovernance.PAUSE_TREASURY != 0) {
            revert ActionPaused(LibGovernance.PAUSE_TREASURY);
        }
        (, PoolKey memory key,,) = _enforcePublicProtocolPool(poolId);
        Currency currency = asset == Currency.unwrap(key.currency0) ? key.currency0 : key.currency1;
        if (asset != Currency.unwrap(currency)) revert LibProtocolRevenue.InvalidRewardAsset(poolId, asset);

        uint256 beforeBalance = IERC20(asset).balanceOf(address(this));
        IStaticsSwapFeeHook.FeeDistribution memory distribution =
            IStaticsSwapFeeHook(_liquidityStorage().hook).settleFeeDistribution(key, currency, address(this));
        grossAmount = _distributionTotal(distribution);
        _enforceReceived(asset, beforeBalance, grossAmount);
        callerTip = Math.mulDiv(distribution.treasury, LibProtocolPools.protocolPoolStorage().revenueTipBps, 10_000);
        if (callerTip != 0) {
            distribution.treasury -= callerTip;
            _pushExactUnreserved(asset, msg.sender, callerTip);
        }
        _accrueDistribution(poolId, asset, distribution);
        emit IStaticsProtocolPools.ProtocolPoolRevenueSettled(poolId, asset, msg.sender, grossAmount, callerTip);
    }

    function compoundProtocolPoolPol(PoolId poolId)
        external
        nonReentrant
        returns (IStaticsProtocolPools.ProtocolPoolPolCompoundResult memory result)
    {
        if (LibGovernance.governanceStorage().pausedActions & LibGovernance.PAUSE_LIQUIDITY != 0) {
            revert ActionPaused(LibGovernance.PAUSE_LIQUIDITY);
        }
        (, PoolKey memory key,,) = _enforcePublicProtocolPool(poolId);
        LibProtocolPools.ProtocolPoolStorage storage ps = LibProtocolPools.protocolPoolStorage();
        result.twapTick = _maintenanceTwapTick(poolId, ps.twapWindow);
        (, result.spotTick,,) = IPoolManager(_liquidityStorage().poolManager).getSlot0(poolId);
        if (_tickDistance(result.spotTick, result.twapTick) > ps.maxTickDeviation) {
            revert ExcessiveSpotTickDeviation(poolId, result.spotTick, result.twapTick, ps.maxTickDeviation);
        }

        address asset0 = Currency.unwrap(key.currency0);
        address asset1 = Currency.unwrap(key.currency1);
        uint256 before0 = IERC20(asset0).balanceOf(address(this));
        uint256 before1 = IERC20(asset1).balanceOf(address(this));
        IStaticsSwapFeeHook.PermanentLiquidityCompound memory compounded = IStaticsSwapFeeHook(_liquidityStorage().hook)
            .compoundPermanentLiquidity(key, ps.compoundTipBps, address(this));
        if (compounded.liquidityAdded == 0) revert EmptyMaintenanceResult();
        _enforceReceived(asset0, before0, compounded.tip0);
        _enforceReceived(asset1, before1, compounded.tip1);
        _pushExactUnreserved(asset0, msg.sender, compounded.tip0);
        _pushExactUnreserved(asset1, msg.sender, compounded.tip1);
        result.liquidityAdded = compounded.liquidityAdded;
        result.amount0Consumed = compounded.amount0Consumed;
        result.amount1Consumed = compounded.amount1Consumed;
        result.tip0 = compounded.tip0;
        result.tip1 = compounded.tip1;
        _emitPolCompounded(poolId, msg.sender, result);
    }

    function _maintenanceTwapTick(PoolId poolId, uint32 window) private view returns (int24 averageTick) {
        if (window == 0 || block.timestamp < window) revert InsufficientMarketHistory(poolId, 0);
        uint256 target = block.timestamp - window;
        LibMarketTape.MarketTapeStorage storage mts = LibMarketTape.marketTapeStorage();
        LibMarketTape.ObservationState storage state = mts.observationState[poolId];
        if (state.stored == 0) revert InsufficientMarketHistory(poolId, target);
        uint64 oldestId = state.latestId - state.stored + 1;
        if (mts.observations[poolId][oldestId].timestamp > target) revert InsufficientMarketHistory(poolId, target);

        uint64 lower = oldestId;
        uint64 upper = state.latestId;
        while (lower < upper) {
            uint64 midpoint = lower + (upper - lower + 1) / 2;
            if (mts.observations[poolId][midpoint].timestamp <= target) lower = midpoint;
            else upper = midpoint - 1;
        }
        uint40 observationTime = mts.observations[poolId][lower].timestamp;
        uint256 elapsed = block.timestamp - observationTime;
        int256 delta = LibMarketTape.currentTickCumulative(mts.canonical[poolId], block.timestamp)
            - mts.observations[poolId][lower].tickCumulative;
        int256 divisor = int256(elapsed);
        int256 quotient = delta / divisor;
        if (delta < 0 && delta % divisor != 0) --quotient;
        if (quotient < type(int24).min || quotient > type(int24).max) revert InvalidMaintenanceConfig();
        averageTick = int24(quotient);
    }

    function _tickDistance(int24 a, int24 b) private pure returns (uint24 distance) {
        int256 difference = int256(a) - int256(b);
        if (difference < 0) difference = -difference;
        distance = uint24(uint256(difference));
    }

    function _accrueDistribution(PoolId poolId, address token, IStaticsSwapFeeHook.FeeDistribution memory distribution)
        private
    {
        LibProtocolRevenue.accrueReceived(
            poolId,
            token,
            IStaticsProtocolRevenue.ProtocolFeeDistribution({
                basketStaker: distribution.basketStaker,
                staticsStaker: distribution.staticsStaker,
                creator: distribution.creator,
                treasury: distribution.treasury
            })
        );
    }

    function _distributionTotal(IStaticsSwapFeeHook.FeeDistribution memory distribution)
        private
        pure
        returns (uint256)
    {
        return distribution.basketStaker + distribution.staticsStaker + distribution.creator + distribution.treasury;
    }

    function _enforceReceived(address token, uint256 beforeBalance, uint256 reported) private view {
        uint256 afterBalance = IERC20(token).balanceOf(address(this));
        uint256 observed = afterBalance > beforeBalance ? afterBalance - beforeBalance : 0;
        if (observed != reported) revert IncompatibleTokenTransfer(token, reported, observed);
    }

    function _pushExactUnreserved(address token, address receiver, uint256 amount) private {
        if (amount == 0) return;
        (uint256 spent, uint256 received) = LibCustody.pushUnreserved(token, receiver, amount, amount);
        if (spent != amount || received != amount) revert IncompatibleTokenTransfer(token, amount, received);
    }

    function _emitPolCompounded(
        PoolId poolId,
        address caller,
        IStaticsProtocolPools.ProtocolPoolPolCompoundResult memory result
    ) private {
        emit IStaticsProtocolPools.ProtocolPoolPolCompounded(
            poolId,
            caller,
            result.liquidityAdded,
            result.amount0Consumed,
            result.amount1Consumed,
            result.tip0,
            result.tip1,
            result.spotTick,
            result.twapTick
        );
    }

    function _liquidityStorage() private view returns (LibBasketLiquidity.LiquidityStorage storage ls) {
        ls = LibBasketLiquidity.liquidityStorage();
        if (!ls.integrationInstalled) revert LiquidityIntegrationNotInstalled();
    }

    function _enforcePublicProtocolPool(PoolId poolId)
        private
        view
        returns (IStaticsProtocolPools.ProtocolPoolKind kind, PoolKey memory key, uint256 basketId, address basketAsset)
    {
        (kind, key, basketId, basketAsset) = LibProtocolPools.enforceRegistered(poolId);
        if (kind == IStaticsProtocolPools.ProtocolPoolKind.PermissionedGeneral) {
            revert PublicProtocolPoolRequired(poolId);
        }
    }
}
