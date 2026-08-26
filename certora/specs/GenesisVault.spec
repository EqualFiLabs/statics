methods {
    function tokenBacking() external returns (uint256) envfree;
    function reserveETH() external returns (uint256) envfree;
    function genesisEpochEnd() external returns (uint256) envfree;
    function creditServiceReserveShareBps() external returns (uint16) envfree;
    function creditServiceTreasuryShareBps() external returns (uint16) envfree;
    function owner() external returns (address) envfree;
}

/// Governance can select any valid credit-service split, and the stored shares
/// remain exact complements that conserve 100% of the configured allocation.
rule creditServiceFeeSplitIsExact(env e, uint16 reserveShareBps, uint16 treasuryShareBps) {
    require e.msg.sender == owner();
    require to_mathint(reserveShareBps) + to_mathint(treasuryShareBps) == 10000;

    setCreditServiceFeeSplit(e, reserveShareBps, treasuryShareBps);

    assert creditServiceReserveShareBps() == reserveShareBps,
        "reserve fee share must equal the governed value";
    assert creditServiceTreasuryShareBps() == treasuryShareBps,
        "treasury fee share must be the exact complement";
    assert to_mathint(creditServiceReserveShareBps())
            + to_mathint(creditServiceTreasuryShareBps()) == 10000,
        "credit-service fee shares must conserve 100 percent";
}

/// Post-epoch buy-in is exactly ceil(reserve / 5,554) at full uint256 width.
rule postEpochBuyInIsExact(env e) {
    require e.block.timestamp >= genesisEpochEnd();
    uint256 reserve = reserveETH();
    uint256 buyIn = reserveBuyIn(e);

    if (reserve == 0) {
        assert buyIn == 0, "zero reserve must have zero buy-in";
    } else {
        assert to_mathint(buyIn) * 5554 >= to_mathint(reserve),
            "buy-in must cover the reserve quotient";
        assert to_mathint(buyIn - 1) * 5554 < to_mathint(reserve),
            "buy-in must be the least covering quotient";
    }
}

/// Post-epoch payout is exactly floor(reserve / 5,555) at full uint256 width.
rule postEpochRedemptionIsExact(env e) {
    require e.block.timestamp >= genesisEpochEnd();
    uint256 reserve = reserveETH();
    uint256 payout = reserveRedemptionPayout(e);

    assert to_mathint(payout) * 5555 <= to_mathint(reserve),
        "redemption must not over-distribute reserve";
    assert to_mathint(reserve) - to_mathint(payout) * 5555 < 5555,
        "redemption remainder must be below the denominator";
}

/// Governance configuration cannot mutate either backing ledger.
rule governanceConfigurationPreservesBacking(env e, bool paused, uint256 fee) {
    require e.msg.sender == owner();
    require fee <= 10000000000000000;

    uint256 tokenBackingBefore = tokenBacking();
    uint256 reserveBefore = reserveETH();

    setPurchasesPaused(e, paused);
    setNativeAcquisitionFee(e, fee);

    assert tokenBacking() == tokenBackingBefore,
        "governance configuration must not change STATICS backing";
    assert reserveETH() == reserveBefore,
        "governance configuration must not change native reserve accounting";
}
