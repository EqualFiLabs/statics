# ADR: Robinhood production STATICS launch parameters

- Status: Proposed for economic ratification
- Date: 2026-08-22
- Scope: Robinhood Chain production parameters for the standalone STATICS Doppler Multicurve launch, Genesis Epoch distribution, Doppler fee rate, launch-position revenue allocation, and production Multicurve price-discovery profile
- Amends: `doppler-genesis-launch-and-staged-rewards.md`
- Amends: `genesis-reserve-backed-vault.md`
- Preserves: fixed STATICS supply, Genesis backing model, ETH reserve model, Doppler Multicurve topology, permanent `StaticsFeeReceiver`, Genesis launch distributor architecture, activation system, and production launch-config hash requirement

## Context

The standalone Genesis architecture launches STATICS through a permanent Doppler Multicurve STATICS/WETH market.

Existing architecture fixes:

```text
STATICS total supply        = 1,000,000,000
Doppler public inventory    =   800,000,000
Statics treasury allocation =   200,000,000

Genesis maximum supply      = 5,555
Genesis STATICS backing     = 180,000 STATICS
```

During the Genesis Epoch, a vault-owned Genesis may be acquired for exactly:

```text
180,000 STATICS
```

with:

```text
no native reserve buy-in
no native acquisition fee
```

Meanwhile, the permanent ETH reserve is already allowed to accumulate from qualifying protocol revenue.

At the end of the Genesis Epoch, the accumulated reserve becomes active Genesis backing.

The production launch therefore has several simultaneous objectives:

1. make Genesis economically accessible during the Genesis Epoch;
2. encourage substantial STATICS trading and price discovery;
3. avoid allowing a large fraction of STATICS supply to be acquired at effectively zero valuation;
4. capitalize the Genesis ETH reserve from real market activity;
5. provide direct launch rewards and treasury capitalization;
6. preserve meaningful permanent STATICS/WETH liquidity at valuations far above the opening market; and
7. allow early participants substantial upside without giving them an unreasonable fraction of supply for negligible capital.

## Decision summary

The production launch should begin with an intentionally low opening STATICS valuation.

The target opening economics are:

```text
180,000 STATICS ~= $20 of WETH
```

which corresponds approximately to:

```text
STATICS price ~= $0.000111
FDV           ~= $111,000
```

The USD values in this ADR are economic modeling references only.

The actual Doppler market is WETH-denominated. Exact production ticks must therefore be derived from a reviewed WETH-denominated launch price using an ETH/USD reference selected near launch.

There is no protocol oracle maintaining the USD valuation after deployment.

## Why the opening valuation is intentionally low

Genesis is intended to enter meaningful circulation during the Genesis Epoch.

A multi-million-dollar initial FDV would cause the 180,000 STATICS requirement to make Genesis unnecessarily expensive before the market has produced meaningful price discovery.

For example:

| STATICS FDV | Value of 180,000 STATICS |
|---:|---:|
| $111k | ~$20 |
| $250k | $45 |
| $500k | $90 |
| $1M | $180 |
| $2M | $360 |
| $5M | $900 |
| $10M | $1,800 |
| $100M | $18,000 |
| $1B | $180,000 |

This progression is intentional.

Genesis begins as an accessible speculative and protocol-participation asset.

If STATICS succeeds, the exact same fixed 180,000-STATICS requirement naturally makes additional Genesis acquisition increasingly expensive.

## No privileged Genesis acquisition

The low opening valuation must not be implemented through:

```text
founder discounts
private Genesis allocations
whitelists
special-price Genesis mints
off-market STATICS allocations
```

All participants acquire the required STATICS through ordinary market availability or existing holdings.

Early access arises from public market timing, not privileged pricing.

## Sniping policy

The production launch accepts that sophisticated participants may attempt to acquire STATICS immediately after market creation.

The protocol does not attempt to eliminate this behavior through access controls.

Instead, protection comes from Multicurve inventory design.

The launch must satisfy:

```text
very low opening price
+
small amount of inventory available near opening price
+
rapid marginal price appreciation
```

The unacceptable outcome is not:

```text
an early participant receives an excellent price
```

The unacceptable outcome is:

```text
an early participant can acquire a structurally significant
fraction of total STATICS supply for negligible capital
```

The Multicurve must therefore constrain low-valuation inventory.

## Target Multicurve distribution

The current production modeling target is:

