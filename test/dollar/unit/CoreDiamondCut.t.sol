// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

import {DiamondKernel} from "src/diamond/DiamondKernel.sol";
import {DiamondCutFacet} from "src/facets/DiamondCutFacet.sol";
import {DiamondLoupeFacet} from "src/facets/DiamondLoupeFacet.sol";
import {OwnershipFacet} from "src/facets/OwnershipFacet.sol";
import {IDiamondCut} from "src/interfaces/IDiamondCut.sol";
import {IDiamondLoupe} from "src/interfaces/IDiamondLoupe.sol";

contract CoreKernelHarness is DiamondKernel {
    constructor(address owner, IDiamondCut.FacetCut[] memory genesisCut)
        DiamondKernel(owner, genesisCut, address(0), "")
    {}
}

contract CoreKernelValueFacet {
    function coreValue() external pure returns (uint256) {
        return 11;
    }
}

contract CoreDiamondCutTest is Test {
    function test_SharedKernelMaintainsIndependentDiamondState() public {
        (CoreKernelHarness first, DiamondLoupeFacet firstLoupe,) = _deploy(address(this));
        address secondOwner = makeAddr("secondOwner");
        (CoreKernelHarness second, DiamondLoupeFacet secondLoupe, OwnershipFacet secondOwnership) = _deploy(secondOwner);

        assertTrue(address(first) != address(second));
        assertEq(firstLoupe.facetAddresses().length, 4);
        assertEq(secondLoupe.facetAddresses().length, 4);
        assertEq(secondOwnership.owner(), secondOwner);
        assertEq(CoreKernelValueFacet(address(first)).coreValue(), 11);
        assertEq(CoreKernelValueFacet(address(second)).coreValue(), 11);
    }

    function test_CoreKernelCanExecuteTerminalRemovalCut() public {
        (CoreKernelHarness core, DiamondLoupeFacet loupe,) = _deploy(address(this));
        IDiamondCut cut = IDiamondCut(address(core));
        bytes4[] memory mutations = new bytes4[](1);
        mutations[0] = IDiamondCut.diamondCut.selector;
        IDiamondCut.FacetCut[] memory finalCut = new IDiamondCut.FacetCut[](1);
        finalCut[0] = IDiamondCut.FacetCut(address(0), IDiamondCut.FacetCutAction.Remove, mutations);

        cut.diamondCut(finalCut, address(0), "");

        for (uint256 i; i < mutations.length; i++) {
            assertEq(loupe.facetAddress(mutations[i]), address(0));
        }
    }

    function _deploy(address owner)
        internal
        returns (CoreKernelHarness core, DiamondLoupeFacet loupe, OwnershipFacet ownership)
    {
        DiamondCutFacet cutFacet = new DiamondCutFacet();
        DiamondLoupeFacet loupeFacet = new DiamondLoupeFacet();
        OwnershipFacet ownershipFacet = new OwnershipFacet();
        CoreKernelValueFacet valueFacet = new CoreKernelValueFacet();
        IDiamondCut.FacetCut[] memory genesis = new IDiamondCut.FacetCut[](4);
        genesis[0] = IDiamondCut.FacetCut(address(cutFacet), IDiamondCut.FacetCutAction.Add, _cutSelectors());
        genesis[1] = IDiamondCut.FacetCut(address(loupeFacet), IDiamondCut.FacetCutAction.Add, _loupeSelectors());
        genesis[2] =
            IDiamondCut.FacetCut(address(ownershipFacet), IDiamondCut.FacetCutAction.Add, _ownershipSelectors());
        bytes4[] memory valueSelector = new bytes4[](1);
        valueSelector[0] = CoreKernelValueFacet.coreValue.selector;
        genesis[3] = IDiamondCut.FacetCut(address(valueFacet), IDiamondCut.FacetCutAction.Add, valueSelector);
        core = new CoreKernelHarness(owner, genesis);
        loupe = DiamondLoupeFacet(address(core));
        ownership = OwnershipFacet(address(core));
    }

    function _cutSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](1);
        selectors[0] = IDiamondCut.diamondCut.selector;
    }

    function _loupeSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](5);
        selectors[0] = IDiamondLoupe.facets.selector;
        selectors[1] = IDiamondLoupe.facetFunctionSelectors.selector;
        selectors[2] = IDiamondLoupe.facetAddresses.selector;
        selectors[3] = IDiamondLoupe.facetAddress.selector;
        selectors[4] = DiamondLoupeFacet.supportsInterface.selector;
    }

    function _ownershipSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](2);
        selectors[0] = OwnershipFacet.transferOwnership.selector;
        selectors[1] = OwnershipFacet.owner.selector;
    }
}
