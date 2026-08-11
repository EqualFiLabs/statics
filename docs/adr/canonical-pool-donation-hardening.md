# ADR: Canonical Pool Donation Hardening

- Status: Accepted
- Date: 2026-08-11
- Scope: Canonical swap routing and protocol-owned liquidity

## Context

Statics canonical pools compound pool-local TOKEN/WETH-style inventory into a
hook-owned full-range position. The permanent-liquidity share, unavailable
canonical-LP share, and unavailable basket-staker share can accumulate in that
inventory. Compounding uses the pool's current price to determine the matched
amounts.

Global Statics rewards are checked independently for each fee asset. Routing
an unavailable global-staker share into POL can therefore create a large
one-sided pending balance. Uniswap v4 native donations would let an arbitrary
account provide the opposite asset immediately after manipulating spot and
force that protocol inventory into the permanent position at the manipulated
ratio. Statics has no product requirement for public donation-router flows.

## Decision

For every canonical swap-fee leg:

- an unavailable canonical-LP share continues to redirect to POL;
- an unavailable basket-staker share continues to redirect to POL; and
- an unavailable global Statics-staker share redirects to treasury.

The hook enables `beforeDonate` and rejects every native PoolManager donation
to a Statics protocol pool. The required hook permission bitmap therefore
changes from `0x10cc` to `0x10ec`.

Automatic compounding after each swap remains unchanged. The permissionless
`compoundPermanentLiquidity` backup remains available. Protocol seeding and
swap-fee allocation are the only supported sources of POL inventory.

## Deployment boundary

Hook permissions are encoded in the deployed hook address and every PoolKey.
This change therefore requires a newly mined hook address and fresh protocol
pools; it is not an in-place configuration update.

The existing public testnet remains a historical deployment with its original
hook. Statics will use a second fresh testnet deployment to rehearse the new
hook and pool keys before mainnet. The historical full deployment manifest is
not rewritten; only future deployment calibration manifests use `0x10ec`.

## Consequences

- Missing global reward eligibility produces protocol revenue instead of
  enlarging one-sided POL.
- LP and basket eligibility fallbacks continue to deepen their own pool.
- Donation routers cannot donate through PoolManager to Statics pools.
- Ordinary swaps, bilateral hook fees, automatic POL compounding, governance
  pool creation, and the permissionless compound backup keep their existing
  behavior.
- Integrations must discover the new hook and PoolKeys from the fresh
  deployment manifest rather than reusing the first testnet addresses.
