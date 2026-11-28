// SPDX-License-Identifier: BUSL-1.1
// ============================================================================
//                              STATICS PROTOCOL
//                         Markets that work for you.
//                       https://staticsprotocol.com
//                              EqualFi Labs
// ============================================================================
pragma solidity ^0.8.28;

interface ICoreBootstrapWiring {
    function pool() external view returns (address);

    function staticsDollar() external view returns (address);

    function staticsDollarRisk() external view returns (address);
}
