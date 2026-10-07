// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;
import {PrepareStaticsBatchRewardsUpgrade} from "./PrepareStaticsBatchRewardsUpgrade.s.sol";

/// @notice Read-only preparation for atomic replacement of a populated #115 diamond.
contract PrepareStaticsAggregatedRewardsUpgrade is PrepareStaticsBatchRewardsUpgrade {
    function run()
        external
        view
        override
        returns (address[] memory targets, uint256[] memory values, bytes[] memory payloads)
    {
        return buildAggregatedBatch(
            vm.envAddress("STATICS_DIAMOND"),
            vm.envAddress("STATICS_BATCH_REWARDS_FACET"),
            vm.envAddress("STATICS_GLOBAL_REWARDS_FACET"),
            vm.envAddress("STATICS_RANGE_GAUGE_LIVENESS_FACET"),
            vm.envAddress("STATICS_GAUGE_INCENTIVE_FACET")
        );
    }

    function buildAggregatedBatch(address diamond, address batch, address global, address lp, address allocator)
        public
        view
        returns (address[] memory targets, uint256[] memory values, bytes[] memory payloads)
    {
        return _build(diamond, batch, global, lp, allocator, true);
    }

    function buildAggregatedTimelockCalldata(
        address diamond,
        address batch,
        address global,
        address lp,
        address allocator,
        bytes32 salt
    )
        external
        view
        returns (address timelock, bytes32 operationId, bytes memory scheduleCall, bytes memory executeCall)
    {
        (address[] memory targets, uint256[] memory values, bytes[] memory payloads) =
            buildAggregatedBatch(diamond, batch, global, lp, allocator);
        return _timelock(diamond, targets, values, payloads, salt);
    }
}
