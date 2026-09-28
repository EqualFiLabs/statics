# ADR: Managed protocol-owned liquidity

- Status: Accepted for Phase 1
- Date: 2026-09-28
- Scope: public protocol pools, POL custody, fee funding, position management, and swap-time reward ownership

## Context

A single hook-owned full-range position makes every future POL increase depend on the same two
boundary ticks. Uniswap v4 shares `liquidityGross` capacity at each tick, so unrelated positions can
consume capacity and permanently prevent that position from accepting more liquidity.

General pool creation is permissionless when its creation fee is enabled. Automatically committing
protocol capital and an ongoing management obligation to every created pool is not scalable.

STATICS-staker swap rewards also need ownership to be fixed when the fee is generated. Deferring
ownership until a later claim-settlement transaction lets stake changes between those transactions
alter who receives already-generated fees.

## Decision

Protocol-owned liquidity is a custody-constrained portfolio of ordinary Uniswap v4 PositionManager
NFTs. Each pool can have any number of explicitly addressed positions and undeployed inventory.
There is no protocol-wide position-count limit and no transaction iterates every position.

The governed POL operator may:

- open a position at caller-selected valid ticks;
- increase, decrease, harvest, or close an explicit position; and
- continue managing positions created through an older compatible liquidity manager after manager
  replacement.

The operator cannot choose an output recipient. All principal, refunds, and inventory remain in the
Diamond's PoolId-specific POL custody account. Position NFTs remain owned by their originating
`StaticsLiquidityManager` and receive a typed `PROTOCOL_POL` binding, so orphan recovery cannot move
them. A manager replacement must retain the same Diamond, PoolManager, PositionManager, and Permit2
bindings. Existing positions keep their original manager address.

Inventory swapping is not part of the initial primitive. A future implementation may add bounded
swap execution, but its output and refunds must remain protocol-owned and PoolId-bound.

## Fee separation

The Statics bilateral hook allocation designated for POL is POL principal. It remains a PoolManager
claim until permissionless settlement moves the exact amount into the pool's POL custody account.

Native Uniswap LP fees earned by POL positions are Treasury revenue. Every increase, decrease,
harvest, and close first collects native fees in a distinct operation and reserves them under the
fee account before principal moves. Native fees never become POL principal automatically.

## Activation and funding

Basket canonical pools are POL-capable because their creator-funded launch position is part of the
atomic basket launch.

General pools start with POL disabled. While disabled, the configured POL share routes to Treasury
and the hook does not accumulate dormant POL inventory. The immutable pool creator may permanently
activate managed POL by paying the exact governed native activation fee, which is sent entirely to
Treasury. Activation affects future swaps only.

Governance may override a pool's effective POL share from zero through the sum of that pool class's
default POL and Treasury shares. Reducing the share reallocates only the difference to Treasury.
Setting it to zero stops new POL funding without closing existing positions or disabling their
management. Clearing the override restores the class default. If governance later reduces the
class-wide POL-plus-Treasury bucket below an existing override, the effective per-pool share is
capped to the new bucket so a stale override cannot underflow fee allocation or stop swaps.
Activation itself is not reversible.

## Lifecycle

Liquidity ingress pause blocks opening and increasing POL positions. Harvest, decrease, and close
remain available so the protocol can reduce risk.

General pool decommissioning is staged. The first call stops the gauge and hook swaps. Operators
then close positions in explicit bounded transactions. Finalization requires zero active POL
positions, settles remaining hook claims, and moves undeployed inventory to Treasury.

Basket `ExitOnly` unwind likewise requires every POL position for that PoolId to be closed first.
The unwind then settles remaining inventory, burns returned BasketTokens, and routes released
constituents to Treasury accounting.

## Swap-time STATICS reward ownership

For public pools, the hook calculates the exact STATICS-staker share for both swap currencies and
passes those values through the authenticated swap callback. The Diamond advances the global reward
index during that same swap transaction using the eligible weight at that instant. The backing
PoolManager claim may remain physically unsettled.

The global reward ledger records that indexed amount as an unfunded swap liability. Permissionless
settlement, reward claims, and Treasury distribution redeem only the exact claim shortfall into
custody before transferring funded rewards. Later stake or eligibility changes cannot reassign the
already-crystallized ownership.

Permissioned venue rewards already transfer into Diamond custody and enter the reward index during
the swap transaction, so they do not use the public hook's deferred-claim ledger.

## Invariants

1. A POL strategy caller cannot direct principal, refunds, fee proceeds, or an NFT to an arbitrary
   recipient.
2. Every active POL position is bound to one registered public PoolId and one manager.
3. Native LP fees are Treasury liabilities; hook POL allocations are POL principal.
4. Disabled general pools create no POL inventory or portfolio obligation.
5. A zero effective funding share does not alter existing positions.
6. Decommission finalization cannot scan positions and cannot complete while any position remains
   active.
7. STATICS-staker ownership is fixed at swap time; later settlement affects liquidity, not ownership.
8. The standalone Genesis and Operator system is unchanged.

## Consequences

No explicit tick reservation is required. Tick capacity failure affects only the selected position;
the operator can choose another range or open another position. The public hook becomes smaller and
contains fee classification and claim settlement rather than a position strategy engine.

Active management introduces strategy risk. Solidity constrains custody, pool identity, recipient
selection, exact accounting, and lifecycle safety. Range selection and portfolio quality remain an
offchain strategy responsibility.
