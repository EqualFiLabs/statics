// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

interface IStaticsPublicHookPolicy {
    function installPublicHooks(address generalHook, address basketHook, address basketTokenFactory) external;
    function publicHookConfiguration()
        external
        view
        returns (address generalHook, address basketHook, address basketTokenFactory, address legacyHook);
}
