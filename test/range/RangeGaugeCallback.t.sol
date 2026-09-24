// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {RangeGaugeCallbackFacet} from "../../src/facets/RangeGaugeCallbackFacet.sol";
import {IStaticsProtocolPools} from "../../src/interfaces/IStaticsProtocolPools.sol";
import {LibProtocolPools} from "../../src/libraries/LibProtocolPools.sol";
import {RangeGaugeCallbackHarness, RangeGaugeHookCaller} from "../helpers/RangeGaugeCallbackHarness.sol";

contract RangeGaugeCallbackTest is Test {
    using PoolIdLibrary for PoolKey;

    RangeGaugeCallbackHarness private callback;
    RangeGaugeHookCaller private hook;
    address private otherHook;

    function setUp() public {
        callback = new RangeGaugeCallbackHarness();
        hook = new RangeGaugeHookCaller();
        otherHook = makeAddr("otherHook");
    }

    function testAcceptsInstalledHookForRegisteredGeneralPool() public {
        PoolKey memory key = _key(address(hook));
        PoolId poolId = callback.registerGeneralPool(key, makeAddr("creator"));
        callback.installPublicIntegration(makeAddr("poolManager"), address(hook));

        hook.notify(address(callback), poolId);
    }

    function testAcceptsInstalledHookForRegisteredBasketPool() public {
        PoolKey memory key = _key(address(hook));
        PoolId poolId = callback.registerBasketPool(key, 7, address(0xBEEF));
        callback.installPublicIntegration(makeAddr("poolManager"), address(hook));

        hook.notify(address(callback), poolId);
    }

    function testRejectsCallbackBeforePublicIntegrationIsInstalled() public {
        vm.expectRevert(RangeGaugeCallbackFacet.PublicLiquidityIntegrationNotInstalled.selector);
        hook.notify(address(callback), PoolId.wrap(bytes32(uint256(1))));
    }

    function testRejectsCallerOtherThanInstalledPublicHook() public {
        callback.installPublicIntegration(makeAddr("poolManager"), address(hook));

        vm.expectRevert(
            abi.encodeWithSelector(
                RangeGaugeCallbackFacet.OnlyInstalledPublicHook.selector, address(this), address(hook)
            )
        );
        callback.afterProtocolPoolSwap(PoolId.wrap(bytes32(uint256(1))));
    }

    function testRejectsUnregisteredPool() public {
        PoolId poolId = PoolId.wrap(bytes32(uint256(1)));
        callback.installPublicIntegration(makeAddr("poolManager"), address(hook));

        vm.expectRevert(abi.encodeWithSelector(LibProtocolPools.ProtocolPoolNotRegistered.selector, poolId));
        hook.notify(address(callback), poolId);
    }

    function testRejectsPermissionedPool() public {
        PoolKey memory key = _key(address(hook));
        PoolId poolId = callback.registerPermissionedPool(key, makeAddr("creator"));
        callback.installPublicIntegration(makeAddr("poolManager"), address(hook));

        vm.expectRevert(
            abi.encodeWithSelector(
                RangeGaugeCallbackFacet.InvalidPublicPoolKind.selector,
                poolId,
                IStaticsProtocolPools.ProtocolPoolKind.PermissionedGeneral
            )
        );
        hook.notify(address(callback), poolId);
    }

    function testRejectsPublicPoolBoundToDifferentHook() public {
        PoolKey memory key = _key(otherHook);
        PoolId poolId = callback.registerGeneralPool(key, makeAddr("creator"));
        callback.installPublicIntegration(makeAddr("poolManager"), address(hook));

        vm.expectRevert(
            abi.encodeWithSelector(
                RangeGaugeCallbackFacet.PublicPoolHookMismatch.selector, poolId, address(hook), otherHook
            )
        );
        hook.notify(address(callback), poolId);
    }

    function _key(address hookAddress) private pure returns (PoolKey memory key) {
        key = PoolKey({
            currency0: Currency.wrap(address(0x1000)),
            currency1: Currency.wrap(address(0x2000)),
            fee: 3_000,
            tickSpacing: 10,
            hooks: IHooks(hookAddress)
        });
    }
}
