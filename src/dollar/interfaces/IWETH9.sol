// SPDX-License-Identifier: BUSL-1.1
// ============================================================================
//                              STATICS PROTOCOL
//                         Markets that work for you.
//                       https://staticsprotocol.com
//                              EqualFi Labs
// ============================================================================
pragma solidity ^0.8.28;

interface IWETH9 {
    function deposit() external payable;

    function withdraw(uint256 wad) external;
}
