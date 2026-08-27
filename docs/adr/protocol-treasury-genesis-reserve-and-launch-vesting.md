# ADR: Protocol Treasury Genesis Reserve and Immutable Launch Vesting

- Status: Accepted
- Date: 2026-08-23
- Scope: protocol-owned Genesis reserve, Doppler-native STATICS vesting, immutable Genesis vesting, initial Genesis Vault backing, treasury withdrawal-recipient recovery, launch configuration commitments, and formal-verification requirements
- Extends: standalone Doppler Genesis launch architecture
- Amends: current 200,000,000 STATICS direct treasury allocation and all-5,555-Genesis Vault bootstrap
- Compatible with: Genesis secured credit and full Statics Operators / PositionNFT integration
- Preserves: fixed 1,000,000,000 STATICS supply, 800,000,000 STATICS Doppler inventory, fixed 5,555 Genesis supply, fixed 180,000 STATICS gross backing per circulating Genesis, permanent native ETH reserve denominator, ordinary Genesis ownership semantics, owner-gated reward registration, secured credit, activation, and PositionNFT linkage

## Context

The standalone STATICS launch currently fixes:

```text
STATICS total supply:
1,000,000,000

Doppler Multicurve inventory:
800,000,000

Protocol / treasury allocation:
200,000,000

Genesis supply:
5,555

STATICS backing per circulating Genesis:
180,000
```

The Doppler token factory can mint scheduled allocations into the token contract
itself while minting the non-vested supply to Airlock. Airlock then supplies the
configured inventory to the Multicurve initializer and sends its exact remaining
balance to the configured downstream recipient.

The current Genesis bootstrap separately mints all 5,555 Genesis NFTs to the Genesis Vault.

Genesis has since evolved into a more substantial protocol asset. Each circulating Genesis represents:

```text
180,000 STATICS gross backing
+
1 / 5,555 of the permanent native ETH reserve
+
activation state
+
direct Genesis reward eligibility when registered
+
future PositionNFT linkage
+
global STATICS staking multiplier utility
+
post-epoch secured-credit access
```

The permanent native reserve may grow materially over the life of the protocol. A protocol-owned reserve of Genesis NFTs therefore provides the treasury with exposure to the same permanent Genesis economics available to ordinary holders.

The protocol should acquire this reserve by using part of its already-approved 20% STATICS allocation to fully back the corresponding Genesis NFTs. This must not create additional STATICS allocation, unbacked Genesis NFTs, special treasury-only Genesis economics, automatic Genesis reward participation, or an administrative ability to unlock launch assets early.

## Decision summary

At launch, the protocol will reserve:

```text
555 Genesis NFTs
```

for protocol treasury ownership.

The number represents approximately 9.991% of the fixed 5,555-token collection.

Each protocol Genesis remains backed by exactly 180,000 STATICS. Therefore initial protocol Genesis backing is:

```text
555 * 180,000
=
99,900,000 STATICS
```

The existing 200,000,000 STATICS protocol allocation becomes:

```text
99,900,000 STATICS
    -> irrevocably committed to Genesis Vault backing

100,100,000 STATICS
    -> vested protocol treasury allocation
```

The total economic protocol allocation remains exactly 200,000,000 STATICS. No additional STATICS are created or reassigned from the 800,000,000 STATICS Doppler inventory.

The 555 protocol Genesis NFTs are held by a dedicated immutable vesting/bootstrap
contract. The remaining 100,100,000 liquid STATICS allocation is held and vested
by the pinned `DopplerERC20V1` token itself for the immutable treasury beneficiary.

Conceptually:

```text
1,000,000,000 STATICS
        |
        v
 DopplerERC20V1 initialization
        |
        +-------------------------------+
        |                               |
        v                               v
100,100,000                        899,900,000
token-held native vest             Airlock balance
for treasury                           |
        |                               +------------------+
        |                               |                  |
        v                               v                  v
60-day release                  800,000,000          99,900,000
directly to treasury            Multicurve           bootstrap contract
                                                         |
                                                         v
                                                   Genesis Vault
                                                   initial backing
```

Genesis custody becomes:

```text
5,555 Genesis
      |
      +---------------------+
      |                     |
      v                     v
 #1 - #5000           #5001 - #5555
 Genesis Vault        StaticsTreasuryVesting

 5,000 public         555 protocol Genesis
 acquisition          vested to treasury
 inventory
```

