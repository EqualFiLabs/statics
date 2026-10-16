// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

/// @dev Hook identities only. Each standalone hook governs its own fee settings.
library LibPublicHookPolicy {
    bytes32 private constant STORAGE_POSITION = keccak256("statics.storage.public.hook.configuration.v1");

    struct PolicyStorage {
        bool initialized;
        address generalHook;
        address basketHook;
        address legacyHook;
        address weth;
    }

    error InvalidConfiguredHook(address hook);
    error UnsupportedHookAllocation(address hook);

    function policyStorage() internal pure returns (PolicyStorage storage ps) {
        bytes32 slot = STORAGE_POSITION;
        assembly ("memory-safe") { ps.slot := slot }
    }

    function enforceConfigured(address hook) internal view {
        PolicyStorage storage ps = policyStorage();
        if (
            !ps.initialized || hook == address(0)
                || (hook != ps.generalHook && hook != ps.basketHook && hook != ps.legacyHook)
        ) {
            revert InvalidConfiguredHook(hook);
        }
    }

    function enforceAllocation(address hook, bool basket) internal view {
        enforceConfigured(hook);
        PolicyStorage storage ps = policyStorage();
        if (hook != ps.legacyHook && hook != (basket ? ps.basketHook : ps.generalHook)) {
            revert UnsupportedHookAllocation(hook);
        }
    }
}
