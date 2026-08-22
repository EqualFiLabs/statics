# ADR: Genesis reserve-backed vault, launch epoch, and fixed-supply STATICS policy

- Status: Proposed
- Date: 2026-08-22
- Scope: standalone Genesis Vault backing, Genesis launch epoch, native ETH reserve accounting, Genesis acquisition and redemption pricing, permanent Doppler WETH reserve funding, and STATICS activation monetary policy
- Amends: `doppler-genesis-launch-and-staged-rewards.md`
- Preserves: Doppler Multicurve launch topology, 1,000,000,000 fixed STATICS supply, 800,000,000 public inventory, 200,000,000 treasury allocation, 5,555 fully minted Genesis NFTs, permanent `StaticsFeeReceiver`, permanent `GenesisActivationRegistry`, staged Genesis rewards, transfer-reset activation, and later handoff to the full Statics protocol

## Context

The accepted standalone Genesis architecture launches STATICS through Doppler Multicurve with a fixed 1,000,000,000-token supply and mints all 5,555 Genesis NFTs into `StaticsGenesisVault`.

The current Genesis Vault gives each circulating Genesis a fixed claim on 180,018 STATICS. Its native acquisition fee is treated as withdrawable treasury revenue. Doppler WETH revenue is distributed entirely through the active reward distributor. Genesis activation permanently burns STATICS.

This ADR changes those economics while preserving the existing Doppler launch architecture.

Genesis becomes a fixed-supply, dual-backed asset representing:

```text
180,000 STATICS
+
1 / 5,555 of a native ETH reserve
```

The ETH reserve is permanently capitalized by protocol revenue and other explicit contributions.

Genesis begins with a finite launch epoch during which the ETH reserve already accumulates but is deliberately excluded from Genesis acquisition and redemption pricing. During that period, a Genesis costs exactly 180,000 STATICS and nothing else. When the epoch ends, the complete accumulated ETH reserve becomes economically active and the normal reserve-backed acquisition and redemption rules begin.

This asymmetry is intentional. Early participants accept launch and STATICS price risk in exchange for obtaining reserve exposure before that reserve is reflected in the acquisition price.

The design also eliminates protocol-directed STATICS burning. Fixed supply, Genesis backing, staking, liquidity, treasury inventory, activation payments, and other protocol utility already create productive competition for STATICS without permanent supply destruction.

## Decision summary

The Genesis collection remains permanently fixed at:

```text
N = 5,555 Genesis NFTs
```

The fixed STATICS backing amount becomes:

```text
P = 180,000 STATICS per acquired Genesis
```

Maximum theoretical STATICS backing is therefore:

```text
5,555 * 180,000
= 999,900,000 STATICS
```

against the fixed:

```text
1,000,000,000 STATICS
```

supply. This leaves 100,000 STATICS outside Genesis backing even if every Genesis NFT were simultaneously circulating.

The protocol does not target or require full Genesis circulation. Genesis backing competes economically with staking, liquidity, treasury inventory, activation, and other uses of the same fixed STATICS supply. The collection size is a maximum supply, not a promise that every Genesis will ever leave the vault simultaneously.

STATICS has:

```text
fixed 1,000,000,000 supply
no protocol inflation
no protocol-directed burns
```

Genesis activation payments are transferred 100% to the Statics treasury instead of being destroyed.

## Two independent backing systems

Genesis has two independent backing systems:

```text
STATICS backing
+
native ETH reserve backing
```

These systems intentionally use different accounting denominators.

### STATICS backing

Only Genesis NFTs outside vault inventory require isolated STATICS backing.

```text
requiredStaticsBacking
    = circulatingGenesis * 180,000 STATICS
```

A Genesis acquisition deposits 180,000 STATICS. A Genesis redemption releases 180,000 STATICS.

The vault must always satisfy:

```text
actual STATICS custody >= logical STATICS backing
```