## Protocol-owned Genesis are ordinary Genesis

The protocol-owned 555 NFTs do not form a separate Genesis class.

They use the same ERC-721 contract, 180,000 STATICS backing, native ETH reserve rights, activation system, reward-registration system, secured-credit system, PositionNFT integration, transfer semantics, and redemption semantics as every other Genesis.

No protocol code should branch on a concept of `treasury Genesis` after initialization.

The only special property is their initial custody inside the immutable treasury vesting contract. Once released from vesting, they become indistinguishable at the protocol level from any other circulating Genesis.

## Initial Genesis state

At successful launch finalization:

```text
minted Genesis:              5,555
Genesis Vault inventory:     5,000
Treasury vesting Genesis:      555
circulating Genesis:           555
```

The Genesis Vault must already contain 99,900,000 accounted STATICS backing before the launch is considered finalized.

Therefore:

```text
grossBacking
=
555 * 180,000
=
99,900,000 STATICS

outstandingGenesisCredit = 0

requiredBacking
=
grossBacking - outstandingGenesisCredit
=
99,900,000 STATICS
```

The initial state must satisfy:

```text
tokenBacking == 99,900,000 STATICS
requiredBacking == 99,900,000 STATICS
```

There must be no interval in which the 555 Genesis are circulating while their backing is absent.

## Backing commitment is not vesting

The 99,900,000 STATICS used to back the 555 protocol Genesis are not treasury-liquid assets subject to future release.

They are committed immediately to `StaticsGenesisVault`.

After commitment they are governed entirely by ordinary Genesis Vault economics and may leave the Vault only through valid Genesis lifecycle operations such as redemption, secured-credit principal release, or secured-credit recovery accounting.

The treasury vesting contract has no withdrawal claim over this backing.

## Treasury Genesis vesting and bootstrap contract

Replace the current one-use `StaticsLaunchAllocationEscrow` with a dedicated contract conceptually named:

```text
StaticsTreasuryVesting
```

The exact name may change during implementation.

The contract has four responsibilities:

1. receive the exact post-Doppler 99,900,000-STATICS remainder;
2. commit exactly 99,900,000 STATICS to initial Genesis backing;
3. custody and vest exactly 555 Genesis NFTs; and
4. allow the immutable recipient admin to recover any STATICS accidentally
   retained by or donated to the contract after bootstrap, only to the configured
   withdrawal recipient.

It must not become a general treasury-management contract.

## Immutable vesting economics

The vesting economics are immutable after successful initialization.

At minimum, the following values are fixed:

```text
DOPPLER_NATIVE_STATICS_VESTING_PRINCIPAL = 100,100,000 STATICS
GENESIS_VESTING_PRINCIPAL = 555
GENESIS_FIRST_ID = 5001
GENESIS_LAST_ID = 5555
GENESIS_BACKING_COMMITMENT = 99,900,000 STATICS
VESTING_DURATION = 60 days
```

Neither the Doppler token nor the bootstrap contract may expose governance
functions capable of changing vesting principal, Genesis count, Genesis ID range,
vesting start, vesting duration, vesting formula, amount already released, Genesis
release count, beneficiary, or initial backing commitment.

There is no `accelerate`, `cancel`, `clawback`, `emergencyWithdraw`, `recoverVestedAssetsEarly`, `changeDuration`, `changePrincipal`, or semantic equivalent.

## Vesting start

The STATICS vesting period begins when Doppler initializes the token during Launch.
The Genesis vesting period begins when the bootstrap contract successfully commits
backing and finalizes the Genesis collection during Finalize.

Conceptually:

```text
STATICS vestingStart = successful Doppler token initialization timestamp
Genesis vestingStart = successful bootstrap/finalization timestamp
```

The start is set once and may never be changed.

## STATICS vesting

The liquid treasury STATICS allocation uses one native `DopplerERC20V1` schedule:

```text
beneficiary = configured treasury
scheduleId = 0
cliff = 0
duration = 60 days
amount = 100,100,000 STATICS
```

The Doppler token mints this principal to itself and vests it linearly over 60 days.

For:

```text
P = 100,100,000 STATICS
S = vestingStart
D = 60 days
```

the vested amount is:

