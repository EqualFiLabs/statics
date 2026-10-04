// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IStaticsProtocolPools} from "../../src/interfaces/IStaticsProtocolPools.sol";
import {IStaticsSwapFeeHook} from "../../src/interfaces/IStaticsSwapFeeHook.sol";
import {StaticsLiquidityManager} from "../../src/liquidity/StaticsLiquidityManager.sol";
import {StaticsTestBase} from "./StaticsTestBase.sol";

/// @notice Current managed-POL accounting shared by the pinned composability forks.
abstract contract ManagedPolForkTestBase is StaticsTestBase {
    using CurrencyLibrary for Currency;

    struct PolAccounting {
        uint128 liquidity;
        uint256 pending0;
        uint256 pending1;
    }

    function _managedPolLiquidity(PoolId poolId) internal view returns (uint128 liquidity) {
        IStaticsProtocolPools protocolPools = IStaticsProtocolPools(address(diamond));
        IStaticsProtocolPools.ProtocolPoolView memory pool = protocolPools.protocolPool(poolId);
        assertTrue(pool.polActivated);
        assertEq(pool.activePolPositions, 1);
        uint256[] memory ids = protocolPools.protocolPolPositionIds(poolId);
        assertEq(ids.length, 1);
        IStaticsProtocolPools.ProtocolPolPositionView memory position = protocolPools.protocolPolPosition(ids[0]);
        assertTrue(position.active);
        assertEq(PoolId.unwrap(position.poolId), PoolId.unwrap(poolId));
        (address manager,) = basketLiquidity.liquidityManager();
        assertEq(position.manager, manager);
        address posm = StaticsLiquidityManager(manager).positionManager();
        assertEq(IERC721(posm).ownerOf(position.posmTokenId), manager);
        assertEq(IPositionManager(posm).getPositionLiquidity(position.posmTokenId), position.liquidity);
        assertGt(position.liquidity, 0);
        return position.liquidity;
    }

    function _snapshotPol(PoolId poolId) internal view returns (PolAccounting memory snapshot) {
        snapshot.liquidity = _managedPolLiquidity(poolId);
        IStaticsProtocolPools.ProtocolPoolView memory pool =
            IStaticsProtocolPools(address(diamond)).protocolPool(poolId);
        IStaticsSwapFeeHook hook = IStaticsSwapFeeHook(address(pool.key.hooks));
        snapshot.pending0 = hook.pendingProtocolPol(poolId, pool.key.currency0);
        snapshot.pending1 = hook.pendingProtocolPol(poolId, pool.key.currency1);
    }

    function _assertPolFeeGrowth(PoolId poolId, PolAccounting memory beforeAction) internal view {
        PolAccounting memory afterAction = _snapshotPol(poolId);
        // Swaps accrue inventory claims; liquidity changes only through explicit POL management.
        assertEq(afterAction.liquidity, beforeAction.liquidity, "swap changed managed POL principal");
        assertGe(afterAction.pending0, beforeAction.pending0);
        assertGe(afterAction.pending1, beforeAction.pending1);
        assertGt(afterAction.pending0 + afterAction.pending1, beforeAction.pending0 + beforeAction.pending1);
        IStaticsProtocolPools.ProtocolPoolView memory pool =
            IStaticsProtocolPools(address(diamond)).protocolPool(poolId);
        IStaticsSwapFeeHook hook = IStaticsSwapFeeHook(address(pool.key.hooks));
        (address manager,,) = basketLiquidity.liquidityIntegration();
        IPoolManager poolManager = IPoolManager(manager);
        assertEq(
            poolManager.balanceOf(address(hook), pool.key.currency0.toId()), hook.claimLiability(pool.key.currency0)
        );
        assertEq(
            poolManager.balanceOf(address(hook), pool.key.currency1.toId()), hook.claimLiability(pool.key.currency1)
        );
    }
}
