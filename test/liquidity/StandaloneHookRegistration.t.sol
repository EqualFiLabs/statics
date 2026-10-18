// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IStaticsSwapFeeHook} from "../../src/interfaces/IStaticsSwapFeeHook.sol";
import {StaticsSwapFeeHook} from "../../src/liquidity/StaticsSwapFeeHook.sol";
import {StaticsBasketHook} from "../../src/liquidity/StaticsBasketHook.sol";

/// @dev Narrow registration/administration proof. Diamond value-moving integration lives in ModularPublicHooks.
contract StandaloneHookRegistrationTest is Test {
    StaticsSwapFeeHook private general;
    StaticsBasketHook private basket;
    IPoolManager private manager;

    function setUp() public {
        manager = IPoolManager(deployCode("out/PoolManager.sol/PoolManager.json", abi.encode(address(this))));
        bytes memory args = abi.encode(manager, address(this), uint16(25), uint16(25), address(0x1234));
        (, bytes32 generalSalt) = HookMiner.find(address(this), 0x10ec, type(StaticsSwapFeeHook).creationCode, args);
        general = new StaticsSwapFeeHook{salt: generalSalt}(manager, address(this), 25, 25, address(0x1234));
        (, bytes32 basketSalt) = HookMiner.find(address(this), 0x1fec, type(StaticsBasketHook).creationCode, args);
        basket = new StaticsBasketHook{salt: basketSalt}(manager, address(this), 25, 25, address(0x1234));
    }

    function testHooksRegisterMultiplePoolsWithIndependentRatesAndLifecycle() public {
        PoolKey memory first = _key(address(general), 3000);
        PoolKey memory second = _key(address(general), 500);
        PoolId a = general.registerPool(first, IStaticsSwapFeeHook.PoolKind.General, address(this));
        PoolId b = general.registerPool(second, IStaticsSwapFeeHook.PoolKind.General, address(this));
        PoolKey memory basketKey = _key(address(basket), 3000);
        PoolId c = basket.registerPool(basketKey, StaticsBasketHook.PoolKind.BasketCanonical, address(this));
        general.setDefaultFeeRate(50, 60);
        general.setPoolFeeRate(a, 70, 80);
        basket.setDefaultFeeRate(90, 100);
        assertEq(general.poolFeeRate(a).inputFeePips, 70);
        assertEq(general.poolFeeRate(b).inputFeePips, 50);
        assertEq(basket.poolFeeRate(c).inputFeePips, 90);
        general.decommissionPool(first);
        assertTrue(general.poolDecommissioned(a));
        assertFalse(general.poolDecommissioned(b));
        assertFalse(basket.poolDecommissioned(c));
        vm.expectRevert(StaticsSwapFeeHook.PoolAlreadyRegistered.selector);
        general.registerPool(first, IStaticsSwapFeeHook.PoolKind.General, address(this));
        vm.expectRevert(StaticsBasketHook.InvalidPoolKind.selector);
        basket.registerPool(_key(address(basket), 500), StaticsBasketHook.PoolKind.General, address(this));
    }

    function testExternalCallerCannotRegisterInitializeOrGovernEitherHook() public {
        address outsider = address(0xBAD);
        PoolKey memory key = _key(address(general), 3000);
        general.registerPool(key, IStaticsSwapFeeHook.PoolKind.General, address(this));
        PoolKey memory basketKey = _key(address(basket), 3000);
        basket.registerPool(basketKey, StaticsBasketHook.PoolKind.BasketCanonical, address(this));
        vm.startPrank(outsider);
        vm.expectPartialRevert(StaticsSwapFeeHook.OnlyStaticsDiamond.selector);
        general.registerPool(_key(address(general), 500), IStaticsSwapFeeHook.PoolKind.General, outsider);
        vm.expectPartialRevert(StaticsBasketHook.OnlyStaticsDiamond.selector);
        basket.registerPool(_key(address(basket), 500), StaticsBasketHook.PoolKind.BasketCanonical, outsider);
        vm.expectPartialRevert(StaticsSwapFeeHook.OnlyStaticsDiamond.selector);
        general.setDefaultFeeRate(1, 1);
        vm.expectPartialRevert(StaticsBasketHook.OnlyStaticsDiamond.selector);
        basket.setDefaultFeeRate(1, 1);
        // General pools register and initialize atomically through the Diamond.
        // Unregistered keys cannot be initialized on the deployed hook.
        vm.expectRevert();
        manager.initialize(_key(address(general), 500), uint160(1 << 96));
        vm.expectRevert();
        manager.initialize(basketKey, uint160(1 << 96));
        vm.stopPrank();
        manager.initialize(key, uint160(1 << 96));
        manager.initialize(basketKey, uint160(1 << 96));
    }

    function _key(address hook, uint24 fee) private pure returns (PoolKey memory) {
        return PoolKey(Currency.wrap(address(0x1000)), Currency.wrap(address(0x2000)), fee, 10, IHooks(hook));
    }
}
