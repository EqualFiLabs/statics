// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

interface IWETH9 {
    function deposit() external payable;

    function withdraw(uint256 wad) external;
}
