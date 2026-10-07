// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;
import {IStaticsAggregatedBatchRewards} from "../../src/interfaces/IStaticsAggregatedBatchRewards.sol";
import {Test} from "forge-std/Test.sol";
import {IStaticsBatchRewards} from "../../src/interfaces/IStaticsBatchRewards.sol";

contract BatchRewardsAbiTest is Test {
    function testSolidityFixture() public {
        IStaticsBatchRewards.GlobalClaim[] memory g = new IStaticsBatchRewards.GlobalClaim[](1);
        address[] memory assets = new address[](2);
        assets[0] = address(0x111);
        assets[1] = address(0x222);
        uint256[] memory minimums = new uint256[](2);
        minimums[0] = 10;
        minimums[1] = 20;
        g[0] = IStaticsBatchRewards.GlobalClaim(30, assets, minimums);
        IStaticsBatchRewards.PoolClaim[] memory l = new IStaticsBatchRewards.PoolClaim[](1);
        IStaticsBatchRewards.PoolClaim[] memory a = new IStaticsBatchRewards.PoolClaim[](1);
        uint8[] memory slots = new uint8[](2);
        slots[0] = 0;
        slots[1] = 1;
        l[0] = IStaticsBatchRewards.PoolClaim(30, bytes32(uint256(1)), slots, minimums);
        slots = new uint8[](2);
        slots[0] = 1;
        slots[1] = 4;
        a[0] = IStaticsBatchRewards.PoolClaim(31, bytes32(uint256(2)), slots, minimums);
        bytes memory callData = abi.encodeCall(IStaticsBatchRewards.batchClaimRewards, (g, l, a, address(0x333)));
        uint256[][] memory gr = new uint256[][](1);
        gr[0] = new uint256[](2);
        gr[0][0] = 123;
        gr[0][1] = 456;
        uint256[][] memory lr = new uint256[][](1);
        lr[0] = new uint256[](2);
        lr[0][0] = 789;
        lr[0][1] = 987;
        uint256[][] memory ar = new uint256[][](1);
        ar[0] = new uint256[](2);
        ar[0][0] = 654;
        ar[0][1] = 321;
        bytes memory result = abi.encode(gr, lr, ar);
        assertEq(bytes4(callData), IStaticsBatchRewards.batchClaimRewards.selector);
        if (vm.envOr("WRITE_BATCH_REWARDS_FIXTURE", false)) {
            vm.serializeBytes("batch", "calldata", callData);
            vm.serializeBytes("batch", "result", result);
            vm.serializeBytes("batch", "limitsCalldata", abi.encodeCall(IStaticsBatchRewards.batchClaimLimits, ()));
            string memory json = vm.serializeBytes("batch", "limitsResult", abi.encode(uint256(16), uint256(64)));
            vm.writeJson(json, "artifacts/diamond-manifests/batch-rewards-solidity.json");
        }
        if (vm.envOr("WRITE_AGGREGATED_REWARDS_FIXTURE", false)) {
            vm.serializeBytes(
                "aggregated",
                "calldata",
                abi.encodeCall(IStaticsAggregatedBatchRewards.batchClaimRewardsAggregated, (g, l, a, address(0x333)))
            );
            string memory json = vm.serializeBytes("aggregated", "result", result);
            vm.writeJson(json, "artifacts/diamond-manifests/aggregated-rewards-solidity.json");
        }
    }
}
