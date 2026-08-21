// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IDiamondCut} from "../interfaces/IDiamondCut.sol";
import {LibDiamond} from "../libraries/LibDiamond.sol";

/// @notice Genesis initializer that applies a facet cut without further protocol setup.
contract StaticsGenesisCut {
    function cut(IDiamondCut.FacetCut[] calldata genesisCut) external {
        LibDiamond.diamondCut(genesisCut, address(0), "");
    }
}