| Region | Approximate modeled FDV range | STATICS inventory | Share of Doppler inventory |
|---|---:|---:|---:|
| Launch access | $100k -> $500k | 20M | 2.5% |
| Genesis discovery | $250k -> $2M | 60M | 7.5% |
| Early | $1M -> $10M | 100M | 12.5% |
| Core | $5M -> $100M | 160M | 20.0% |
| Growth | $50M -> $1B | 340M | 42.5% |
| Permanent tail | $1B -> maximum practical tick | 120M | 15.0% |
| **Total** | | **800M** | **100%** |

These are economic targets, not yet the final `Multicurve` structs.

The exact production configuration still requires:

```text
tickLower
tickUpper
numPositions
shares
```

for every curve.

The final permanent tail should follow Doppler's documented tail pattern: one position beginning exactly where the preceding growth curve ends and extending to the maximum practical tick.

## Intentional overlap

The target regions before the permanent tail overlap.

This is deliberate.

Overlapping curves provide smoother liquidity composition as STATICS appreciates and avoid hard economic cliffs between distinct valuation regimes.

The production curve should not behave as a sequence of isolated bonding-curve stages.

The permanent tail is the exception: it begins at the growth curve's terminal $1B modeling target rather than overlapping it.

## Opening inventory constraint

Only:

```text
20,000,000 STATICS
```

or:

```text
2.5% of public Doppler inventory
2.0% of total STATICS supply
```

is targeted for the true launch-access region.

Twenty million STATICS represents only:

```text
20,000,000 / 180,000
~= 111 Genesis backing units
```

if every token from the band were immediately placed into Genesis backing.

This creates meaningful early accessibility without exposing hundreds of millions of STATICS at the opening valuation.

## Genesis discovery inventory

The first two target regions contain:

```text
20M + 60M = 80M STATICS
```

or approximately:

```text
444 Genesis backing units
```

This creates room for hundreds of Genesis NFTs to enter circulation while the market remains relatively early.

The protocol does not guarantee that this number of Genesis NFTs will be acquired.

STATICS purchased in these regions may instead remain liquid, be traded, activated, staked, supplied as liquidity, or used for other protocol purposes.

## Permanent tail

The final Multicurve allocation should contain approximately:

```text
120,000,000 STATICS
```

or:

```text
15% of Doppler public inventory
12% of total STATICS supply
```

in a single long-duration tail beginning at the modeled $1B FDV endpoint of the preceding growth curve and extending toward the maximum practical Uniswap price range.

This leaves:

```text
680,000,000 STATICS
```

or 85% of Doppler public inventory participating in the launch, discovery, early, core, and growth regions below the tail.

The purpose of the tail is not short-term fundraising and it is not intended to warehouse an excessive fraction of public inventory above $1B.

It exists to preserve original protocol launch liquidity if STATICS appreciates through valuations such as:

```text
$1B
$2B
$5B
$10B
and beyond
```

The production configuration must not create an artificial terminal valuation comparable to the current nonproduction filler curve.

STATICS reaching $1B FDV must not require exhausting the original 800M Doppler inventory, but the protocol also should not unnecessarily withhold a third or more of public inventory from sub-$1B price discovery.

## Doppler swap fee

The current production candidate is:

```text
STATICS_DOPPLER_FEE = 15,000
```

corresponding to:

```text
1.5%
```

This parameter is proposed but not yet finally ratified.

The fee applies to swaps through the Doppler pool in both directions.

The rationale for considering a materially higher fee than a conventional mature-token market is that launch trading is also a capitalization mechanism.

Fees support:

```text
Genesis ETH reserve capitalization
Genesis direct rewards
Statics treasury capitalization
permanent protocol revenue
```

The fee must nevertheless remain low enough that price discovery, arbitrage, secondary liquidity, and speculative turnover remain viable.

Before final ratification, at minimum the following candidates should be compared:

```text
0.50%
1.00%
1.50%
3.00%
```

The current preference is:

```text
1.50%
```

## Doppler beneficiary split

The permanent Doppler launch-position beneficiary split remains:

```text
Doppler / Airlock owner = 5%
StaticsFeeReceiver      = 95%
```

This ADR does not change that topology.

## Genesis reserve share

The proposed production reserve parameter is:

```text
STATICS_GENESIS_RESERVE_SHARE_BPS = 5,000
```

or:

```text
50%
```

of WETH harvested by `StaticsFeeReceiver`.

Only WETH revenue receives this reserve split.

The reserve portion is:

```text
unwrapped to native ETH
        |
        v
StaticsGenesisVault.donate()
```

and permanently capitalizes the Genesis ETH reserve.

STATICS-denominated Doppler revenue is not routed into the ETH reserve and continues through the active distributor.

## Genesis launch reward share

The proposed production launch-distributor parameter is:

```text
STATICS_GENESIS_REWARD_SHARE_BPS = 5,000
```

or:

```text
50%
```