Genesis STATICS backing may never be withdrawn, borrowed, staked, burned, lent, used for liquidity, or distributed as revenue. It exists solely to satisfy Genesis redemption claims.

### ETH reserve backing

The ETH reserve is attributed across the entire fixed Genesis collection. The denominator is always:

```text
5,555
```

It does not depend on circulating Genesis, vault inventory, registered Genesis, or activated Genesis.

A Genesis NFT held by `StaticsGenesisVault` remains one of the fixed 5,555 reserve shares.

For:

```text
R = reserveETH
N = 5,555
```

the current ETH reserve backing per Genesis is:

```text
R / N
```

or:

```text
reserveETH / 5,555
```

Circulating supply determines STATICS backing requirements. It does not determine ETH reserve ownership.

## Explicit reserve accounting

`StaticsGenesisVault` records:

```solidity
uint256 public reserveETH;
```

`reserveETH` is the sole source of truth for Genesis ETH reserve accounting.

Raw `address(this).balance` must not be used as reserve NAV because native currency can be forcibly transferred into a contract without executing protocol accounting.

The vault exposes:

```solidity
function donate() external payable;
```

A successful donation increases `reserveETH` by exactly `msg.value`.

Forced or accidental native ETH that does not execute `donate()` does not increase `reserveETH` and therefore does not alter Genesis reserve NAV.

The vault must satisfy:

```text
address(vault).balance >= reserveETH
```

There is no governance, treasury, guardian, or administrative path capable of withdrawing accounted `reserveETH`.

## Genesis launch epoch

The standalone release begins with a one-time Genesis Epoch.

The epoch has an immutable end timestamp fixed during deployment:

```text
genesisEpochEnd
```

Governance may not extend it, shorten it, restart it, repeat it, or pause its passage.

No keeper, administrator, oracle, or settlement transaction is required to end the epoch. The transition occurs automatically according to:

```text
block.timestamp < genesisEpochEnd
    -> Genesis Epoch pricing

block.timestamp >= genesisEpochEnd
    -> reserve-backed pricing
```

### Purpose of the epoch

The Genesis Epoch creates a finite early-acquisition opportunity.

During the epoch, participants acquire Genesis solely by committing STATICS. They do not pay for the ETH reserve exposure accumulating behind Genesis during that period.

Participants therefore accept early launch risk in exchange for receiving exposure to reserve growth before that reserve becomes part of the acquisition price.

This asymmetry is intentional.

## Reserve accumulation during the Genesis Epoch

The ETH reserve is fully operational from deployment.

During the Genesis Epoch, `reserveETH` may increase through:

```text
Doppler WETH reserve funding
permissionless donate()
future explicitly integrated ETH revenue sources
```

The ETH is held and accounted normally inside `StaticsGenesisVault`. However, reserve value is excluded from both acquisition and redemption pricing until the Genesis Epoch ends.

Nothing is distributed, checkpointed, or moved at epoch end. The already-accounted `reserveETH` simply becomes active in the normal Genesis pricing formulas.

## Genesis Epoch acquisition

While:

```text
block.timestamp < genesisEpochEnd
```

a vault-owned Genesis costs exactly:

```text
180,000 STATICS
```

There is:

```text
no reserve buy-in
no native acquisition fee
```

The phrase "180,000 STATICS" is literal.

A Genesis Epoch acquisition does not modify `reserveETH`. It only:

1. receives exactly 180,000 STATICS;
2. increases logical STATICS backing by exactly 180,000 STATICS; and
3. transfers the selected vault-owned Genesis to the receiver.

The Genesis Epoch therefore provides the only period during which a participant can acquire exposure to the existing Genesis ETH reserve without paying an ETH reserve buy-in.

## Genesis Epoch redemption

While:

```text
block.timestamp < genesisEpochEnd
```

a Genesis redemption returns exactly:

```text
180,000 STATICS
```

No ETH is released.

An epoch redemption therefore reverses the STATICS conversion but does not permit extraction of the still-dormant ETH reserve. `reserveETH` is unchanged by Genesis Epoch redemptions.

