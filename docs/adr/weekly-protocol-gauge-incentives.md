# ADR: Continuous protocol STATICS gauge incentives

- Status: Accepted
- Date: 2026-09-30
- Scope: Phase 1 public range-gauge incentives and reserve accounting

## Decision

Phase 1 routes a finite, reserve-backed STATICS budget continuously across eligible public range gauges. The reserve spending policy is set in anchored seven-day periods, while pool entitlement accrues by timestamp through cumulative indexes. Keeper timing does not determine who earns rewards.

Each public range gauge has five fixed reward slots:

- slot 0 is permanently reserved for protocol STATICS released from the gauge reserve; and
- slots 1 through 4 are independent, permissionlessly funded LP reward programs. A pool creator may configure a share of each future direct deposit for the PositionNFTs allocating STATICS to that pool.

The direct funding path cannot fund slot 0. The protocol reserve cannot fund allocator rewards. Direct STATICS funding remains available in slots 1 through 4 without merging custody, indexes, or liabilities with slot 0.

## Protocol reserve and release schedule

The Diamond holds real STATICS in a dedicated gauge-reserve custody account. Anyone may fund it after approving the Diamond. Funding grants no allocation weight, claim, governance right, or refund right.

Reserve accounting has three disjoint partitions:

- `available` may fund a future period;
- `deferred` contains deposits and recycled rewards that mature at the next anchored boundary; and
- `committed` backs accounted routing liabilities and slot-0 LP claims.

Governance configures a weekly release in basis points. The deployment default is 400 bps and the hard maximum is 1,000 bps. Governance activates the schedule once. Activation anchors the first seven-day period at the activation timestamp and immediately commits its budget:

```text
periodBudget = floor(available * releaseBps / 10,000)
```

The schedule does not depend on a weekday. If activation occurs on Wednesday, all later boundaries remain Wednesday-aligned.

Within a period, release uses cumulative budget and elapsed-time math:

```text
targetAccounted = floor(periodBudget * elapsed / 7 days)
newlyAccounted = targetAccounted - periodAccounted
```

At the exact finish, `targetAccounted` equals the complete period budget. Fragmenting checkpoints cannot change the total scheduled amount.

Deposits before activation are immediately available. Deposits after activation checkpoint the current schedule first and enter `deferred` for the next boundary. A deposit never changes an already committed period budget. Recycling follows the same boundary rule.

A release-rate change is scheduled for the next anchored boundary. The effective rate for a completed interval cannot be changed by delayed checkpointing. Only one future rate is required because scheduling first catches the schedule up to the current timestamp.

## Bounded lazy rollover

No keeper is required for economic correctness. The first later interaction accounts elapsed time and every crossed boundary from the stored schedule state.

Each call may process at most 52 complete periods. The permissionless `checkpointGaugeSchedule` entry point accepts a caller-selected bound within that limit and may make partial progress. A caller can therefore recover any period of inactivity through bounded calls without an unbounded transaction.

Actions that change weights, policy, funding maturity, or pool eligibility require the schedule to be current after their bounded catch-up attempt. They revert with an explicit catch-up requirement if more work remains. A normal swap with no managed range boundary does not touch this machinery. A boundary-crossing swap processes at most one boundary period and otherwise requires prior permissionless catch-up.

## Persistent PositionNFT allocations

A PositionNFT owner or approved operator may split the PositionNFT's raw staked STATICS across at most 16 eligible public PoolIds. One allocated STATICS is one unit of routing weight. Genesis tiers, Operator state, reward multipliers, prices, TVL, volume, LP fees, and direct reward programs do not affect Phase 1 routing weight.

Allocations persist until changed. A change first settles protocol and creator-funded allocator accounting through the current timestamp under the old weights, then applies the new weights immediately.

The default allocation cooldown is four hours and governance may configure it, including zero. Every positive STATICS stake ingress starts or extends the PositionNFT deadline to the greater of its existing deadline and the current timestamp plus the configured cooldown. This prevents allocation churn from bypassing the cooldown by moving stake into a newly created PositionNFT. Existing allocations remain active while the deadline runs.

During cooldown a PositionNFT may reduce or remove existing allocations, but it may not add a destination, increase an amount, or redirect weight. A permitted allocation change starts a new cooldown only when the previous cooldown has ended. Governance changes are prospective: changing the configured duration does not rewrite an existing deadline, while a later stake ingress uses the new duration without shortening a longer stored deadline. A zero duration permits immediate allocation.

The stake unavailable for voluntary unstaking is the sum of currently valid allocations. The cooldown does not lock unallocated principal, so users explicitly deallocate before unstaking and may withdraw unallocated stake while the routing deadline is active. If an external staking loss or Morpho synchronization reduces the position below its recorded allocation total, an authenticated Diamond self-call checkpoints the affected pools and clears the allocations.

Gauge routing is separate from global reward-asset opt-in. Allocations choose which pools receive protocol liquidity incentives. Global opt-in chooses which reward assets a PositionNFT may earn from protocol fee revenue.

## Continuous routing index

The routing layer maintains a cumulative Q160 reward index over total allocated STATICS. Each checkpoint:

1. accounts the reserve release through the requested timestamp;
2. divides the newly accounted reward by the old total allocation weight;
3. advances the global routing index; and
4. retains numerator carry for later checkpoints.

