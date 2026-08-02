// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

import {StaticsDiamond} from "src/diamond/StaticsDiamond.sol";
import {DiamondKernel} from "src/diamond/DiamondKernel.sol";
import {DiamondCutFacet} from "src/facets/DiamondCutFacet.sol";
import {DiamondLoupeFacet} from "src/facets/DiamondLoupeFacet.sol";
import {OwnershipFacet} from "src/facets/OwnershipFacet.sol";
import {IDiamondCut} from "src/interfaces/IDiamondCut.sol";
import {IDiamondLoupe} from "src/interfaces/IDiamondLoupe.sol";
import {LibDiamond} from "src/libraries/LibDiamond.sol";

contract DiamondValueFacetV1 {
    function value() external pure returns (uint256) {
        return 1;
    }
}

contract DiamondValueFacetV2 {
    function value() external pure returns (uint256) {
        return 2;
    }
}

contract DiamondAddedFacet {
    function addedValue() external pure returns (uint256) {
        return 3;
    }
}

contract DiamondInitializerFacet {
    bytes32 internal constant VALUE_SLOT = keccak256("statics.diamond.test.initializer.value");

    error InitializationFailed(uint256 value);

    function initializeValue(uint256 newValue) external {
        bytes32 slot = VALUE_SLOT;
        assembly {
            sstore(slot, newValue)
        }
    }

    function setValueAndRevert(uint256 newValue) external {
        bytes32 slot = VALUE_SLOT;
        assembly {
            sstore(slot, newValue)
        }
        revert InitializationFailed(newValue);
    }

    function initializedValue() external view returns (uint256 result) {
        bytes32 slot = VALUE_SLOT;
        assembly {
            result := sload(slot)
        }
    }
}