This prevents the epoch from becoming an immediate acquire-and-redeem reserve drain while preserving the underlying STATICS redemption claim.

## Epoch transition

At:

```text
block.timestamp >= genesisEpochEnd
```

the complete accumulated ETH reserve becomes economically active.

If the reserve at that moment is `R`, each of the fixed 5,555 Genesis NFTs immediately represents:

```text
R / 5,555 ETH
```

of reserve backing.

No special accounting transition occurs. No reserve value is minted, transferred, allocated, or checkpointed. Acquisition and redemption simply begin consulting the already-existing `reserveETH`.

For example, if:

```text
reserveETH = 5,555 ETH
```

at epoch end, each Genesis immediately has 1 ETH of reserve backing in addition to its 180,000 STATICS claim.

## Intentional early-holder arbitrage

A Genesis holder who acquired during the epoch may redeem immediately after the epoch ends and receive the newly active reserve backing.

This is intentional.

For example, an epoch buyer may pay:

```text
180,000 STATICS
```

while the reserve accumulates. If the epoch ends with:

```text
reserveETH = 5,555 ETH
```

the same Genesis may immediately be redeemed for approximately:

```text
180,000 STATICS
+
1 ETH
```

The resulting ETH profit relative to the Genesis Epoch acquisition price is not considered an exploit, accounting defect, or unintended arbitrage. It is a deliberate reward for taking early Genesis and STATICS launch risk.

The protocol does not impose vesting, redemption delay, cooldown, epoch-holder lockup, or reserve clawback to prevent this behavior.

## Hold-versus-redeem decision

The Genesis Epoch does not require early holders to redeem when reserve backing activates.

After the epoch, each holder faces an ongoing economic choice.

Redeeming realizes:

```text
180,000 STATICS
+
current ETH reserve share
```

but returns the Genesis NFT to vault inventory and therefore gives up exposure to future reserve growth, direct rewards, activation-weighted yield, eligible DEX revenue, and future Genesis utility.

Holding preserves:

```text
180,000 STATICS redemption claim
+
current ETH reserve share
+
future reserve accretion exposure
+
direct reward eligibility
+
activation-weighted staking yield
+
activation-weighted eligible DEX revenue participation
+
future Genesis utility
```

The reserve is intended to receive recurring revenue. Although `reserveETH` is not mathematically monotonic because redemptions withdraw reserve shares, ongoing revenue and future acquisitions can recapitalize and grow it.

The design deliberately creates tension between immediate realization of backing and continued ownership of an asset exposed to future protocol cash flows.

## Post-epoch Genesis acquisition

After:

```text
block.timestamp >= genesisEpochEnd
```

a vault-owned Genesis is acquired by supplying:

```text
180,000 STATICS
+
reserve buy-in
+
native acquisition fee
```

The reserve buy-in must equal the Genesis NFT's reserve backing after the buyer's contribution itself enters the reserve.

Let:

```text
R = reserveETH immediately before acquisition
x = reserve buy-in
N = 5,555
```

Require:

```text
x = (R + x) / N
```

Solving gives:

```text
x = R / (N - 1)
```

Therefore:

```text
reserveBuyIn
    = ceil(reserveETH / 5,554)
```

The implementation rounds upward so integer truncation cannot dilute the reserve. The complete reserve buy-in is added to `reserveETH`.

## Post-epoch acquisition fee

The existing working native acquisition fee remains:

```text
0.003 ETH
```

subject to final production-parameter ratification and the existing immutable maximum-fee policy.

The acquisition fee begins applying only after the Genesis Epoch ends. It is no longer treasury revenue.

The entire acquisition fee is added to `reserveETH` and therefore permanently accretes value to the fixed 5,555 Genesis reserve shares.

During the Genesis Epoch the native acquisition fee is zero.

## Post-epoch purchase slippage

Post-epoch reserve pricing may change between quote and execution because donations may occur, Doppler fees may be harvested, or other reserve sources may contribute.

