methods {
    function owner() external returns (address) envfree;
    function feeReceiver() external returns (address) envfree;
    function poolManager() external returns (address) envfree;
    function registrationFeesWithinCap(bytes32) external returns (bool) envfree;
    function registrationDigest(bytes32) external returns (bytes32) envfree;
}

/// Every registered pool retains the protocol-wide bilateral fee cap.
invariant registeredFeesNeverExceedCap(bytes32 poolId)
    registrationFeesWithinCap(poolId);

/// Fee routing never targets an invalid custody endpoint.
invariant feeReceiverIsAlwaysValid()
    feeReceiver() != 0
        && feeReceiver() != currentContract
        && feeReceiver() != poolManager();

/// Receiver rotation cannot mutate any sampled pool registration.
rule receiverUpdatePreservesRegistration(env e, address nextReceiver, bytes32 poolId) {
    bytes32 registrationBefore = registrationDigest(poolId);

    setFeeReceiver@withrevert(e, nextReceiver);

    assert lastReverted || registrationDigest(poolId) == registrationBefore,
        "receiver rotation must preserve pool registration";
}

/// A successful receiver update can only be authorized by the current owner.
rule onlyOwnerCanUpdateReceiver(env e, address nextReceiver) {
    address ownerBefore = owner();

    setFeeReceiver@withrevert(e, nextReceiver);

    assert lastReverted || e.msg.sender == ownerBefore,
        "only owner may update receiver";
}