```text
timestamp <= S:
    vested = 0

S < timestamp < S + D:
    vested = floor(P * (timestamp - S) / D)

timestamp >= S + D:
    vested = P
```

The releasable amount and released accounting are implemented by the pinned
Doppler token:

```text
releasableSTATICS
=
vestedSTATICS(timestamp) - releasedSTATICS
```

At all times:

```text
releasedSTATICS
<= vestedSTATICS(timestamp)
<= 100,100,000 STATICS
```

## Genesis vesting

The 555 Genesis NFTs vest over the same 60-day period.

Genesis vesting is based on count rather than fractional ownership.

For `N = 555`:

```text
timestamp <= S:
    vestedGenesis = 0

S < timestamp < S + D:
    vestedGenesis = floor(N * (timestamp - S) / D)

timestamp >= S + D:
    vestedGenesis = N
```

At all times:

```text
releasedGenesis
<= vestedGenesis(timestamp)
<= 555
```

Genesis release order is deterministic. The reserve owns Genesis #5001 through Genesis #5555 and releases them in ascending order.

Conceptually:

```text
nextGenesisId = 5001 + releasedGenesis
```

The caller does not select arbitrary Genesis IDs.

## Permissionless release

Release operations should be permissionless.

Any caller may trigger Doppler `releaseFor(treasury, 0, amount)` and
`releaseGenesis(...)`.

The caller never selects the destination. Doppler always sends STATICS to the
immutable treasury beneficiary. The bootstrap contract sends Genesis to its
currently configured `withdrawalRecipient`.

Permissionless release prevents treasury operational availability from becoming a vesting liveness dependency. Calling the release function provides no economic privilege to the caller.

## Genesis release batching

The implementation must not require all currently releasable Genesis NFTs to be transferred in one transaction.

Genesis release should support bounded batching.

For example:

```text
releaseGenesis(maxCount)
```

may release:

```text
min(maxCount, 50, vestedGenesis - releasedGenesis)
```

sequential NFTs. A zero request is invalid, a request above 50 is clamped to 50, and a call when no Genesis is currently releasable reverts.

The exact API may differ. The critical requirements are deterministic release order, no NFT beyond vested count may leave, eventual release of all 555 remains possible, and gas usage remains bounded per transaction.

## Mutable withdrawal recipient

The vesting schedule is immutable, but the final withdrawal address must be recoverable.

A treasury wallet may become compromised. Leaving the withdrawal recipient permanently immutable would expose every future vested release after such a compromise.

Therefore `withdrawalRecipient` is mutable.

`withdrawalRecipient` is the only bootstrap-contract destination variable that
governance may change. It affects Genesis releases and STATICS surplus recovery;
it does not alter Doppler's immutable STATICS beneficiary.

## Governance authority

Withdrawal-recipient changes and post-bootstrap surplus sweeps are guarded by an immutable `recipientAdmin` set to the configured `STATICS_GENESIS_GOVERNANCE` Safe or multisig at deployment.

No vesting-specific timelock, transferable ownership role, or later administrator replacement is introduced. The Safe may evolve its own signers and threshold without changing its address or the vesting contract.

Governance may change `withdrawalRecipient`. After bootstrap, it may also sweep
the bootstrap contract's complete remaining STATICS balance only to that current
recipient.

Governance may not release unvested assets, alter vesting amounts, alter vesting timestamps, alter vesting formulas, change Genesis IDs, withdraw the 99.9M Genesis backing, or choose an arbitrary sweep destination.

The security boundary is:

> Governance controls where vested Genesis and bootstrap-contract surplus go,
> but cannot redirect or accelerate Doppler-native STATICS vesting.

## Withdrawal-recipient compromise recovery

If Treasury Safe A is compromised:

```text
Treasury Safe A compromised
        |
        v
configured governance Safe/multisig
executes withdrawal-recipient change
        |
        v
withdrawalRecipient = Treasury Safe B
```

After execution, future Genesis releases and bootstrap-contract surplus recovery
go to Treasury Safe B. The Doppler-native STATICS beneficiary remains Treasury
Safe A because it is committed in the token initialization payload; changing it
would require a different, explicitly ratified launch design.

## Reward behavior while vested

The vesting contract does not register its 555 Genesis for direct Genesis rewards.

Current and planned Genesis reward systems require explicit actual-owner registration. The vesting contract intentionally exposes no method that performs this registration.