A purchase must therefore not require exact native input from an earlier quote.

The purchaser supplies a maximum native amount. At execution:

```text
requiredNative
    = current reserveBuyIn
    + current nativeAcquisitionFee
```

The purchase succeeds only when:

```text
msg.value >= requiredNative
```

Any excess is refunded.

This prevents a small reserve contribution from trivially invalidating a pending Genesis purchase.

## Post-epoch Genesis redemption

After the Genesis Epoch, a Genesis owner may return an eligible NFT to the vault and receive:

```text
180,000 STATICS
+
floor(reserveETH / 5,555) ETH
```

The initial implementation charges no redemption fee.

A redemption atomically:

1. calculates the ETH reserve payout from pre-redemption `reserveETH`;
2. transfers the Genesis NFT into vault inventory;
3. decreases logical STATICS backing by exactly 180,000 STATICS;
4. decreases `reserveETH` by exactly the ETH amount paid;
5. transfers 180,000 STATICS to the receiver; and
6. transfers the ETH reserve payout.

Redemption remains available even when new Genesis acquisitions are paused.

## Fixed denominator after redemption

A redeemed NFT remains one of the fixed 5,555 Genesis reserve shares after it returns to vault inventory.

The denominator therefore remains 5,555 after redemption.

As a result, a redemption decreases `reserveETH / 5,555` for all Genesis shares until reserve value is replenished by revenue, donations, or future acquisitions.

This behavior is intentional. The protocol does not use circulating Genesis as the reserve denominator.

## Redemption and reacquisition symmetry

Ignoring integer rounding, acquisition fees, and intervening reserve revenue, a redemption followed by a future reacquisition restores the ETH removed by the redemption.

Starting with `R`, a redemption pays:

```text
R / 5,555
```

leaving:

```text
R' = R - R / 5,555
```

The next post-epoch acquisition requires:

```text
R' / 5,554
```

which equals:

```text
R / 5,555
```

Therefore the reserve buy-in restores the reserve share previously withdrawn.

Implementation rounding is deliberately asymmetric:

```text
acquisition buy-in -> round up
redemption payout  -> round down
```

so rounding dust remains with the reserve.

## Permanent Doppler reserve funding

The standalone STATICS/WETH market uses Doppler's standard Multicurve initializer and Doppler hook.

Statics does not modify Doppler swap execution or impose a custom native fee on individual standalone STATICS/WETH swaps.

Instead, Genesis receives a configurable share of the WETH revenue earned by the permanent `StaticsFeeReceiver`.

The existing Doppler beneficiary split remains:

```text
Doppler / Airlock owner:  5%
StaticsFeeReceiver:      95%
```

The Genesis reserve allocation applies only to WETH inside the Statics 95% beneficiary allocation. It does not apply to fees earned by unrelated external LP positions.

For each successful harvest:

```text
grossWeth
    = WETH actually harvested by StaticsFeeReceiver

reserveWeth
    = floor(grossWeth * reserveShareBps / 10,000)

distributorWeth
    = grossWeth - reserveWeth
```

`reserveWeth` is:

1. unwrapped through canonical WETH;
2. received as native ETH by `StaticsFeeReceiver`; and
3. forwarded to `StaticsGenesisVault.donate()`.

The remaining WETH is attributed through the existing active-distributor accounting.

STATICS-denominated Doppler revenue is not skimmed. It continues through the distributor path unchanged.

## Reserve funding during the Genesis Epoch

Permanent Doppler reserve funding begins immediately. It is not delayed until `genesisEpochEnd`.

Therefore:

```text
Doppler trading during Genesis Epoch
        |
        v
StaticsFeeReceiver
        |
        v
reserve WETH allocation
        |
        v
unwrap to ETH
        |
        v
GenesisVault.donate()
        |
        v
reserveETH increases
```

The resulting ETH remains dormant for Genesis pricing until the epoch ends.

