// SPDX-License-Identifier: BUSL-1.1
// ============================================================================
//                              STATICS PROTOCOL
//                         Markets that work for you.
//                       https://staticsprotocol.com
//                              EqualFi Labs
// ============================================================================
pragma solidity 0.8.33;

import {IERC173} from "../interfaces/IERC173.sol";
import {LibDiamond} from "../libraries/LibDiamond.sol";

contract OwnershipFacet is IERC173 {
    function owner() external view returns (address owner_) {
        owner_ = LibDiamond.diamondStorage().contractOwner;
    }

    function transferOwnership(address newOwner) external {
        LibDiamond.enforceIsContractOwner();
        if (newOwner == address(0)) revert LibDiamond.ZeroAddress();
        LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
        address previousOwner = ds.contractOwner;
        ds.contractOwner = newOwner;
        emit LibDiamond.OwnershipTransferred(previousOwner, newOwner);
    }
}
