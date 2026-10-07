// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IStaticsAggregatedBatchRewards} from "../src/interfaces/IStaticsAggregatedBatchRewards.sol";
import {GlobalRewardsFacet} from "../src/facets/GlobalRewardsFacet.sol";
import {RangeGaugeLivenessFacet} from "../src/facets/RangeGaugeLivenessFacet.sol";
import {GaugeIncentiveFacet} from "../src/facets/GaugeIncentiveFacet.sol";
import {Script} from "forge-std/Script.sol";
import {IERC173} from "../src/interfaces/IERC173.sol";
import {IDiamondCut} from "../src/interfaces/IDiamondCut.sol";
import {IDiamondLoupe} from "../src/interfaces/IDiamondLoupe.sol";
import {IStaticsBatchRewards} from "../src/interfaces/IStaticsBatchRewards.sol";
import {IStaticsGlobalRewards} from "../src/interfaces/IStaticsGlobalRewards.sol";
import {IStaticsRangeGauge} from "../src/interfaces/IStaticsRangeGauge.sol";
import {IStaticsGaugeIncentives} from "../src/interfaces/IStaticsGaugeIncentives.sol";
import {BatchRewardsFacet} from "../src/facets/BatchRewardsFacet.sol";
import {DiamondCutFacet} from "../src/facets/DiamondCutFacet.sol";
import {StaticsInterfaceInit} from "../src/diamond/StaticsInterfaceInit.sol";
import {StaticsTimelock} from "../src/governance/StaticsTimelock.sol";
import {StaticsSelectors} from "../src/libraries/StaticsSelectors.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