This is a core property of the Genesis Epoch. Early market activity can therefore build reserve value before reserve-backed pricing activates.

## Reserve funding belongs in StaticsFeeReceiver

The WETH reserve split is implemented in permanent `StaticsFeeReceiver`, not temporary `GenesisLaunchDistributor`.

`GenesisLaunchDistributor` is explicitly replaceable when the full Statics reward system accepts future fee distribution. Reserve capitalization must survive distributor rotation and later full-protocol handoff.

The permanent topology is:

```text
Doppler STATICS/WETH market
        |
        v
StaticsFeeReceiver
        |
        +-- STATICS fees
        |       |
        |       v
        |   active distributor
        |
        +-- WETH fees
                |
                +-- reserveShareBps
                |       |
                |       v
                |     unwrap
                |       |
                |       v
                |      ETH
                |       |
                |       v
                |  GenesisVault.donate()
                |
                +-- remainder
                        |
                        v
                 active distributor
```

The receiver should expose cumulative reserve-funding accounting sufficient to verify independently gross WETH harvested, WETH routed to reserve, and WETH attributed to distributors.

## Reserve vault binding

`StaticsFeeReceiver` must exist before Doppler creates the STATICS token. `StaticsGenesisVault` can only be created after the resulting STATICS token address exists.

The Genesis Vault therefore cannot be an immutable receiver-constructor parameter.

The fee receiver instead supports a one-time reserve-vault binding during the standalone deployment.

The binding must:

- accept only a deployed contract;
- verify the vault is paired with the bound STATICS token;
- become permanent after successful configuration; and
- occur before the first active distributor is accepted.

If `reserveShareBps` is nonzero, WETH harvesting must not silently route around an unbound reserve vault.

## WETH unwrap boundary

The reserve holds native ETH, not WETH.

`StaticsFeeReceiver` unwraps only its configured canonical `numeraire`. For the production standalone market that numeraire is canonical WETH.

The fee receiver accepts ordinary native ETH only from canonical WETH during withdrawal.

If either WETH withdrawal or `GenesisVault.donate()` fails, the entire harvest reverts atomically. No partial reserve or distributor accounting may remain.

Canonical production WETH is part of the launch security boundary and must be verified and recorded in the production deployment manifest.

## Launch reward distributor

`GenesisLaunchDistributor` remains the temporary launch reward implementation. It does not understand ETH reserve accounting.

It receives:

```text
all attributed STATICS revenue
+
WETH remaining after the permanent reserve allocation
```

Its existing `genesisRewardShareBps` divides those net assets between registered Genesis reward weight and the Statics treasury.

The permanent ETH reserve and direct launch rewards are intentionally separate economic systems.

A Genesis may therefore have:

```text
fixed STATICS backing
+
ETH reserve backing
+
direct launch rewards
+
activation-based reward multiplier
```

## Activation as yield and DEX-revenue weight

Activation is not cosmetic and is not solely a launch-reward boost.

The permanent `GenesisActivationRegistry` remains the canonical source of activation tier and multiplier state across the standalone launch and later Statics integration.

The activation multiplier is intended to increase the Genesis holder's weight in eligible protocol reward systems, including:

```text
Genesis-linked staking yield
eligible DEX revenue participation
launch-era Genesis rewards where applicable
```

Higher activation therefore requires an additional STATICS commitment while increasing the holder's share of eligible future protocol cash flows.

The exact downstream reward modules may change across the standalone and full-protocol phases, but the semantic rule is preserved: where a Genesis activation multiplier is an accepted reward weight, a higher activation tier receives proportionally greater eligible reward weight.

Owner-changing Genesis transfers continue to reset activation to Tier 0 under the existing activation architecture.

This creates a deliberate economic distinction between holding and activating a Genesis for yield versus transferring or flipping the NFT.

## STATICS monetary policy

STATICS has a fixed maximum supply of:

```text
1,000,000,000
```

