# ADR: Weekly protocol STATICS gauge incentives

- Status: Accepted
- Date: 2026-09-24
- Scope: Phase 1 public range-gauge incentives and reserve accounting

## Decision

Phase 1 adds a reserve-backed weekly STATICS incentive to the existing public
range gauges. The system extends the range-gauge engine rather than creating a
second LP reward system.

Each public gauge has five fixed reward slots:

- slot 0 is permanently reserved for protocol STATICS committed by the weekly
  routing system; and
- slots 1 through 4 remain ordinary direct reward programs that any funder may
  use, including a separate directly funded STATICS program. A pool creator may
  direct a configured share of each future deposit to PositionNFT allocators.

The direct funding path cannot fund slot 0. Protocol allocation does not modify
the asset, duration, or liabilities of any directly funded slot.

## Creator-directed allocator rewards

Each direct slot has a creator-controlled allocator share from 0 through 10,000
bps. Zero preserves a pure active-range LP stream. The setting applies
immediately to future deposits and never rewrites an existing LP stream or an
already funded allocator budget. A funder supplies the expected share and target
epoch with `fundPoolReward`; a changed setting or weekly boundary reverts the
contribution instead of silently changing its economics.

The Diamond measures the tokens actually received and partitions that amount:

```text
allocator amount = floor(actual received * allocator share / 10,000)
LP amount = actual received - allocator amount
```

The LP amount retains the slot's active-range emission semantics. The allocator
amount is reserved for the next weekly epoch in a separate PoolId, slot, and
epoch custody account. A 100% allocator share creates no LP stream and therefore
does not apply the LP stream's minimum remaining-duration check.

Allocator rewards use the same raw STATICS allocation signal as protocol
routing, but they do not use the top-ten filter. Every PositionNFT with a valid
allocation to the funded PoolId for the funded epoch receives its pro-rata
share. Protocol slot 0, reserve accounting, and creator-funded allocator
liabilities remain separate even when their reward asset is STATICS.

Allocation and aggregate-pool checkpoints are recorded by effective epoch.
Changing or removing an allocation in a later epoch cannot rewrite an earlier
funded epoch. Claims follow current PositionNFT ownership and approval. A
PositionNFT that is closed before claiming forfeits no protocol principal; its
unclaimed reward eventually expires to treasury.

Anyone may finalize a direct-slot allocator budget after its funded epoch ends.
If the pool has zero valid weight, became ineligible before the epoch, or was
stopped before the epoch, the full allocator amount routes to treasury. A
mid-epoch reward restriction or gauge stop prorates the distributable amount to
the eligible portion of the week and routes the remainder to treasury. Claims
expire 26 epochs after the funded epoch. Expiry routes abandoned claims and
integer-division dust to treasury. Direct funders receive no refund and budgets
never roll forward.

Restriction ordering uses a monotonic occurrence sequence in addition to the
first restriction timestamp retained for proration. Repeated or same-block
restriction cycles after funding therefore invalidate the future budget rather
than relying on timestamp ordering.

## Reserve

The Diamond holds real STATICS for protocol gauge rewards in a dedicated
custody account. Anyone may call `fundGaugeReserve` after approving the
Diamond. Funding grants no routing weight, claim, or governance right.

Reserve accounting has three disjoint partitions:

- `available` may back a future epoch;
- `deferred` contains deposits or same-epoch recycling that mature for a later
  epoch; and
- `committed` backs active or claimable slot-0 liabilities.

A deposit made during epoch N matures in epoch N+1. Committing a budget moves
accounting from available to committed and moves the same physical reservation
from the reserve account to the winning pool's slot-0 account. Claims consume
committed backing. Recycled rewards move both the reservation and accounting
back toward the reserve. No path mints STATICS or promises the same custody
twice.

Governance schedules the weekly release in basis points for the next epoch.
The deployment default is 400 bps and the hard maximum is 1,000 bps. A
finalized epoch records the rate it used, so later changes cannot rewrite its
budget.

## PositionNFT allocations

A PositionNFT owner or approved operator may split the PositionNFT's raw
staked STATICS across at most 16 eligible public PoolIds. Phase 1 uses one
allocated STATICS as one unit of routing weight. Genesis tiers, Operator state,
reward multipliers, prices, volume, TVL, native LP fees, and direct reward
programs do not affect routing weight.

