# ADR: Statics market tape and permanent swap callback

- Status: Accepted
- Date: 2026-09-27
- Scope: Phase 1 public and permissioned pool telemetry

## Decision

Phase 1 fixes the hook-to-Diamond callback as:

```solidity
afterStaticsPoolSwap(
    PoolId poolId,
    BalanceDelta poolDelta,
    uint256 staticsFeesPacked,
    uint8 flags
)
```

The hook sends only information that cannot be reconstructed after the swap. `poolDelta` is the raw
PoolManager delta and `staticsFeesPacked` contains the exact Statics fee for currency0 in the low
128 bits and currency1 in the high 128 bits. Flags identify direction, exact-output public swaps,
permissioned pools, internal normalization, and partial fills. The Diamond reads the final tick and
current native Uniswap LP fee rate directly from PoolManager.

Public and permissioned pools keep static native Uniswap v4 fees in Phase 1. Dynamic-fee PoolKeys,
hook factories, and pool migration belong to a separately reviewed future pool version. The callback
leaves room for those systems without making Phase 1 pools depend on them.

## Telemetry layers

Market telemetry has three deliberately separate layers:

1. Canonical MarketTape state is gapless, swap-critical, and cumulative. It is the authoritative
   onchain state for lifetime counters and the canonical sequence.
2. `MarketSwapRecorded` is the granular event tape. The Diamond emits exactly one event after every
   successful canonical record using the same sequence. It is suitable for offchain full-history
   reconstruction without correlating separate protocol events.
3. The historical observation ring is bounded, cadence-based, replaceable, and fail-open. It is a
   convenience layer for recent onchain analytics, not the authoritative granular history.

The Diamond emits:

```solidity
event MarketSwapRecorded(
    PoolId indexed poolId,
    uint256 indexed sequence,
    BalanceDelta poolDelta,
    uint256 staticsFeesPacked,
    int24 finalTick,
    uint24 nativeLpFee,
    uint8 flags
);
```

`poolId` and `sequence` are indexed because they are the primary venue and ordering keys. The event
preserves the signed PoolManager delta instead of duplicating derived absolute volumes. It also
preserves the authenticated packed Statics fees rather than expanding them into separate event
words. The remaining fields record final execution state and classification facts. Block metadata
provides the timestamp, so the event does not duplicate it.

The dispatcher emits the event after hook authentication, pool registration and hook consistency
checks, the final PoolManager state read, and successful canonical recording. It emits before public
range synchronization and the fail-open observation attempt. Any later swap-critical range failure
rolls back the entire swap, canonical record, and event together. A stopped gauge still emits the
event, and an observation failure does not remove it from a successful transaction.

Permissioned external trades and internal normalization are distinct canonical records with
consecutive sequences and distinct events. Internal records carry the internal flag and do not enter
headline external volume. The permissioned hook executes normalization inside the outer swap's fee
routing before it records the outer swap. When normalization occurs, the nested internal record is
therefore sequence N and the external record is sequence N+1. The event tape preserves that actual
execution order rather than presenting a synthetic order. Consumers can group the records by
transaction and distinguish them with the internal flag.

## Canonical MarketTape state

`LibMarketTape` records gapless per-PoolId counters for:

- external volume in currency0 and currency1;
- internal permissioned normalization volume in currency0 and currency1;
- exact Statics fees in currency0 and currency1;
- external and internal swap counts;
- a monotonic record sequence;
- tick cumulative, last tick, last timestamp, current native LP fee rate in pips, and last flags; and
- saturation flags for lifetime counters.

The counters use unsigned 256-bit saturation. A lifetime counter that reaches its maximum remains at
that maximum and marks its field instead of reverting every future swap. Tick accumulation is bounded
by the 40-bit timestamp domain and Uniswap tick range. Internal normalization never contributes to
headline external volume. Sequence also saturates at `uint256.max`; that unreachable lifetime edge
stops assigning distinct sequence numbers but does not revert later swaps.

The tape does not claim exact cumulative native LP fee amounts. Uniswap v4 exposes the configured
static fee rate after a swap, but the final aggregate delta and fee rate do not preserve every
swap-step rounding decision or protocol-fee split needed to reconstruct an exact native-fee amount.
Native fee revenue remains authoritative in Uniswap position accounting.

Uniswap v4 intentionally suppresses hook callbacks when a hook swaps its own pool. The permissioned
hook therefore records fee-normalization swaps explicitly after validating the returned PoolManager
delta and before settlement. This preserves one external record and one separately classified
internal record without relying on a callback that cannot occur. Both records use the final
post-normalization tick. Telemetry therefore treats the external trade and its normalization as one
atomic venue operation. PoolManager swap events remain the source for an intermediate outer-swap
endpoint when an offchain consumer needs it.

## Failure domains

Canonical recording is swap-critical. Authentication, PoolId resolution, the PoolManager state read,
and the bounded counter update either all succeed or the swap reverts. This makes the canonical
sequence gapless and prevents analytics from silently presenting incomplete lifetime totals.

Public range topology remains swap-critical only when a managed boundary is crossed. Weekly reserve
release, PoolId allocation resolution, and protocol stream activation are not executed by swaps.
Their failure cannot stop trading. A stopped public gauge still records canonical market activity.
Boundary traversal remains linear in the number of crossed managed boundaries multiplied by the
configured reward slots. This is an accepted exact-accounting liveness cost: dense ranges can require
a large price move to be split into smaller swaps, while stopping the gauge restores the minimal
telemetry-only swap path. Boundary density and active reward-slot count are operational availability
metrics.

Richer historical observations are a separate best-effort layer. They may be replaced or disabled
through Diamond upgrades without changing the immutable hook, the callback ABI, or existing PoolIds.
Observation failure must be detectable by comparing its recorded sequence with the canonical
sequence and must not revert an otherwise valid swap.

## Historical observations

The replaceable `MarketTapeObservationFacet` stores cumulative snapshots with these bounds:

- default cadence: 15 minutes;
- cadence range: 1 minute through 1 day;
- default target cardinality: 96;
- maximum cardinality: 672; and
- maximum lookback queries per call: 64.

The first eligible swap commits the first observation. Capacity grows by at most one slot on each
later commit until it reaches the configured target. Once full, each commit overwrites one logical
ring entry by deleting the oldest retained ID and writing one new monotonic ID. Configuration never
loops through history, and ordinary swaps before the cadence boundary perform no observation write.

The swap dispatcher invokes the recorder through a self-call capped at 500,000 gas while retaining a
100,000-gas failure reserve. A missing, replaced, reverting, or unexpectedly expensive recorder cannot
roll back canonical accounting or the swap. Its failure increments a saturating counter when enough
gas remains and always emits `MarketObservationWriteFailed`. Each successful observation includes the
canonical sequence at its snapshot, so consumers can identify its relationship to gapless activity.

`observeMarket()` locates the newest retained snapshot at or before each requested timestamp with a
bounded binary search over monotonic observation IDs. A zero lookback synthesizes the current
canonical state and current tick cumulative. Volume and fee totals remain stepwise historical
snapshots; the view does not pretend to interpolate trades that occurred between committed
observations.

## Portability

`StaticsSwapFeeHook` remains below the 24,320-byte project gate, which reserves 256 bytes beneath the
24,576-byte EIP-170 runtime ceiling. Telemetry storage and accounting live in Diamond facets and
libraries rather than expanding the immutable hook into an analytics engine.