Statics protocol contracts do not intentionally destroy STATICS as part of normal protocol economics.

There is:

```text
no protocol inflation
no protocol-directed burn
```

Scarcity instead comes from productive uses including Genesis backing, staking, liquidity, treasury inventory, activation payments, and protocol utility.

These sinks are reversible.

Genesis is specifically an elastic sink:

```text
acquire Genesis
    -> 180,000 STATICS enters isolated backing

redeem Genesis
    -> 180,000 STATICS returns to the holder
```

The protocol does not require permanent destruction to create scarcity.

Underlying token functionality allowing independent holders to voluntarily destroy their own tokens is outside this monetary policy. EqualFi protocol contracts must not invoke that functionality.

## Genesis activation payments

Genesis activation no longer burns STATICS.

The activation tier and multiplier model otherwise remains unchanged.

An activation becomes:

```text
Genesis holder
      |
      | exact STATICS activation payment
      v
GenesisActivationRegistry
      |
      v
Statics treasury
```

One hundred percent of the activation payment is transferred to treasury.

Activation payments do not fund Genesis STATICS backing, fund the Genesis ETH reserve, or reduce STATICS total supply.

Treasury may later use those STATICS for liquidity, market making, integrations, incentives, grants, future EqualFi products, or other governance-approved purposes.

The activation registry removes its burn-specific token dependency. ABI and event terminology must use payment rather than burn terminology.

## Economic consequences

Genesis becomes a fixed-supply asset with several overlapping economic components:

```text
180,000 STATICS redemption claim
permanent native ETH reserve backing
direct/protocol reward utility
activation-weighted staking yield
activation-weighted eligible DEX revenue participation
```

The Genesis Epoch adds a launch-specific component:

```text
early reserve exposure
```

Early participants acquire Genesis before the accumulated reserve is included in its price. At the epoch boundary they receive the economic benefit of the reserve that formed during the launch period.

After the epoch, new buyers must purchase into the existing reserve NAV and no longer receive that reserve exposure for free.

The system therefore transitions from:

```text
Genesis Epoch
    -> speculative early acquisition

Post-Epoch
    -> NAV-aware reserve-backed acquisition
```

without changing the Genesis NFT or migrating holders.

An early holder may immediately redeem the activated reserve value after the epoch, but doing so surrenders the Genesis and therefore future reserve accretion, activation-weighted yield, eligible DEX revenue participation, and future utility.

## Productive STATICS scarcity

The requirement to supply 180,000 STATICS to acquire each Genesis creates a large reversible token sink.

As Genesis circulation increases:

```text
more STATICS enters vault backing
less STATICS remains liquid
```

At the same time STATICS is useful for staking, liquidity, activation, treasury programs, and later protocol utility.

These uses compete for the same fixed 1 billion supply. This competition is intentional.

The protocol does not artificially limit Genesis circulation based on remaining liquid STATICS.

If sourcing another 180,000 STATICS becomes economically unattractive, new Genesis acquisition slows naturally.

If STATICS becomes valuable enough relative to future Genesis reserve and yield exposure, existing holders may redeem and release 180,000 STATICS back into circulation.

## Future reserve growth

Reserve value is expected to receive recurring protocol revenue but is not guaranteed to increase monotonically.

Reserve increases include:

```text
Doppler WETH revenue
post-epoch reserve buy-ins
post-epoch acquisition fees
donations
future EqualFi revenue integrations
```

Reserve decreases include:

```text
post-epoch Genesis redemptions
```

A holder therefore decides whether current redemption value is more valuable than continued exposure to future reserve growth and protocol revenue.

That decision is intentionally left to the market.

## Future Statics integration

This ADR governs the standalone Doppler Genesis launch.

It does not implement native Statics action fees, basket-pool reserve funding, permissionless general-pool reserve funding, or changes to the full Statics swap hook. Those belong to later full-protocol integration.

The permanent reserve integration boundary established by this ADR is:

```solidity
StaticsGenesisVault.donate()
```

