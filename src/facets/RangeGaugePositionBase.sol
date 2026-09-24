// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IStaticsLiquidityManager} from "../interfaces/IStaticsLiquidityManager.sol";
import {IStaticsProtocolPools} from "../interfaces/IStaticsProtocolPools.sol";
import {IStaticsRangeGauge} from "../interfaces/IStaticsRangeGauge.sol";
import {IStaticsSwapFeeHook} from "../interfaces/IStaticsSwapFeeHook.sol";
import {LibBasketLiquidity} from "../libraries/LibBasketLiquidity.sol";
import {LibCustody} from "../libraries/LibCustody.sol";
import {LibGovernance} from "../libraries/LibGovernance.sol";
import {LibProtocolPools} from "../libraries/LibProtocolPools.sol";
import {LibRangeGauge} from "../libraries/LibRangeGauge.sol";
import {LibPosition} from "../position/LibPosition.sol";

abstract contract RangeGaugePositionBase is ReentrancyGuard {
    using StateLibrary for IPoolManager;

    struct InputBalances {
        address token0;
        address token1;
        uint256 payer0Before;
        uint256 payer1Before;
    }

    function _storeNewLeg(
        uint256 positionId,
        PoolId poolId,
        address manager,
        uint256 posmTokenId,
        IStaticsLiquidityManager.ManagedPositionState memory state
    ) internal {
        LibRangeGauge.RangeGaugeStorage storage rgs = LibRangeGauge.rangeGaugeStorage();
        LibRangeGauge.LpLeg storage leg = rgs.lpLegs[positionId][poolId];
        leg.manager = manager;
        leg.posmTokenId = posmTokenId;
        leg.tickLower = state.tickLower;
        leg.tickUpper = state.tickUpper;
        leg.liquidity = state.liquidity;
        PoolKey memory key = state.poolKey;
        LibRangeGauge.registerPositionRange(poolId, state.tickLower, state.tickUpper, key.tickSpacing, state.liquidity);
        LibRangeGauge.checkpointLeg(poolId, leg);
        LibRangeGauge.addPositionPool(positionId, poolId);
        LibRangeGauge.bindPosm(leg.posmTokenId, positionId, poolId);
        ++rgs.gauges[poolId].managedLegCount;
        ++rgs.gauges[poolId].unresolvedLegCount;
        LibPosition.activateLeg(positionId, LibPosition.LP_MODULE, PoolId.unwrap(poolId));
    }

    function _replaceRange(
        PoolId poolId,
        int24 tickSpacing,
        LibRangeGauge.LpLeg storage leg,
        int24 nextLower,
        int24 nextUpper,
        uint128 nextLiquidity
    ) internal {
        LibRangeGauge.unregisterPositionRange(poolId, leg.tickLower, leg.tickUpper, tickSpacing, leg.liquidity);
        leg.tickLower = nextLower;
        leg.tickUpper = nextUpper;
        leg.liquidity = nextLiquidity;
        LibRangeGauge.registerPositionRange(poolId, nextLower, nextUpper, tickSpacing, nextLiquidity);
        LibRangeGauge.checkpointLeg(poolId, leg);
    }

    function _synchronizeAndSettle(PoolId poolId, PoolKey memory key, LibRangeGauge.LpLeg storage leg) internal {
        _synchronize(poolId, key);
        LibRangeGauge.settleLeg(poolId, leg);
    }

    function _synchronize(PoolId poolId, PoolKey memory key) internal {
        LibBasketLiquidity.LiquidityStorage storage ls = LibBasketLiquidity.liquidityStorage();
        (, int24 liveTick,,) = IPoolManager(ls.poolManager).getSlot0(poolId);
        LibRangeGauge.synchronizeTopology(poolId, key.tickSpacing, liveTick, LibRangeGauge.timestamp40(block.timestamp));
    }

    function _leg(uint256 positionId, PoolId poolId) internal view returns (LibRangeGauge.LpLeg storage leg) {
        leg = LibRangeGauge.rangeGaugeStorage().lpLegs[positionId][poolId];
        if (leg.manager == address(0)) revert IStaticsRangeGauge.ManagedLegNotFound(positionId, poolId);
    }

    function _enforceNoLeg(uint256 positionId, PoolId poolId) internal view {
        if (LibRangeGauge.hasPositionPool(positionId, poolId)) {
            revert IStaticsRangeGauge.ManagedLegAlreadyExists(positionId, poolId);
        }
    }

    function _verifiedState(
        address manager,
        uint256 posmTokenId,
        PoolId poolId,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity
    ) internal view returns (IStaticsLiquidityManager.ManagedPositionState memory state) {
        state = IStaticsLiquidityManager(manager).inspectManagedPosition(posmTokenId);
        if (
            PoolId.unwrap(state.poolId) != PoolId.unwrap(poolId) || state.owner != manager
                || state.subscriber != address(0) || state.tickLower != tickLower || state.tickUpper != tickUpper
                || state.liquidity != liquidity
        ) revert IStaticsRangeGauge.PositionMutationMismatch(posmTokenId);
    }

    function _activeManager() internal view returns (address manager) {
        LibBasketLiquidity.LiquidityStorage storage ls = LibBasketLiquidity.liquidityStorage();
        manager = ls.manager;
        if (!ls.managerInstalled || manager.code.length == 0) revert IStaticsRangeGauge.LiquidityManagerNotInstalled();
        IStaticsLiquidityManager bound = IStaticsLiquidityManager(manager);
        _enforceManagerBinding(manager, address(this), bound.staticsDiamond());
        _enforceManagerBinding(manager, ls.poolManager, bound.poolManager());
        if (bound.positionManager() == address(0) || bound.permit2() == address(0)) {
            revert IStaticsRangeGauge.LiquidityManagerNotInstalled();
        }
    }

    function _enforceManagerBinding(address manager, address expected, address actual) internal pure {
        if (expected != actual) revert IStaticsRangeGauge.LiquidityManagerBindingMismatch(manager, expected, actual);
    }

    function _enforcePublicGauge(PoolId poolId, bool active) internal view returns (PoolKey memory key) {
        (IStaticsProtocolPools.ProtocolPoolKind kind, PoolKey memory registeredKey,,) =
            LibProtocolPools.enforceRegistered(poolId);
        if (
            kind != IStaticsProtocolPools.ProtocolPoolKind.General
                && kind != IStaticsProtocolPools.ProtocolPoolKind.BasketCanonical
        ) revert IStaticsRangeGauge.InvalidPublicPool(poolId);
        LibBasketLiquidity.LiquidityStorage storage ls = LibBasketLiquidity.liquidityStorage();
        if (address(registeredKey.hooks) != ls.hook) revert IStaticsRangeGauge.InvalidPublicPool(poolId);
        LibRangeGauge.GaugePool storage gauge = LibRangeGauge.rangeGaugeStorage().gauges[poolId];
        if (!gauge.initialized) revert IStaticsRangeGauge.InvalidPublicPool(poolId);
        if (active && gauge.stopped) revert IStaticsRangeGauge.GaugeStopped(poolId);
        if (active && IStaticsSwapFeeHook(ls.hook).poolDecommissioned(poolId)) {
            revert IStaticsRangeGauge.PublicPoolDecommissioned(poolId);
        }
        key = registeredKey;
    }

    function _inputBalances(PoolKey memory key, address payer) internal view returns (InputBalances memory balances) {
        balances.token0 = Currency.unwrap(key.currency0);
        balances.token1 = Currency.unwrap(key.currency1);
        balances.payer0Before = IERC20(balances.token0).balanceOf(payer);
        balances.payer1Before = IERC20(balances.token1).balanceOf(payer);
    }

    function _fundManager(
        PoolKey memory key,
        address payer,
        address manager,
        uint256 amount0Maximum,
        uint256 amount1Maximum
    ) internal returns (uint256 received0, uint256 received1) {
        received0 = _fundManagerToken(Currency.unwrap(key.currency0), payer, manager, amount0Maximum, 0);
        received1 = _fundManagerToken(Currency.unwrap(key.currency1), payer, manager, amount1Maximum, 0);
    }

    function _fundRebalance(
        PoolKey memory key,
        address payer,
        address manager,
        uint256 principal0,
        uint256 principal1,
        uint256 amount0Maximum,
        uint256 amount1Maximum
    ) internal returns (uint256 received0, uint256 received1) {
        received0 = _fundManagerToken(Currency.unwrap(key.currency0), payer, manager, amount0Maximum, principal0);
        received1 = _fundManagerToken(Currency.unwrap(key.currency1), payer, manager, amount1Maximum, principal1);
    }

    function _fundManagerToken(address asset, address payer, address manager, uint256 maximum, uint256 existing)
        internal
        returns (uint256 received)
    {
        uint256 payerBefore = IERC20(asset).balanceOf(payer);
        uint256 pulled = maximum == 0 ? 0 : LibCustody.pull(asset, payer, maximum);
        _enforceInputDebit(asset, payerBefore, payer, maximum);
        uint256 amount = existing + pulled;
        if (amount == 0) return 0;
        (uint256 spent, uint256 managerReceived) = LibCustody.pushUnreserved(asset, manager, amount, amount);
        if (spent != amount) revert IStaticsRangeGauge.ManagerAssetTransferMismatch(asset, amount, spent);
        received = managerReceived;
    }

    function _enforceInputDebits(
        InputBalances memory balances,
        address payer,
        uint256 amount0Maximum,
        uint256 amount1Maximum
    ) internal view {
        _enforceInputDebit(balances.token0, balances.payer0Before, payer, amount0Maximum);
        _enforceInputDebit(balances.token1, balances.payer1Before, payer, amount1Maximum);
    }

    function _enforceInputDebit(address asset, uint256 beforeBalance, address payer, uint256 maximum) internal view {
        uint256 afterBalance = IERC20(asset).balanceOf(payer);
        uint256 debit = beforeBalance > afterBalance ? beforeBalance - afterBalance : 0;
        if (debit > maximum) revert IStaticsRangeGauge.InputDebitExceedsMaximum(asset, debit, maximum);
    }

    function _managerRequest(
        uint256 posmTokenId,
        uint128 liquidity,
        uint256 amount0Limit,
        uint256 amount1Limit,
        uint256 deadline,
        address receiver
    ) internal pure returns (IStaticsLiquidityManager.ManagedLiquidityRequest memory request) {
        request = IStaticsLiquidityManager.ManagedLiquidityRequest({
                tokenId: posmTokenId,
                liquidity: liquidity,
                amount0Limit: amount0Limit,
                amount1Limit: amount1Limit,
                deadline: deadline,
                receiver: receiver
            });
    }

    function _inputMovement(IStaticsLiquidityManager.ManagedPositionMovement memory managed)
        internal
        pure
        returns (IStaticsRangeGauge.LiquidityMovement memory movement)
    {
        movement = IStaticsRangeGauge.LiquidityMovement({
            posmTokenId: managed.tokenId,
            liquidity: managed.liquidityAfter,
            spent0: managed.spent0,
            received0: managed.refund0,
            spent1: managed.spent1,
            received1: managed.refund1
        });
    }

    function _outputMovement(IStaticsLiquidityManager.ManagedPositionMovement memory managed)
        internal
        pure
        returns (IStaticsRangeGauge.LiquidityMovement memory movement)
    {
        movement = IStaticsRangeGauge.LiquidityMovement({
            posmTokenId: managed.tokenId,
            liquidity: managed.liquidityAfter,
            spent0: 0,
            received0: managed.received0,
            spent1: 0,
            received1: managed.received1
        });
    }

    function _enforceLiquidityAvailable() internal view {
        if (LibGovernance.governanceStorage().pausedActions & LibGovernance.PAUSE_LIQUIDITY != 0) {
            revert IStaticsRangeGauge.ActionPaused(LibGovernance.PAUSE_LIQUIDITY);
        }
    }
}
