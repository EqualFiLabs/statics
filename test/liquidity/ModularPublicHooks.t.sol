// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IStaticsBasket} from "../../src/interfaces/IStaticsBasket.sol";
import {IStaticsBasketLiquidity} from "../../src/interfaces/IStaticsBasketLiquidity.sol";
import {IStaticsProtocolPools} from "../../src/interfaces/IStaticsProtocolPools.sol";
import {IStaticsPublicHookPolicy} from "../../src/interfaces/IStaticsPublicHookPolicy.sol";
import {IStaticsHookAdministration} from "../../src/interfaces/IStaticsHookAdministration.sol";
import {IStaticsSwapFeeHook} from "../../src/interfaces/IStaticsSwapFeeHook.sol";
import {StaticsGeneralPoolHook} from "../../src/liquidity/StaticsGeneralPoolHook.sol";
import {LibPublicHookPolicy} from "../../src/libraries/LibPublicHookPolicy.sol";
import {RangeGaugeFeatureTestBase} from "../helpers/RangeGaugeFeatureTestBase.sol";
import {RangeGaugeLifecycleTestBase} from "../helpers/RangeGaugeLifecycleTestBase.sol";
import {PublicHookPolicyFacet} from "../../src/facets/PublicHookPolicyFacet.sol";

contract ModularPublicHooksTest is RangeGaugeFeatureTestBase {
    using PoolIdLibrary for PoolKey;

    function testGeneralPoolsShareGeneralHookAndKeepPoolLocalRates() public {
        PoolId first = _createRangeGaugePool(alice, address(assetA), address(assetB));
        PoolId second = _createRangeGaugePool(alice, address(assetA), address(stakingAsset));
        IStaticsProtocolPools pools = IStaticsProtocolPools(address(diamond));
        assertEq(address(pools.protocolPool(first).key.hooks), address(_localGeneralHook));
        assertEq(address(pools.protocolPool(second).key.hooks), address(_localGeneralHook));
        pools.setProtocolPoolFeeRate(first, IStaticsProtocolPools.PoolSwapFeeRate(800, 900));
        assertEq(pools.protocolPoolFeeRate(first).inputFeePips, 800);
        assertEq(pools.protocolPoolFeeRate(second).inputFeePips, 2_500);
    }

    function testRegistrationAndInitializationRequireDiamond() public {
        IStaticsProtocolPools.GeneralPoolQuote memory quote =
            IStaticsProtocolPools(address(diamond)).quotePool(_params(500));
        vm.expectPartialRevert(StaticsGeneralPoolHook.OnlyStaticsDiamond.selector);
        vm.prank(alice);
        _localGeneralHook.registerPool(quote.key, StaticsGeneralPoolHook.PoolKind.General, alice);
        vm.prank(address(diamond));
        _localGeneralHook.registerPool(quote.key, StaticsGeneralPoolHook.PoolKind.General, alice);
        vm.expectRevert();
        vm.prank(alice);
        IPoolManager(poolManager).initialize(quote.key, quote.sqrtPriceX96);
        vm.expectPartialRevert(StaticsGeneralPoolHook.PoolAlreadyRegistered.selector);
        vm.prank(address(diamond));
        _localGeneralHook.registerPool(quote.key, StaticsGeneralPoolHook.PoolKind.General, alice);
    }

    function testDuplicateCompletePoolKeyIsRejected() public {
        IStaticsProtocolPools.CreatePoolParams memory params = _params(501);
        IStaticsProtocolPools(address(diamond)).createPool(params, "");
        params.nonce = 502;
        vm.expectRevert();
        IStaticsProtocolPools(address(diamond)).createPool(params, "");
    }

    function testBasketPoolsShareBasketHookAndStaySeparateFromGeneral() public {
        PoolId general = _createRangeGaugePool(alice, address(assetA), address(assetB));
        IStaticsProtocolPools(address(diamond)).setPoolCreationFee(1 wei);
        (uint256 id,) = _createDefaultBasket(0, 0);
        IStaticsBasket.BasketView memory basket = baskets.basket(id);
        for (uint256 i; i < basket.assets.length; ++i) {
            IStaticsBasketLiquidity.CanonicalPoolView memory market =
                basketLiquidity.canonicalPool(id, basket.assets[i]);
            assertEq(market.hook, address(_localBasketHook));
            assertTrue(_localBasketHook.poolRegistration(market.poolId).registered);
            assertFalse(_localGeneralHook.poolRegistration(market.poolId).registered);
        }
        assertEq(
            address(IStaticsProtocolPools(address(diamond)).protocolPool(general).key.hooks), address(_localGeneralHook)
        );
        assertFalse(_localBasketHook.poolRegistration(general).registered);
    }

    function testFeeSettingsAreIndependentAndLegacySelectorsKeepLegacyBehavior() public {
        IStaticsHookAdministration admin = IStaticsHookAdministration(address(diamond));
        IStaticsProtocolPools legacy = IStaticsProtocolPools(address(diamond));
        (uint16 basketBefore,) = _localBasketHook.defaultFeeRate();
        admin.setDefaultProtocolPoolFeeRate(address(_localGeneralHook), IStaticsProtocolPools.PoolSwapFeeRate(700, 800));
        assertEq(admin.defaultProtocolPoolFeeRate(address(_localGeneralHook)).inputFeePips, 700);
        assertEq(admin.defaultProtocolPoolFeeRate(address(_localBasketHook)).inputFeePips, basketBefore);
        legacy.setDefaultProtocolPoolFeeRate(IStaticsProtocolPools.PoolSwapFeeRate(900, 1_000));
        assertEq(legacy.defaultProtocolPoolFeeRate().inputFeePips, 900);
        assertEq(admin.defaultProtocolPoolFeeRate(address(_localGeneralHook)).inputFeePips, 700);
        assertEq(admin.defaultProtocolPoolFeeRate(address(_localBasketHook)).inputFeePips, basketBefore);
        admin.setGeneralFeeAllocation(
            address(_localGeneralHook), IStaticsProtocolPools.GeneralFeeAllocation(3500, 4000, 2000)
        );
        assertEq(admin.generalFeeAllocation(address(_localGeneralHook)).staticsStakerShareBps, 4000);
        assertEq(legacy.generalFeeAllocation().staticsStakerShareBps, 3500);
        (bool generalExposesBasket,) = address(_localGeneralHook)
            .staticcall(abi.encodeWithSelector(IStaticsSwapFeeHook.basketFeeAllocation.selector));
        assertFalse(generalExposesBasket);
        (bool basketExposesGeneral,) = address(_localBasketHook)
            .staticcall(abi.encodeWithSelector(IStaticsSwapFeeHook.generalFeeAllocation.selector));
        assertFalse(basketExposesGeneral);
        vm.expectRevert(
            abi.encodeWithSelector(LibPublicHookPolicy.UnsupportedHookAllocation.selector, address(_localBasketHook))
        );
        admin.setGeneralFeeAllocation(
            address(_localBasketHook), IStaticsProtocolPools.GeneralFeeAllocation(3500, 4000, 2000)
        );
        vm.expectRevert(abi.encodeWithSelector(LibPublicHookPolicy.InvalidConfiguredHook.selector, alice));
        admin.setDefaultProtocolPoolFeeRate(alice, IStaticsProtocolPools.PoolSwapFeeRate(1, 1));
        vm.expectRevert();
        vm.prank(alice);
        admin.setDefaultProtocolPoolFeeRate(address(_localGeneralHook), IStaticsProtocolPools.PoolSwapFeeRate(1, 1));
    }

    function testConfigurationAndOneTimeInstallation() public {
        (address general, address basket, address factory, address legacy) =
            IStaticsPublicHookPolicy(address(diamond)).publicHookConfiguration();
        assertEq(general, address(_localGeneralHook));
        assertEq(basket, address(_localBasketHook));
        assertEq(factory, address(_localBasketFactory));
        (, address installedLegacy,) = basketLiquidity.liquidityIntegration();
        assertEq(legacy, installedLegacy);
        assertEq(uint160(general) & ((1 << 14) - 1), 0x10ec);
        assertEq(uint160(basket) & ((1 << 14) - 1), 0x1fec);
        vm.expectRevert(PublicHookPolicyFacet.PublicHooksAlreadyInstalled.selector);
        IStaticsPublicHookPolicy(address(diamond)).installPublicHooks(general, basket, factory);
    }

    function _params(uint256 nonce) private view returns (IStaticsProtocolPools.CreatePoolParams memory params) {
        params = IStaticsProtocolPools.CreatePoolParams(
            address(assetA),
            address(assetB),
            3000,
            10,
            SQRT_PRICE_1_1,
            IStaticsProtocolPools.PoolSwapFeeRate(2500, 2500),
            address(this),
            false,
            nonce,
            type(uint256).max
        );
    }
}

