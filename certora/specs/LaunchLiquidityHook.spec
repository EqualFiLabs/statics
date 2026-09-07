methods {
    function owner() external returns (address) envfree;
    function feeReceiver() external returns (address) envfree;
    function MAX_HOOK_FEE_BPS() external returns (uint16) envfree;
    function registrationFees(bytes32) external returns (uint16, uint16, bool) envfree;
    function registrationDigest(bytes32) external returns (bytes32) envfree;
    function registrationStructureDigest(bytes32) external returns (bytes32) envfree;
}

/// Every registered pool retains the protocol-wide bilateral fee cap.
invariant registeredFeesNeverExceedCap(bytes32 poolId)
    let inputFeeBps, outputFeeBps, registered = registrationFees(poolId) in
        !registered || (
            inputFeeBps <= MAX_HOOK_FEE_BPS()
                && outputFeeBps <= MAX_HOOK_FEE_BPS()
        );

/// Receiver rotation cannot mutate any sampled pool registration.
rule receiverUpdatePreservesRegistration(env e, address nextReceiver, bytes32 poolId) {
    bytes32 registrationBefore = registrationDigest(poolId);

    setFeeReceiver@withrevert(e, nextReceiver);

    assert lastReverted || registrationDigest(poolId) == registrationBefore,
        "receiver rotation must preserve pool registration";
}

/// Per-pool fee updates cannot mutate currencies, native fee, spacing, price, or registration state.
rule feeUpdatePreservesRegistrationStructure(
    env e,
    bytes32 poolId,
    uint16 inputFeeBps,
    uint16 outputFeeBps
) {
    bytes32 structureBefore = registrationStructureDigest(poolId);

    setHookFees@withrevert(e, poolId, inputFeeBps, outputFeeBps);

    assert lastReverted || registrationStructureDigest(poolId) == structureBefore,
        "fee update must preserve immutable registration fields";
}

/// A successful receiver update can only be authorized by the current owner.
rule onlyOwnerCanUpdateReceiver(env e, address nextReceiver) {
    address ownerBefore = owner();

    setFeeReceiver@withrevert(e, nextReceiver);

    assert lastReverted || e.msg.sender == ownerBefore,
        "only owner may update receiver";
}

/// A successful per-pool fee update can only be authorized by the current owner.
rule onlyOwnerCanUpdateFees(env e, bytes32 poolId, uint16 inputFeeBps, uint16 outputFeeBps) {
    address ownerBefore = owner();

    setHookFees@withrevert(e, poolId, inputFeeBps, outputFeeBps);

    assert lastReverted || e.msg.sender == ownerBefore,
        "only owner may update fees";
}