Future EqualFi products may capitalize Genesis by contributing native ETH through that interface.

The permanent activation integration boundary remains `GenesisActivationRegistry` and its activation multiplier. Full Statics reward systems may consume that multiplier for eligible staking and DEX-revenue weighting without migrating activation state.

## Required invariants

Implementation and invariant testing must prove at minimum:

```text
Genesis minted supply == 5,555

Genesis ETH reserve denominator == 5,555 at all times

STATICS backing per circulating Genesis == 180,000 STATICS

required STATICS backing
    == circulatingGenesis * 180,000 STATICS

STATICS custody >= logical STATICS backing

native custody >= reserveETH

forced ETH does not modify reserveETH

donate(value) increases reserveETH by exactly value

genesisEpochEnd is immutable

before genesisEpochEnd:
    acquisition requires exactly 180,000 STATICS
    acquisition requires zero native ETH
    acquisition does not modify reserveETH
    redemption returns exactly 180,000 STATICS
    redemption returns zero ETH
    redemption does not modify reserveETH

reserve funding remains fully active during the Genesis Epoch

at block.timestamp >= genesisEpochEnd:
    reserve pricing activates automatically
    no keeper or governance action is required
    the full existing reserveETH becomes active backing

post-epoch single-NFT reserve buy-in
    == ceil(prePurchaseReserve / 5,554)

post-epoch redemption ETH payout
    == floor(preRedemptionReserve / 5,555)

post-epoch acquisition fee enters reserveETH

post-epoch reserve buy-in enters reserveETH

post-epoch redemption reduces reserveETH only by actual ETH paid

no administrative function can withdraw reserveETH

Doppler reserve allocation applies only to WETH

gross harvested WETH
    == reserve-funded WETH + distributor-attributed WETH

STATICS Doppler revenue is unaffected by reserve allocation

activation transfers exact STATICS payment to treasury

activation does not reduce STATICS totalSupply

activation never debits Genesis Vault backing

failed WETH unwrap, reserve donation, acquisition, or redemption reverts atomically without partial accounting
```

Fuzz and invariant testing must cover arbitrary sequences of:

```text
Genesis Epoch acquisitions
Genesis Epoch redemptions
epoch-boundary transitions
post-epoch acquisitions
post-epoch redemptions
reserve donations
Doppler WETH harvests
activation payments
ordinary Genesis transfers
forced ETH
```

Boundary tests must explicitly cover:

```text
block.timestamp == genesisEpochEnd - 1
block.timestamp == genesisEpochEnd
block.timestamp == genesisEpochEnd + 1
```

## Deployment changes

Standalone deployment configuration gains:

```text
genesisEpochEnd or immutable epoch duration
reserveShareBps
```

Production configuration must commit to all economically material launch parameters including:

```text
1,000,000,000 fixed STATICS supply
800,000,000 Doppler inventory
200,000,000 treasury allocation
180,000 STATICS Genesis backing
5,555 Genesis maximum supply
Genesis Epoch duration/end
post-epoch native acquisition fee
reserveShareBps
Genesis direct reward share
Doppler static LP fee
Multicurve configuration
Doppler / Statics beneficiary allocation
```

The production launch hash must include these values.

The deployment sequence must bind `StaticsGenesisVault` into `StaticsFeeReceiver` before the first distributor acceptance can trigger fee harvesting.

Robinhood production deployment remains compile-time locked until the complete production economic configuration is separately reviewed and the exact config hash is ratified.

## Required Robinhood integration proof

The existing real-network Doppler fork proof must be extended to demonstrate:

```text
deploy standalone launch stack

Genesis Epoch active

real V4 swap
    |
    v
Doppler fee accrual
    |
    v
StaticsFeeReceiver harvest
    |
    v
WETH reserve allocation
    |
    v
WETH unwrap
    |
    v
GenesisVault.donate()
    |
    v
reserveETH increases

Genesis Epoch acquisition
    -> costs exactly 180,000 STATICS
    -> receives no reserve charge

advance to epoch end

same accumulated reserve becomes active

post-epoch redemption
    -> returns 180,000 STATICS
    -> returns exact ETH reserve share

post-epoch acquisition
    -> requires current reserve buy-in
```

