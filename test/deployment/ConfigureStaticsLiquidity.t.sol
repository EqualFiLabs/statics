// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";

import {ConfigureStaticsLiquidity, StaticsLiquidityConfig} from "../../script/ConfigureStaticsLiquidity.s.sol";
import {IStaticsBasketLiquidity} from "../../src/interfaces/IStaticsBasketLiquidity.sol";

contract ConfigureStaticsLiquidityTest is Test {
    function testBatchContainsOnlyTypedDiamondInstallationCalls() public {
        ConfigureStaticsLiquidity ceremony = new ConfigureStaticsLiquidity();
        address diamond = makeAddr("diamond");
        StaticsLiquidityConfig memory config = StaticsLiquidityConfig({
            poolManager: makeAddr("poolManager"),
            positionManager: makeAddr("positionManager"),
            permit2: makeAddr("permit2"),
            hook: makeAddr("hook"),
            manager: makeAddr("manager"),
            hookFeeBps: 1,
            poolManagerCodeHash: bytes32(0),
            positionManagerCodeHash: bytes32(0),
            permit2CodeHash: bytes32(0)
        });

        (address[] memory targets, uint256[] memory values, bytes[] memory payloads) =
            ceremony.buildBatch(diamond, config);

        assertEq(targets.length, 2);
        assertEq(values.length, 2);
        assertEq(payloads.length, 2);
        assertEq(targets[0], diamond);
        assertEq(targets[1], diamond);
        assertEq(values[0], 0);
        assertEq(values[1], 0);
        assertEq(_selector(payloads[0]), IStaticsBasketLiquidity.installCanonicalPoolIntegration.selector);
        assertEq(_selector(payloads[1]), IStaticsBasketLiquidity.installLiquidityManager.selector);
        assertEq(_addressArgument(payloads[0], 0), config.poolManager);
        assertEq(_addressArgument(payloads[0], 1), config.hook);
        assertEq(_addressArgument(payloads[1], 0), config.manager);
    }

    function _selector(bytes memory payload) private pure returns (bytes4 selector) {
        assembly ("memory-safe") {
            selector := mload(add(payload, 0x20))
        }
    }

    function _addressArgument(bytes memory payload, uint256 index) private pure returns (address value) {
        assembly ("memory-safe") {
            value := mload(add(add(payload, 0x24), mul(index, 0x20)))
        }
    }
}
