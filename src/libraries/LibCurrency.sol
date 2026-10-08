// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Physical pool-asset operations; address(0) is actual native ETH.
library LibCurrency {
    error NativeTransferFailed(address receiver, uint256 amount);
    error InvalidMsgValue(uint256 expected, uint256 actual);

    function balance(address asset, address owner) internal view returns (uint256) {
        return asset == address(0) ? owner.balance : IERC20(asset).balanceOf(owner);
    }

    function sendNative(address receiver, uint256 amount) internal {
        if (amount == 0) return;
        (bool success,) = receiver.call{value: amount}("");
        if (!success) revert NativeTransferFailed(receiver, amount);
    }

    function enforceValue(address currency0, uint256 maximum0) internal view {
        uint256 expected = currency0 == address(0) ? maximum0 : 0;
        if (msg.value != expected) revert InvalidMsgValue(expected, msg.value);
    }
}
