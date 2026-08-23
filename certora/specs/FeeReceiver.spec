ghost mapping(address => mathint) harvestedGhost {
    init_state axiom forall address asset. harvestedGhost[asset] == 0;
}

hook Sstore cumulativeHarvested[KEY address asset] uint256 newValue (uint256 oldValue) {
    harvestedGhost[asset] = harvestedGhost[asset]
        + to_mathint(newValue) - to_mathint(oldValue);
}

methods {
    function statics() external returns (address) envfree;
    function numeraire() external returns (address) envfree;
    function cumulativeHarvested(address) external returns (uint256) envfree;
    function cumulativeReserveWeth() external returns (uint256) envfree;
    function cumulativeDistributorWeth() external returns (uint256) envfree;
    function cumulativeDistributorAttributed(address, address) external returns (uint256) envfree;
    function distributorClaimable(address, address) external returns (uint256) envfree;
    function totalDistributorLiability(address) external returns (uint256) envfree;
    function owner() external returns (address) envfree;
}

/// The ghost ledger independently tracks every harvested-fee storage update.
invariant harvestedGhostMatchesStorage(address asset)
    harvestedGhost[asset] == to_mathint(cumulativeHarvested(asset));

/// Every harvested WETH unit is assigned either to reserve or distributor.
invariant wethHarvestIsExactlyConserved()
    to_mathint(cumulativeHarvested(numeraire()))
        == to_mathint(cumulativeReserveWeth())
            + to_mathint(cumulativeDistributorWeth());

/// A distributor's current claim cannot exceed its cumulative attribution.
invariant claimableWithinAttribution(address distributor, address asset)
    distributorClaimable(distributor, asset)
        <= cumulativeDistributorAttributed(distributor, asset);

/// Recovering donated surplus never changes accounted distributor liability.
rule recoverSurplusPreservesLiability(
    env e,
    address asset,
    address receiver,
    uint256 amount
) {
    require e.msg.sender == owner();
    uint256 liabilityBefore = totalDistributorLiability(asset);

    recoverSurplus(e, asset, receiver, amount);

    assert totalDistributorLiability(asset) == liabilityBefore,
        "surplus recovery must not consume distributor liabilities";
}