Therefore while held by `StaticsTreasuryVesting`:

```text
registered == false
direct Genesis reward weight == 0
```

The protocol-owned reserve does not dilute the direct Genesis reward pool during vesting.

There is no special reward exclusion implemented for treasury Genesis. They simply remain unregistered.

## Activation while vested

The vesting contract does not activate its Genesis NFTs.

Protocol-owned Genesis remain at their ordinary default activation state while vested. There is no automated activation and no vesting-contract method for purchasing activation tiers.

After release, the treasury may use the ordinary Genesis activation path.

## Secured credit while vested

The vesting contract does not open secured credit against its Genesis NFTs.

Secured-credit origination requires actual Genesis ownership and an explicit owner call. Because `StaticsTreasuryVesting` is the owner and intentionally does not expose a credit-origination path:

```text
protocol Genesis cannot borrow against their backing while vested
```

Their 99,900,000 STATICS backing therefore remains fully retained during the vesting period unless future protocol code violates this stated boundary.

After release, each Genesis uses ordinary secured-credit semantics. No treasury-specific credit rules are introduced.

## PositionNFT integration while vested

The vesting contract does not link its Genesis NFTs to PositionNFTs.

Full Genesis integration requires actual ownership of both the Genesis and PositionNFT. The vesting contract exposes no linkage mechanism.

Therefore while vested:

```text
linkedPosition(genesisId) == 0
```

for the 555 protocol Genesis.

After release, ordinary PositionNFT integration becomes available under the standard ownership and linkage rules.

## Ordinary behavior after release

Once a Genesis has vested and transferred to `withdrawalRecipient`, it becomes an ordinary protocol-owned Genesis.

Treasury may then choose to hold it, transfer or sell it, register it for rewards, activate it, link it to a PositionNFT, use secured credit, or redeem it, subject to the same protocol rules as every other Genesis owner.

There is no permanent protocol restriction arising from its origin in the treasury reserve.

## Treasury reserve economics

The protocol treasury therefore receives at launch:

```text
100,100,000 STATICS
    subject to Doppler-native vesting directly to treasury

555 Genesis
    subject to vesting
    backed by 99,900,000 STATICS
```

This represents exactly 200,000,000 STATICS of launch economic allocation.

The protocol-owned Genesis reserve gives the treasury long-term exposure to 180,000 STATICS backing per Genesis, permanent native reserve value, Genesis market scarcity, future Genesis utility, activation, direct rewards if later registered, PositionNFT utility, and secured-credit liquidity without extracting direct Genesis rewards during the initial vesting period.

If the native reserve grows materially, the treasury may eventually realize that value through ordinary Genesis disposition, redemption, or future utility.

No special treasury claim over the native reserve is created. The treasury owns ordinary Genesis NFTs that possess ordinary reserve rights.

## Maximum Genesis backing remains unchanged

This decision does not alter the maximum Genesis STATICS sink.

If all remaining 5,000 public Genesis are acquired:

```text
public Genesis backing:
5,000 * 180,000
=
900,000,000 STATICS

initial protocol Genesis backing:
555 * 180,000
=
99,900,000 STATICS

total:
999,900,000 STATICS
```

Therefore the theoretical maximum remains 999,900,000 of 1,000,000,000 STATICS backing circulating Genesis.

Only the initial distribution of that backing changes.

## STATICS surplus

Launch execution verifies in the same transaction that Airlock sent exactly
99,900,000 STATICS to the bootstrap contract, retained zero STATICS, and left
exactly 100,100,000 STATICS inside the token's native vesting custody. This binds
the intended split without relying on a later balance observation.

Finalization accepts bootstrap custody greater than or equal to 99,900,000
STATICS so an unsolicited donation cannot block the launch. It transfers exactly
99,900,000 STATICS into accounted Genesis backing and leaves any excess as
unaccounted surplus. Surplus never increases `tokenBacking`, either vesting
principal, vested amounts, or released counters. After bootstrap, only
`recipientAdmin` may sweep the complete remaining bootstrap-contract balance to
the current `withdrawalRecipient`; later donations remain recoverable through
another sweep.
## Bootstrap sequence

The launch ceremony must preserve atomic correctness.

Conceptually:

