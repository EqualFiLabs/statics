// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IDiamondCut} from "../interfaces/IDiamondCut.sol";
import {DiamondKernel} from "./DiamondKernel.sol";

contract StaticsDiamond is DiamondKernel {
    address private immutable NATIVE_SENDER;

    error NativeSenderNotAllowed(address sender);

    constructor(address owner, IDiamondCut.FacetCut[] memory cut, address init, bytes memory data, address nativeSender)
        DiamondKernel(owner, cut, init, data)
    {
        NATIVE_SENDER = nativeSender;
    }

    receive() external payable {
        if (msg.sender != NATIVE_SENDER) revert NativeSenderNotAllowed(msg.sender);
    }
}
