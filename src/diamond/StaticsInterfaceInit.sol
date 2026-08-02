// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {LibDiamond} from "../libraries/LibDiamond.sol";

contract StaticsInterfaceInit {
    error InvalidArrayLength();

    function setInterfaces(bytes4[] calldata interfaceIds, bool[] calldata supported) external {
        LibDiamond.enforceIsContractOwner();
        uint256 length = interfaceIds.length;
        if (length != supported.length) revert InvalidArrayLength();
        LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
        for (uint256 i; i < length; ++i) {
            ds.supportedInterfaces[interfaceIds[i]] = supported[i];
        }
    }
}