```text
1. Deploy launch receivers and treasury vesting contract.

2. Launch STATICS through Doppler Airlock.

3. DopplerERC20V1 mints 100.1M STATICS to itself under the immutable
   treasury schedule and 899.9M STATICS to Airlock.

4. Airlock transfers exactly 800M STATICS to the Multicurve initializer
   and the exact 99.9M remainder to StaticsTreasuryVesting.

5. Launch execution verifies the native schedule, exact token and bootstrap
   custody, and zero Airlock balance before returning.

6. Deploy Genesis Vault and permanent Genesis infrastructure.

7. Deploy StaticsGenesis:
       #1-5000    -> Genesis Vault
       #5001-5555 -> StaticsTreasuryVesting

8. StaticsTreasuryVesting verifies collection custody and at least
   99.9M STATICS custody.

9. StaticsTreasuryVesting transfers exactly
   99.9M STATICS -> Genesis Vault.

10. Any STATICS above the fixed 99.9M backing commitment remains
   in StaticsTreasuryVesting as unaccounted surplus.

11. Genesis Vault records exactly
    99.9M initial tokenBacking.

12. Genesis Vault verifies:
        mintedSupply == 5555
        vault inventory == 5000
        circulating == 555
        requiredBacking == 99.9M
        tokenBacking == 99.9M
        custody >= tokenBacking

13. Genesis launch finalizes.

14. Genesis vesting start becomes immutable; Doppler-native STATICS vesting
    has already started at Launch.

15. Bootstrap authority is permanently removed.

16. The immutable configured governance Safe becomes the only
    authority capable of changing withdrawalRecipient or sweeping
    bootstrap-contract surplus.
```

Exact ordering may be adjusted during implementation to accommodate deterministic deployment and constructor dependencies. The required post-condition may not change.

## Genesis Vault bootstrap changes

`StaticsGenesisVault` currently expects all Genesis NFTs to begin in Vault custody.

This decision replaces that requirement.

Finalization must instead validate the intended split:

```text
mintedSupply == 5,555
Genesis Vault balance == 5,000
Treasury vesting balance == 555
```

and the exact initial backing:

```text
tokenBacking == 99,900,000 STATICS
```

The implementation must not allow arbitrary initial circulation counts or arbitrary bootstrap backing amounts. These are fixed launch economics.

## Circulating Genesis definition remains unchanged

No treasury-specific exception is introduced into `circulatingGenesis`.

The existing semantic definition remains:

```text
minted Genesis - Genesis held by Vault
```

Therefore the 555 Genesis owned by the vesting contract are ordinary circulating Genesis.

This is intentional. Their presence automatically creates the corresponding backing obligation.

## Interaction with secured credit

Genesis secured credit changes required physical backing according to:

```text
grossBacking
=
circulatingGenesis * 180,000 STATICS

requiredBacking
=
grossBacking - totalOutstandingGenesisCredit
```

At launch:

```text
circulatingGenesis = 555
grossBacking = 99,900,000
totalOutstandingGenesisCredit = 0
requiredBacking = 99,900,000
```

The treasury vesting mechanism does not require a new secured-credit accounting branch.

Once a Genesis vests and ordinary secured credit is opened against it, the canonical secured-credit state machine adjusts retained backing normally.

## Interaction with full Genesis integration

The full Statics Operators integration introduces direct Genesis reward registration, Genesis <-> PositionNFT linkage, Genesis activation-driven staking multipliers, and permanent StaticsFeeReceiver successor distribution.

The treasury vesting reserve remains outside those systems while it owns the 555 Genesis.

It does not register Genesis, link Genesis, stake through PositionNFT, activate Genesis, or claim Genesis rewards.

After release, those ordinary capabilities become available.

The vesting reserve therefore requires no special integration into `GenesisNFTFacet`.

## Launch configuration hash

These new economics are production launch commitments and must be included in the reviewed launch configuration hash.

The hash should commit at minimum to semantic equivalents of:

```text
TREASURY_GENESIS_COUNT = 555
TREASURY_GENESIS_FIRST_ID = 5001
TREASURY_GENESIS_LAST_ID = 5555
TREASURY_GENESIS_BACKING = 99,900,000 STATICS
DOPPLER_NATIVE_STATICS_VESTING_PRINCIPAL = 100,100,000 STATICS
DOPPLER_NATIVE_STATICS_VESTING_BENEFICIARY = treasury
DOPPLER_NATIVE_STATICS_VESTING_CLIFF = 0
TREASURY_VESTING_DURATION = 60 days
withdrawal recipient
immutable governance Safe / multisig authority
maximum Genesis release batch = 50
```

