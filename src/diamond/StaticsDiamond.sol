// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {DiamondKernel} from "./DiamondKernel.sol";

contract StaticsDiamond is DiamondKernel {
    address private immutable NATIVE_SENDER;

    error NativeSenderNotAllowed(address sender);

    constructor(address owner, address nativeSender, address init, bytes memory initData)
        DiamondKernel(owner, init, initData)
    {
        NATIVE_SENDER = nativeSender;
    }

    receive() external payable {
        if (msg.sender != NATIVE_SENDER) revert NativeSenderNotAllowed(msg.sender);
    }
}
