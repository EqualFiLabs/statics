// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LibExactAssetTransfer} from "./LibExactAssetTransfer.sol";

/// @notice One-use receiver that keeps Doppler rounding dust out of the exact 20% treasury allocation.
contract StaticsLaunchAllocationEscrow {
    using LibExactAssetTransfer for IERC20;

    uint256 public constant TREASURY_ALLOCATION = 200_000_000 ether;

    address public immutable treasury;
    address public bootstrapper;
    bool public released;

    error InvalidTreasury();
    error InvalidBootstrapper();
    error UnauthorizedBootstrapper(address caller);
    error AllocationAlreadyReleased();
    error InvalidToken();
    error InvalidResidualReceiver();
    error InsufficientAllocation(uint256 balance, uint256 required);

    event LaunchAllocationReleased(
        address indexed token, address indexed treasury, address indexed residualReceiver, uint256 residual
    );

    constructor(address treasury_, address bootstrapper_) {
        if (treasury_ == address(0)) revert InvalidTreasury();
        if (bootstrapper_ == address(0)) revert InvalidBootstrapper();
        treasury = treasury_;
        bootstrapper = bootstrapper_;
    }

    function release(IERC20 token, address residualReceiver) external returns (uint256 residual) {
        if (msg.sender != bootstrapper) revert UnauthorizedBootstrapper(msg.sender);
        if (released) revert AllocationAlreadyReleased();
        if (address(token) == address(0) || address(token).code.length == 0) revert InvalidToken();
        if (residualReceiver == address(0) || residualReceiver == address(this)) revert InvalidResidualReceiver();
        uint256 balance = token.balanceOf(address(this));
        if (balance < TREASURY_ALLOCATION) revert InsufficientAllocation(balance, TREASURY_ALLOCATION);

        released = true;
        delete bootstrapper;
        residual = balance - TREASURY_ALLOCATION;
        token.pushExact(treasury, TREASURY_ALLOCATION);
        if (residual != 0) token.pushExact(residualReceiver, residual);
        emit LaunchAllocationReleased(address(token), treasury, residualReceiver, residual);
    }
}