If any additional vesting parameter affects asset availability, it must also be included.

The production-approved Robinhood launch hash remains zero until the final launch configuration is independently reviewed and ratified.

## Required invariants

Implementation and verification must establish at minimum:

1. STATICS total supply remains exactly 1,000,000,000.
2. Doppler target inventory remains exactly 800,000,000.
3. Protocol economic allocation remains exactly 200,000,000 STATICS.
4. Initial protocol Genesis count is exactly 555.
5. Initial public Vault inventory is exactly 5,000 Genesis.
6. Protocol Genesis IDs are exactly 5001 through 5555.
7. Initial Genesis backing commitment is exactly 99,900,000 STATICS.
8. Doppler-native treasury STATICS vesting principal is exactly 100,100,000 STATICS.
9. `initial tokenBacking == initial requiredBacking == 99,900,000 STATICS`.
10. No circulating protocol Genesis exists without its required initial backing.
11. Bootstrap-contract surplus cannot increase native treasury vesting principal.
12. Surplus cannot increase `tokenBacking`.
13. Doppler-released STATICS never exceeds Doppler-vested STATICS.
14. Released Genesis count never exceeds vested Genesis count.
15. STATICS vesting never exceeds 100,100,000.
16. Genesis vesting never exceeds 555.
17. At native vest completion exactly 100,100,000 STATICS are releasable/released in aggregate.
18. At vest completion exactly 555 Genesis are releasable/released in aggregate.
19. Genesis are released only in deterministic ascending order.
20. No Genesis outside IDs 5001-5555 can be released by the vesting contract.
21. Changing `withdrawalRecipient` cannot alter Genesis or Doppler vesting accounting.
22. Changing `withdrawalRecipient` cannot redirect native STATICS or make additional assets immediately vested.
23. Only the immutable configured governance Safe/multisig may change `withdrawalRecipient` or sweep surplus.
24. Governance has no path to withdraw unvested native STATICS.
25. Governance cannot withdraw unvested Genesis.
26. Bootstrap-contract surplus cannot be swept before successful bootstrap.
27. An authorized sweep transfers the complete remaining STATICS balance only to the current `withdrawalRecipient`.
28. Governance cannot modify vesting duration, start, or principal.
29. Governance cannot recover the 99.9M Vault backing through the vesting contract.
30. Permissionless native STATICS release always pays the immutable treasury;
    permissionless Genesis release always pays the current withdrawal recipient.
31. Repeated release calls cannot double-release assets.
32. Genesis held by the vesting contract remain unregistered for direct rewards.
33. Genesis held by the vesting contract cannot originate secured credit through the vesting contract.
34. Genesis held by the vesting contract cannot link to a Position through the vesting contract.
35. Vesting completion does not itself register, activate, borrow against, or link a Genesis.
36. After release, a Genesis follows ordinary protocol semantics with no treasury-specific branch.

## Formal verification

The existing Genesis formal-verification framework should be extended rather than replaced.

The current escrow proof becomes obsolete because the former property:

```text
200M STATICS -> treasury immediately
```

is intentionally removed.

The replacement formal targets should prove the Genesis vesting/bootstrap
contract and initial Vault state. The pinned Doppler implementation's native
vesting behavior is exercised by the official-module fork proof rather than
duplicated as a local custom vesting model.

### Vesting conservation

Prove:

```text
Doppler vestedTotalAmount == 100,100,000 STATICS
Doppler totalAllocatedOf(treasury) == 100,100,000 STATICS
Doppler vestingOf(treasury, 0).totalAmount == 100,100,000 STATICS
```

subject only to explicit exact-transfer assumptions.

For Genesis:

```text
releasedGenesis
+
Genesis still held by vesting contract
=
555
```

before considering impossible or explicitly unmodeled unsolicited NFT behavior.

### Time bounds

For arbitrary timestamp:

```text
Doppler releasedSTATICS <= Doppler vestedSTATICS(timestamp)
releasedGenesis <= vestedGenesis(timestamp)
```

### Governance isolation

