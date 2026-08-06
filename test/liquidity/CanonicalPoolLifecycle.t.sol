// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IStaticsBasket} from "../../src/interfaces/IStaticsBasket.sol";
import {IStaticsBasketLiquidity} from "../../src/interfaces/IStaticsBasketLiquidity.sol";
import {IStaticsBasketLaunchModule} from "../../src/interfaces/IStaticsBasketLaunchModule.sol";
import {IStaticsSwapFeeHook} from "../../src/interfaces/IStaticsSwapFeeHook.sol";
import {BasketLiquidityFacet} from "../../src/facets/BasketLiquidityFacet.sol";
import {LibDiamond} from "../../src/libraries/LibDiamond.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {CanonicalPoolTestBase} from "../helpers/CanonicalPoolTestBase.sol";

contract CanonicalPoolLifecycleTest is CanonicalPoolTestBase {
    event CanonicalPoolFeeConfigurationSet(
        uint256 indexed basketId,
        address indexed asset,
        bytes32 indexed poolId,
        uint16 inputFeeBps,
        uint16 outputFeeBps,
        uint16 polShareBps,
        uint16 liquidityProviderShareBps,
        uint16 basketStakerShareBps,
        uint16 staticsStakerShareBps,
        uint16 treasuryShareBps
    );
    event CanonicalPoolFeeConfigurationCleared(uint256 indexed basketId, address indexed asset, bytes32 indexed poolId);

    function testLaunchHelpersRejectDirectCalls() public {
        IStaticsBasket.PoolLaunchParams[] memory pools = new IStaticsBasket.PoolLaunchParams[](0);
        uint256[] memory amounts = new uint256[](0);

        vm.expectRevert(abi.encodeWithSelector(BasketLiquidityFacet.OnlyDiamondSelf.selector, address(this)));
        IStaticsBasketLaunchModule(address(diamond)).launchBasketPools(0, alice, pools, amounts);

        vm.expectRevert(abi.encodeWithSelector(BasketLiquidityFacet.OnlyDiamondSelf.selector, address(this)));
        IStaticsBasketLaunchModule(address(diamond)).mintBasketLaunch(0, alice, 1 ether, amounts, amounts);
    }

    function testSingleAssetBasketCreatesOneDerivedCanonicalPool() public {
        (uint256 basketId, address[] memory assets) = _createBasketWithAssets(1);
        _assertCanonicalPool(basketId, assets[0]);
    }

    function testThreeAssetBasketCreatesOnePoolPerConstituent() public {
        (uint256 basketId, address[] memory assets) = _createBasketWithAssets(3);
        for (uint256 i; i < assets.length; ++i) {
            _assertCanonicalPool(basketId, assets[i]);
        }
    }

    function testSixteenAssetBasketCreatesOnePoolPerConstituent() public {
        (uint256 basketId, address[] memory assets) = _createBasketWithAssets(16);
        for (uint256 i; i < assets.length; ++i) {
            _assertCanonicalPool(basketId, assets[i]);
        }
    }

    function testPoolPairAndConfigurationCannotBeSuppliedByCaller() public {
        (uint256 basketId, address[] memory assets) = _createBasketWithAssets(1);
        IStaticsBasketLiquidity.CanonicalPoolView memory pool = basketLiquidity.canonicalPool(basketId, assets[0]);
        assertEq(pool.lpFee, 0);
        assertEq(pool.tickSpacing, 10);
        assertEq(pool.hook, address(swapFeeHook));
        assertTrue(
            (pool.currency0 == pool.basketToken && pool.currency1 == assets[0])
                || (pool.currency1 == pool.basketToken && pool.currency0 == assets[0])
        );

        assertGt(swapFeeHook.lockedLiquidity(pool.poolId), 0);
    }

    function testCanonicalPoolFeeOverrideIsOwnerControlledAndUsesRegisteredPool() public {
        (uint256 basketId, address[] memory assets) = _createBasketWithAssets(1);
        IStaticsBasketLiquidity.CanonicalPoolView memory pool = basketLiquidity.canonicalPool(basketId, assets[0]);
        IStaticsBasketLiquidity.SwapFeeConfiguration memory configuration = IStaticsBasketLiquidity.SwapFeeConfiguration({
            inputFeeBps: 40,
            outputFeeBps: 60,
            polShareBps: 0,
            liquidityProviderShareBps: 0,
            basketStakerShareBps: 0,
            staticsStakerShareBps: 8_000,
            treasuryShareBps: 2_000
        });

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(LibDiamond.NotContractOwner.selector, bob, address(this)));
        basketLiquidity.setCanonicalPoolFeeConfiguration(basketId, assets[0], configuration);

        vm.expectEmit(true, true, true, true, address(diamond));
        emit CanonicalPoolFeeConfigurationSet(
            basketId, assets[0], PoolId.unwrap(pool.poolId), 40, 60, 0, 0, 0, 8_000, 2_000
        );
        basketLiquidity.setCanonicalPoolFeeConfiguration(basketId, assets[0], configuration);

        IStaticsBasketLiquidity.PoolFeeConfigurationView memory effective =
            basketLiquidity.canonicalPoolFeeConfiguration(basketId, assets[0]);
        assertEq(effective.inputFeeBps, 40);
        assertEq(effective.outputFeeBps, 60);
        assertEq(effective.polShareBps, 0);
        assertEq(effective.liquidityProviderShareBps, 0);
        assertEq(effective.basketStakerShareBps, 0);
        assertEq(effective.staticsStakerShareBps, 8_000);
        assertEq(effective.treasuryShareBps, 2_000);
        assertTrue(effective.overridden);
        IStaticsSwapFeeHook.PoolFeeConfigurationView memory hookEffective =
            swapFeeHook.poolFeeConfiguration(pool.poolId);
        assertEq(hookEffective.inputFeeBps, effective.inputFeeBps);
        assertEq(hookEffective.outputFeeBps, effective.outputFeeBps);
        assertEq(hookEffective.staticsStakerShareBps, effective.staticsStakerShareBps);
        assertTrue(hookEffective.overridden);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(LibDiamond.NotContractOwner.selector, bob, address(this)));
        basketLiquidity.clearCanonicalPoolFeeConfiguration(basketId, assets[0]);

        vm.expectEmit(true, true, true, true, address(diamond));
        emit CanonicalPoolFeeConfigurationCleared(basketId, assets[0], PoolId.unwrap(pool.poolId));
        basketLiquidity.clearCanonicalPoolFeeConfiguration(basketId, assets[0]);
        effective = basketLiquidity.canonicalPoolFeeConfiguration(basketId, assets[0]);
        assertEq(effective.inputFeeBps, 25);
        assertEq(effective.outputFeeBps, 25);
        assertEq(effective.polShareBps, 1_000);
        assertEq(effective.liquidityProviderShareBps, 2_500);
        assertEq(effective.basketStakerShareBps, 2_500);
        assertEq(effective.staticsStakerShareBps, 1_500);
        assertEq(effective.treasuryShareBps, 2_500);
        assertFalse(effective.overridden);
    }

    function testCanonicalPoolFeeConfigurationRejectsUnconfiguredIdentifier() public {
        (uint256 basketId,) = _createBasketWithAssets(1);
        IStaticsBasketLiquidity.SwapFeeConfiguration memory configuration = IStaticsBasketLiquidity.SwapFeeConfiguration({
            inputFeeBps: 40,
            outputFeeBps: 60,
            polShareBps: 0,
            liquidityProviderShareBps: 0,
            basketStakerShareBps: 0,
            staticsStakerShareBps: 8_000,
            treasuryShareBps: 2_000
        });
        address unconfigured = makeAddr("unconfigured");
        vm.expectRevert(
            abi.encodeWithSelector(BasketLiquidityFacet.CanonicalPoolNotConfigured.selector, basketId, unconfigured)
        );
        basketLiquidity.setCanonicalPoolFeeConfiguration(basketId, unconfigured, configuration);
        vm.expectRevert(
            abi.encodeWithSelector(BasketLiquidityFacet.CanonicalPoolNotConfigured.selector, basketId, unconfigured)
        );
        basketLiquidity.clearCanonicalPoolFeeConfiguration(basketId, unconfigured);
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
        assertEq(pool.asset, asset);
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
            recoveryPenaltyBps: 500,
            loanDuration: 30 days
        });
        (IStaticsBasket.PoolLaunchParams[] memory pools, uint256[] memory maximums) = _fundDefaultLaunch(assets, alice);
        uint256 creationFeeAmount = basketAdmin.creationFee();
        vm.prank(alice);
        (basketId,) = baskets.createBasket{value: creationFeeAmount}(params, pools, maximums, type(uint256).max);
    }
}