Allocation changes made in epoch N become effective for epoch N+1. A position
may replace its pending allocation repeatedly before that boundary. The routing
heap always represents the scheduled weight for the next checkpoint.

The stake that cannot be unstaked is:

```text
max(valid active allocation total, valid pending allocation total)
```

Users therefore deallocate before voluntarily unstaking. If an external
staking loss or Morpho synchronization reduces the position below that lock,
the Diamond clears the position's gauge allocations through an authenticated
self-call rather than leaving the position unable to exit.

Gauge routing is separate from global reward-asset opt-in. Allocations choose
which pools receive protocol incentives. Global opt-in chooses which assets a
PositionNFT is eligible to earn.

## Eligibility and ranking

An allocation target must be an initialized, active public range gauge for a
registered general or basket-canonical Statics pool. Permissioned venues are
not eligible. A pool is ineligible while either currency is reward-restricted.

Each allocation records an eligibility version derived from its PoolId and the
restriction nonces of both currencies. Stopping a gauge, decommissioning a
pool, adding a restriction, or changing a restriction version makes its stored
weight stale. Any account may call `refreshGaugePoolWeight` to remove stale
weight. Removed weight is not restored automatically if eligibility later
returns; a PositionNFT owner must schedule a new valid allocation.

All nonzero scheduled pool weights live in an indexed max heap. Each allocation
change updates at most 16 entries with logarithmic heap work. Epoch
finalization reads only the ten highest entries plus a bounded frontier and
never iterates every protocol pool. Higher weight wins. Equal weights use the
numerically lower PoolId first, producing deterministic ties.

If a winning entry is stale, finalization fails closed and identifies the PoolId
that must be refreshed. This avoids silently awarding an ineligible pool while
keeping cleanup permissionless.

## Epoch finalization

Epochs are seven days and align to Monday UTC. Anyone may call
`checkpointGaugeEpoch`. Scheduling an allocation also checkpoints a missed
boundary before changing next-epoch weight.

For epoch E:

```text
nominal budget = available reserve * release bps / 10,000
distributable budget = nominal budget * remaining epoch time / one week
pool budget = distributable budget * pool weight / sum(top-ten weights)
```

Only the top ten form the denominator. Pools below tenth receive no protocol
STATICS for that epoch. Integer division dust remains available in the reserve.
If finalization is late, linear remaining-time proration prevents retroactive
emission and leaves the uncommitted portion available.

The finalized epoch stores its winners, weights, budgets, activation time,
finish, release rate, nominal budget, committed budget, and denominator. A
second checkpoint in the same epoch is a no-op.

## Slot-0 settlement

Protocol slot 0 uses the existing active-range liquidity index. It emits only
while productive managed liquidity is active. Time with zero active liquidity
is accounted as recycled rather than claimable. A reward restriction that
becomes effective during an epoch terminates that pool's protocol stream at the
recorded restriction timestamp and recycles the remaining budget.

At the next epoch checkpoint, the previous winners are settled before new
budgets are committed. Stopping a gauge, forfeiting slot-0 claims, or
reconciling a stopped gauge also returns the applicable STATICS to the reserve.
Ordinary checkpoints preserve the range-gauge numerator carry. A genuine
active-liquidity denominator change resets only a Q160 fraction smaller than
`2^-32` of one raw token unit and does not immediately recycle any slot-0
STATICS. The LP portions of slots 1 through 4 keep their existing emission,
forfeiture, and treasury reconciliation behavior. Their allocator portions use
the separate fixed-epoch claim lifecycle above.

## Genesis boundary

The weekly routing system reads only the Diamond's raw staked STATICS balance.
It neither calls nor configures the already deployed standalone Genesis and
Operator contracts. Future governance may introduce a separately reviewed
weight formula, but Phase 1 does not require or install that integration.

## Operational properties

- Epoch correctness does not trust a privileged keeper. Finalization and stale
  weight cleanup are permissionless.
- Delayed activation prevents a last-block allocation from earning the epoch
  that just ended.
- Late finalization cannot backdate rewards.
- Direct STATICS incentives remain possible in slots 1 through 4 without
  merging their liabilities with protocol slot 0.
- Creator-directed allocator rewards pay every valid allocator to the PoolId,
  independent of whether that pool ranks in the protocol top ten.
- The reserve release rate controls spending velocity; product revenue,
  buybacks, treasury transfers, or external contributors control reserve size.