For arbitrary valid withdrawal-recipient changes:

```text
vestingStart unchanged
vestingDuration unchanged
STATICS principal unchanged
Genesis principal unchanged
released counters unchanged
vested amount unchanged for same timestamp
```

Only `withdrawalRecipient` may differ.

### Bootstrap solvency

Immediately after launch finalization prove:

```text
circulatingGenesis == 555
grossBacking == 99,900,000 STATICS
outstandingGenesisCredit == 0
requiredBacking == 99,900,000 STATICS
tokenBacking == 99,900,000 STATICS
Vault STATICS custody >= tokenBacking
```

Then preserve the existing Genesis Vault solvency theorem under subsequent valid lifecycle transitions.

### Reward inactivity

Prove or regression-test that the vesting bootstrap does not register the protocol-owned Genesis.

The proof need not claim that the vesting contract is incapable of interacting with every future protocol extension. It must establish that the deployed contract exposes no current path that registers Genesis rewards, activates Genesis, opens Genesis credit, or links Genesis to a Position.

## Required tests

At minimum, add real-flow coverage for:

```text
fresh launch
    -> 800M Multicurve inventory
    -> exact 99.9M bootstrap balance
    -> 99.9M Vault backing
    -> exact 100.1M Doppler-native vesting principal for treasury
    -> zero Airlock balance
    -> 5000 Genesis Vault
    -> 555 Genesis vesting
```

```text
timestamp == each vestingStart
    -> 0 Doppler-native STATICS releasable
    -> 0 Genesis releasable
```

```text
mid-vesting
    -> exact expected Doppler-native STATICS vested
    -> exact floor Genesis count vested
```

```text
timestamp == vestingEnd
    -> full 100.1M Doppler-native STATICS vested
    -> all 555 Genesis vested
```

```text
repeated release
    -> no double release
```

```text
Genesis batch release
    -> deterministic ascending IDs
```

```text
request batch > releasable
    -> only releasable count transferred
```

```text
governance Safe changes withdrawalRecipient
    -> future Genesis release and surplus recovery go to new recipient
    -> Doppler-native STATICS beneficiary remains treasury
    -> previously released accounting unchanged
```

```text
non-admin attempts recipient change
    -> revert
```

```text
recipient changed at multiple timestamps
    -> vesting quantity unaffected
```

```text
arbitrary pre-bootstrap STATICS surplus
    -> bootstrap succeeds
    -> not included in 100.1M vest
    -> not classified as 99.9M backing
    -> retained for post-bootstrap admin recovery
```

```text
surplus sweep before bootstrap
    -> revert

surplus sweep after bootstrap
    -> only recipientAdmin
    -> complete balance to current withdrawalRecipient
```

```text
Treasury Genesis during vest
    -> not registered for rewards
    -> no reward weight
```

```text
Treasury Genesis after vest
    -> ordinary reward registration works
```

```text
Treasury Genesis during vest
    -> no credit facility exists
```

```text
Treasury Genesis after vest
    -> ordinary secured credit works
```

```text
Treasury Genesis during vest
    -> unlinked
```

```text
Treasury Genesis after vest
    -> ordinary PositionNFT linkage works
```

## Deployment changes

The launch deployer must be updated to:

- replace `StaticsLaunchAllocationEscrow` with the treasury vesting/bootstrap contract;
- bind the immutable configured governance Safe/multisig as `recipientAdmin`;
- bind the initial withdrawal recipient;
- encode one zero-cliff 60-day Doppler-native allocation of 100.1M STATICS to treasury;
- route the exact 99.9M Airlock post-sale remainder to the bootstrap contract;
- deploy Genesis with the 5,000 / 555 custody split;
- seed the Genesis Vault with exactly 99.9M STATICS;
- initialize Vault backing accordingly;
- retain any donated STATICS above the backing commitment for post-bootstrap recovery;
- start native STATICS vesting at Launch and Genesis vesting after successful bootstrap;
- remove bootstrap authority permanently;
- include all fixed treasury-reserve economics in `launchConfigHash`;
- expose the vesting contract in deployment manifests and SDK/configuration surfaces where appropriate.

No production deployment is authorized by this ADR.

## Verification documentation

The formal-verification property ledger must be updated.

Remove or supersede the old property:

```text
Escrow release sends exactly 200M STATICS
to treasury and cannot repeat
```

