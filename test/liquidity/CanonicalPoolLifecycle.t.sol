// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IStaticsBasket} from "../../src/interfaces/IStaticsBasket.sol";
import {IStaticsBasketLiquidity} from "../../src/interfaces/IStaticsBasketLiquidity.sol";
import {IStaticsSwapFeeHook} from "../../src/interfaces/IStaticsSwapFeeHook.sol";
import {BasketLiquidityFacet} from "../../src/facets/BasketLiquidityFacet.sol";
import {LibBasket} from "../../src/libraries/LibBasket.sol";
import {LibGovernance} from "../../src/libraries/LibGovernance.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {CanonicalPoolTestBase} from "../helpers/CanonicalPoolTestBase.sol";

contract CanonicalPoolLifecycleTest is CanonicalPoolTestBase {
    function testSingleAssetBasketCreatesOneDerivedCanonicalPool() public {
        (uint256 basketId, address[] memory assets) = _createBasketWithAssets(1);
        basketLiquidity.initializeCanonicalPool(basketId, assets[0], SQRT_PRICE_1_1);
        _assertCanonicalPool(basketId, assets[0]);
    }

    function testThreeAssetBasketCreatesOnePoolPerConstituent() public {
        (uint256 basketId, address[] memory assets) = _createBasketWithAssets(3);
        for (uint256 i; i < assets.length; ++i) {
            basketLiquidity.initializeCanonicalPool(basketId, assets[i], SQRT_PRICE_1_1);
            _assertCanonicalPool(basketId, assets[i]);
        }
    }

    function testSixteenAssetBasketCreatesOnePoolPerConstituent() public {
        (uint256 basketId, address[] memory assets) = _createBasketWithAssets(16);
        for (uint256 i; i < assets.length; ++i) {
            basketLiquidity.initializeCanonicalPool(basketId, assets[i], SQRT_PRICE_1_1);
            _assertCanonicalPool(basketId, assets[i]);
        }
    }

    function testPoolPairAndConfigurationCannotBeSuppliedByCaller() public {
        (uint256 basketId, address[] memory assets) = _createBasketWithAssets(1);
        basketLiquidity.initializeCanonicalPool(basketId, assets[0], SQRT_PRICE_1_1);
        IStaticsBasketLiquidity.CanonicalPoolView memory pool = basketLiquidity.canonicalPool(basketId, assets[0]);
        assertEq(pool.lpFee, 500);
        assertEq(pool.tickSpacing, 10);
        assertEq(pool.hook, address(swapFeeHook));
        assertTrue(
            (pool.currency0 == pool.basketToken && pool.currency1 == assets[0])
                || (pool.currency1 == pool.basketToken && pool.currency0 == assets[0])
        );

        vm.expectRevert(
            abi.encodeWithSelector(BasketLiquidityFacet.CanonicalPoolAlreadyConfigured.selector, basketId, assets[0])
        );
        basketLiquidity.initializeCanonicalPool(basketId, assets[0], SQRT_PRICE_1_1);
        vm.expectRevert(
            abi.encodeWithSelector(BasketLiquidityFacet.AssetNotInBasket.selector, basketId, makeAddr("not-asset"))
        );
        basketLiquidity.initializeCanonicalPool(basketId, makeAddr("not-asset"), SQRT_PRICE_1_1);
    }

    function testGuardianPauseAndQuarantineBlockNewPoolExposureButNotCheckpointing() public {
        (uint256 basketId,) = _createDefaultBasket(0, 0);
        basketLiquidity.initializeCanonicalPool(basketId, address(assetA), SQRT_PRICE_1_1);

        vm.prank(guardian);
        governance.pause(LibGovernance.PAUSE_LIQUIDITY);
        vm.expectRevert(
            abi.encodeWithSelector(BasketLiquidityFacet.ActionPaused.selector, LibGovernance.PAUSE_LIQUIDITY)
        );
        basketLiquidity.initializeCanonicalPool(basketId, address(assetB), SQRT_PRICE_1_1);
        basketLiquidity.checkpointCanonicalPool(basketId, address(assetA));

        governance.unpause(LibGovernance.PAUSE_LIQUIDITY);
        vm.prank(guardian);
        governance.quarantineBasket(basketId);
        vm.expectPartialRevert(LibBasket.BasketNotActive.selector);
        basketLiquidity.initializeCanonicalPool(basketId, address(assetB), SQRT_PRICE_1_1);
        basketLiquidity.checkpointCanonicalPool(basketId, address(assetA));

        vm.warp(block.timestamp + 1 hours);
        vm.expectPartialRevert(LibBasket.BasketNotActive.selector);
        basketLiquidity.activateCanonicalPool(basketId, address(assetA));
    }

    function testIntegrationIdentityCanOnlyBeInstalledOnce() public {
        vm.expectRevert(BasketLiquidityFacet.LiquidityIntegrationAlreadyInstalled.selector);
        basketLiquidity.installCanonicalPoolIntegration(address(poolManager), address(swapFeeHook));
        (address configuredManager, address configuredHook, bool installed) = basketLiquidity.liquidityIntegration();
        assertEq(configuredManager, address(poolManager));
        assertEq(configuredHook, address(swapFeeHook));
        assertTrue(installed);
    }

    function _assertCanonicalPool(uint256 basketId, address asset) private view {
        IStaticsBasketLiquidity.CanonicalPoolView memory pool = basketLiquidity.canonicalPool(basketId, asset);
        assertEq(uint8(pool.status), uint8(IStaticsBasketLiquidity.CanonicalPoolStatus.Warming));
        assertEq(pool.asset, asset);
        assertEq(pool.initializedAt, block.timestamp);
        assertEq(pool.spotTick, 0);
        IStaticsSwapFeeHook.PoolRegistration memory registered = swapFeeHook.poolRegistration(pool.poolId);
        assertTrue(registered.registered);
        assertEq(Currency.unwrap(registered.currency0), pool.currency0);
        assertEq(Currency.unwrap(registered.currency1), pool.currency1);
    }

    function _createBasketWithAssets(uint256 count) private returns (uint256 basketId, address[] memory assets) {
        assets = new address[](count);
        uint256[] memory bundleAmounts = new uint256[](count);
        for (uint256 i; i < count; ++i) {
            assets[i] = address(new MockERC20("Constituent", "C", 18));
            bundleAmounts[i] = (i + 1) * 0.01 ether;
        }
        IStaticsBasket.CreateBasketParams memory params = IStaticsBasket.CreateBasketParams({
            name: "Canonical Basket",
            symbol: "sCAN",
            assets: assets,
            bundleAmounts: bundleAmounts,
            mintFeeTiers: new IStaticsBasket.FeeTier[](0),
            redemptionFeeTiers: new IStaticsBasket.FeeTier[](0),
            flashFeeBps: 0,
            originationFeeBps: 0,
            extensionFeeBps: 0,
            ltvBps: 9_500,
            loanDuration: 30 days
        });
        vm.prank(alice);
        (basketId,) = baskets.createBasket{value: basketAdmin.creationFee()}(params);
    }
}
