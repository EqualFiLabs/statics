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
routing. Every PositionNFT with a valid allocation to the funded PoolId for the
funded epoch receives its pro-rata share. Protocol slot 0, reserve accounting,
and creator-funded allocator liabilities remain separate even when their reward
asset is STATICS.

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

A deposit made during epoch N matures in epoch N+1. Finalizing an epoch moves
its distributable budget from available to committed accounting. Each pool's
pro-rata share remains in the reserve custody account until that pool is lazily
activated, when the same reservation moves to its slot-0 account. Claims consume
committed backing. Recycled rewards move both the reservation and accounting
back toward the reserve. No path mints STATICS or promises the same custody
twice.

Governance schedules the weekly release in basis points for the next epoch.
The deployment default is 400 bps and the hard maximum is 1,000 bps. A
finalized epoch records the rate it used, so later changes cannot rewrite its
budget. A scheduled rate becomes the effective current rate at its epoch
boundary even if nobody has called the permissionless epoch checkpoint yet.
Scheduling another future rate first promotes any matured decision, so keeper
timing cannot erase an already-effective governance policy. A not-yet-effective
schedule may still be replaced before its boundary.

## PositionNFT allocations

A PositionNFT owner or approved operator may split the PositionNFT's raw
staked STATICS across at most 16 eligible public PoolIds. Phase 1 uses one
allocated STATICS as one unit of routing weight. Genesis tiers, Operator state,
reward multipliers, prices, volume, TVL, native LP fees, and direct reward
programs do not affect routing weight.

Allocation changes made in epoch N become effective for epoch N+1. A position
may replace its pending allocation repeatedly before that boundary. Each change
updates the affected PoolId checkpoints and one aggregate scheduled-weight
total. There is no global pool list or ranking structure.

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

## Eligibility and abstention

An allocation target must be an initialized, active public range gauge for a
registered general or basket-canonical Statics pool. Permissioned venues are
not eligible. A pool is ineligible while either currency is reward-restricted.

Each allocation records an eligibility version derived from its PoolId and the
restriction nonces of both currencies. Stopping a gauge, decommissioning a
pool, adding a restriction, or changing a restriction version makes that
allocation stale. Its weight remains in the epoch denominator as an abstention,
but its calculated protocol share is recycled instead of being redistributed
to other pools. This makes a restriction incapable of increasing another
pool's reward after the allocation boundary. If eligibility later returns, a
PositionNFT owner must schedule a new valid allocation.

Restriction occurrence sequences are checkpointed cumulatively by epoch. A
pool resolution compares its allocation-time sequence against the latest
sequence before the funded epoch, so an old restriction cannot age out of the
stale-allocation rule. A restriction first applied during the funded epoch
still uses its first timestamp to prorate an already-valid epoch share.

Every nonzero scheduled allocation contributes to the aggregate epoch weight.
There is no minimum allocation, winner cutoff, tie rule, heap, or iteration over
all pools. Pool-specific weight and eligibility are resolved only when that
PoolId is checkpointed.

## Epoch finalization

Epochs are seven days and align to Monday UTC. Anyone may call
`checkpointGaugeEpoch`. Scheduling an allocation also checkpoints a missed
boundary before changing next-epoch weight.

For epoch E:

```text
nominal budget = available reserve * release bps / 10,000
distributable budget = nominal budget * remaining epoch time / one week
pool budget = distributable budget * pool weight / total epoch allocation weight
```

Every PoolId with positive epoch weight has a pro-rata budget, including a pool
with the smallest allocation. Integer division dust remains in the epoch's
unactivated commitment and is recycled when the activation window closes. If
finalization is late, linear remaining-time proration prevents retroactive
emission and leaves the uncommitted portion available.

The finalized epoch stores its activation time, finish, one-extra-epoch
activation deadline, release rate, nominal budget, committed budget,
unactivated budget, and aggregate denominator. A second checkpoint in the same
epoch is a no-op. Finalization performs constant work regardless of pool count.

Pool activation is permissionless and lazy. `checkpointGaugePool` calculates
that PoolId's immutable epoch share and starts slot 0 from the finalized epoch's
original activation time. Ordinary pool swaps, managed-liquidity changes,
claims, and stop paths call the same checkpoint automatically before changing
the pool's economic state. A pool that has no activity can be activated through
the following weekly epoch. After that grace window, anyone may close the epoch,
and any unactivated shares plus rounding dust recycle to the reserve. The epoch
`closed` flag means no further pool shares can be activated; it does not mean
already-started slot-0 liabilities have been claimed or recycled.

## Slot-0 settlement

Protocol slot 0 uses the existing active-range liquidity index. It emits only
while productive managed liquidity is active. Time with zero active liquidity
is accounted as recycled rather than claimable. A reward restriction that
becomes effective during an epoch terminates that pool's protocol stream at the
recorded restriction timestamp and recycles the remaining budget.

Each PoolId settles its prior protocol stream before a later share is activated.
Stopping a gauge, forfeiting slot-0 claims, or reconciling a stopped gauge also
returns the applicable STATICS to the reserve.
If a pool's lifetime slot-0 index capacity cannot accept its complete epoch
share, activation resolves without starting a partial stream and recycles the
whole share. Capacity exhaustion therefore cannot block swaps, LP exits,
claims, or pool decommissioning.
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

- Epoch correctness does not trust a privileged keeper. Epoch finalization,
  per-pool activation, and expiry are permissionless, while ordinary pool use
  activates the relevant PoolId automatically.
- Delayed activation prevents a last-block allocation from earning the epoch
  that just ended.
- Late finalization cannot backdate rewards.
- Direct STATICS incentives remain possible in slots 1 through 4 without
  merging their liabilities with protocol slot 0.
- Creator-directed allocator rewards and protocol routing both use all valid
  PoolId allocations without a winner cutoff.
- The reserve release rate controls spending velocity; product revenue,
  buybacks, treasury transfers, or external contributors control reserve size.