/// @notice Read-only preparation; does not broadcast or deploy contracts.
contract PrepareStaticsBatchRewardsUpgrade is Script {
    error InvalidBatchFacet(address facet);
    error InvalidClaimFacet(address facet);
    error UnexpectedSelectorOwner(bytes4 selector, address expected, address actual);
    error ExistingBatchRequired();
    error InvalidUpgradeRoute(bytes4 selector, address facet);
    error RequiredClaimRouteMissing(bytes4 selector);
    error BatchSelectorAlreadyInstalled(bytes4 selector);
    error InvalidTimelock(address owner);

    function run()
        external
        view
        virtual
        returns (address[] memory targets, uint256[] memory values, bytes[] memory payloads)
    {
        return buildBatch(
            vm.envAddress("STATICS_DIAMOND"),
            vm.envAddress("STATICS_BATCH_REWARDS_FACET"),
            vm.envAddress("STATICS_GLOBAL_REWARDS_FACET"),
            vm.envAddress("STATICS_RANGE_GAUGE_LIVENESS_FACET"),
            vm.envAddress("STATICS_GAUGE_INCENTIVE_FACET")
        );
    }

    function buildBatch(address diamond, address facet)
        public
        view
        returns (address[] memory targets, uint256[] memory values, bytes[] memory payloads)
    {
        IDiamondLoupe loupe = IDiamondLoupe(diamond);
        return _build(
            diamond,
            facet,
            loupe.facetAddress(IStaticsGlobalRewards.claimRewards.selector),
            loupe.facetAddress(IStaticsRangeGauge.claimLpRewards.selector),
            loupe.facetAddress(IStaticsGaugeIncentives.claimGaugeAllocatorRewards.selector),
            false
        );
    }

    function buildBatch(address diamond, address facet, address global, address lp, address allocator)
        public
        view
        returns (address[] memory targets, uint256[] memory values, bytes[] memory payloads)
    {
        return _build(diamond, facet, global, lp, allocator, false);
    }

    function _build(address diamond, address facet, address global, address lp, address allocator, bool existing)
        internal
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
        _requireUpgradeRoute(loupe, IDiamondCut.diamondCut.selector, keccak256(type(DiamondCutFacet).runtimeCode));
        _requireUpgradeRoute(
            loupe, StaticsInterfaceInit.setInterfaces.selector, keccak256(type(StaticsInterfaceInit).runtimeCode)
        );
        if (global.codehash != keccak256(type(GlobalRewardsFacet).runtimeCode)) revert InvalidClaimFacet(global);
        if (lp.codehash != keccak256(type(RangeGaugeLivenessFacet).runtimeCode)) revert InvalidClaimFacet(lp);
        if (allocator.codehash != keccak256(type(GaugeIncentiveFacet).runtimeCode)) {
            revert InvalidClaimFacet(allocator);
        }
        IDiamondCut.FacetCut[] memory cut = _cut(loupe, facet, global, lp, allocator, existing);
        _requireTimelock(diamond);
        targets = new address[](1);
        targets[0] = diamond;
        values = new uint256[](1);
        payloads = new bytes[](1);
        payloads[0] = abi.encodeCall(
            IDiamondCut.diamondCut,
            (cut, loupe.facetAddress(StaticsInterfaceInit.setInterfaces.selector), _interfaceData())
        );
    }

    function _cut(IDiamondLoupe loupe, address facet, address global, address lp, address allocator, bool existing)
        private
        view
        returns (IDiamondCut.FacetCut[] memory cut)
    {
        bytes4[] memory selectors = StaticsSelectors.batchRewards();
        address installed = loupe.facetAddress(selectors[0]);
        if (existing) {
            if (installed.code.length == 0) revert ExistingBatchRequired();
            if (loupe.facetAddress(selectors[1]) != installed) {
                revert UnexpectedSelectorOwner(selectors[1], installed, loupe.facetAddress(selectors[1]));
            }
            if (loupe.facetAddress(selectors[2]) != address(0)) revert BatchSelectorAlreadyInstalled(selectors[2]);
        } else {
            for (uint256 i; i < selectors.length; ++i) {
                if (loupe.facetAddress(selectors[i]) != address(0)) revert BatchSelectorAlreadyInstalled(selectors[i]);
            }
        }
        cut = new IDiamondCut.FacetCut[](5);
        uint256 count = 0;
        count = _replacement(loupe, cut, count, global, StaticsSelectors.globalRewards());
        count = _replacement(loupe, cut, count, lp, StaticsSelectors.rangeGaugeLiveness());
        count = _replacement(loupe, cut, count, allocator, StaticsSelectors.gaugeIncentiveActions());
        if (existing) {
            bytes4[] memory prior = new bytes4[](2);
            prior[0] = selectors[0];
            prior[1] = selectors[1];
            if (installed != facet) {
                cut[count++] = IDiamondCut.FacetCut(facet, IDiamondCut.FacetCutAction.Replace, prior);
            }
            bytes4[] memory added = new bytes4[](1);
            added[0] = selectors[2];
            cut[count++] = IDiamondCut.FacetCut(facet, IDiamondCut.FacetCutAction.Add, added);
        } else {
            cut[count++] = IDiamondCut.FacetCut(facet, IDiamondCut.FacetCutAction.Add, selectors);
        }
        assembly ("memory-safe") { mstore(cut, count) }
    }

    function _interfaceData() private pure returns (bytes memory) {
        bytes4[] memory interfaces = new bytes4[](2);
        interfaces[0] = type(IStaticsBatchRewards).interfaceId;
        interfaces[1] = type(IStaticsAggregatedBatchRewards).interfaceId;
        bool[] memory supported = new bool[](2);
        supported[0] = true;
        supported[1] = true;
        return abi.encodeCall(StaticsInterfaceInit.setInterfaces, (interfaces, supported));
    }

    function _replacement(
        IDiamondLoupe loupe,
        IDiamondCut.FacetCut[] memory cut,
        uint256 count,
        address facet,
        bytes4[] memory selectors
    ) private view returns (uint256) {
        address prior = loupe.facetAddress(selectors[0]);
        if (prior == address(0)) revert RequiredClaimRouteMissing(selectors[0]);
        for (uint256 i; i < selectors.length; ++i) {
            address actual = loupe.facetAddress(selectors[i]);
            if (actual != prior) revert UnexpectedSelectorOwner(selectors[i], prior, actual);
        }
        if (prior != facet) cut[count++] = IDiamondCut.FacetCut(facet, IDiamondCut.FacetCutAction.Replace, selectors);
        return count;
    }

    function buildTimelockCalldata(address diamond, address facet, bytes32 salt)
        external
        view
        returns (address timelock, bytes32 operationId, bytes memory scheduleCall, bytes memory executeCall)
    {
        (address[] memory targets, uint256[] memory values, bytes[] memory payloads) = buildBatch(diamond, facet);
        return _timelock(diamond, targets, values, payloads, salt);
    }

    function buildTimelockCalldata(
        address diamond,
        address facet,
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
            buildBatch(diamond, facet, global, lp, allocator);
        return _timelock(diamond, targets, values, payloads, salt);
    }

    function _timelock(
        address diamond,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory payloads,
        bytes32 salt
    )
        internal
        view
        returns (address timelock, bytes32 operationId, bytes memory scheduleCall, bytes memory executeCall)
    {
        timelock = _requireTimelock(diamond);
        TimelockController controller = TimelockController(payable(timelock));
        operationId = controller.hashOperationBatch(targets, values, payloads, bytes32(0), salt);
        scheduleCall = abi.encodeCall(
            TimelockController.scheduleBatch, (targets, values, payloads, bytes32(0), salt, controller.getMinDelay())
        );
        executeCall = abi.encodeCall(TimelockController.executeBatch, (targets, values, payloads, bytes32(0), salt));
    }

    function _requireUpgradeRoute(IDiamondLoupe loupe, bytes4 selector, bytes32 expectedHash) private view {
        address facet = loupe.facetAddress(selector);
        if (facet.codehash != expectedHash) revert InvalidUpgradeRoute(selector, facet);
    }

    function _requireTimelock(address diamond) private view returns (address timelock) {
        timelock = IERC173(diamond).owner();
        if (timelock.codehash != keccak256(type(StaticsTimelock).runtimeCode)) revert InvalidTimelock(timelock);
    }

    function _requireRoute(IDiamondLoupe loupe, bytes4 selector) private view {
        if (loupe.facetAddress(selector).code.length == 0) revert RequiredClaimRouteMissing(selector);
    }
}