The proof must also demonstrate that the remaining WETH after the reserve allocation is attributed exactly to the launch distributor.

## Rejected alternatives

### Continue activation burns

Rejected.

Genesis backing, staking, liquidity, treasury inventory, activation utility, and later protocol utility already create productive scarcity. Burning STATICS permanently reduces the supply available to support these uses and removes the ability for supply to return when economic incentives change.

### Use 180,018 STATICS per Genesis

Rejected.

The additional 18 STATICS provides negligible practical benefit and introduces unnecessary user-facing complexity.

The accepted backing amount is:

```text
180,000 STATICS
```

### Divide ETH reserve by circulating Genesis

Rejected.

Vault-owned Genesis NFTs remain members of the fixed 5,555 reserve-share set. Circulating supply determines STATICS backing requirements, not ETH reserve ownership.

### Include reserve NAV in Genesis Epoch acquisition price

Rejected.

The Genesis Epoch intentionally gives early participants access to accumulated reserve exposure without requiring a reserve buy-in. This early-holder advantage is part of the launch design.

### Permit ETH reserve redemption during the Genesis Epoch

Rejected.

The reserve is economically dormant during the epoch. Allowing reserve redemption before the epoch ends would enable participants to extract reserve immediately after acquiring Genesis at the epoch price rather than taking exposure through the complete launch period.

### Add vesting or cooldown after the Genesis Epoch

Rejected.

Immediate post-epoch redemption and realization of accumulated reserve backing is explicitly allowed and intended. Early holders accepted launch risk in exchange for this opportunity.

### Price post-epoch acquisition using reserveETH / 5,555

Rejected.

Because the acquisition contribution itself enters the reserve, the buyer would pay less than the reserve backing of the NFT immediately after purchase.

The self-consistent buy-in is:

```text
ceil(reserveETH / 5,554)
```

### Keep native acquisition fees as treasury revenue

Rejected.

After the Genesis Epoch, acquisition fees permanently capitalize Genesis reserve backing.

### Put reserve WETH routing in GenesisLaunchDistributor

Rejected.

The launch distributor is temporary and replaceable. Reserve funding must survive distributor rotation and full Statics handoff.

### Modify Doppler swap execution

Rejected for the standalone launch.

The standard Doppler fee-beneficiary system already provides a simpler source of permanent reserve funding without requiring a custom hook or router.

## Consequences

Genesis changes from a fixed STATICS redemption NFT into a fixed-supply, dual-backed asset with a permanent native ETH reserve.

The Genesis Epoch creates a finite launch window where Genesis may be acquired for exactly 180,000 STATICS while the reserve accumulates in the background.

At the end of that epoch, the complete accumulated reserve becomes active without migration or settlement.

Early holders may realize that accumulated backing immediately or continue holding for future reserve growth, activation-weighted staking yield, eligible DEX revenue participation, direct rewards, and future utility.

The vault remains intentionally narrow. It understands only:

```text
Genesis NFTs
STATICS
native ETH
time relative to genesisEpochEnd
```

It does not perform swaps, read oracles, convert arbitrary ERC-20 assets, lend, stake, farm yield, or manage market liquidity.

`StaticsFeeReceiver` gains one permanent responsibility beyond its existing Doppler revenue accounting: directing a configured portion of WETH revenue into the Genesis native ETH reserve.

STATICS monetary policy becomes:

```text
fixed 1 billion supply
no protocol inflation
no protocol burns
productive and reversible scarcity
```

The resulting launch architecture establishes Genesis as both an early speculative asset and a long-lived reserve-backed protocol asset while leaving the full Statics system free to add additional ETH reserve revenue sources and activation-weighted reward integrations later.
