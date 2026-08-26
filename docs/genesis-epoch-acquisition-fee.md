# Genesis Epoch Acquisition Fee

## Purpose

Restore the native Genesis acquisition fee during the Genesis Epoch while preserving the epoch subsidy that waives the reserve buy-in.

This change must land before the formal-verification PR so the verification suite proves the final launch behavior.

## Intended economics

During the Genesis Epoch:

- Genesis price remains exactly `180,000 STATICS`.
- `reserveBuyIn` remains `0`.
- `nativeAcquisitionFee` is charged.
- The acquisition fee is added 100% to `reserveETH`.
- Redemption continues to return exactly `180,000 STATICS` and `0 ETH` while the epoch is active.

After the Genesis Epoch:

- Genesis price remains exactly `180,000 STATICS`.
- `reserveBuyIn` is charged using the existing post-epoch formula.
- `nativeAcquisitionFee` is charged.
- Both the reserve buy-in and acquisition fee are added to `reserveETH`.

The intended purchase formulas are therefore:

```text
Genesis Epoch:
180,000 STATICS + nativeAcquisitionFee

Post-Epoch:
180,000 STATICS + reserveBuyIn + nativeAcquisitionFee
```

The epoch subsidy is the waived reserve buy-in, not a waived acquisition fee.

## Required contract changes

### `StaticsGenesisVault.buyGenesis`

The acquisition fee must no longer depend on epoch state.

Conceptually, replace behavior equivalent to:

```solidity
uint256 buyIn;
uint256 fee;
if (!epochActive_) {
    buyIn = _reserveBuyIn(reserveETH);
    fee = nativeAcquisitionFee;
}
```

with behavior equivalent to:

```solidity
uint256 buyIn = epochActive_ ? 0 : _reserveBuyIn(reserveETH);
uint256 fee = nativeAcquisitionFee;
```

Do not introduce a second epoch-specific fee variable. Continue using the existing governed `nativeAcquisitionFee` and existing maximum.

The existing reserve accounting should remain authoritative: the acquisition fee permanently accretes to `reserveETH` during both epoch states.

### `StaticsGenesisVault.quoteGenesisPurchase`

During the epoch, the quote must report:

- `reserveBuyIn == 0`
- `nativeFee == nativeAcquisitionFee`
- `requiredNative == nativeAcquisitionFee`
- `epochActive == true`

After the epoch, existing reserve-buy-in behavior remains unchanged.

## Documentation changes

Update the Genesis launch and reserve-backed-vault documentation wherever it currently states or implies that Genesis Epoch acquisition requires no native currency.

The docs should explicitly state:

> During the Genesis Epoch, the reserve buy-in is waived, but the normal native acquisition fee still applies. The acquisition fee permanently capitalizes the Genesis native reserve.

Do not change the rule that Genesis Epoch redemption pays no ETH.

## Unit and integration tests

Update all tests that currently encode zero native cost during the epoch.

Required coverage:

1. Epoch purchase quote has zero reserve buy-in and nonzero configured acquisition fee.
2. Epoch `requiredNative` equals `nativeAcquisitionFee`.
3. Epoch purchase succeeds when exactly the acquisition fee is supplied.
4. Epoch purchase increases `reserveETH` by exactly the acquisition fee.
5. Epoch purchase reverts when native value is below the required acquisition fee.
6. Epoch purchase refunds excess native value.
7. Governance changes to `nativeAcquisitionFee` are reflected in epoch quotes and purchases.
8. Epoch redemption continues to return zero ETH and does not reduce `reserveETH`.
9. Post-epoch acquisition behavior remains unchanged: reserve buy-in plus acquisition fee both accrete to the reserve.

Rename tests whose names currently encode `NoNative` or equivalent behavior.

## Formal verification changes

The formal-verification branch currently asserts that the Genesis Epoch native fee and required native amount are both zero. Those assertions must be updated before the formal PR is considered valid for launch.

At minimum, the epoch quote property should prove:

```text
reserveBuyIn == 0
nativeFee == nativeAcquisitionFee
requiredNative == nativeAcquisitionFee
```

Preserve the existing post-epoch buy-in and redemption arithmetic properties.

Add or update a property showing that an epoch acquisition increases accounted native reserve by exactly the acquisition fee while maintaining vault solvency.

## PR stack integration

This PR is intentionally stacked on `feat/genesis-treasury-vesting` / PR #45.

Implementation should be completed on this branch or a successor branch based on it.

After the acquisition-fee implementation and tests are complete:

1. Rebase or retarget PR #41 (`feat/genesis-formal-verification`) onto the completed acquisition-fee branch.
2. Update Halmos and any affected Certora harness/spec assumptions.
3. Rerun the complete formal and Foundry validation suite.
4. Do not merge #41 while it still proves zero native acquisition fee during the Genesis Epoch.

## Non-goals

This change does not alter:

- the fixed `180,000 STATICS` Genesis backing amount;
- the post-epoch reserve buy-in formula;
- the post-epoch reserve redemption formula;
- the Genesis Epoch rule that redemption pays no ETH;
- secured-credit service fee routing;
- Doppler fee routing;
- activation fee routing;
- the governed acquisition-fee maximum.

## Acceptance criteria

The change is complete when all of the following are true:

- Genesis Epoch purchases require `180,000 STATICS + nativeAcquisitionFee`.
- Genesis Epoch reserve buy-in remains zero.
- The acquisition fee is fully added to permanent `reserveETH`.
- Genesis Epoch redemption still pays no ETH.
- Quotes, unit tests, integration tests, documentation, and formal properties all describe the same behavior.
- PR #41 is rebased/retargeted onto the completed implementation and its proofs pass against the corrected behavior.
