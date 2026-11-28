// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IStaticsBasket} from "../../src/interfaces/IStaticsBasket.sol";
import {IStaticsBasketLiquidity} from "../../src/interfaces/IStaticsBasketLiquidity.sol";
import {IStaticsBasketSettlement} from "../../src/interfaces/IStaticsBasketSettlement.sol";
import {IStaticsProtocolPools} from "../../src/interfaces/IStaticsProtocolPools.sol";
import {IStaticsPublicHookPolicy} from "../../src/interfaces/IStaticsPublicHookPolicy.sol";
import {IStaticsHookAdministration} from "../../src/interfaces/IStaticsHookAdministration.sol";
import {IStaticsSwapFeeHook} from "../../src/interfaces/IStaticsSwapFeeHook.sol";
import {RangeGaugeFeatureTestBase} from "../helpers/RangeGaugeFeatureTestBase.sol";
import {RangeGaugeLifecycleTestBase} from "../helpers/RangeGaugeLifecycleTestBase.sol";
import {StaticsSwapFeeHook} from "../../src/liquidity/StaticsSwapFeeHook.sol";
import {StaticsBasketHook} from "../../src/liquidity/StaticsBasketHook.sol";
import {PublicHookPolicyFacet} from "../../src/facets/PublicHookPolicyFacet.sol";
import {ProtocolPoolCreationFacet} from "../../src/facets/ProtocolPoolCreationFacet.sol";