Each pool stores its current weight, eligibility version, routing-index cursor, and entitlement remainder. Before a pool weight changes, the pool settles through the current global index under its old weight. New weight begins at the current index and cannot inherit historical rewards.

Pool settlement consumes its indexed protocol entitlement in one of two ways:

- an eligible pool with active managed gauge liquidity moves backed STATICS from the reserve account into slot 0 and increases the active-range reward index; or
- an ineligible, stopped, capacity-exhausted, or zero-active-liquidity pool recycles the amount for a future period.

Allocation changes never alter the protocol's total scheduled release. They only route that finite flow. Zero total allocation weight recycles the scheduled amount rather than redistributing it later.

There is no winner cutoff, ranking heap, minimum allocation, or iteration over all pools. Every valid positive pool weight receives its pro-rata share when that PoolId is settled.

## Eligibility and abstention

An allocation target must be an initialized, active public range gauge for a registered general or basket-canonical Statics pool. Permissioned venues are not eligible. A pool is ineligible while either currency is reward-restricted.

Each allocation records an eligibility version derived from its PoolId and both currency restriction nonces. A restriction, gauge stop, or pool decommission makes prior allocations stale. The stale weight remains in the global denominator as abstaining weight, and its indexed share recycles instead of increasing another pool's reward.

Reward restrictions record a monotonic sequence, timestamp, and routing index. A pool valid before a restriction may settle only through the recorded cutoff index. Historical entitlement is preserved while later entitlement recycles. Removing a restriction does not revive stale allocations. A PositionNFT owner must submit a new valid allocation.

## Slot-0 active-range settlement

Protocol slot 0 is an LP-only reward stream. It has no allocator-share setting and no direct funding entry point.

When protocol entitlement is credited, the existing range-gauge global-growth and outside-growth accounting immediately assigns it using the current `activeGaugeLiquidity`. If active liquidity is zero, the entitlement recycles instead of becoming a future windfall.

Every action that can change active managed liquidity checkpoints the pool under the old denominator before mutating topology. For swaps, the immutable callback does no routing work when no managed boundary is crossed. When a boundary is crossed, it:

1. catches up the bounded schedule and settles the pool at the old active liquidity;
2. checkpoints direct LP streams once;
3. flips each crossed boundary's outside-growth state; and
4. applies the resulting active-liquidity change.

Multiple boundaries in one swap share one timestamp and one pre-crossing stream checkpoint. Denominator changes reset only the bounded Q160 numerator carry and do not route creator-funded rewards to treasury.

Slot-0 claims consume committed reserve backing. Forfeited claims and stopped-gauge reconciliation return their STATICS to the reserve and defer it to the next boundary.

## Creator-funded allocator rewards

For each direct slot 1 through 4, the pool creator may set an allocator share from 0 through 10,000 bps. The funder supplies the expected share to protect contribution intent. The Diamond measures actual tokens received and partitions them as:

```text
allocatorAmount = floor(actualReceived * allocatorShareBps / 10,000)
lpAmount = actualReceived - allocatorAmount
```

The LP amount keeps the existing active-range stream. The allocator amount moves to a separate PoolId-and-slot custody account and accrues continuously through its own Q160 pool allocation index. It never enters protocol slot 0 or reserve accounting.

Creator-funded allocator streams use the configured direct-reward duration. A top-up to an active stream preserves its remaining finish; a new or completed stream starts a fresh duration. If pool allocation weight is zero, emission pauses by extending the finish rather than destroying the budget. A new allocator begins at the current index and cannot earn historical emission.

Claims follow current PositionNFT ownership and approval. Earned claims do not expire. If the gauge stops or the pool becomes ineligible, emission ends at the recorded cutoff, earned entitlement remains claimable, and the unvested balance becomes treasury revenue. A 100 percent allocator share creates no LP stream; a zero percent allocator share creates no allocator stream.

## Custody and conservation

Protocol reserve custody, protocol slot-0 custody, direct LP custody, allocator custody, and treasury custody remain distinct accounts.

The accounting preserves these properties:

- the reserve never promises more STATICS than is held and reserved;
- `available + deferred + committed` changes only through funding, commitment, claims, and recycling;
- pool-weight changes cannot rewrite historical routing entitlement;
- denominator changes settle the old denominator first;
- schedule and allocation checkpoint fragmentation cannot increase emissions;
- slot 0 is LP-only and cannot fund allocator rewards;
- creator-funded allocator rewards cannot consume protocol reserve backing; and
- integer rounding can leave bounded dust but cannot create insolvency or checkpoint-frequency extraction.

## Genesis boundary

Gauge routing reads only the Diamond's raw staked STATICS balance. It does not call, configure, or modify the already deployed standalone Genesis and Operator contracts. Phase 1 installs no Genesis multiplier or Operator dependency.

## Operational properties

- Permissionless checkpoints improve freshness but are not trusted for entitlement correctness.
- Ordinary swaps without a managed boundary crossing remain on the minimal market-accounting path.
- A long-inactive schedule is recoverable through bounded permissionless calls.
- Pool restriction and stop paths preserve already-earned claims and recycle later protocol entitlement.
- Direct slots remain economically independent from protocol slot 0.
- Existing active-range liquidity weighting, native Uniswap LP fees, principal exit, managed-position custody, and public-pool fee accounting are unchanged.