with the new properties covering initial 99.9M Vault commitment, the exact
Doppler-native 100.1M treasury schedule, 555 Genesis vesting conservation,
time-bounded release, recipient-rotation isolation, and initial Vault solvency.

Any existing proof whose assumptions rely on:

```text
initial circulatingGenesis == 0
```

must be rerun or rewritten against:

```text
initial circulatingGenesis == 555
```

## Documentation changes

Update the relevant launch, Genesis, deployment, and treasury documentation to describe:

```text
5,000 public Genesis launch inventory
555 protocol-owned Genesis reserve
99.9M initial Genesis backing
100.1M liquid protocol STATICS allocation
60-day immutable vesting
60-day Genesis vesting
Safe-guarded withdrawal-recipient recovery
```

Public-facing language should distinguish `protocol allocation` from `immediately liquid treasury tokens` because the protocol does not receive 200M freely transferable STATICS at launch under this design.

After all 555 Genesis have been released and no surplus remains, the bootstrap
contract is economically inert except that later accidental STATICS donations
remain recoverable. Doppler's token contract independently completes the 100.1M
native STATICS vest.

## Security rationale

The design reduces launch trust assumptions.

Instead of:

```text
200M STATICS
    -> immediately liquid treasury
```

the protocol receives:

```text
99.9M STATICS
    -> irrevocably committed Genesis backing

100.1M STATICS
    -> immutable 60-day vest

555 fully backed Genesis
    -> immutable 60-day vest
```

The immutable governance Safe retains recovery authority over the withdrawal destination but cannot accelerate the economic schedule.

This allows the protocol to credibly state that the launch allocation cannot be dumped immediately through either liquid STATICS or protocol-owned Genesis NFTs, even if treasury operators or governance wished to do so.

## Out of scope

This ADR does not define treasury trading strategy, when treasury should sell Genesis, when treasury should redeem Genesis, whether treasury should later register Genesis for rewards, whether treasury should activate Genesis, whether treasury should use secured credit, whether treasury should link Genesis to PositionNFTs, treasury market-making policy, treasury voting policy, additional vesting after the initial 60 days, team allocations, advisor allocations, employee vesting, or investor allocations.

Those are treasury or governance policy questions rather than launch-solvency requirements.

## Rejected alternatives

### Send all 200M STATICS directly to treasury

Rejected.

This provides no onchain assurance against immediate disposal and fails to recognize the strategic value of protocol-owned Genesis.

### Mint 555 protocol Genesis without backing them

Rejected.

Every circulating Genesis must represent the same 180,000 STATICS gross backing relationship. Protocol ownership does not justify weaker solvency.

### Vest the 99.9M Genesis backing over 60 days

Rejected.

The 555 Genesis become circulating claims immediately. Their full required backing must therefore be present before launch finalization.

### Give protocol Genesis special reward-exclusion logic

Rejected.

Genesis rewards are opt-in through owner registration. The vesting contract simply does not register its NFTs. No second Genesis class is necessary.

### Make protocol Genesis permanently ineligible for rewards

Rejected.

After vesting they are ordinary Genesis NFTs. The treasury or a later buyer may register them under the standard rules.

### Allow governance to accelerate vesting

Rejected.

This would weaken the primary credibility benefit of the vesting architecture.

### Add an emergency withdrawal

Rejected.

An emergency withdrawal capable of extracting unvested assets is functionally an administrative vesting bypass. Compromise recovery is handled by changing the withdrawal recipient instead.

### Make the withdrawal recipient immutable

Rejected.

A compromised treasury wallet would otherwise receive every future vested release. The destination may change through the immutable configured governance Safe without changing vesting economics.

### Give the treasury wallet authority over the vesting contract

Rejected.

Compromise of the treasury should not compromise future vesting custody. Administrative authority belongs to the immutable configured governance Safe/multisig and is limited to withdrawal-recipient rotation.

### Allow arbitrary Genesis release order

Rejected.

Sequential deterministic release is simpler, less discretionary, easier to test, and easier to formally verify.

### Use separate vesting contracts for STATICS and Genesis

Rejected unless implementation constraints prove otherwise.

Both assets arise from the same fixed protocol launch allocation and use the same vesting period and destination. A single narrowly scoped custody contract provides a clearer launch commitment and formal-verification boundary.