contract ModularPublicHooksTest is RangeGaugeFeatureTestBase {
    using PoolIdLibrary for PoolKey;

    function testGeneralPoolsShareGeneralHookAndKeepPoolLocalRates() public {
        PoolId first = _createRangeGaugePool(alice, address(assetA), address(assetB));
        PoolId second = _createRangeGaugePool(alice, address(assetA), address(stakingAsset));
        IStaticsProtocolPools pools = IStaticsProtocolPools(address(diamond));
        assertEq(address(pools.protocolPool(first).key.hooks), address(swapFeeHook));
        assertEq(address(pools.protocolPool(second).key.hooks), address(swapFeeHook));
        pools.setProtocolPoolFeeRate(first, IStaticsProtocolPools.PoolSwapFeeRate(800, 900));
        assertEq(pools.protocolPoolFeeRate(first).inputFeePips, 800);
        assertEq(pools.protocolPoolFeeRate(second).inputFeePips, 2_500);
        assertFalse(IStaticsBasketSettlement(address(diamond)).canAccrueBasketCurrencyRewards(first, address(assetA)));
    }

    function testGeneralCreationRejectsPoolAlreadyRegisteredInDeployedHook() public {
        IStaticsProtocolPools pools = IStaticsProtocolPools(address(diamond));
        IStaticsProtocolPools.CreatePoolParams memory params = _params(503);
        IStaticsProtocolPools.GeneralPoolQuote memory quote = pools.quotePool(params);
        // Exercise a registration outside the Diamond registry; normal duplicate creation
        // is rejected by the Diamond before the hook-registration check.
        vm.prank(address(diamond));
        swapFeeHook.registerPool(quote.key, IStaticsSwapFeeHook.PoolKind.General, address(this));
        vm.expectRevert(
            abi.encodeWithSelector(ProtocolPoolCreationFacet.PoolAlreadyRegisteredInHook.selector, quote.poolId)
        );
        pools.createPool(params, "");
    }

    function testGeneralRegistrationRequiresDiamondAndUnregisteredInitializationFails() public {
        IStaticsProtocolPools.GeneralPoolQuote memory quote =
            IStaticsProtocolPools(address(diamond)).quotePool(_params(500));
        vm.expectPartialRevert(StaticsSwapFeeHook.OnlyStaticsDiamond.selector);
        vm.prank(alice);
        swapFeeHook.registerPool(quote.key, IStaticsSwapFeeHook.PoolKind.General, alice);
        vm.expectRevert();
        vm.prank(alice);
        IPoolManager(poolManager).initialize(quote.key, quote.sqrtPriceX96);
        IStaticsProtocolPools(address(diamond)).createPool(_params(500), "");
        vm.expectPartialRevert(StaticsSwapFeeHook.PoolAlreadyRegistered.selector);
        vm.prank(address(diamond));
        swapFeeHook.registerPool(quote.key, IStaticsSwapFeeHook.PoolKind.General, alice);
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
            assertFalse(swapFeeHook.poolRegistration(market.poolId).registered);
        }
        assertEq(address(IStaticsProtocolPools(address(diamond)).protocolPool(general).key.hooks), address(swapFeeHook));
        assertFalse(_localBasketHook.poolRegistration(general).registered);
    }

    function testBasketFeesAreIndependentAndExistingSelectorsGovernGeneralHook() public {
        IStaticsHookAdministration admin = IStaticsHookAdministration(address(diamond));
        IStaticsProtocolPools pools = IStaticsProtocolPools(address(diamond));
        admin.setDefaultProtocolPoolFeeRate(address(_localBasketHook), IStaticsProtocolPools.PoolSwapFeeRate(700, 800));
        assertEq(admin.defaultProtocolPoolFeeRate(address(_localBasketHook)).inputFeePips, 700);
        assertEq(pools.defaultProtocolPoolFeeRate().inputFeePips, 25);
        pools.setDefaultProtocolPoolFeeRate(IStaticsProtocolPools.PoolSwapFeeRate(900, 1000));
        assertEq(admin.defaultProtocolPoolFeeRate(address(swapFeeHook)).inputFeePips, 900);
        assertEq(admin.defaultProtocolPoolFeeRate(address(_localBasketHook)).inputFeePips, 700);
        admin.setGeneralFeeAllocation(
            address(swapFeeHook), IStaticsProtocolPools.GeneralFeeAllocation(3500, 4000, 2000)
        );
        assertEq(pools.generalFeeAllocation().staticsStakerShareBps, 4000);
        vm.expectRevert();
        admin.setGeneralFeeAllocation(
            address(_localBasketHook), IStaticsProtocolPools.GeneralFeeAllocation(3500, 4000, 2000)
        );
        vm.expectRevert();
        vm.prank(alice);
        admin.setDefaultProtocolPoolFeeRate(address(_localBasketHook), IStaticsProtocolPools.PoolSwapFeeRate(1, 1));
    }

    function testOwnerCanAdministerCompatibleFutureHookWithoutInstallingIt() public {
        StaticsBasketHook futureHook = _deployBasketHook(poolManager);
        IStaticsHookAdministration admin = IStaticsHookAdministration(address(diamond));
        admin.setDefaultProtocolPoolFeeRate(address(futureHook), IStaticsProtocolPools.PoolSwapFeeRate(600, 700));
        admin.setBasketFeeAllocation(
            address(futureHook), IStaticsProtocolPools.BasketFeeAllocation(3000, 1000, 3500, 2000)
        );
        assertEq(admin.defaultProtocolPoolFeeRate(address(futureHook)).inputFeePips, 600);
        assertEq(admin.basketFeeAllocation(address(futureHook)).staticsStakerShareBps, 3500);
        vm.prank(alice);
        vm.expectRevert();
        admin.setBasketFeeAllocation(
            address(futureHook), IStaticsProtocolPools.BasketFeeAllocation(3000, 1000, 3500, 2000)
        );
    }

    function testConfigurationAndOneTimeInstallation() public {
        (address basket, address factory) = IStaticsPublicHookPolicy(address(diamond)).basketHookConfiguration();
        assertEq(basket, address(_localBasketHook));
        assertEq(factory, address(_localBasketFactory));
        (, address general,) = basketLiquidity.liquidityIntegration();
        assertEq(general, address(swapFeeHook));
        assertEq(uint160(basket) & ((1 << 14) - 1), 0x1fec);
        vm.expectRevert(PublicHookPolicyFacet.BasketHookAlreadyInstalled.selector);
        IStaticsPublicHookPolicy(address(diamond)).installBasketHook(basket, factory);
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

    function _installBasketHook() internal pure override returns (bool) {
        return false;
    }

    function setUp() public override {
        super.setUp();
        legacyPool = _createRangeGaugePool(address(this), address(assetA), address(assetB));
        IStaticsProtocolPools(address(diamond))
            .setDefaultProtocolPoolFeeRate(IStaticsProtocolPools.PoolSwapFeeRate(600, 700));
        _localBasketFactory = _deployTestBasketFactory(address(diamond), poolManager, swapFeeHook);
        _localBasketHook = _deployBasketHook(poolManager);
        PublicHookPolicyFacet(address(diamond))
            .installBasketHook(address(_localBasketHook), address(_localBasketFactory));
        generalPool = _createRangeGaugePool(address(this), address(assetA), address(stakingAsset));
    }

    function testBasketInstallationSeedsOnlyBasketPolicyAndPreservesGeneralIdentity() public {
        (uint16 generalInput, uint16 generalOutput) = swapFeeHook.defaultFeeRate();
        (uint16 basketInput, uint16 basketOutput) = _localBasketHook.defaultFeeRate();
        assertEq(generalInput, 600);
        assertEq(generalOutput, 700);
        assertEq(basketInput, generalInput);
        assertEq(basketOutput, generalOutput);
        assertEq(
            _localBasketHook.basketFeeAllocation().staticsStakerShareBps,
            swapFeeHook.basketFeeAllocation().staticsStakerShareBps
        );
        vm.expectRevert();
        vm.prank(alice);
        IStaticsPublicHookPolicy(address(diamond))
            .installBasketHook(address(_localBasketHook), address(_localBasketFactory));
    }

    function testExistingGeneralPoolKeyCannotBeCreatedAgainAfterBasketInstallation() public {
        vm.expectPartialRevert(bytes4(keccak256("ProtocolPoolAlreadyRegistered(bytes32,uint8)")));
        _createRangeGaugePool(address(this), address(assetA), address(assetB));
    }

    function testGeneralPoolsBeforeAndAfterBasketInstallationUseSameHook() public view {
        IStaticsProtocolPools pools = IStaticsProtocolPools(address(diamond));
        assertEq(address(pools.protocolPool(legacyPool).key.hooks), address(swapFeeHook));
        assertEq(address(pools.protocolPool(generalPool).key.hooks), address(swapFeeHook));
        assertTrue(swapFeeHook.poolRegistration(legacyPool).registered);
        assertTrue(swapFeeHook.poolRegistration(generalPool).registered);
    }
}
