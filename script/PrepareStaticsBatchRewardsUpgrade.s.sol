// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Script} from "forge-std/Script.sol";
import {IERC173} from "../src/interfaces/IERC173.sol";
import {IDiamondCut} from "../src/interfaces/IDiamondCut.sol";
import {IDiamondLoupe} from "../src/interfaces/IDiamondLoupe.sol";
import {IStaticsBatchRewards} from "../src/interfaces/IStaticsBatchRewards.sol";
import {IStaticsGlobalRewards} from "../src/interfaces/IStaticsGlobalRewards.sol";
import {IStaticsRangeGauge} from "../src/interfaces/IStaticsRangeGauge.sol";
import {IStaticsGaugeIncentives} from "../src/interfaces/IStaticsGaugeIncentives.sol";
import {BatchRewardsFacet} from "../src/facets/BatchRewardsFacet.sol";
import {StaticsInterfaceInit} from "../src/diamond/StaticsInterfaceInit.sol";
import {StaticsTimelock} from "../src/governance/StaticsTimelock.sol";
import {StaticsSelectors} from "../src/libraries/StaticsSelectors.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

/// @notice Read-only preparation; does not broadcast or deploy contracts.
contract PrepareStaticsBatchRewardsUpgrade is Script {
    error InvalidBatchFacet(address facet);
    error RequiredClaimRouteMissing(bytes4 selector);
    error BatchSelectorAlreadyInstalled(bytes4 selector);
    error InvalidTimelock(address owner);

    function run() external view returns (address[] memory targets, uint256[] memory values, bytes[] memory payloads) {
        return buildBatch(vm.envAddress("STATICS_DIAMOND"), vm.envAddress("STATICS_BATCH_REWARDS_FACET"));
    }

    function buildBatch(address diamond, address facet)
        public
        view
        returns (address[] memory targets, uint256[] memory values, bytes[] memory payloads)
    {
        if (facet.codehash != keccak256(type(BatchRewardsFacet).runtimeCode)) revert InvalidBatchFacet(facet);
        IDiamondLoupe loupe = IDiamondLoupe(diamond);
        _requireRoute(loupe, IStaticsGlobalRewards.claimRewards.selector);
        _requireRoute(loupe, IStaticsRangeGauge.claimLpRewards.selector);
        _requireRoute(loupe, IStaticsGaugeIncentives.claimGaugeAllocatorRewards.selector);
        _requireRoute(loupe, IDiamondCut.diamondCut.selector);
        _requireRoute(loupe, StaticsInterfaceInit.setInterfaces.selector);
        bytes4[] memory selectors = StaticsSelectors.batchRewards();
        for (uint256 i; i < selectors.length; ++i) {
            if (loupe.facetAddress(selectors[i]) != address(0)) revert BatchSelectorAlreadyInstalled(selectors[i]);
        }
        IDiamondCut.FacetCut[] memory cut = new IDiamondCut.FacetCut[](1);
        cut[0] = IDiamondCut.FacetCut(facet, IDiamondCut.FacetCutAction.Add, selectors);
        bytes4[] memory interfaces = new bytes4[](1);
        interfaces[0] = type(IStaticsBatchRewards).interfaceId;
        bool[] memory supported = new bool[](1);
        supported[0] = true;
        targets = new address[](2);
        targets[0] = diamond;
        targets[1] = diamond;
        values = new uint256[](2);
        payloads = new bytes[](2);
        payloads[0] = abi.encodeCall(IDiamondCut.diamondCut, (cut, address(0), bytes("")));
        payloads[1] = abi.encodeCall(StaticsInterfaceInit.setInterfaces, (interfaces, supported));
    }

    function buildTimelockCalldata(address diamond, address facet, bytes32 salt)
        external
        view
        returns (address timelock, bytes32 operationId, bytes memory scheduleCall, bytes memory executeCall)
    {
        (address[] memory targets, uint256[] memory values, bytes[] memory payloads) = buildBatch(diamond, facet);
        timelock = IERC173(diamond).owner();
        if (timelock.codehash != keccak256(type(StaticsTimelock).runtimeCode)) revert InvalidTimelock(timelock);
        TimelockController controller = TimelockController(payable(timelock));
        operationId = controller.hashOperationBatch(targets, values, payloads, bytes32(0), salt);
        scheduleCall = abi.encodeCall(
            TimelockController.scheduleBatch, (targets, values, payloads, bytes32(0), salt, controller.getMinDelay())
        );
        executeCall = abi.encodeCall(TimelockController.executeBatch, (targets, values, payloads, bytes32(0), salt));
    }

    function _requireRoute(IDiamondLoupe loupe, bytes4 selector) private view {
        if (loupe.facetAddress(selector).code.length == 0) revert RequiredClaimRouteMissing(selector);
    }
}
