methods {
    function owner() external returns (address) envfree;
    function feeReceiver() external returns (address) envfree;
    function poolManager() external returns (address) envfree;
    function positionManager() external returns (address) envfree;
    function registrationFeesWithinCap(bytes32) external returns (bool) envfree;
    function registrationDigest(bytes32) external returns (bytes32) envfree;
    function registrationInitialized(bytes32) external returns (bool) envfree;
    function registrationActive(bytes32) external returns (bool) envfree;
    function registrationLaunchOperator(bytes32) external returns (address) envfree;
    function registrationInputFee(bytes32) external returns (uint16) envfree;
    function registrationOutputFee(bytes32) external returns (uint16) envfree;
    function registrationLifecycleIsCoherent(bytes32) external returns (bool) envfree;
}

/// Every registered pool retains the protocol-wide bilateral fee cap.
invariant registeredFeesNeverExceedCap(bytes32 poolId)
    registrationFeesWithinCap(poolId);

/// Trading activation can never exist without a successful registered initialization.
invariant activePoolWasInitialized(bytes32 poolId)
    registrationLifecycleIsCoherent(poolId);

/// Fee routing never targets an invalid custody endpoint.
invariant feeReceiverIsAlwaysValid()
    feeReceiver() != 0
        && feeReceiver() != currentContract
        && feeReceiver() != poolManager()
        && feeReceiver() != positionManager();

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

/// A successful bilateral fee update can only be authorized by the current owner.
rule onlyOwnerCanUpdatePoolFees(env e, bytes32 poolId, uint16 inputFeeBps, uint16 outputFeeBps) {
    address ownerBefore = owner();

    setHookFees@withrevert(e, poolId, inputFeeBps, outputFeeBps);

    assert lastReverted || e.msg.sender == ownerBefore,
        "only owner may update bilateral pool fees";
}

/// A successful fee update writes the exact requested rates and cannot mutate another pool.
rule feeUpdateIsExactAndPoolLocal(
    env e,
    bytes32 poolId,
    bytes32 otherPoolId,
    uint16 inputFeeBps,
    uint16 outputFeeBps
) {
    bytes32 otherRegistrationBefore = registrationDigest(otherPoolId);

    setHookFees@withrevert(e, poolId, inputFeeBps, outputFeeBps);

    assert lastReverted || registrationInputFee(poolId) == inputFeeBps,
        "successful update must set the exact input fee";
    assert lastReverted || registrationOutputFee(poolId) == outputFeeBps,
        "successful update must set the exact output fee";
    assert lastReverted || poolId == otherPoolId || registrationDigest(otherPoolId) == otherRegistrationBefore,
        "fee update must not mutate another pool";
}

/// Activation is one-way, requires prior initialization, and is limited to owner or launch operator.
rule activationIsAuthorizedAndOneWay(env e, bytes32 poolId) {
    address ownerBefore = owner();
    address operatorBefore = registrationLaunchOperator(poolId);
    bool initializedBefore = registrationInitialized(poolId);
    bool activeBefore = registrationActive(poolId);

    activatePoolRaw@withrevert(e, poolId);
    bool activationReverted = lastReverted;

    assert activationReverted || initializedBefore,
        "activation requires initialization";
    assert activationReverted || e.msg.sender == ownerBefore || e.msg.sender == operatorBefore,
        "activation requires owner or launch operator";
    assert activationReverted || registrationActive(poolId),
        "successful activation sets active state";
    assert !activeBefore || activationReverted,
        "active pools cannot be activated twice";
}

/// Administrative ownership cannot be permanently discarded.
rule ownershipCannotBeRenounced(env e) {
    renounceOwnership@withrevert(e);
    assert lastReverted,
        "ownership renunciation must always revert";
}
