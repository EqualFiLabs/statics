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
    uint256 private constant MAX_128_FOUR_STREAM_CALLBACK_GAS = 15_000_000;

    event CallbackPathGas(bytes32 indexed scenario, uint256 gasUsed);
    event BoundaryTraversalGas(
        uint256 indexed boundaryCount, bool indexed rightward, uint8 historyStreams, int24 tickSpacing, uint256 gasUsed
    );

    struct GasScenario {
        RangeGaugeCallbackHarness callback;
        RangeGaugeHookCaller hook;
        RangeGaugePoolManagerMock poolManager;
        PoolId poolId;
    }

    /// @dev Excluded from optimizer-disabled coverage because instrumentation changes runtime size.
    function test_PublicHookRetainsEip170Headroom() public {
        uint256 runtimeSize = vm.getDeployedCode("src/liquidity/StaticsSwapFeeHook.sol:StaticsSwapFeeHook").length;
        emit log_named_uint("reviewed public hook baseline bytes", REVIEWED_HOOK_BASELINE);
        emit log_named_uint("callback-enabled public hook bytes", runtimeSize);
        emit log_named_uint("public hook EIP-170 headroom", EIP170_RUNTIME_LIMIT - runtimeSize);
        assertLe(runtimeSize, EIP170_RUNTIME_LIMIT - MIN_HOOK_HEADROOM);
    }

    function testNoMovementAndNoBoundaryMovementGas() public {
        uint256 noMovementGas = _measureNoBoundary(0);
        uint256 noBoundaryMovementGas = _measureNoBoundary(1);

        emit log_named_uint("no-movement callback gas", noMovementGas);
        emit log_named_uint("movement-without-boundary callback gas", noBoundaryMovementGas);
        emit CallbackPathGas(keccak256("no movement"), noMovementGas);
        emit CallbackPathGas(keccak256("movement without boundary"), noBoundaryMovementGas);
        assertLe(noMovementGas, MAX_NO_BOUNDARY_CALLBACK_GAS);
        assertLe(noBoundaryMovementGas, MAX_NO_BOUNDARY_CALLBACK_GAS);
    }

    function testBoundaryTraversalGasMatrixInBothDirections() public {
        uint256[5] memory counts = [uint256(1), 4, 16, 64, 128];
        uint256[5] memory rightward;
        uint256[5] memory leftward;
        for (uint256 i; i < counts.length; ++i) {
            rightward[i] = _measureBoundaryTraversal(counts[i], true, 0, 10);
            leftward[i] = _measureBoundaryTraversal(counts[i], false, 0, 10);
            if (i != 0) {
                assertLt(rightward[i - 1], rightward[i]);
                assertLt(leftward[i - 1], leftward[i]);
            }
        }
        emit log_named_uint("1 rightward crossing", rightward[0]);
        emit log_named_uint("1 leftward crossing", leftward[0]);
        emit log_named_uint("4 rightward crossings", rightward[1]);
        emit log_named_uint("4 leftward crossings", leftward[1]);
        emit log_named_uint("16 rightward crossings", rightward[2]);
        emit log_named_uint("16 leftward crossings", leftward[2]);
        emit log_named_uint("64 rightward crossings", rightward[3]);
        emit log_named_uint("64 leftward crossings", leftward[3]);
        emit log_named_uint("128 rightward crossings", rightward[4]);
        emit log_named_uint("128 leftward crossings", leftward[4]);
        assertLe(rightward[4], MAX_128_BOUNDARY_CALLBACK_GAS);
        assertLe(leftward[4], MAX_128_BOUNDARY_CALLBACK_GAS);
    }

    function testRewardHistoryGasForOneAndFourStreams() public {
        uint256 oneRight = _measureBoundaryTraversal(16, true, 1, 10);
        uint256 fourRight = _measureBoundaryTraversal(16, true, 4, 10);
        uint256 oneLeft = _measureBoundaryTraversal(16, false, 1, 10);
        uint256 fourLeft = _measureBoundaryTraversal(16, false, 4, 10);
        uint256 worstCase = _measureBoundaryTraversal(128, true, 4, 10);

        emit log_named_uint("16 rightward crossings with one stream", oneRight);
        emit log_named_uint("16 rightward crossings with four streams", fourRight);
        emit log_named_uint("16 leftward crossings with one stream", oneLeft);
        emit log_named_uint("16 leftward crossings with four streams", fourLeft);
        emit log_named_uint("128 rightward crossings with four streams", worstCase);
        assertLt(oneRight, fourRight);
        assertLt(oneLeft, fourLeft);
        assertLe(worstCase, MAX_128_FOUR_STREAM_CALLBACK_GAS);
    }

    function testSparseMovementAndMinimumTickSpacingGas() public {
        uint256 sparseRight = _measureSparseTraversal(true);
        uint256 sparseLeft = _measureSparseTraversal(false);
        uint256 spacingOneRight = _measureBoundaryTraversal(128, true, 0, 1);
        uint256 spacingOneLeft = _measureBoundaryTraversal(128, false, 0, 1);

        emit CallbackPathGas(keccak256("large sparse rightward movement"), sparseRight);
        emit CallbackPathGas(keccak256("large sparse leftward movement"), sparseLeft);
        emit log_named_uint("large sparse rightward movement", sparseRight);
        emit log_named_uint("large sparse leftward movement", sparseLeft);
        emit log_named_uint("128 rightward crossings at spacing 1", spacingOneRight);
        emit log_named_uint("128 leftward crossings at spacing 1", spacingOneLeft);
        assertLe(sparseRight, MAX_NO_BOUNDARY_CALLBACK_GAS);
        assertLe(sparseLeft, MAX_NO_BOUNDARY_CALLBACK_GAS);
        assertLe(spacingOneRight, MAX_128_BOUNDARY_CALLBACK_GAS);
        assertLe(spacingOneLeft, MAX_128_BOUNDARY_CALLBACK_GAS);
    }

    function _ready(int256 referenceTick, int256 tickSpacing) private returns (GasScenario memory scenario) {
        scenario.callback = new RangeGaugeCallbackHarness();
        scenario.hook = new RangeGaugeHookCaller();
        scenario.poolManager = new RangeGaugePoolManagerMock();
        MockERC20 statics = new MockERC20("Statics", "STATICS", 18);
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0x1000)),
            currency1: Currency.wrap(address(0x2000)),
            fee: 3_000,
            tickSpacing: int24(tickSpacing),
            hooks: IHooks(address(scenario.hook))
        });
        scenario.poolId = scenario.callback.registerGeneralPool(key, makeAddr("creator"));
        scenario.callback.initialize(address(statics));
        scenario.callback.initializeGauge(scenario.poolId, referenceTick);
        scenario.callback.installPublicIntegration(address(scenario.poolManager), address(scenario.hook));
    }

    function _measureNoBoundary(int256 finalTick) private returns (uint256 gasUsed) {
        GasScenario memory scenario = _ready(0, 10);
        scenario.poolManager.setTick(scenario.poolId, finalTick);

        uint256 gasBefore = gasleft();
        scenario.hook.notify(address(scenario.callback), scenario.poolId);
        gasUsed = gasBefore - gasleft();

        (,, int24 referenceTick, uint128 activeLiquidity) = scenario.callback.gaugeState(scenario.poolId);
        assertEq(referenceTick, 0);
        assertEq(activeLiquidity, 0);
    }

    function _measureBoundaryTraversal(
        uint256 boundaryCount,
        bool rightward,
        uint256 historyStreams,
        int256 tickSpacing
    ) private returns (uint256 gasUsed) {
        GasScenario memory scenario = _ready(0, tickSpacing);
        for (uint256 i; i < boundaryCount; ++i) {
            if (rightward) {
                scenario.callback
                    .addRange(scenario.poolId, -tickSpacing, int256((i + 1) * uint256(tickSpacing)), tickSpacing, 0, 1);
            } else {
                scenario.callback
                    .addRange(scenario.poolId, -int256((i + 1) * uint256(tickSpacing)), tickSpacing, tickSpacing, 0, 1);
            }
        }
        scenario.callback.setActiveLiquidity(scenario.poolId, boundaryCount);
        _addRewardHistory(scenario, historyStreams);

        int256 distance = int256(boundaryCount * uint256(tickSpacing));
        int256 finalTick = rightward ? distance : -distance - 1;
        scenario.poolManager.setTick(scenario.poolId, finalTick);

        uint256 gasBefore = gasleft();
        scenario.hook.notify(address(scenario.callback), scenario.poolId);
        gasUsed = gasBefore - gasleft();

        (,, int24 referenceTick, uint128 activeLiquidity) = scenario.callback.gaugeState(scenario.poolId);
        assertEq(referenceTick, finalTick);
        assertEq(activeLiquidity, 0);
        emit BoundaryTraversalGas(boundaryCount, rightward, uint8(historyStreams), int24(tickSpacing), gasUsed);
    }

    function _measureSparseTraversal(bool rightward) private returns (uint256 gasUsed) {
        GasScenario memory scenario = _ready(0, 10);
        scenario.callback.addRange(scenario.poolId, -800_000, 800_000, 10, 0, 1);
        scenario.callback.setActiveLiquidity(scenario.poolId, 1);
        int256 finalTick = rightward ? int256(800_000) : int256(-800_001);
        scenario.poolManager.setTick(scenario.poolId, finalTick);

        uint256 gasBefore = gasleft();
        scenario.hook.notify(address(scenario.callback), scenario.poolId);
        gasUsed = gasBefore - gasleft();

        (,, int24 referenceTick, uint128 activeLiquidity) = scenario.callback.gaugeState(scenario.poolId);
        assertEq(referenceTick, finalTick);
        assertEq(activeLiquidity, 0);
    }

    function _addRewardHistory(GasScenario memory scenario, uint256 historyStreams) private {
        if (historyStreams == 0) return;
        for (uint256 slot = 1; slot < historyStreams; ++slot) {
            scenario.callback.appendRewardAsset(scenario.poolId, address(uint160(0x3000 + slot)));
        }
        uint256 start = block.timestamp + 1;
        vm.warp(start);
        for (uint256 slot; slot < historyStreams; ++slot) {
            scenario.callback.fundStream(scenario.poolId, slot, 700 ether + slot, start, 7 days);
        }
        vm.warp(start + 1 days);
    }
}
