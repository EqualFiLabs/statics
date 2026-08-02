// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IDiamondCut} from "../interfaces/IDiamondCut.sol";

/// @notice Shared EIP-2535 storage and cut logic for every Statics Diamond.
library LibDiamond {
    bytes32 internal constant DIAMOND_STORAGE_POSITION = keccak256("statics.diamond.storage.v2");

    struct FacetAddressAndPosition {
        address facetAddress;
        uint96 functionSelectorPosition;
    }

    struct FacetFunctionSelectors {
        bytes4[] functionSelectors;
        uint256 facetAddressPosition;
    }

    struct DiamondStorage {
        mapping(bytes4 => FacetAddressAndPosition) selectorToFacetAndPosition;
        mapping(address => FacetFunctionSelectors) facetFunctionSelectors;
        address[] facetAddresses;
        mapping(bytes4 => bool) supportedInterfaces;
        address contractOwner;
    }

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event DiamondCut(IDiamondCut.FacetCut[] cut, address init, bytes data);

    error ZeroAddress();
    error NotContractOwner(address caller, address owner);
    error NoSelectorsInFacet();
    error ZeroFacetAddress();
    error FunctionAlreadyExists(bytes4 selector);
    error FunctionDoesNotExist(bytes4 selector);
    error InvalidInitialization(address init, uint256 dataLength);
    error InitReverted();
    error FacetHasNoCode(address facet);
    error IncorrectFacetCutAction(uint8 action);

    function diamondStorage() internal pure returns (DiamondStorage storage ds) {
        bytes32 position = DIAMOND_STORAGE_POSITION;
        assembly {
            ds.slot := position
        }
    }

    function initializeOwnership(address owner_) internal {
        if (owner_ == address(0)) revert ZeroAddress();
        DiamondStorage storage ds = diamondStorage();
        address previousOwner = ds.contractOwner;
        ds.contractOwner = owner_;
        emit OwnershipTransferred(previousOwner, owner_);
    }

    function contractOwner() internal view returns (address) {
        return diamondStorage().contractOwner;
    }

    function enforceIsContractOwner() internal view {
        DiamondStorage storage ds = diamondStorage();
        if (msg.sender != ds.contractOwner) revert NotContractOwner(msg.sender, ds.contractOwner);
    }

    function diamondCut(IDiamondCut.FacetCut[] memory cut, address init, bytes memory data) internal {
        for (uint256 facetIndex; facetIndex < cut.length; ++facetIndex) {
            IDiamondCut.FacetCutAction action = cut[facetIndex].action;
            if (action == IDiamondCut.FacetCutAction.Add) {
                addFunctions(cut[facetIndex].facetAddress, cut[facetIndex].functionSelectors);
            } else if (action == IDiamondCut.FacetCutAction.Replace) {
                replaceFunctions(cut[facetIndex].facetAddress, cut[facetIndex].functionSelectors);
            } else if (action == IDiamondCut.FacetCutAction.Remove) {
                removeFunctions(cut[facetIndex].facetAddress, cut[facetIndex].functionSelectors);
            } else {
                revert IncorrectFacetCutAction(uint8(action));
            }
        }
        emit DiamondCut(cut, init, data);
        initializeCut(init, data);
    }

    function addFunctions(address facetAddress, bytes4[] memory selectors) internal {
        if (selectors.length == 0) revert NoSelectorsInFacet();
        if (facetAddress == address(0)) revert ZeroFacetAddress();
        enforceHasContractCode(facetAddress);

        DiamondStorage storage ds = diamondStorage();
        uint96 selectorPosition = uint96(ds.facetFunctionSelectors[facetAddress].functionSelectors.length);
        if (selectorPosition == 0) addFacet(ds, facetAddress);
        for (uint256 selectorIndex; selectorIndex < selectors.length; ++selectorIndex) {
            bytes4 selector = selectors[selectorIndex];
            if (ds.selectorToFacetAndPosition[selector].facetAddress != address(0)) {
                revert FunctionAlreadyExists(selector);
            }
            ds.selectorToFacetAndPosition[selector] = FacetAddressAndPosition(facetAddress, selectorPosition);
            ds.facetFunctionSelectors[facetAddress].functionSelectors.push(selector);
            ++selectorPosition;
        }
    }

    function replaceFunctions(address facetAddress, bytes4[] memory selectors) internal {
        if (selectors.length == 0) revert NoSelectorsInFacet();
        if (facetAddress == address(0)) revert ZeroFacetAddress();
        enforceHasContractCode(facetAddress);

        DiamondStorage storage ds = diamondStorage();
        uint96 selectorPosition = uint96(ds.facetFunctionSelectors[facetAddress].functionSelectors.length);
        if (selectorPosition == 0) addFacet(ds, facetAddress);
        for (uint256 selectorIndex; selectorIndex < selectors.length; ++selectorIndex) {
            bytes4 selector = selectors[selectorIndex];
            address oldFacet = ds.selectorToFacetAndPosition[selector].facetAddress;
            if (oldFacet == facetAddress || oldFacet == address(0)) revert FunctionDoesNotExist(selector);
            removeFunction(ds, oldFacet, selector);
            ds.selectorToFacetAndPosition[selector] = FacetAddressAndPosition(facetAddress, selectorPosition);
            ds.facetFunctionSelectors[facetAddress].functionSelectors.push(selector);
            ++selectorPosition;
        }
    }

    function removeFunctions(address facetAddress, bytes4[] memory selectors) internal {
        if (selectors.length == 0) revert NoSelectorsInFacet();
        if (facetAddress != address(0)) revert ZeroFacetAddress();

        DiamondStorage storage ds = diamondStorage();
        for (uint256 selectorIndex; selectorIndex < selectors.length; ++selectorIndex) {
            bytes4 selector = selectors[selectorIndex];
            address oldFacet = ds.selectorToFacetAndPosition[selector].facetAddress;
            if (oldFacet == address(0)) revert FunctionDoesNotExist(selector);
            removeFunction(ds, oldFacet, selector);
        }
    }

    function initializeCut(address init, bytes memory data) internal {
        if (init == address(0)) {
            if (data.length != 0) revert InvalidInitialization(init, data.length);
            return;
        }
        if (data.length == 0) revert InvalidInitialization(init, data.length);
        enforceHasContractCode(init);
        (bool success, bytes memory reason) = init.delegatecall(data);
        if (success) return;
        if (reason.length > 0) {
            assembly {
                revert(add(32, reason), mload(reason))
            }
        }
        revert InitReverted();
    }

    function addFacet(DiamondStorage storage ds, address facetAddress) private {
        ds.facetFunctionSelectors[facetAddress].facetAddressPosition = ds.facetAddresses.length;
        ds.facetAddresses.push(facetAddress);
    }

    function removeFunction(DiamondStorage storage ds, address facetAddress, bytes4 selector) private {
        uint256 selectorPosition = ds.selectorToFacetAndPosition[selector].functionSelectorPosition;
        uint256 lastSelectorPosition = ds.facetFunctionSelectors[facetAddress].functionSelectors.length - 1;
        if (selectorPosition != lastSelectorPosition) {
            bytes4 lastSelector = ds.facetFunctionSelectors[facetAddress].functionSelectors[lastSelectorPosition];
            ds.facetFunctionSelectors[facetAddress].functionSelectors[selectorPosition] = lastSelector;
            ds.selectorToFacetAndPosition[lastSelector].functionSelectorPosition = uint96(selectorPosition);
        }
        ds.facetFunctionSelectors[facetAddress].functionSelectors.pop();
        delete ds.selectorToFacetAndPosition[selector];

        if (ds.facetFunctionSelectors[facetAddress].functionSelectors.length == 0) {
            uint256 lastFacetAddressPosition = ds.facetAddresses.length - 1;
            uint256 facetAddressPosition = ds.facetFunctionSelectors[facetAddress].facetAddressPosition;
            if (facetAddressPosition != lastFacetAddressPosition) {
                address lastFacetAddress = ds.facetAddresses[lastFacetAddressPosition];
                ds.facetAddresses[facetAddressPosition] = lastFacetAddress;
                ds.facetFunctionSelectors[lastFacetAddress].facetAddressPosition = facetAddressPosition;
            }
            ds.facetAddresses.pop();
            delete ds.facetFunctionSelectors[facetAddress].facetAddressPosition;
        }
    }

    function enforceHasContractCode(address account) private view {
        if (account.code.length == 0) revert FacetHasNoCode(account);
    }
}
