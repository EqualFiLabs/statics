methods {
    function GENESIS_VESTING_PRINCIPAL() external returns (uint256) envfree;
    function VESTING_DURATION() external returns (uint256) envfree;
    function statics() external returns (address) envfree;
    function genesisVault() external returns (address) envfree;
    function genesis() external returns (address) envfree;
    function recipientAdmin() external returns (address) envfree;
    function withdrawalRecipient() external returns (address) envfree;
    function vestingStart() external returns (uint256) envfree;
    function vestingEnd() external returns (uint256) envfree;
    function releasedGenesis() external returns (uint256) envfree;
    function vestedGenesisAt(uint256) external returns (uint256) envfree;
    function sweepStaticsSurplus() external returns (uint256);
}

/// Genesis vesting is linear by integer floor and caps at 555 NFTs.
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
    assert releasedGenesis() == genesisReleasedBefore,
        "recipient rotation must preserve released Genesis";
}

/// Only the immutable recipient admin may sweep retained STATICS surplus.
rule nonAdminCannotSweepSurplus(env e) {
    require e.msg.sender != recipientAdmin();

    sweepStaticsSurplus(e)@withrevert;

    assert lastReverted, "non-admin surplus sweep must revert";
}

/// Bootstrap must bind the STATICS token before surplus recovery is enabled.
rule unbootstrappedCannotSweepSurplus(env e) {
    require e.msg.sender == recipientAdmin();
    require vestingStart() == 0;

    sweepStaticsSurplus(e)@withrevert;

    assert lastReverted, "surplus sweep must wait for bootstrap";
}

/// A successful surplus sweep cannot alter vesting bindings, schedule, destination, or NFT accounting.
rule successfulSweepPreservesVestingState(env e) {
    require e.msg.sender == recipientAdmin();
    require vestingStart() != 0;

    address staticsBefore = statics();
    address vaultBefore = genesisVault();
    address genesisBefore = genesis();
    address adminBefore = recipientAdmin();
    address recipientBefore = withdrawalRecipient();
    uint256 startBefore = vestingStart();
    uint256 endBefore = vestingEnd();
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
    assert releasedGenesis() == genesisReleasedBefore, "sweep must preserve released Genesis";
}
