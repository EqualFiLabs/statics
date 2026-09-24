// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {RangeGaugeCallbackHarness, RangeGaugeHookCaller} from "../helpers/RangeGaugeCallbackHarness.sol";

contract RangeGaugeGasTest is Test {
    uint256 private constant REVIEWED_HOOK_BASELINE = 24_228;
    uint256 private constant EIP170_RUNTIME_LIMIT = 24_576;
    uint256 private constant MIN_HOOK_HEADROOM = 256;
    uint256 private constant MAX_VALIDATION_CALLBACK_GAS = 45_000;

    /// @dev Excluded from optimizer-disabled coverage because instrumentation changes runtime size.
    function test_PublicHookRetainsEip170Headroom() public {
        uint256 runtimeSize = vm.getDeployedCode("src/liquidity/StaticsSwapFeeHook.sol:StaticsSwapFeeHook").length;
        emit log_named_uint("reviewed public hook baseline bytes", REVIEWED_HOOK_BASELINE);
        emit log_named_uint("callback-enabled public hook bytes", runtimeSize);
        emit log_named_uint("public hook EIP-170 headroom", EIP170_RUNTIME_LIMIT - runtimeSize);
        assertLe(runtimeSize, EIP170_RUNTIME_LIMIT - MIN_HOOK_HEADROOM);
    }

    function testNoBoundaryCallbackGas() public {
        RangeGaugeCallbackHarness callback = new RangeGaugeCallbackHarness();
        RangeGaugeHookCaller hook = new RangeGaugeHookCaller();
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0x1000)),
            currency1: Currency.wrap(address(0x2000)),
            fee: 3_000,
            tickSpacing: 10,
            hooks: IHooks(address(hook))
        });
        PoolId poolId = callback.registerGeneralPool(key, makeAddr("creator"));
        callback.installPublicIntegration(makeAddr("poolManager"), address(hook));

        uint256 gasBefore = gasleft();
        hook.notify(address(callback), poolId);
        uint256 gasUsed = gasBefore - gasleft();

        emit log_named_uint("registered no-boundary callback gas", gasUsed);
        assertLe(gasUsed, MAX_VALIDATION_CALLBACK_GAS);
    }
}
