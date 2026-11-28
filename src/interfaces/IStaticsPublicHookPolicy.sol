// SPDX-License-Identifier: BUSL-1.1
// ============================================================================
//                              STATICS PROTOCOL
//                         Markets that work for you.
//                       https://staticsprotocol.com
//                              EqualFi Labs
// ============================================================================
pragma solidity 0.8.33;

interface IStaticsPublicHookPolicy {
    function installBasketHook(address basketHook, address basketTokenFactory) external;
    function basketHookConfiguration() external view returns (address basketHook, address basketTokenFactory);
}