contract DiamondProxyFacet {
    address internal immutable implementation;

    constructor(address implementation_) {
        implementation = implementation_;
    }

    fallback() external payable {
        address target = implementation;
        assembly {
            calldatacopy(0, 0, calldatasize())
            let result := delegatecall(gas(), target, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch result
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }
}

contract DiamondCutTest is Test {
    address internal outsider = makeAddr("outsider");
    StaticsDiamond internal diamond;
    IDiamondCut internal cut;
    IDiamondLoupe internal loupe;
    OwnershipFacet internal ownership;
    DiamondValueFacetV1 internal valueFacetV1;

    function setUp() public {
        DiamondCutFacet cutFacet = new DiamondCutFacet();
        DiamondLoupeFacet loupeFacet = new DiamondLoupeFacet();
        OwnershipFacet ownershipFacet = new OwnershipFacet();
        valueFacetV1 = new DiamondValueFacetV1();

        IDiamondCut.FacetCut[] memory genesisCut = new IDiamondCut.FacetCut[](4);
        genesisCut[0] = IDiamondCut.FacetCut(address(cutFacet), IDiamondCut.FacetCutAction.Add, _cutSelectors());
        genesisCut[1] = IDiamondCut.FacetCut(address(loupeFacet), IDiamondCut.FacetCutAction.Add, _loupeSelectors());
        genesisCut[2] =
            IDiamondCut.FacetCut(address(ownershipFacet), IDiamondCut.FacetCutAction.Add, _ownershipSelectors());
        genesisCut[3] = IDiamondCut.FacetCut(
            address(valueFacetV1), IDiamondCut.FacetCutAction.Add, _singleSelector(DiamondValueFacetV1.value.selector)
        );

        diamond = new StaticsDiamond(address(this), genesisCut, address(0), "", address(0));
        cut = IDiamondCut(address(diamond));
        loupe = IDiamondLoupe(address(diamond));
        ownership = OwnershipFacet(address(diamond));
    }

    function test_GenesisRequiresOwner() public {
        IDiamondCut.FacetCut[] memory empty = new IDiamondCut.FacetCut[](0);
        vm.expectRevert(LibDiamond.ZeroAddress.selector);
        new StaticsDiamond(address(0), empty, address(0), "", address(0));
    }

    function test_GenesisRejectsFacetWithoutCode() public {
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        IDiamondCut.FacetCut[] memory genesisCut =
            _singleCut(predicted, IDiamondCut.FacetCutAction.Add, DiamondAddedFacet.addedValue.selector);
        vm.expectRevert(abi.encodeWithSelector(LibDiamond.FacetHasNoCode.selector, predicted));
        new StaticsDiamond(address(this), genesisCut, address(0), "", address(0));
    }

    function test_DiamondCutRequiresOwnerAndRejectsDuplicateSelectors() public {
        DiamondAddedFacet addedFacet = new DiamondAddedFacet();
        IDiamondCut.FacetCut[] memory addition =
            _singleCut(address(addedFacet), IDiamondCut.FacetCutAction.Add, DiamondAddedFacet.addedValue.selector);

        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(LibDiamond.NotContractOwner.selector, outsider, address(this)));
        cut.diamondCut(addition, address(0), "");

        bytes4[] memory duplicateSelectors = new bytes4[](2);
        duplicateSelectors[0] = DiamondAddedFacet.addedValue.selector;
        duplicateSelectors[1] = DiamondAddedFacet.addedValue.selector;
        addition[0].functionSelectors = duplicateSelectors;
        vm.expectRevert(
            abi.encodeWithSelector(LibDiamond.FunctionAlreadyExists.selector, DiamondAddedFacet.addedValue.selector)
        );
        cut.diamondCut(addition, address(0), "");
    }

    function test_AddReplaceAndRemovePreserveExactRouting() public {
        DiamondAddedFacet addedFacet = new DiamondAddedFacet();
        cut.diamondCut(
            _singleCut(address(addedFacet), IDiamondCut.FacetCutAction.Add, DiamondAddedFacet.addedValue.selector),
            address(0),
            ""
        );
        assertEq(DiamondAddedFacet(address(diamond)).addedValue(), 3);

        DiamondValueFacetV2 valueFacetV2 = new DiamondValueFacetV2();
        cut.diamondCut(
            _singleCut(address(valueFacetV2), IDiamondCut.FacetCutAction.Replace, DiamondValueFacetV1.value.selector),
            address(0),
            ""
        );
        assertEq(DiamondValueFacetV2(address(diamond)).value(), 2);

        cut.diamondCut(
            _singleCut(address(0), IDiamondCut.FacetCutAction.Remove, DiamondAddedFacet.addedValue.selector),
            address(0),
            ""
        );
        assertEq(loupe.facetAddress(DiamondAddedFacet.addedValue.selector), address(0));
    }

    function test_OwnershipTransferIsImmediate() public {
        address newOwner = makeAddr("newOwner");
        ownership.transferOwnership(newOwner);
        assertEq(ownership.owner(), newOwner);
    }

    function test_AllowsFacetContainingDelegatecall() public {
        DiamondAddedFacet implementation = new DiamondAddedFacet();
        DiamondProxyFacet proxyFacet = new DiamondProxyFacet(address(implementation));
        cut.diamondCut(
            _singleCut(address(proxyFacet), IDiamondCut.FacetCutAction.Add, DiamondAddedFacet.addedValue.selector),
            address(0),
            ""
        );
        assertEq(DiamondAddedFacet(address(diamond)).addedValue(), 3);
    }

    function test_RuntimeInitializationDelegatecallsArbitraryContractAndCanReplay() public {
        DiamondInitializerFacet initializerFacet = new DiamondInitializerFacet();
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = DiamondInitializerFacet.initializeValue.selector;
        selectors[1] = DiamondInitializerFacet.initializedValue.selector;
        IDiamondCut.FacetCut[] memory addition = new IDiamondCut.FacetCut[](1);
        addition[0] = IDiamondCut.FacetCut(address(initializerFacet), IDiamondCut.FacetCutAction.Add, selectors);
        bytes memory data = abi.encodeCall(DiamondInitializerFacet.initializeValue, (42));

        cut.diamondCut(addition, address(initializerFacet), data);
        assertEq(DiamondInitializerFacet(address(diamond)).initializedValue(), 42);

        IDiamondCut.FacetCut[] memory noCut = new IDiamondCut.FacetCut[](0);
        cut.diamondCut(noCut, address(initializerFacet), abi.encodeCall(DiamondInitializerFacet.initializeValue, (84)));
        assertEq(DiamondInitializerFacet(address(diamond)).initializedValue(), 84);
    }

    function test_InitializerRevertBubblesAndRollsBackCut() public {
        DiamondAddedFacet addedFacet = new DiamondAddedFacet();
        DiamondInitializerFacet initializer = new DiamondInitializerFacet();
        IDiamondCut.FacetCut[] memory addition =
            _singleCut(address(addedFacet), IDiamondCut.FacetCutAction.Add, DiamondAddedFacet.addedValue.selector);
        bytes memory data = abi.encodeCall(DiamondInitializerFacet.setValueAndRevert, (7));

        vm.expectRevert(abi.encodeWithSelector(DiamondInitializerFacet.InitializationFailed.selector, 7));
        cut.diamondCut(addition, address(initializer), data);

        assertEq(loupe.facetAddress(DiamondAddedFacet.addedValue.selector), address(0));
    }

    function test_FinalCutCanPermanentlyRemoveUpgradeSelectors() public {
        bytes4[] memory cutMutations = _singleSelector(IDiamondCut.diamondCut.selector);
        bytes4[] memory ownershipMutations = new bytes4[](1);
        ownershipMutations[0] = OwnershipFacet.transferOwnership.selector;
        IDiamondCut.FacetCut[] memory finalCut = new IDiamondCut.FacetCut[](2);
        finalCut[0] = IDiamondCut.FacetCut(address(0), IDiamondCut.FacetCutAction.Remove, cutMutations);
        finalCut[1] = IDiamondCut.FacetCut(address(0), IDiamondCut.FacetCutAction.Remove, ownershipMutations);
        cut.diamondCut(finalCut, address(0), "");

        DiamondAddedFacet addedFacet = new DiamondAddedFacet();
        vm.expectRevert(
            abi.encodeWithSelector(DiamondKernel.FunctionNotFound.selector, IDiamondCut.diamondCut.selector)
        );
        cut.diamondCut(
            _singleCut(address(addedFacet), IDiamondCut.FacetCutAction.Add, DiamondAddedFacet.addedValue.selector),
            address(0),
            ""
        );
    }

    function test_SelectorManifestIsExact() public view {
        IDiamondLoupe.Facet[] memory installed = loupe.facets();
        assertEq(installed.length, 4);
        assertEq(loupe.facetAddress(IDiamondCut.diamondCut.selector), installed[0].facetAddress);
        assertEq(loupe.facetFunctionSelectors(installed[0].facetAddress).length, _cutSelectors().length);
        assertEq(loupe.facetFunctionSelectors(installed[1].facetAddress).length, _loupeSelectors().length);
        assertEq(loupe.facetFunctionSelectors(installed[2].facetAddress).length, _ownershipSelectors().length);
    }

    function _singleCut(address facet, IDiamondCut.FacetCutAction action, bytes4 selector)
        internal
        pure
        returns (IDiamondCut.FacetCut[] memory diamondCut)
    {
        diamondCut = new IDiamondCut.FacetCut[](1);
        diamondCut[0] = IDiamondCut.FacetCut(facet, action, _singleSelector(selector));
    }

    function _singleSelector(bytes4 selector) internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](1);
        selectors[0] = selector;
    }

    function _cutSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = _singleSelector(IDiamondCut.diamondCut.selector);
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
