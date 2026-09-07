// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {SymTest} from "halmos-cheatcodes/SymTest.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IStaticsLaunchLiquidityHook} from "../../src/interfaces/IStaticsLaunchLiquidityHook.sol";
import {
    FormalLaunchAccessController,
    FormalLaunchPoolManager,
    FormalLaunchPositionManager,
    FormalLaunchToken,
    FormalStaticsLaunchLiquidityHook
} from "./mocks/FormalLaunchLiquidityMocks.sol";

contract StaticsLaunchLiquidityGovernanceHalmosTest is SymTest, Test {
    using PoolIdLibrary for PoolKey;

    uint160 private constant SQRT_PRICE_1_1 = 1 << 96;

    FormalLaunchAccessController private controller;
    FormalLaunchPoolManager private manager;
    FormalLaunchPositionManager private positionManager;
    FormalStaticsLaunchLiquidityHook private hook;
    PoolKey private key;
    PoolId private poolId;

    function setUp() public {
        FormalLaunchToken tokenA = new FormalLaunchToken();
        FormalLaunchToken tokenB = new FormalLaunchToken();
        controller = new FormalLaunchAccessController();
        manager = new FormalLaunchPoolManager();
        positionManager = new FormalLaunchPositionManager(IPoolManager(address(manager)));
        hook = new FormalStaticsLaunchLiquidityHook(
            IPoolManager(address(manager)),
            IPositionManager(address(positionManager)),
            address(controller),
            address(0xBEEF)
        );

        (Currency currency0, Currency currency1) = address(tokenA) < address(tokenB)
            ? (Currency.wrap(address(tokenA)), Currency.wrap(address(tokenB)))
            : (Currency.wrap(address(tokenB)), Currency.wrap(address(tokenA)));
        key = PoolKey({currency0: currency0, currency1: currency1, fee: 3_000, tickSpacing: 60, hooks: IHooks(hook)});
        poolId = key.toId();
    }

    function check_registrationTracksCurrentProposerRole(address caller, bool enabled) public {
        _assumeExternalCaller(caller);
        controller.setProposer(caller, enabled);

        vm.prank(caller);
        (bool success,) =
            address(hook).call(abi.encodeCall(hook.registerPool, (key, SQRT_PRICE_1_1, 25, 75, address(this))));

        assertEq(success, enabled);
        IStaticsLaunchLiquidityHook.PoolRegistration memory registration = hook.poolRegistration(poolId);
        assertEq(registration.registered, enabled);
        if (enabled) {
            assertEq(registration.expectedSqrtPriceX96, SQRT_PRICE_1_1);
            assertEq(registration.inputFeeBps, 25);
            assertEq(registration.outputFeeBps, 75);
            assertEq(registration.launchOperator, address(this));
        }
    }

    function check_ownerCanRegisterDirectly() public {
        vm.prank(address(controller));
        PoolId returned = hook.registerPool(key, SQRT_PRICE_1_1, 25, 75, address(this));

        assertEq(PoolId.unwrap(returned), PoolId.unwrap(poolId));
        assertTrue(hook.poolRegistration(poolId).registered);
    }

    function check_revokedProposerCannotRegister(address caller) public {
        _assumeExternalCaller(caller);
        controller.setProposer(caller, true);
        controller.setProposer(caller, false);

        vm.prank(caller);
        (bool success,) =
            address(hook).call(abi.encodeCall(hook.registerPool, (key, SQRT_PRICE_1_1, 25, 75, address(this))));

        assertFalse(success);
        assertFalse(hook.poolRegistration(poolId).registered);
    }

    function check_proposerCannotChangeOwnerOnlyConfiguration(address caller, uint16 inputFeeBps, uint16 outputFeeBps)
        public
    {
        _assumeExternalCaller(caller);
        controller.setProposer(caller, true);
        vm.prank(address(controller));
        hook.registerPool(key, SQRT_PRICE_1_1, 25, 75, address(this));
        IStaticsLaunchLiquidityHook.PoolRegistration memory registrationBefore = hook.poolRegistration(poolId);
        address receiverBefore = hook.feeReceiver();

        vm.startPrank(caller);
        (bool feesSucceeded,) =
            address(hook).call(abi.encodeCall(hook.setHookFees, (poolId, inputFeeBps, outputFeeBps)));
        (bool receiverSucceeded,) = address(hook).call(abi.encodeCall(hook.setFeeReceiver, (address(0xCAFE))));
        vm.stopPrank();

        assertFalse(feesSucceeded);
        assertFalse(receiverSucceeded);
        assertEq(keccak256(abi.encode(hook.poolRegistration(poolId))), keccak256(abi.encode(registrationBefore)));
        assertEq(hook.feeReceiver(), receiverBefore);
    }

    function _assumeExternalCaller(address caller) private view {
        vm.assume(caller != address(0));
        vm.assume(caller != address(controller));
        vm.assume(caller != address(manager));
        vm.assume(caller != address(positionManager));
        vm.assume(caller != address(hook));
        vm.assume(caller != address(this));
    }
}
