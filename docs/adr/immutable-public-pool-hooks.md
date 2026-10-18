# ADR: Standalone market hooks and baskets

- Status: Accepted for implementation; deployment remains separately authorized
- Date: 2026-10-14
- Base: `03c6d23cd8207c6f69b6b9a53b56f103c30ee52c`
- Reuses: restricted basket work from PR #113 at `283ee71788dd2329a97f0a96adc21b2cea521354`

## Decision

Phase 2 introduces one `StaticsBasketToken` implementation. Every basket token uses
the same distributor and exact-settlement transfer rules. There is no unrestricted
variant or earlier deployed basket version. Token identities and distributor
approvals live in the existing basket storage; prepared tokens register there
before funding. Deployed Phase 1 General pools and their liabilities retain their
existing behavior.

Existing and new General pools use the deployed `StaticsSwapFeeHook`. Basket
pools use one separate immutable `StaticsBasketHook`, serving multiple pools.
The Basket hook is standalone and does not inherit from the deployed hook or a
shared Statics hook base. The deployed General hook source and existing PoolKeys
remain unchanged.

The Diamond registers each PoolId before initializing it in the same transaction.
Both hooks reject initialization of unregistered pools; the Basket hook also
requires the Diamond as initializer. The Basket hook adds basket-token liquidity,
swap and exact-claim settlement. Duplicate complete PoolKeys are rejected. No
child hooks, hook queues, per-pool hook salts, or commit–reveal steps are used.

The owner installs the Basket hook and token-only `StaticsBasketTokenFactory`
once with `installBasketHook`. Their addresses are exposed together by
`basketHookConfiguration`; `liquidityIntegration` continues to identify the
existing General hook. Installation seeds the Basket hook with the current
General-hook default rates and basket allocation. Subsequent changes remain
independent: existing administration selectors govern the deployed General hook;
hook-addressed overloads govern compatible current or future hooks directly.

All hooks connect to the existing Diamond custody, fee indexes, creator accounting,
and reward ownership. Authentication uses the registered PoolKey's hook. Generation
crystallizes rewards once; later funding does not index the same revenue again.
Sources retain `(hook, PoolId, currency)` provenance, with the scoped settlement
ABI used for Basket-hook claims and the existing ABI used for General
sources. Existing native/WETH normalization and legacy liabilities remain payable.
Each queued source stores this triple directly. Hook/currency totals keep queued
claims separate from pre-upgrade liabilities during legacy funding. Basket-hook
staker settlement always requires a registered originating pool containing the
claimed currency.
Fee overrides, distributions, POL and decommission state remain isolated by pool.
Compatible future hooks can use the existing funded-revenue entrypoint without
sharing fee policy with these hooks.

Basket tokens can be prepared and deployed deterministically for
verification before funding. Atomic creation initializes every canonical pool in
one transaction. POL starts disabled per PoolId and uses the existing creator-paid
activation function and governed fee. Launch may opt individual pools in with or
without a seed. Zero paired funding initializes without minting or contributing
backing; positive funding requires activation and contributes protocol-owned LP.
Inactive POL and unavailable Basket-staker fees route to Treasury. Activation is
prospective and does not reclassify earlier Treasury revenue.
Optional staged creation accepts a caller-selected batch size and reuses the same
pool initialization, backing, minting and POL code. Creation charges the basket
fee once; each batch charges the live POL activation fee for its selected pools. The
last batch activates the basket without a separate finalize transaction.

A staged basket has appended status `Pending` (existing enum values are unchanged).
Only its creator can continue against the original pool terms, deadline and
aggregate asset-debit limits. Public mint, redeem, collateral,
flash operations, swaps, liquidity additions and new markets remain unavailable.
Only the current pool's internal initialization/seeding context can use pending
settlement. Existing transfer tickets remain exact; distributor approvals cannot
move pending tokens. The creator or owner may cancel to `ExitOnly` even after
expiry or a change to the creator's committed launch terms. Contributions remain protocol-owned; close seeded
POL positions and use the existing unwind-to-treasury path, including its backed
Uniswap rounding dust. Cancellation does not refund the creation fee or POL gifts.
Batch mints use the existing action-size fee tiers independently per mint.

