// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IDiamondCut} from "../interfaces/IDiamondCut.sol";
import {LibDiamond} from "../libraries/LibDiamond.sol";

/// @notice Shared fallback and atomic genesis path for every Statics Diamond.
abstract contract DiamondKernel {
    error FunctionNotFound(bytes4 selector);

    /// @dev Genesis facets are applied by the init contract during this delegatecall so the
    /// constructor signature stays free of nested dynamic arrays, which legacy Solidity
    /// codegen cannot encode within the EVM stack limit.
    constructor(address owner, address init, bytes memory initData) {
        LibDiamond.initializeOwnership(owner);
        LibDiamond.initializeCut(init, initData);
    }

    fallback() external payable {
        LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
        address facet = ds.selectorToFacetAndPosition[msg.sig].facetAddress;
        if (facet == address(0)) revert FunctionNotFound(msg.sig);
        assembly {
            calldatacopy(0, 0, calldatasize())
            let result := delegatecall(gas(), facet, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch result
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }
}
