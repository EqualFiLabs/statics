methods {
    function STATICS_VESTING_PRINCIPAL() external returns (uint256) envfree;
    function GENESIS_VESTING_PRINCIPAL() external returns (uint256) envfree;
    function VESTING_DURATION() external returns (uint256) envfree;
    function statics() external returns (address) envfree;
    function genesisVault() external returns (address) envfree;
    function genesis() external returns (address) envfree;
    function recipientAdmin() external returns (address) envfree;
    function withdrawalRecipient() external returns (address) envfree;
    function vestingStart() external returns (uint256) envfree;
    function vestingEnd() external returns (uint256) envfree;
    function releasedStatics() external returns (uint256) envfree;
    function releasedGenesis() external returns (uint256) envfree;
    function vestedStaticsAt(uint256) external returns (uint256) envfree;
    function vestedGenesisAt(uint256) external returns (uint256) envfree;
    function sweepStaticsSurplus() external returns (uint256);
}

/// STATICS vesting is zero before launch, linear by integer floor, and capped at principal.
rule staticsVestingIsExact(uint256 timestamp) {
    uint256 start = vestingStart();
    uint256 duration = VESTING_DURATION();
    uint256 principal = STATICS_VESTING_PRINCIPAL();
    uint256 vested = vestedStaticsAt(timestamp);

    if (start == 0 || timestamp <= start) {
        assert vested == 0, "STATICS must not vest before the launch timestamp";
    } else if (to_mathint(timestamp) - to_mathint(start) >= to_mathint(duration)) {
        assert vested == principal, "STATICS vesting must cap at principal";
    } else {
        mathint elapsed = to_mathint(timestamp) - to_mathint(start);
        assert to_mathint(vested) * to_mathint(duration)
            <= to_mathint(principal) * elapsed,
            "STATICS vested amount cannot exceed the linear quotient";
        assert to_mathint(principal) * elapsed
                - to_mathint(vested) * to_mathint(duration)
            < to_mathint(duration),
            "STATICS vested amount must be the floored linear quotient";
    }
}

/// Genesis vesting follows the same exact linear schedule and caps at 555 NFTs.
rule genesisVestingIsExact(uint256 timestamp) {
    uint256 start = vestingStart();
    uint256 duration = VESTING_DURATION();
    uint256 principal = GENESIS_VESTING_PRINCIPAL();
    uint256 vested = vestedGenesisAt(timestamp);

    if (start == 0 || timestamp <= start) {
        assert vested == 0, "Genesis must not vest before the launch timestamp";
    } else if (to_mathint(timestamp) - to_mathint(start) >= to_mathint(duration)) {
        assert vested == principal, "Genesis vesting must cap at principal";
    } else {
        mathint elapsed = to_mathint(timestamp) - to_mathint(start);
        assert to_mathint(vested) * to_mathint(duration)
            <= to_mathint(principal) * elapsed,
            "Genesis vested amount cannot exceed the linear quotient";
        assert to_mathint(principal) * elapsed
                - to_mathint(vested) * to_mathint(duration)
            < to_mathint(duration),
            "Genesis vested amount must be the floored linear quotient";
    }
}

/// Recipient recovery cannot alter schedule, bindings, or released accounting.
rule recipientRotationPreservesVestingState(env e, address nextRecipient) {
    require e.msg.sender == recipientAdmin();
    require nextRecipient != 0;
    require nextRecipient != currentContract;

    address staticsBefore = statics();
    address vaultBefore = genesisVault();
    address genesisBefore = genesis();
    address adminBefore = recipientAdmin();
    uint256 startBefore = vestingStart();
    uint256 endBefore = vestingEnd();
    uint256 staticsReleasedBefore = releasedStatics();
    uint256 genesisReleasedBefore = releasedGenesis();

    setWithdrawalRecipient(e, nextRecipient);

    assert withdrawalRecipient() == nextRecipient,
        "recipient rotation must set the requested destination";
    assert statics() == staticsBefore,
        "recipient rotation must preserve the STATICS binding";
    assert genesisVault() == vaultBefore,
        "recipient rotation must preserve the Vault binding";
    assert genesis() == genesisBefore,
        "recipient rotation must preserve the Genesis binding";
    assert recipientAdmin() == adminBefore,
        "recipient rotation must preserve immutable administration";
    assert vestingStart() == startBefore && vestingEnd() == endBefore,
        "recipient rotation must preserve the schedule";
    assert releasedStatics() == staticsReleasedBefore,
        "recipient rotation must preserve released STATICS";
    assert releasedGenesis() == genesisReleasedBefore,
        "recipient rotation must preserve released Genesis";
}

/// Only the immutable recipient admin may sweep retained STATICS surplus.
rule nonAdminCannotSweepSurplus(env e) {
    require e.msg.sender != recipientAdmin();

    sweepStaticsSurplus(e)@withrevert;

    assert lastReverted, "non-admin surplus sweep must revert";
}

/// Elapsed time alone is insufficient: the full STATICS principal must have been released.
rule incompletePrincipalCannotSweepSurplus(env e) {
    require e.msg.sender == recipientAdmin();
    require releasedStatics() != STATICS_VESTING_PRINCIPAL();

    sweepStaticsSurplus(e)@withrevert;

    assert lastReverted, "surplus sweep must wait for actual principal release";
}

/// A successful surplus sweep cannot alter vesting bindings, schedule, destination, or release accounting.
rule successfulSweepPreservesVestingState(env e) {
    require e.msg.sender == recipientAdmin();
    require releasedStatics() == STATICS_VESTING_PRINCIPAL();

    address staticsBefore = statics();
    address vaultBefore = genesisVault();
    address genesisBefore = genesis();
    address adminBefore = recipientAdmin();
    address recipientBefore = withdrawalRecipient();
    uint256 startBefore = vestingStart();
    uint256 endBefore = vestingEnd();
    uint256 staticsReleasedBefore = releasedStatics();
    uint256 genesisReleasedBefore = releasedGenesis();

    sweepStaticsSurplus(e)@withrevert;
    require !lastReverted;

    assert statics() == staticsBefore, "sweep must preserve the STATICS binding";
    assert genesisVault() == vaultBefore, "sweep must preserve the Vault binding";
    assert genesis() == genesisBefore, "sweep must preserve the Genesis binding";
    assert recipientAdmin() == adminBefore, "sweep must preserve immutable administration";
    assert withdrawalRecipient() == recipientBefore, "sweep must preserve its fixed destination";
    assert vestingStart() == startBefore && vestingEnd() == endBefore,
        "sweep must preserve the schedule";
    assert releasedStatics() == staticsReleasedBefore, "sweep must preserve released STATICS";
    assert releasedGenesis() == genesisReleasedBefore, "sweep must preserve released Genesis";
}
