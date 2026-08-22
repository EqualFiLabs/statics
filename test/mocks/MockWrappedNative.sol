// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Minimal canonical-WETH-like mock: wraps and unwraps native ETH 1:1.
contract MockWrappedNative is ERC20 {
    error WithdrawTransferFailed(address receiver, uint256 amount);

    constructor() ERC20("Wrapped Ether", "WETH") {}

    receive() external payable {
        _mint(msg.sender, msg.value);
    }

    function deposit() external payable {
        _mint(msg.sender, msg.value);
    }

    function withdraw(uint256 amount) external {
        _burn(msg.sender, amount);
        (bool success,) = msg.sender.call{value: amount}("");
        if (!success) revert WithdrawTransferFailed(msg.sender, amount);
    }

    /// @notice Test helper to mint wrapped balance without native funding.
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