Release qualification requires at least 10% headroom against the smaller of the
observed chain transaction cap, target/local block limit and submitted transaction
limit. The Phase 2 cut and measured maximum-basket lifecycle actions use a
16,777,216 gas limit, including two prepared 8-pool batches. Atomic finalization
is measured against the target chain cap. The staged path is the Ethereum gas-budget
check on the pinned Robinhood fork, not an Ethereum deployment. Additional basket
markets use the configured Basket hook directly.

Preserve restricted tokens, distributors, Morpho custody and settlement, and the
existing arbitrage settlement. Exclude launchpad, procurement, Dutch auctions,
campaigns, and bootstrap zaps.

## Admission

A zero public pool creation fee means owner-only creation on every pool-producing
path, including restricted markets and canonical pools created with baskets.
Check execution-time configuration and the authenticated external caller;
prepared/automatic salts and creator signatures cannot bypass the gate. The separate
basket creation fee retains its own zero-means-owner-only rule and exact-payment
terms. Canonical basket creation does not acquire an additional per-pool charge.

When the public creation fee is nonzero, General creation uses the existing
creator authorization and signature checks directly. Exact creation fees and
execution-time authorization remain required.

Independent restricted markets derive attribution from the first restricted
currency in the sorted PoolKey. The corresponding basket creator receives creator
rights and revenue; the transaction sender receives no creator authority. For a
BasketToken/BasketToken pair this rule also fixes one canonical basket identity
independent of caller-supplied token order.

## Approved distributors

The Diamond owner governs one distributor registry shared by all newly created
BasketTokens. An ordinary transfer requires either endpoint to be
approved or an exact protocol transfer ticket. Approval does not exempt a spender
from ERC-20 allowances, and ownership grants no implicit transfer exemption.
Consume a matching ticket before consulting the registry. PoolManager lock,
directional-budget and claim checks always take precedence over distributor
approval, including approval of PoolManager itself.

Morpho uses the same distributor approval. Remove per-token Morpho bindings and
ingress tickets; the later Morpho configuration batch explicitly approves its
contract. No special revocation guard is required. Direct collateral top-ups to
a position's Morpho account improve Morpho health without increasing tracked
collateral or Statics stake; only the excess above tracked collateral is untracked
surplus. Preserve net-balance loss recognition, so replenishment before
synchronization can offset a deficit and its reward forfeiture. Existing position,
custody, debt, loss and surplus-recovery accounting remains authoritative.
Phase 2 installs the registry empty and does not activate Morpho.

## Release requirements

The new Basket hook, BasketToken, the token factory, and embedded creation code include the IPFS
metadata hash. Preserve the historical default compiler profile, solc 0.8.33,
Cancun, optimizer 200, no global IR, and exact release/dependency provenance.
Before deployment, independently reproduce the exact creation/runtime code and
metadata from frozen Standard JSON, then compare a successful fork dry run's
constructor arguments, runtime substitutions, the factory-embedded token creation code and Diamond
routes with that build. This is a mandatory pre-deployment check. Explorer full
match at the new Basket hook address is required before executing the Diamond
cut. A partial match, missing status, different compiler, constructor arguments or
runtime blocks configuration. The existing General hook remains deployed with
its original metadata and is outside this new-deployment verification gate.

Use explicit selector replacements/additions and one-time initialization for
the existing Diamond. Keep unrelated Dollar/Morpho production selectors absent.
Validate old/new pools, real swaps and claims, basket token movement,
zero-fee authority, native/WETH sources, gauges, POL, metadata, storage, and
selector parity. A pinned-fork rehearsal and external verification remain
separate evidence from local tests.

## Qualification boundary

The release freezes a committed candidate and preserves historical artifacts and
the original pre-upgrade fixture. Local tests, pinned-fork execution, bytecode
reproduction, static analysis, focused security review and CI report distinct
evidence. Formal workloads run only in CI or on the dedicated verification box.
The impairment scenario funds mixed-currency rewards through real PoolManager
swaps before freezing a constituent. Qualification requires a successful healthy
reward payout, exact forfeiture event and zero impaired-token calls, unchanged
forfeited fee reservations, cleared claims, and mined unauthorized/replay failures.
Receipt, trace, returned amounts, and block-bound view observations must agree.
Production deployment and Diamond upgrades remain separate operations.
