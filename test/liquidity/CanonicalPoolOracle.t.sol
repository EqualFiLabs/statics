// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IStaticsBasketLiquidity} from "../../src/interfaces/IStaticsBasketLiquidity.sol";
import {IStaticsSwapFeeHook} from "../../src/interfaces/IStaticsSwapFeeHook.sol";
import {BasketLiquidityFacet} from "../../src/facets/BasketLiquidityFacet.sol";
import {StaticsSwapFeeHook} from "../../src/liquidity/StaticsSwapFeeHook.sol";
import {CanonicalPoolTestBase} from "../helpers/CanonicalPoolTestBase.sol";

contract CanonicalPoolOracleTest is CanonicalPoolTestBase {
    function testPoolActivatesAfterFixedWarmupWithStableReference() public {
        (uint256 basketId,) = _createDefaultBasket(0, 0);

        vm.warp(block.timestamp + 1 hours - 1);
        basketLiquidity.checkpointCanonicalPool(basketId, address(assetA));
        vm.expectPartialRevert(BasketLiquidityFacet.PoolStillWarming.selector);
        basketLiquidity.activateCanonicalPool(basketId, address(assetA));

        vm.warp(block.timestamp + 1);
        (int24 referenceTick, int24 spotTick) = basketLiquidity.activateCanonicalPool(basketId, address(assetA));
        assertEq(referenceTick, 0);
        assertEq(spotTick, 0);
        IStaticsBasketLiquidity.CanonicalPoolView memory pool = basketLiquidity.canonicalPool(basketId, address(assetA));
        assertEq(uint8(pool.status), uint8(IStaticsBasketLiquidity.CanonicalPoolStatus.Active));
        assertEq(pool.activatedAt, block.timestamp);
        assertTrue(pool.referenceAvailable);
    }

    function testObservationRingIsBoundedAndOneCheckpointPerMinute() public {
        (uint256 basketId,) = _createDefaultBasket(0, 0);
        IStaticsBasketLiquidity.CanonicalPoolView memory pool = basketLiquidity.canonicalPool(basketId, address(assetA));

        assertFalse(basketLiquidity.checkpointCanonicalPool(basketId, address(assetA)));
        uint256 checkpointAt = block.timestamp;
        for (uint256 i; i < 70; ++i) {
            checkpointAt += 1 minutes;
            vm.warp(checkpointAt);
            assertTrue(basketLiquidity.checkpointCanonicalPool(basketId, address(assetA)));
        }
        assertFalse(basketLiquidity.checkpointCanonicalPool(basketId, address(assetA)));

        IStaticsSwapFeeHook.OracleStateView memory state = swapFeeHook.oracleState(pool.poolId);
        assertEq(state.observationCardinality, 64);
        assertEq(state.latestObservationAt, block.timestamp);
        for (uint8 i; i < 64; ++i) {
            (uint40 timestamp,) = swapFeeHook.observationAt(pool.poolId, i);
            assertGt(timestamp, 0);
        }
    }

    function testOneBlockPriceManipulationCannotAuthorizePool() public {
        (uint256 basketId, address basketToken) = _createDefaultBasket(0, 0);
        IStaticsBasketLiquidity.CanonicalPoolView memory pool = basketLiquidity.canonicalPool(basketId, address(assetA));
        PoolKey memory key = _poolKey(pool);

        uint256[] memory quote = baskets.quoteMint(basketId, 100 ether);
        _fundAndApprove(alice, quote[0], quote[1]);
        vm.prank(alice);
        baskets.mint(basketId, 100 ether, alice, quote);
        assetA.mint(alice, 100 ether);
        _approveV4Router(alice, basketToken);
        _approveV4Router(alice, address(assetA));

        ModifyLiquidityParams memory liquidityParams = ModifyLiquidityParams({
            tickLower: TickMath.minUsableTick(10),
            tickUpper: TickMath.maxUsableTick(10),
            liquidityDelta: 10 ether,
            salt: bytes32(0)
        });
        vm.prank(alice);
        v4Router.modifyLiquidity(key, liquidityParams);

        uint256 initializedAt = block.timestamp;
        vm.warp(initializedAt + 30 minutes);
        basketLiquidity.checkpointCanonicalPool(basketId, address(assetA));
        vm.warp(initializedAt + 1 hours);
        basketLiquidity.checkpointCanonicalPool(basketId, address(assetA));

        bool zeroForOne = pool.currency0 == basketToken;
        SwapParams memory swapParams = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -2 ether,
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });
        vm.prank(alice);
        v4Router.swap(key, swapParams);

        (, int24 spotTick,) = swapFeeHook.consult(pool.poolId, 30 minutes);
        assertGt(spotTick > 0 ? int256(spotTick) : -int256(spotTick), 100);
        vm.expectPartialRevert(BasketLiquidityFacet.PriceDeviationTooHigh.selector);
        basketLiquidity.activateCanonicalPool(basketId, address(assetA));
    }

    function testConsultRejectsWindowWithoutHistory() public {
        (uint256 basketId,) = _createDefaultBasket(0, 0);
        IStaticsBasketLiquidity.CanonicalPoolView memory pool = basketLiquidity.canonicalPool(basketId, address(assetA));

        vm.expectPartialRevert(StaticsSwapFeeHook.InsufficientOracleHistory.selector);
        swapFeeHook.consult(pool.poolId, 30 minutes);
    }

    function _poolKey(IStaticsBasketLiquidity.CanonicalPoolView memory pool) private pure returns (PoolKey memory key) {
        key = PoolKey({
            currency0: Currency.wrap(pool.currency0),
            currency1: Currency.wrap(pool.currency1),
            fee: pool.lpFee,
            tickSpacing: pool.tickSpacing,
            hooks: IHooks(pool.hook)
        });
    }
}
