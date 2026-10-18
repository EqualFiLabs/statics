// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Script} from "forge-std/Script.sol";
import {IDiamondCut} from "../src/interfaces/IDiamondCut.sol";
import {IDiamondLoupe} from "../src/interfaces/IDiamondLoupe.sol";
import {IERC173} from "../src/interfaces/IERC173.sol";
import {IStaticsBasketAdmin} from "../src/interfaces/IStaticsBasketAdmin.sol";
import {IStaticsBasketConversion} from "../src/interfaces/IStaticsBasketConversion.sol";
import {StaticsInterfaceInit} from "../src/diamond/StaticsInterfaceInit.sol";
import {StaticsSelectors} from "../src/libraries/StaticsSelectors.sol";
import {StaticsProtocolPlan, StaticsProtocolParts} from "./libraries/StaticsProtocolPlan.sol";

/// @notice Read-only Safe preparation for an installed Phase 2 Diamond.
/// @dev Supply the reviewed candidate's complete Phase 2 parts. Library users must be rebuilt too.
contract PrepareStaticsBasketConversionUpgrade is Script {
    function buildBatch(
        address diamond,
        address facet,
        address initializer,
        address zap,
        StaticsProtocolParts memory parts
    ) public view returns (address[] memory targets, uint256[] memory values, bytes[] memory payloads) {
        IDiamondCut.FacetCut[] memory cut = _cut(diamond, facet, parts);
        bytes4[] memory interfaces = new bytes4[](1);
        interfaces[0] = type(IStaticsBasketConversion).interfaceId;
        bool[] memory supported = new bool[](1);
        supported[0] = true;
        targets = new address[](2);
        values = new uint256[](2);
        payloads = new bytes[](2);
        targets[0] = diamond;
        targets[1] = diamond;
        payloads[0] = abi.encodeCall(
            IDiamondCut.diamondCut,
            (cut, initializer, abi.encodeCall(StaticsInterfaceInit.setInterfaces, (interfaces, supported)))
        );
        payloads[1] = abi.encodeCall(IStaticsBasketAdmin.setBasketDistributor, (zap, true));
    }

    function _cut(address diamond, address facet, StaticsProtocolParts memory parts)
        private
        view
        returns (IDiamondCut.FacetCut[] memory cut)
    {
        IDiamondCut.FacetCut[] memory desired = StaticsProtocolPlan.cumulative(parts, 2);
        cut = new IDiamondCut.FacetCut[](desired.length + 1);
        uint256 count;
        for (uint256 i; i < desired.length; ++i) {
            bytes4[] memory selectors = new bytes4[](desired[i].functionSelectors.length);
            uint256 n;
            for (uint256 j; j < selectors.length; ++j) {
                bytes4 selector = desired[i].functionSelectors[j];
                address current = IDiamondLoupe(diamond).facetAddress(selector);
                if (current != address(0) && current != desired[i].facetAddress) selectors[n++] = selector;
            }
            assembly ("memory-safe") { mstore(selectors, n) }
            if (n != 0) {
                cut[count++] =
                    IDiamondCut.FacetCut(desired[i].facetAddress, IDiamondCut.FacetCutAction.Replace, selectors);
            }
        }
        cut[count++] = IDiamondCut.FacetCut(facet, IDiamondCut.FacetCutAction.Add, StaticsSelectors.basketConversion());
        assembly ("memory-safe") { mstore(cut, count) }
        return cut;
    }

    function buildSafeJson(
        address diamond,
        address facet,
        address initializer,
        address zap,
        StaticsProtocolParts memory parts
    ) external view returns (string memory) {
        (address[] memory targets,, bytes[] memory payloads) = buildBatch(diamond, facet, initializer, zap, parts);
        return string.concat(
            '{"version":"1.0","chainId":"',
            vm.toString(block.chainid),
            '","createdAt":',
            vm.toString(block.timestamp * 1000),
            ',"meta":{"name":"Statics basket conversion","createdFromSafeAddress":"',
            vm.toString(IERC173(diamond).owner()),
            '"},"transactions":[',
            _transaction(targets[0], payloads[0]),
            ",",
            _transaction(targets[1], payloads[1]),
            "]}"
        );
    }

    function _transaction(address target, bytes memory data) private pure returns (string memory) {
        return string.concat(
            '{"to":"',
            vm.toString(target),
            '","value":"0","data":"',
            vm.toString(data),
            '","contractMethod":null,"contractInputsValues":null}'
        );
    }
}
