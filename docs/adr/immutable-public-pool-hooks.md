# ADR: Standalone market hooks and restricted baskets

- Status: Accepted for implementation; deployment remains separately authorized
- Date: 2026-10-14
- Base: `03c6d23cd8207c6f69b6b9a53b56f103c30ee52c`
- Reuses: restricted basket work from PR #113 at `283ee71788dd2329a97f0a96adc21b2cea521354`

## Decision

New General pools use one immutable `StaticsGeneralPoolHook`; restricted-basket
pools use one separate immutable `StaticsBasketHook`. Each hook serves multiple
pools. Neither inherits from the deployed `StaticsSwapFeeHook` or a shared Statics
hook base. The legacy source and existing PoolKeys remain unchanged.

The Diamond registers each PoolId before initializing it; only the Diamond may
register or initialize a pool. The General hook retains the existing General fee
behavior. The Basket hook adds restricted-token liquidity, swap and exact-claim
settlement. Duplicate complete PoolKeys are rejected. No child hooks, hook queues,
per-pool hook salts, or commit–reveal steps are used.

The owner installs both hooks and the token-only `StaticsBasketTokenFactory` once.
Installation seeds the approved legacy default rates and the allocation relevant
to each new hook. Subsequent changes remain independent: existing administration
selectors govern the legacy hook; hook-addressed overloads govern configured hooks
and reject allocations for an unsupported market type.

All hooks connect to the existing Diamond custody, fee indexes, creator accounting,
and reward ownership. Authentication uses the registered PoolKey's hook. Generation
crystallizes rewards once; later funding does not index the same revenue again.
Sources retain `(hook, PoolId, currency)` provenance, with the scoped settlement
ABI used for Basket-hook claims and the existing ABI used for legacy and General
sources. Existing native/WETH normalization and legacy liabilities remain payable.
Fee overrides, distributions, POL and decommission state remain isolated by pool.
Compatible future hooks can use the existing funded-revenue entrypoint without
sharing fee policy with these hooks.

Restricted basket tokens can be prepared and deployed deterministically for
verification before funding. Atomic creation initializes and seeds every canonical
pool in one transaction. Optional staged creation accepts a caller-selected batch
size and reuses the same pool initialization, backing, minting and POL code. The
last batch activates the basket without a separate finalize transaction.

A staged basket has appended status `Pending` (existing enum values are unchanged).
Only its creator can continue against the original pool terms, deadline, deployment
environment and aggregate asset-debit limits. Public mint, redeem, collateral,
flash operations, swaps, liquidity additions and new markets remain unavailable.
Only the current pool's internal initialization/seeding context can use pending
settlement. Existing transfer tickets remain exact; distributor approvals cannot
move pending tokens. The creator or owner may cancel to `ExitOnly` even after
expiry or an environment change. Contributions remain protocol-owned; close seeded
POL positions and use the existing unwind-to-treasury path, including its backed
Uniswap rounding dust. Cancellation does not refund the creation fee or POL gifts.
Batch mints use the existing action-size fee tiers independently per mint.

Release qualification requires at least 10% headroom against the smaller of the
observed chain transaction cap, target/local block limit and submitted transaction
limit. The maximum-basket rehearsal includes atomic finalization and two prepared
8-pool batches constrained to 16,777,216 gas each. This is an Ethereum gas-budget
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
restricted BasketTokens. An ordinary transfer requires either endpoint to be
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

Both standalone hooks, the restricted token, token factory, and embedded creation code include the IPFS
metadata hash. Preserve the historical default compiler profile, solc 0.8.33,
Cancun, optimizer 200, no global IR, and exact release/dependency provenance.
Before deployment, independently reproduce the exact creation/runtime code and
metadata from frozen Standard JSON, then compare a successful fork dry run's
constructor arguments, runtime substitutions, the token-factory code store and Diamond
routes with that build. This is a mandatory pre-deployment check. Explorer full
match at both deployed hook addresses is required before executing the Diamond
cut. A partial match, missing status, different compiler, constructor arguments or
runtime blocks configuration.

Use explicit selector replacements/additions and one-time initialization for
the existing Diamond. Keep unrelated Dollar/Morpho production selectors absent.
Validate old/new pools, real swaps and claims, restricted token movement,
zero-fee authority, native/WETH sources, gauges, POL, metadata, storage, and
selector parity. A pinned-fork rehearsal and external verification remain
separate evidence from local tests.

## Qualification boundary

The release freezes a committed candidate and preserves historical artifacts and
the original pre-upgrade fixture. Local tests, pinned-fork execution, bytecode
reproduction, static analysis, focused security review and CI report distinct
evidence. Formal workloads run only in CI or on the dedicated verification box.
Production deployment and Diamond upgrades remain separate operations.