contract ModularPublicHookLegacyContinuityTest is RangeGaugeLifecycleTestBase {
    PoolId private legacyPool;
    PoolId private generalPool;

    function _installLegacyBasketFactory() internal pure override returns (bool) {
        return false;
    }

    function setUp() public override {
        super.setUp();
        legacyPool = _createRangeGaugePool(address(this), address(assetA), address(assetB));
        _localBasketFactory = _deployTestBasketFactory(address(diamond), poolManager, swapFeeHook);
        _localGeneralHook = _deployGeneralHook(poolManager);
        _localBasketHook = _deployBasketHook(poolManager);
        PublicHookPolicyFacet(address(diamond))
            .installPublicHooks(address(_localGeneralHook), address(_localBasketHook), address(_localBasketFactory));
        generalPool = _createRangeGaugePool(address(this), address(assetA), address(stakingAsset));
    }

    function testLegacyPoolRetainsItsHookAfterInstallation() public view {
        IStaticsProtocolPools pools = IStaticsProtocolPools(address(diamond));
        assertEq(address(pools.protocolPool(legacyPool).key.hooks), address(swapFeeHook));
        assertEq(address(pools.protocolPool(generalPool).key.hooks), address(_localGeneralHook));
        assertTrue(swapFeeHook.poolRegistration(legacyPool).registered);
        assertTrue(_localGeneralHook.poolRegistration(generalPool).registered);
    }
}