of revenue attributed to `GenesisLaunchDistributor`, subject to registered Genesis reward weight.

The remaining attributed revenue belongs to the Statics treasury.

## Effective WETH fee distribution

With:

```text
Doppler owner share      = 5%
Statics beneficiary      = 95%
Genesis reserve share    = 50%
Genesis reward share     = 50% of distributor remainder
```

gross WETH launch-position fee revenue is economically divided approximately as:

```text
Doppler / Airlock       5.00%
Genesis ETH reserve    47.50%
Genesis rewards        23.75%
Statics treasury       23.75%
```

subject to integer rounding and Genesis reward-weight availability.

## Effective STATICS fee distribution

STATICS-denominated launch-position fees do not receive a reserve skim.

They therefore divide approximately as:

```text
Doppler / Airlock       5.00%
Genesis rewards        47.50%
Statics treasury       47.50%
```

again subject to Genesis reward-weight availability.

## Genesis Epoch capitalization loop

The launch is intentionally designed around the following feedback loop:

```text
WETH buys STATICS
       |
       +--> STATICS market price rises
       |
       +--> Doppler WETH fees accrue
       |         |
       |         v
       |    Genesis ETH reserve
       |
       v
user acquires Genesis
       |
       v
180,000 STATICS enters isolated backing
       |
       v
liquid STATICS supply contracts
       |
       v
additional market pressure / trading / price discovery
```

The ETH reserve remains economically dormant for Genesis acquisition and redemption during the Genesis Epoch.

At:

```text
block.timestamp >= genesisEpochEnd
```

the accumulated reserve becomes active backing under the already accepted reserve-backed Genesis architecture.

## Early-holder economics

An early Genesis participant accepts:

```text
STATICS launch risk
market volatility
smart-contract risk
liquidity risk
Genesis utility uncertainty
```

in exchange for the possibility of:

```text
very low initial Genesis acquisition cost
STATICS appreciation
launch reward participation
dormant ETH reserve accumulation
future reserve exposure
activation-weighted protocol yield
future Genesis utility
```

At epoch end an early holder may immediately redeem and realize:

```text
180,000 STATICS
+
current ETH reserve share
```

or continue holding.

Immediate post-epoch redemption remains intentional and is not treated as an exploit.

## Reserve capitalization objective

The protocol does not target a predetermined ETH reserve balance.

Instead, reserve capitalization should emerge from real market activity.

For a proposed 1.5% Doppler fee and current 95% / 50% WETH routing:

```text
gross WETH buy-side volume
    * 1.5%
    * 95%
    * 50%
```

is routed into the Genesis ETH reserve.

Therefore approximately:

```text
0.7125% of qualifying WETH-side volume
```

capitalizes Genesis.

This is before considering future non-Doppler reserve revenue sources.

## Genesis as an elastic STATICS sink

The fixed:

```text
180,000 STATICS
```

backing requirement is preserved.

The launch does not reduce this coupling to make Genesis issuance easier.

Genesis acquisition removes liquid STATICS:

```text
100 Genesis   ->  18M STATICS backing
500 Genesis   ->  90M STATICS backing
1,000 Genesis -> 180M STATICS backing
2,000 Genesis -> 360M STATICS backing
```

Redemption releases the same STATICS back into circulation.

Genesis therefore acts as a large reversible monetary sink rather than a burn mechanism.

## Genesis Epoch duration

The exact production value of:

```text
STATICS_GENESIS_EPOCH_END
```

remains TBD.

It must be separately ratified.

The selected duration should be long enough to permit:

```text
meaningful Genesis distribution
meaningful STATICS trading
meaningful reserve capitalization
organic price discovery
```

without keeping reserve backing dormant for an unnecessarily long period.

The timestamp remains immutable once deployed.

## Production Multicurve implementation requirement

The approximate valuation regions in this ADR must not be inserted directly into production configuration without simulation.

Doppler Multicurve positions allocate equal token amounts per position and space positions in tick space.

Because tick space is logarithmic in price, broad valuation ranges can produce unintuitive distribution behavior.

The final configuration must therefore be simulated using the actual upstream Doppler formulas.

At minimum, the ratification report must calculate:

```text
opening STATICS price

cost of 180,000 STATICS at launch

cumulative STATICS released at:
    $250k FDV
    $500k
    $1M
    $2M
    $5M
    $10M
    $25M
    $50M
    $100M
    $250M
    $500M
    $1B
    $2B
    $5B
    $10B

cumulative WETH absorbed at each milestone

marginal and average acquisition price

remaining Doppler inventory at each milestone
```

The same simulation must calculate the effect of common trade sizes during the opening region.

