ghost mapping(address => mathint) allocatedGhost {
    init_state axiom forall address asset. allocatedGhost[asset] == 0;
}

hook Sstore indexedReceiverAttribution[KEY address asset] uint256 newValue (uint256 oldValue) {
    allocatedGhost[asset] = allocatedGhost[asset]
        + to_mathint(newValue) - to_mathint(oldValue);
}

methods {
    function statics() external returns (address) envfree;
    function numeraire() external returns (address) envfree;
    function indexedReceiverAttribution(address) external returns (uint256) envfree;
    function accountedCustody(address) external returns (uint256) envfree;
    function genesisRewardShareBps() external returns (uint16) envfree;
    function vault() external returns (address) envfree;
    function owner() external returns (address) envfree;
}

/// Ghost accounting independently tracks cumulative receiver attribution.
invariant allocatedGhostMatchesAttribution(address asset)
    allocatedGhost[asset] == to_mathint(indexedReceiverAttribution(asset));

/// The constructor rejects an absent or identical launch pair.
invariant rewardAssetsAreValid()
    statics() != 0 && numeraire() != 0 && statics() != numeraire();

/// Governance can never configure more than 100% of attributed revenue as Genesis rewards.
invariant rewardShareIsBounded()
    genesisRewardShareBps() <= 10000;

/// Every crystallized Genesis reward is either claimable or already claimed.
invariant crystallizedRewardConservation(address asset)
    asset == statics() || asset == numeraire()
        => to_mathint(currentContract._rewardBooks[asset].crystallizedAmount)
            == to_mathint(currentContract._rewardBooks[asset].totalClaimable)
                + to_mathint(currentContract._rewardBooks[asset].totalClaimed);

/// Secured-credit recovery is STATICS-only and cannot alter any numeraire reward ledger.
rule recoveryPreservesNumeraireAccounting(env e, uint256 amount) {
    requireInvariant rewardAssetsAreValid();
    require e.msg.sender == vault();
    address asset = numeraire();
    uint256 attributionBefore = indexedReceiverAttribution(asset);
    uint256 custodyBefore = accountedCustody(asset);
    uint256 indexBefore = currentContract._rewardBooks[asset].indexRay;
    uint256 remainderBefore = currentContract._rewardBooks[asset].indexRemainder;
    uint256 indexedBefore = currentContract._rewardBooks[asset].indexedAmount;
    uint256 crystallizedBefore = currentContract._rewardBooks[asset].crystallizedAmount;
    uint256 claimableBefore = currentContract._rewardBooks[asset].totalClaimable;
    uint256 claimedBefore = currentContract._rewardBooks[asset].totalClaimed;
    uint256 treasuryBefore = currentContract._rewardBooks[asset].treasuryClaimable;

    accrueGenesisRecovery(e, amount);

    assert indexedReceiverAttribution(asset) == attributionBefore,
        "recovery must not change numeraire attribution";
    assert accountedCustody(asset) == custodyBefore,
        "recovery must not change numeraire custody";
    assert currentContract._rewardBooks[asset].indexRay == indexBefore,
        "recovery must not change numeraire index";
    assert currentContract._rewardBooks[asset].indexRemainder == remainderBefore,
        "recovery must not change numeraire remainder";
    assert currentContract._rewardBooks[asset].indexedAmount == indexedBefore,
        "recovery must not change numeraire indexed rewards";
    assert currentContract._rewardBooks[asset].crystallizedAmount == crystallizedBefore,
        "recovery must not change numeraire crystallized rewards";
    assert currentContract._rewardBooks[asset].totalClaimable == claimableBefore,
        "recovery must not change numeraire claimable rewards";
    assert currentContract._rewardBooks[asset].totalClaimed == claimedBefore,
        "recovery must not change numeraire claimed rewards";
    assert currentContract._rewardBooks[asset].treasuryClaimable == treasuryBefore,
        "recovery must not change numeraire treasury rewards";
}

/// Donated-token recovery cannot alter any accounted reward quantity.
rule recoverSurplusPreservesRewardAccounting(
    env e,
    address asset,
    address receiver,
    uint256 amount
) {
    require e.msg.sender == owner();
    require asset == statics() || asset == numeraire();

    uint256 custodyBefore = accountedCustody(asset);
    uint256 attributionBefore = indexedReceiverAttribution(asset);
    uint256 indexedBefore = currentContract._rewardBooks[asset].indexedAmount;
    uint256 crystallizedBefore = currentContract._rewardBooks[asset].crystallizedAmount;
    uint256 claimableBefore = currentContract._rewardBooks[asset].totalClaimable;
    uint256 claimedBefore = currentContract._rewardBooks[asset].totalClaimed;
    uint256 treasuryBefore = currentContract._rewardBooks[asset].treasuryClaimable;

    recoverSurplus(e, asset, receiver, amount);

    assert accountedCustody(asset) == custodyBefore,
        "surplus recovery must not change accounted custody";
    assert indexedReceiverAttribution(asset) == attributionBefore,
        "surplus recovery must not change receiver attribution";
    assert currentContract._rewardBooks[asset].indexedAmount == indexedBefore,
        "surplus recovery must not change indexed rewards";
    assert currentContract._rewardBooks[asset].crystallizedAmount == crystallizedBefore,
        "surplus recovery must not change crystallized rewards";
    assert currentContract._rewardBooks[asset].totalClaimable == claimableBefore,
        "surplus recovery must not change claimable rewards";
    assert currentContract._rewardBooks[asset].totalClaimed == claimedBefore,
        "surplus recovery must not change claimed rewards";
    assert currentContract._rewardBooks[asset].treasuryClaimable == treasuryBefore,
        "surplus recovery must not change treasury rewards";
}
