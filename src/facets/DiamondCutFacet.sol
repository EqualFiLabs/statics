// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IDiamondCut} from "../interfaces/IDiamondCut.sol";
import {LibDiamond} from "../libraries/LibDiamond.sol";

contract DiamondCutFacet is IDiamondCut {
    function diamondCut(FacetCut[] calldata cut, address init, bytes calldata data) external {
        LibDiamond.enforceIsContractOwner();
        LibDiamond.diamondCut(cut, init, data);
    }
}