## Required opening-price tests

The final production configuration should specifically model:

```text
$20
$50
$100
$250
$500
$1,000
```

as target values for 180,000 STATICS.

For each target, the model should report:

```text
current STATICS FDV
cumulative WETH input
cumulative STATICS distributed
remaining low-band inventory
maximum Genesis backing units represented by distributed STATICS
```

This provides a direct view of Genesis Epoch accessibility.

## No production deployment before ratification

Robinhood production deployment remains blocked until the exact economic configuration has been reviewed.

The final launch configuration hash must bind all material production values, including:

```text
fixed STATICS supply
Doppler public inventory
treasury allocation
Genesis backing
Genesis maximum supply
Genesis Epoch end
post-epoch native acquisition fee
Doppler swap fee
Doppler beneficiary split
Genesis reserve share
Genesis reward share
exact Multicurve configuration
metadata commitments
```

The existing deployment script currently leaves:

```text
APPROVED_ROBINHOOD_LAUNCH_CONFIG_HASH = bytes32(0)
```

specifically so production cannot proceed before this economic ratification.

## Parameters proposed for ratification

```text
STATICS_SUPPLY
    1,000,000,000 STATICS

DOPPLER_INVENTORY
    800,000,000 STATICS

TREASURY_ALLOCATION
    200,000,000 STATICS

GENESIS_MAX_SUPPLY
    5,555

GENESIS_BACKING
    180,000 STATICS

OPENING_GENESIS_STATICS_VALUE_TARGET
    approximately $20 of WETH

OPENING_FDV_MODEL_TARGET
    approximately $100k-$125k

DOPPLER_OWNER_SHARE
    5%

STATICS_FEE_SHARE
    95%

STATICS_DOPPLER_FEE
    proposed: 15,000 / 1.5%
    final ratification pending

STATICS_GENESIS_RESERVE_SHARE_BPS
    proposed: 5,000 / 50%

STATICS_GENESIS_REWARD_SHARE_BPS
    proposed: 5,000 / 50%

POST_EPOCH_NATIVE_ACQUISITION_FEE
    0.003 ETH

STATICS_GENESIS_EPOCH_END
    TBD

MULTICURVE_PERMANENT_TAIL
    proposed: 120,000,000 STATICS / 15% of Doppler inventory
    modeled start: $1B FDV
    one position to maximum practical tick

MULTICURVE
    exact ticks and positions TBD following simulation
```

## Rejected alternatives

### Begin at multi-million-dollar FDV

Rejected as the current preferred direction.

A high opening valuation makes the fixed 180,000-STATICS Genesis backing requirement expensive before the market has established meaningful demand or protocol activity.

### Make Genesis backing cheaper

Rejected.

The 180,000-STATICS coupling is retained.

Genesis accessibility should come from launch price discovery, not weakening the long-term backing relationship.

### Expose large inventory near $100k FDV

Rejected.

A low starting valuation is acceptable only if low-price inventory is tightly constrained.

### Eliminate sniping through permissioned access

Rejected.

The market should remain public and permissionless.

Economic curve design is preferred over privileged access.

### Allocate 35% of Doppler inventory to the permanent tail

Rejected.

A 280M-STATICS tail would withhold too much of the public inventory from sub-$1B price discovery, especially because Genesis acquisition itself can remove large amounts of STATICS from liquid circulation.

A 15% tail preserves substantial permanent high-valuation liquidity while leaving 85% of the public Doppler allocation available through the pre-tail launch curve.

### Exhaust Doppler inventory near $1B FDV

Rejected.

A permanent liquidity tail is preferred so the original launch market can remain economically relevant at much larger valuations.

### Route STATICS fees into the ETH reserve

Rejected for the standalone launch.

The reserve remains native ETH backed.

WETH revenue may be unwrapped into the reserve while STATICS-denominated revenue remains available to the distributor.

## Consequences

The resulting launch intentionally begins at a very low nominal valuation while limiting the supply available at that valuation.

Early participants can obtain Genesis for relatively little capital.

Meaningful purchases rapidly move the market into higher valuation regions.

Genesis acquisition removes STATICS from liquid circulation.

Doppler trading produces protocol revenue.

WETH-side fee revenue capitalizes a dormant ETH reserve.

At epoch end, that reserve becomes active Genesis backing.

The launch therefore combines:

```text
price discovery
Genesis distribution
reversible STATICS scarcity
fee generation
ETH reserve capitalization
direct rewards
treasury capitalization
permanent liquidity
```

inside one market process.

Before changing the production launch hash, the target bands in this ADR must be converted into exact Doppler Multicurve ticks and position counts and validated using the actual upstream Doppler math.