// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IDiamondCut} from "../interfaces/IDiamondCut.sol";
import {IDiamondLoupe} from "../interfaces/IDiamondLoupe.sol";
import {IERC173} from "../interfaces/IERC173.sol";
import {LibDiamond} from "../libraries/LibDiamond.sol";

contract StaticsInterfaceInit {
    error InvalidArrayLength();
    error InvalidInterfaceId(bytes4 interfaceId);
    error StandardInterfaceManaged(bytes4 interfaceId);

    function setInterfaces(bytes4[] calldata interfaceIds, bool[] calldata supported) external {
        LibDiamond.enforceIsContractOwner();
        uint256 length = interfaceIds.length;
        if (length != supported.length) revert InvalidArrayLength();
        LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
        for (uint256 i; i < length; ++i) {
            if (interfaceIds[i] == 0xffffffff && supported[i]) revert InvalidInterfaceId(interfaceIds[i]);
            if (_isStandardInterface(interfaceIds[i])) revert StandardInterfaceManaged(interfaceIds[i]);
            ds.supportedInterfaces[interfaceIds[i]] = supported[i];
        }
    }

    function _isStandardInterface(bytes4 interfaceId) private pure returns (bool) {
        return interfaceId == type(IERC165).interfaceId || interfaceId == type(IDiamondCut).interfaceId
            || interfaceId == type(IDiamondLoupe).interfaceId || interfaceId == type(IERC173).interfaceId;
    }
}
