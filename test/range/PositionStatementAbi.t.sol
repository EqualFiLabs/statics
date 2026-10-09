// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IStaticsRangeGauge} from "../../src/interfaces/IStaticsRangeGauge.sol";
import {IStaticsGaugeIncentives} from "../../src/interfaces/IStaticsGaugeIncentives.sol";
import {IStaticsGlobalRewards} from "../../src/interfaces/IStaticsGlobalRewards.sol";
import {IStaticsNonSwapRevenue} from "../../src/interfaces/IStaticsNonSwapRevenue.sol";

/// @notice ABI fixture emitter only; real transfer semantics are covered in PositionStatementEvents.
contract PositionStatementAbiTest is Test {
    function testSolidityEventFixtures() public {
        PoolId pool = PoolId.wrap(bytes32(uint256(2)));
        IStaticsRangeGauge.LiquidityStatementMovement memory movement =
            IStaticsRangeGauge.LiquidityStatementMovement(11, 22, address(0x111), address(0x222), 33, 44, 55, 66);
        IStaticsRangeGauge.RebalanceSettlement memory settlement =
            IStaticsRangeGauge.RebalanceSettlement(77, 88, 99, 111, 222, 333);
        PoolId[] memory pools = new PoolId[](2);
        pools[0] = pool;
        pools[1] = PoolId.wrap(bytes32(uint256(3)));
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 5;
        amounts[1] = 7;
        vm.recordLogs();
        emit IStaticsRangeGauge.ManagedLiquidityProvided(1, pool, 3, address(0x333), -10, 20, movement);
        emit IStaticsRangeGauge.ManagedLiquidityChanged(1, pool, 3, movement);
        emit IStaticsRangeGauge.ManagedLiquidityRebalanced(1, pool, 3, 4, address(0x333), -10, 20, movement, settlement);
        emit IStaticsRangeGauge.ManagedLiquidityExited(1, pool, 3, movement);
        emit IStaticsRangeGauge.ManagedLiquidityFeesCollected(1, pool, 3, address(0x222), 5, 6);
        emit IStaticsGaugeIncentives.PositionGaugeAllocationsSet(1, 123, 12, pools, amounts);
        emit IStaticsGlobalRewards.RewardClaimed(1, address(0x222), address(0x444), 100, 90);
        emit IStaticsNonSwapRevenue.NonSwapStakerShareBpsSet(9_000, 6_000);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 8);
        if (!vm.envOr("WRITE_STATEMENT_FIXTURES", false)) return;
        string[8] memory names = [
            "ManagedLiquidityProvided",
            "ManagedLiquidityChanged",
            "ManagedLiquidityRebalanced",
            "ManagedLiquidityExited",
            "ManagedLiquidityFeesCollected",
            "PositionGaugeAllocationsSet",
            "RewardClaimed",
            "NonSwapStakerShareBpsSet"
        ];
        string memory json;
        for (uint256 i; i < logs.length; ++i) {
            vm.serializeBytes32(names[i], "topics", logs[i].topics);
            string memory item = vm.serializeBytes(names[i], "data", logs[i].data);
            json = string.concat(json, i == 0 ? "" : ",", "\"", names[i], "\":", item);
        }
        bytes memory setter = abi.encodeCall(IStaticsNonSwapRevenue.setNonSwapStakerShareBps, (6_000));
        bytes memory getter = abi.encodeCall(IStaticsNonSwapRevenue.nonSwapStakerShareBps, ());
        json = string.concat(
            "{",
            json,
            ",\"shareSetCalldata\":\"",
            vm.toString(setter),
            "\",\"shareGetCalldata\":\"",
            vm.toString(getter),
            "\"}"
        );
        vm.writeJson(json, "artifacts/diamond-manifests/position-statement-solidity.json");
    }
}
