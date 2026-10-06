// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IStaticsProtocolPools} from "../../src/interfaces/IStaticsProtocolPools.sol";
import {IStaticsPosition} from "../../src/interfaces/IStaticsPosition.sol";
import {IStaticsRangeGauge} from "../../src/interfaces/IStaticsRangeGauge.sol";
import {IStaticsBasketLiquidity} from "../../src/interfaces/IStaticsBasketLiquidity.sol";
import {RangeGaugeFeatureTestBase} from "../helpers/RangeGaugeFeatureTestBase.sol";

contract RestrictedRangeGaugeTest is RangeGaugeFeatureTestBase {
    function testRealRestrictedPositionProvideIncreaseCollectRebalanceAndExit() public {
        (uint256 basketId, address token) = _createDefaultBasket(0, 0);
        IStaticsBasketLiquidity.CanonicalPoolView memory market =
            basketLiquidity.canonicalPool(basketId, address(assetA));
        uint256[] memory backing = baskets.quoteMint(basketId, 5 ether);
        _fundAndApprove(alice, backing[0], backing[1]);
        vm.prank(alice);
        baskets.mint(basketId, 5 ether, alice, backing);
        assetA.mint(alice, 5 ether);
        vm.startPrank(alice);
        IERC20(token).approve(address(diamond), type(uint256).max);
        assetA.approve(address(diamond), type(uint256).max);
        uint256 positionId = IStaticsPosition(address(diamond)).createPosition(alice);
        IStaticsRangeGauge.LiquidityMovement memory provided = rangeGauge.provideLiquidity(
            positionId,
            IStaticsRangeGauge.ProvideLiquidityParams(
                market.poolId, TickMath.minUsableTick(10), TickMath.maxUsableTick(10), 0.1 ether,
                1 ether, 1 ether, block.timestamp
            )
        );
        assertEq(IERC721(address(rangePositionManager)).ownerOf(provided.posmTokenId), address(rangeLiquidityManager));
        assertEq(rangeGauge.lpLeg(positionId, market.poolId).liquidity, 0.1 ether);
        rangeGauge.increaseLiquidity(
            positionId, market.poolId, IStaticsRangeGauge.IncreaseLiquidityParams(0.1 ether, 1 ether, 1 ether, block.timestamp)
        );
        assertEq(rangeGauge.lpLeg(positionId, market.poolId).liquidity, 0.2 ether);
        vm.stopPrank();
        assetA.mint(bob, 1 ether);
        PoolKey memory key = IStaticsProtocolPools(address(diamond)).protocolPool(market.poolId).key;
        bool direction = Currency.unwrap(key.currency0) == address(assetA);
        vm.startPrank(bob);
        assetA.approve(address(v4Router), 1 ether);
        v4Router.swap(key, SwapParams(direction, -int256(0.1 ether),
            direction ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1));
        vm.stopPrank();
        vm.startPrank(alice);
        IStaticsRangeGauge.LiquidityMovement memory collected =
            rangeGauge.collectNativeFees(positionId, market.poolId, 0, 0, block.timestamp);
        assertGt(collected.received0 + collected.received1, 0);
        rangeGauge.decreaseLiquidity(
            positionId, market.poolId, IStaticsRangeGauge.DecreaseLiquidityParams(0.05 ether, 0, 0, block.timestamp)
        );
        assertEq(rangeGauge.lpLeg(positionId, market.poolId).liquidity, 0.15 ether);
        IStaticsRangeGauge.LiquidityMovement memory rebalanced = rangeGauge.rebalanceLiquidity(
            positionId, market.poolId,
            IStaticsRangeGauge.RebalanceLiquidityParams(-600, 600, 0.15 ether, 1 ether, 1 ether, 0, 0, block.timestamp)
        );
        assertNotEq(rebalanced.posmTokenId, provided.posmTokenId);
        assertEq(IERC721(address(rangePositionManager)).ownerOf(rebalanced.posmTokenId), address(rangeLiquidityManager));
        vm.stopPrank();
        governance.decommissionBasket(basketId);
        vm.prank(alice);
        vm.expectRevert();
        rangeGauge.increaseLiquidity(
            positionId, market.poolId, IStaticsRangeGauge.IncreaseLiquidityParams(1, 1 ether, 1 ether, block.timestamp)
        );
        vm.prank(alice);
        IStaticsRangeGauge.LiquidityMovement memory exited =
            rangeGauge.exitLiquidity(positionId, market.poolId, 0, 0, block.timestamp);
        assertGt(exited.received0 + exited.received1, 0);
        assertEq(rangeGauge.lpLeg(positionId, market.poolId).liquidity, 0);
        assertEq(IERC20(token).balanceOf(address(rangeLiquidityManager)), 0);
        assertEq(assetA.balanceOf(address(rangeLiquidityManager)), 0);
        assertGe(IERC20(token).balanceOf(address(diamond)), custody.globalReservedByToken(token));
    }
}
