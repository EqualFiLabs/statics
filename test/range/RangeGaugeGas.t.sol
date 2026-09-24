// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {
    RangeGaugeCallbackHarness,
    RangeGaugeHookCaller,
    RangeGaugePoolManagerMock
} from "../helpers/RangeGaugeCallbackHarness.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

contract RangeGaugeGasTest is Test {
    uint256 private constant REVIEWED_HOOK_BASELINE = 24_228;
    uint256 private constant EIP170_RUNTIME_LIMIT = 24_576;
    uint256 private constant MIN_HOOK_HEADROOM = 256;
    uint256 private constant MAX_NO_BOUNDARY_CALLBACK_GAS = 100_000;
    uint256 private constant MAX_128_BOUNDARY_CALLBACK_GAS = 8_000_000;

    event BoundaryTraversalGas(uint256 indexed boundaryCount, uint256 gasUsed);

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
        RangeGaugePoolManagerMock poolManager = new RangeGaugePoolManagerMock();
        MockERC20 statics = new MockERC20("Statics", "STATICS", 18);
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0x1000)),
            currency1: Currency.wrap(address(0x2000)),
            fee: 3_000,
            tickSpacing: 10,
            hooks: IHooks(address(hook))
        });
        PoolId poolId = callback.registerGeneralPool(key, makeAddr("creator"));
        callback.initialize(address(statics));
        callback.initializeGauge(poolId, 0);
        callback.installPublicIntegration(address(poolManager), address(hook));
        poolManager.setTick(poolId, 1);

        uint256 gasBefore = gasleft();
        hook.notify(address(callback), poolId);
        uint256 gasUsed = gasBefore - gasleft();

        emit log_named_uint("registered no-boundary callback gas", gasUsed);
        assertLe(gasUsed, MAX_NO_BOUNDARY_CALLBACK_GAS);
    }

    function testBoundaryTraversalGasMatrix() public {
        uint256 gas1 = _measureBoundaryTraversal(1);
        uint256 gas4 = _measureBoundaryTraversal(4);
        uint256 gas16 = _measureBoundaryTraversal(16);
        uint256 gas64 = _measureBoundaryTraversal(64);
        uint256 gas128 = _measureBoundaryTraversal(128);

        emit log_named_uint("one-boundary callback gas", gas1);
        emit log_named_uint("four-boundary callback gas", gas4);
        emit log_named_uint("sixteen-boundary callback gas", gas16);
        emit log_named_uint("sixty-four-boundary callback gas", gas64);
        emit log_named_uint("one-hundred-twenty-eight-boundary callback gas", gas128);

        assertLt(gas1, gas4);
        assertLt(gas4, gas16);
        assertLt(gas16, gas64);
        assertLt(gas64, gas128);
        assertLe(gas128, MAX_128_BOUNDARY_CALLBACK_GAS);
    }

    function _measureBoundaryTraversal(uint256 boundaryCount) private returns (uint256 gasUsed) {
        RangeGaugeCallbackHarness callback = new RangeGaugeCallbackHarness();
        RangeGaugeHookCaller hook = new RangeGaugeHookCaller();
        RangeGaugePoolManagerMock poolManager = new RangeGaugePoolManagerMock();
        MockERC20 statics = new MockERC20("Statics", "STATICS", 18);
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0x1000)),
            currency1: Currency.wrap(address(0x2000)),
            fee: 3_000,
            tickSpacing: 10,
            hooks: IHooks(address(hook))
        });
        PoolId poolId = callback.registerGeneralPool(key, makeAddr("creator"));
        callback.initialize(address(statics));
        callback.initializeGauge(poolId, 0);
        callback.installPublicIntegration(address(poolManager), address(hook));
        for (uint256 i; i < boundaryCount; ++i) {
            callback.addRange(poolId, -10, int256((i + 1) * 10), 10, 0, 1);
        }
        callback.setActiveLiquidity(poolId, boundaryCount);
        poolManager.setTick(poolId, int256(boundaryCount * 10));

        uint256 gasBefore = gasleft();
        hook.notify(address(callback), poolId);
        gasUsed = gasBefore - gasleft();

        (,, int24 referenceTick, uint128 activeLiquidity) = callback.gaugeState(poolId);
        assertEq(referenceTick, int256(boundaryCount * 10));
        assertEq(activeLiquidity, 0);
        emit BoundaryTraversalGas(boundaryCount, gasUsed);
    }
}
