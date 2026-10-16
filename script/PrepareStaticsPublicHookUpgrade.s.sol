// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Script} from "forge-std/Script.sol";
import {IDiamondCut} from "../src/interfaces/IDiamondCut.sol";
import {IDiamondLoupe} from "../src/interfaces/IDiamondLoupe.sol";
import {IERC173} from "../src/interfaces/IERC173.sol";
import {StaticsPublicHookReleaseInit} from "../src/diamond/StaticsPublicHookReleaseInit.sol";
import {StaticsPublicHookUpgradeGuard} from "../src/diamond/StaticsPublicHookUpgradeGuard.sol";
import {StaticsProtocolPlan, StaticsProtocolParts} from "./libraries/StaticsProtocolPlan.sol";

/// @notice Read-only payload construction. Does not deploy, broadcast, or assume a timelock owner.
contract PrepareStaticsPublicHookUpgrade is Script {
    error InvalidUpgradeContract(address target);
    error UnknownInstalledSelector(bytes4 selector);
    error EmptyReleaseFacet();
    error UnreviewedSnapshot();

    struct Configuration {
        address diamond;
        address guard;
        bytes32 expectedSnapshot;
        address initializer;
        address generalHook;
        address basketHook;
        address basketTokenFactory;
        address liquidityManager;
        uint256 basketFee;
        uint256 flashFeeBps;
    }

    /// @notice Safe Transaction Builder import; both calls must execute in one atomic Safe batch.
    function buildSafeJson(Configuration memory config, StaticsProtocolParts memory parts)
        external
        view
        returns (string memory)
    {
        (address[] memory targets,, bytes[] memory payloads) = this.build(config, parts);
        return string.concat(
            '{"version":"1.0","chainId":"',
            vm.toString(block.chainid),
            '","createdAt":',
            vm.toString(block.timestamp * 1000),
            ',"meta":{"name":"Statics immutable public hooks","createdFromSafeAddress":"',
            vm.toString(IERC173(config.diamond).owner()),
            '"},"transactions":[',
            _transactionJson(targets[0], payloads[0]),
            ",",
            _transactionJson(targets[1], payloads[1]),
            "]}"
        );
    }

    function _transactionJson(address target, bytes memory payload) private pure returns (string memory) {
        return string.concat(
            '{"to":"',
            vm.toString(target),
            '","value":"0","data":"',
            vm.toString(payload),
            '","contractMethod":null,"contractInputsValues":null}'
        );
    }

    function build(Configuration memory config, StaticsProtocolParts memory parts)
        external
        view
        returns (address[] memory targets, uint256[] memory values, bytes[] memory payloads)
    {
        if (config.expectedSnapshot == bytes32(0)) revert UnreviewedSnapshot();
        if (config.guard.codehash != keccak256(type(StaticsPublicHookUpgradeGuard).runtimeCode)) {
            revert InvalidUpgradeContract(config.guard);
        }
        if (config.initializer.codehash != keccak256(type(StaticsPublicHookReleaseInit).runtimeCode)) {
            revert InvalidUpgradeContract(config.initializer);
        }
        StaticsPublicHookUpgradeGuard(config.guard).assertSnapshot(config.diamond, config.expectedSnapshot);
        IDiamondCut.FacetCut[] memory desired = StaticsProtocolPlan.cumulative(parts, 2);
        _enforceRetainedSelectors(config.diamond, desired);
        IDiamondCut.FacetCut[] memory cut = _replacementCut(config.diamond, desired);
        targets = new address[](2);
        values = new uint256[](2);
        payloads = new bytes[](2);
        targets[0] = config.guard;
        payloads[0] =
            abi.encodeCall(StaticsPublicHookUpgradeGuard.assertSnapshot, (config.diamond, config.expectedSnapshot));
        targets[1] = config.diamond;
        payloads[1] = abi.encodeCall(
            IDiamondCut.diamondCut,
            (
                cut,
                config.initializer,
                abi.encodeCall(
                    StaticsPublicHookReleaseInit.initialize,
                    (
                        config.generalHook,
                        config.basketHook,
                        config.basketTokenFactory,
                        config.liquidityManager,
                        config.basketFee,
                        config.flashFeeBps
                    )
                )
            )
        );
    }

    function _enforceRetainedSelectors(address diamond, IDiamondCut.FacetCut[] memory desired) private view {
        IDiamondLoupe.Facet[] memory installed = IDiamondLoupe(diamond).facets();
        for (uint256 i; i < installed.length; ++i) {
            for (uint256 j; j < installed[i].functionSelectors.length; ++j) {
                bytes4 selector = installed[i].functionSelectors[j];
                bool found;
                for (uint256 k; k < desired.length && !found; ++k) {
                    for (uint256 l; l < desired[k].functionSelectors.length; ++l) {
                        if (desired[k].functionSelectors[l] == selector) {
                            found = true;
                            break;
                        }
                    }
                }
                if (!found) revert UnknownInstalledSelector(selector);
            }
        }
    }

    function _replacementCut(address diamond, IDiamondCut.FacetCut[] memory desired)
        private
        view
        returns (IDiamondCut.FacetCut[] memory cut)
    {
        cut = new IDiamondCut.FacetCut[](desired.length * 2);
        uint256 count;
        for (uint256 i; i < desired.length; ++i) {
            address facet = desired[i].facetAddress;
            if (facet.code.length == 0) revert EmptyReleaseFacet();
            bytes4[] memory added = new bytes4[](desired[i].functionSelectors.length);
            bytes4[] memory replaced = new bytes4[](added.length);
            uint256 a;
            uint256 r;
            for (uint256 j; j < added.length; ++j) {
                bytes4 selector = desired[i].functionSelectors[j];
                address current = IDiamondLoupe(diamond).facetAddress(selector);
                if (current == address(0)) added[a++] = selector;
                else if (current != facet) replaced[r++] = selector;
            }
            assembly ("memory-safe") {
                mstore(added, a)
                mstore(replaced, r)
            }
            if (a != 0) cut[count++] = IDiamondCut.FacetCut(facet, IDiamondCut.FacetCutAction.Add, added);
            if (r != 0) cut[count++] = IDiamondCut.FacetCut(facet, IDiamondCut.FacetCutAction.Replace, replaced);
        }
        assembly ("memory-safe") { mstore(cut, count) }
    }
}
