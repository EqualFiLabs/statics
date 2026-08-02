# ADR: Protocol-Owned Basket Liquidity and Canonical Swap Revenue

> **Superseded (2026-07-22).** This ADR describes the former primary-fee POL
> reserve, protocol PositionManager NFT, epoch, and LP-fee model. The live
> design instead charges bilateral hook fees, routes them
> 10%/25%/25%/15%/25% by default across POL/canonical LPs/deposited
> BasketTokens/global Statics stakers/treasury, and compounds the matched share
> into hook-owned full-range permanent liquidity. Canonical pools have zero
> native LP fee. See `canonical-lp-nft-rewards.md`,
> `Statics-Design.md`, and `docs/integration.md` for current behavior.

- Status: Superseded
- Date: 2026-07-20
- Scope: Statics Basket fee allocation, secondary liquidity, Uniswap v4
  integration, borrower-owned liquidity, protocol revenue, and decommissioning
- Related: `position-fee-index-and-bounded-looping.md`

## Context

Statics BasketTokens are freely transferable ERC-20 tokens representing fixed
vectors of underlying assets. Their deterministic mint and redemption terms
create an arbitrage anchor, but that anchor does not create a secondary market
by itself. A market-price arbitrage requires an external venue where an
arbitrageur can acquire or sell the BasketToken.

The PositionNFT fee index creates a competing use for BasketTokens. Deposited
BasketTokens earn the holder share of basket fees, while BasketTokens supplied
to an external AMM remain loose and do not earn PositionNFT rewards. If all fee
income is distributed to deposited positions, rational holders can remove
BasketTokens from external liquidity precisely when protocol activity and fee
yield increase. Thin external liquidity then widens spreads, makes entry and
exit harder, and weakens the arbitrage mechanism that generates the fees.

Temporary liquidity-mining emissions do not solve this durably. They rent
liquidity from external providers and can create an abrupt loss of depth when
the subsidy ends. Statics instead needs a mechanism that converts a portion of
its own recurring activity into protocol-owned liquidity that cannot be
withdrawn by mercenary LPs.

The agreed mechanism uses a dedicated portion of basket-native fees to build a
matched inventory of newly backed BasketTokens and their constituents. For a
basket with three constituents, the protocol creates or adds to three external
pools:

```text
BasketToken / ASSET_A
BasketToken / ASSET_B
BasketToken / ASSET_C
```

Each pool becomes another direct arbitrage point between the BasketToken, one
constituent, the remaining external constituent markets, and Statics' fixed
mint and redemption conversion.

Uniswap v4 is the initial external liquidity venue. Its `PositionManager`
supports batched pool initialization and position modification, and its LP
positions accrue swap fees in both pool currencies. Statics will additionally
use v4 custom accounting to collect a separate protocol fee from every swap
through a canonical Statics pool. This gives Statics swap-derived revenue even
when all active liquidity belongs to third parties.

The hook cannot force every BasketToken market to pay Statics. Anyone may
create another pool without the Statics hook. The protocol instead concentrates
POL, canonical metadata, and supported routing around the hooked pools so they
are expected to offer the deepest and most useful BasketToken markets.

## Decision

Statics will add protocol-owned liquidity, abbreviated **POL**, as an isolated
per-basket subsystem. A dedicated share of eligible Statics Basket fees will
fund a per-basket, per-asset liquidity reserve. Once per 24-hour epoch, anyone
may trigger a bounded compounding flow that:

1. selects an exactly backed proportional slice of the liquidity reserve;
2. uses approximately half of that slice to back newly minted BasketTokens;
3. pairs the newly minted BasketTokens with the other half of the constituent
   slice across one BasketToken/constituent pool per asset; and
4. adds the resulting inventory to protocol-owned Uniswap v4 positions.

Every canonical BasketToken/constituent pool must use the immutable,
narrowly-scoped `StaticsSwapFeeHook`. A successful swap through one of those
pools pays a static hook fee in addition to the pool's LP fee. The hook fee is
terminal basket protocol revenue regardless of who owns the active liquidity.

The hook fee and the v4 positions' earned LP fees are separate streams:

```text
canonical pool swap
├── LP fee
│   └── distributed pro rata to all active LP positions
└── Statics hook fee
    └── 100% becomes terminal basket protocol revenue

Statics-owned position's pro-rata LP fee earnings
├── 90% remains POL and is recompounded
└── 10% becomes terminal basket protocol revenue
```

Position borrowers receive an optional second path after loan origination.
They may continue receiving the proportional underlying bundle at any chosen
receiver and use it without Statics involvement, or they may atomically use the
borrowed bundle to create user-owned liquidity in the canonical hooked pools.
The optional path does not change the loan's collateral, LTV, maturity,
recovery, or fee-index eligibility.

The 90/10 LP-fee split is fixed by this decision. The exact share of primary
Statics fees initially assigned to the liquidity reserve remains an economic
calibration decision described under Deferred Parameters. The exact hook fee
rate is also deferred, but the fee is static for each canonical pool and its
existence and revenue treatment are not optional.

### Fee sources and allocation boundaries

The existing basket fee books must not be swept after the fact. A fee is
classified when it enters Statics, before any holder, liquidity, or treasury
claim is created.

Mint, redemption, and flash-loan fees currently entering the basket reward
distribution will use three explicit destinations:

```text
gross eligible basket fee
├── holder reward reserve
├── protocol-owned liquidity reserve
└── terminal protocol revenue
```

For every eligible fee source:

```text
holderShareBps + liquidityShareBps + protocolShareBps = 10,000
```

The holder amount continues through the existing multi-asset PositionNFT fee
index. The liquidity amount enters the new isolated POL reserve. The protocol
amount enters the existing basket-and-asset protocol revenue book.

Basket creation fees remain native treasury revenue. Basket-loan origination
fees and underlying-denominated extension fees remain terminal basket protocol
revenue under the existing lending decision. Recovery surplus remains governed
by its own lending-accounting decision. Redirecting any of those sources into
POL requires an explicit amendment rather than silently applying the action-fee
split to them.

No amount already recorded as holder fee reserve, a position claim, protocol
revenue, basket backing, outstanding loan principal, or recovery surplus may be
reclassified into POL.

### Isolated POL reserve

For each basket and constituent, Statics records:

```text
liquidityReserve[basketId][asset]
```

The POL reserve is economically separate from:

- `vaultBalances`, which back BasketToken supply;
- outstanding loan principal;
- PositionNFT holder fee reserves and claims;
- terminal protocol revenue; and
- lending recovery surplus.

While the reserve remains in the Diamond, it contributes to both the basket's
module-local custody reservation and `globalReservedByToken`. It is never
treated as raw unreserved balance.

### Converting the reserve into matched inventory

Let a basket contain constituent amounts `bundleAmount[i]`. A compounding epoch
must first determine the largest proportional constituent slice that can fund
both sides of the POL construction.

Conceptually, for available POL reserve `R[i]`:

```text
maximum POL shares is bounded by every constituent:

    mintBacking[i] + pairedUnderlying[i] <= R[i]

where, before rounding:

    mintBacking[i]      ~= bundleAmount[i] * shares / 1e18
    pairedUnderlying[i] ~= bundleAmount[i] * shares / 1e18
```

Production calculations must reuse the basket's supply-aware backing increase
math and round conservatively. The limiting constituent determines how many
BasketTokens can be minted. Transfer-tax effects, donations, rounding, and
different fee histories may leave the reserve non-proportional; unmatched
residues remain in `liquidityReserve` for a later epoch.

The selected mint-backing vector is atomically reclassified:

```text
liquidityReserve decreases
vaultBalances increases by the exact same constituent amounts
BasketToken supply increases by the exactly backed share amount
```

This is an internal POL mint, not an ordinary user mint. It does not pull
tokens, charge another mint fee, enter the holder fee index, or expose a
general fee-exempt mint path. The only permitted output recipient is the
configured Statics liquidity manager.

The other half of the selected vector remains outside BasketToken backing and
is transferred as the constituent side of the LP inventory. Newly minted
BasketTokens and the paired underlying allocation become POL assets rather
than user redemption backing or user rewards.

### One pool per constituent

Every active constituent may have one canonical POL pool against the basket's
BasketToken:

```text
poolKey[basketId][asset]
positionTokenId[basketId][asset]
```

A one-asset basket therefore has one pool. A three-asset basket has three
pools, and a sixteen-asset basket may have sixteen pools. Each pool remains
isolated in manager accounting even though Uniswap v4 operates through a
singleton `PoolManager`.

The newly minted BasketTokens are not divided equally by pool count. Their
allocation must correspond to the value of the underlying assigned to each
pool at the accepted reference price. If constituent value weights are 40%,
25%, and 35%, a 100-BasketToken POL mint is approximately allocated as:

```text
40 BasketTokens → BasketToken / ASSET_A
25 BasketTokens → BasketToken / ASSET_B
35 BasketTokens → BasketToken / ASSET_C
```

Actual v4 liquidity math and range boundaries determine the amounts consumed.
Unused BasketTokens or constituents remain isolated idle POL inventory for the
same basket and pool. The compounder does not automatically swap mismatched
inventory merely to force every token into active liquidity.

### Required canonical-pool hook

Every canonical pool uses the same `StaticsSwapFeeHook` implementation. The
hook is protocol plumbing rather than a user-facing Statics entrypoint. It may
serve many canonical pools, but it records an explicit association for each
one:

```text
poolId => basketId + constituentAsset + hookFeeBps + enabled
```

This association is not a constituent token registry. Basket creation and
constituent selection remain permissionless. It is the minimum accounting
metadata needed to attribute a physical currency collected by the shared hook
to one isolated basket and asset book. Canonical pool activation records the
association before swaps can accrue Statics revenue. An unassociated pool may
not use the hook to create revenue obligations or contaminate another basket's
accounting.

The hook fee is static for the life of a canonical pool and appears in the
pool's published configuration. Changing that fee requires an explicit
migration to a new canonical pool rather than silently changing the economics
of an existing market.

The hook has only the permissions and behavior required to collect its swap
fee and settle accrued revenue. It has no dynamic fee algorithm, custom pricing
curve, liquidity-deposit fee, liquidity-withdrawal fee, trader allowlist,
fee-exempt caller, arbitrary external execution, basket custody authority, or
PositionNFT authority. Direct swaps, aggregator swaps, ordinary routers, and
protocol-originated swaps have identical hook-fee economics.

The hook address and permission bitmap are part of each immutable v4 pool key.
The initial hook implementation is immutable. Replacing its logic requires a
new hook address and the governed pool-migration process; it is not upgraded
in place through `StaticsDiamond`.

### Hook-fee calculation

The hook uses `afterSwap` custom accounting and charges against the amount that
actually executed. It does not charge against an optimistic quote or an amount
that a price limit prevented from swapping.

For exact-input swaps, the hook fee is withheld from the output currency:

```text
user supplies the declared input
pool executes the realized swap
hook retains the static share of realized output
user receives output minus the hook fee
```

For exact-output swaps, the hook fee is added in the input currency:

```text
user receives the declared output
pool determines the realized input
user supplies realized input plus the hook fee
hook retains the additional input amount
```

The fee uses the same basis-point rate in both swap directions. A nonzero
realized charged amount rounds up, so the one-basis-point first-release fee is
at least one unit of the charged currency; a zero execution charges zero. Each
Statics pool encountered by a multi-hop route is a separate swap and charges
its configured hook fee; integrations must display the route's aggregate fee
rather than implying that the fee is charged only once per transaction.

The hook fee is additive to the configured LP fee and any enabled Uniswap
protocol fee. It does not reduce, redirect, or subordinate the fee earnings of
third-party LP positions. External LP ownership can change the amount of LP
fees earned by Statics POL, but it cannot change the hook fee owed to Statics.

### Hook-fee custody and settlement

The hook uses v4 delta settlement and `PoolManager.take` to retain direct token
balances during the swap. The returned hook delta charges the requested fee;
the liability records the hook's measured receipt, so transfer-tax effects do
not create an uncovered claim. It does not call back into `StaticsDiamond` or
transfer to the Diamond on every swap. It records accrued amounts by canonical
pool and currency so identical physical tokens used by multiple pools cannot
erase basket attribution. Diamond-only withdrawal measures both the hook debit
and Diamond receipt, and rejects a sender-extra debit above that pool's
liability before it can consume another pool's attributed balance.

Anyone may call a bounded settlement function for an associated pool. The
settlement consumes only that pool's accrued claim and transfers its currencies
to `StaticsDiamond`. Receipt is measured by balance delta, reserved under the
destination basket's custody account, and handled according to currency type:

- an underlying hook fee becomes
  `protocolRevenue[basketId][constituentAsset]`; and
- a BasketToken hook fee is burned, its exact proportional backing is removed
  from `vaultBalances`, and that same underlying vector becomes terminal
  `protocolRevenue[basketId][asset]`.

The BasketToken path realizes revenue without selling into the canonical pool.
Neither path passes through the primary action-fee allocation or the POL
LP-fee 90/10 split. Settlement may be permissionless and batched, but a caller
cannot choose another basket, another revenue destination, or an arbitrary
recipient.

### Optional borrow-to-liquidity path

Ordinary position lending remains unchanged. A position owner may lock
deposited BasketTokens, borrow the proportional constituent bundle, and send
that bundle to any nonzero receiver. Statics does not require a borrower to use
the canonical pools or otherwise constrain how withdrawn loan proceeds are
used.

As an optional convenience, `StaticsDiamond` will expose a typed combined
action conceptually shaped as:

```solidity
borrowAndProvideLiquidity(
    uint256 positionId,
    uint256 basketId,
    uint256 collateralShares,
    LiquidityParams[] calldata pools,
    address lpRecipient
)
```

The exact ABI is finalized only after the v4 hook, canonical pool key, range,
and PositionManager integration types exist. It must remain a typed Statics
operation and must not introduce arbitrary router calldata or a general
external-execution surface.

The combined action executes atomically:

1. settle the position's basket rewards;
2. charge the ordinary loan origination fee, lock the resulting collateral,
   and record the ordinary proportional underlying principal and maturity;
3. calculate the maximum balanced user-liquidity allocation after the ordinary
   static mint fee and conservative rounding;
4. use the mint portion of the borrowed vector to mint exactly backed
   BasketTokens through the ordinary user-mint economics;
5. pair those BasketTokens with the remaining borrowed constituents across the
   selected canonical BasketToken/constituent pools;
6. mint the resulting v4 position NFTs directly to `lpRecipient`; and
7. return every unused BasketToken, constituent amount, and PositionManager
   refund to `lpRecipient` rather than retaining it as POL or protocol revenue.

The path may avoid transferring the mint portion out of and back into the
Diamond, but any internal reclassification must be economically identical to
an ordinary borrow followed by an ordinary mint. It may not waive the static
mint fee, create historical PositionNFT reward entitlement, reduce recorded
loan principal, or source assets from raw unreserved Diamond balances.

Ignoring fees and rounding, collateral representing a proportional bundle of
100 units at 95% LTV produces:

```text
locked, reward-eligible BasketTokens      100
borrowed proportional underlying bundle   95
new BasketTokens supplied to v4          47.5
constituent value supplied to v4         47.5
user-owned gross v4 liquidity              95
```

With a static mint-fee vector `F` and borrowed vector `B`, the approximate
equal-value allocation is:

```text
mint backing value      ~= (B - F) / 2
paired underlying value ~= (B - F) / 2
```

Production math operates per constituent and reuses the basket's supply-aware
mint quote. For a multi-asset basket, the remaining half of each constituent
funds its corresponding canonical pool. Newly minted BasketTokens are
allocated among those pools by accepted reference value and the selected v4
ranges, not equally by pool count. Range math may leave unmatched assets; the
combined action does not swap them merely to force a perfect deposit.

The newly minted BasketTokens placed into v4 are loose tokens. They are not
deposited into the PositionNFT, do not enter `totalEligibleShares`, and do not
earn PositionNFT basket rewards. The original locked collateral remains reward
eligible under the existing lending decision.

The v4 position NFTs belong directly to `lpRecipient`. They are not additional
loan collateral, POL, basket backing, holder reward reserves, or protocol
assets. Transferring the Statics PositionNFT transfers its collateral and debt
but does not transfer independently owned v4 positions. Loan repayment,
extension, expiry, and recovery neither seize nor mutate those v4 positions.

User-owned v4 positions receive their complete pro-rata LP fee entitlement.
Their LP earnings do not use the 90/10 POL split. Swaps against their liquidity
still pay the separate Statics hook fee because they occur through the same
canonical pools.

The user is responsible for v4 inventory risk. Removing liquidity may return a
different mix of BasketTokens and constituents than was deposited. Repayment
still requires the exact stored proportional principal, so a borrower may need
to redeem returned BasketTokens, rebalance externally, or contribute additional
constituents. A future typed remove-liquidity-and-repay convenience may perform
those bounded steps, but Statics does not guarantee that the LP position alone
will satisfy the debt.

### Non-user-facing liquidity manager

Uniswap integration will use a dedicated `StaticsLiquidityManager`. This
contract is protocol plumbing, not another user entrypoint. Ordinary mint,
redeem, position, reward, lending, flash-loan, and Dollar integrations remain
on `StaticsDiamond`.

The liquidity manager exists to keep external DEX permissions away from the
Diamond's shared custody. It may only:

- receive a prepared basket-and-pool POL allocation;
- receive a transaction-scoped user allocation prepared by the Diamond for the
  optional combined borrow path;
- own the configured POL v4 position NFTs;
- give bounded approvals required for the current v4 operation;
- create or increase configured positions;
- mint a newly created user position directly to the specified `lpRecipient`;
- collect and split POL-earned LP fees;
- return terminal protocol revenue to the Diamond; and
- unwind or migrate POL through the explicit lifecycle paths.

It has no authority over basket backing, holder rewards, Dollar custody,
unrelated basket reserves, pre-existing user balances, BasketTokens outside a
current prepared allocation, or arbitrary external calls. The manager must
isolate idle balances, positions, and collected fees by basket and pool. A
failure in one external pool cannot authorize spending from another basket's
prepared allocation.

The manager owns each POL v4 position NFT. Those positions' principal,
uncollected fees, and idle inventory are protocol assets outside all
BasketToken redemption and PositionNFT reward obligations.

The manager never owns a user v4 position after the combined call. Assets
prepared for that call are segregated from POL accounting, may be spent only
on the caller-selected canonical pools within the supplied bounds, and must be
fully consumed or returned before the call completes. A user position cannot
be increased from POL inventory, and a POL position cannot be increased from a
user allocation.

### Permissionless 24-hour epochs

POL preparation and compounding are callable permissionlessly once the
basket's next epoch has arrived:

```text
block.timestamp >= nextCompoundAt[basketId]
```

A successful epoch advances the basket's next eligible timestamp by 24 hours.
The implementation must prevent duplicate preparation or deployment of the
same reserve allocation.

Permissionless execution does not imply that execution happens automatically.
The exact keeper compensation is deferred, but any bounty must be paid from an
explicit POL allocation before the 50/50 construction, be capped, and be
recorded independently. A caller may not retain unused v4 inputs, rounding
residue, or PositionManager refunds as an implicit bounty.

### V4 LP swap-fee collection

Uniswap v4 accrues position fees in both pool currencies. For a
BasketToken/asset pool, the manager collects:

```text
BasketToken fee amount
underlying asset fee amount
```

The manager collects fees without removing LP principal by using the v4
PositionManager's zero-liquidity decrease flow followed by taking both pool
currencies. It measures its balance changes around collection rather than
trusting an offchain estimate or treating the position's principal as fees.

Each measured currency is split independently:

```text
compoundAmount = floor(collectedAmount * 9,000 / 10,000)
revenueAmount  = collectedAmount - compoundAmount
```

Rounding therefore favors terminal protocol revenue rather than creating
unowned dust.

The 90% portions remain attributed to the same basket and pool. They are
combined with new epoch inventory and used to increase the existing position.
If the current position cannot consume both currencies, unmatched balances
remain idle POL and do not become protocol revenue or user claims.

### Converting the 10% LP share into terminal protocol revenue

The underlying-asset revenue share is transferred back to `StaticsDiamond`,
measured on receipt, reserved under the basket custody account, and recorded
directly as:

```text
protocolRevenue[basketId][underlyingAsset]
```

The BasketToken revenue share is not held for later sale into the protocol's
own liquidity. The manager transfers it to the Diamond, where Statics:

1. burns the measured BasketToken amount;
2. calculates the exact backing reduction at the current supply;
3. removes that vector from `vaultBalances`; and
4. records the same vector as terminal per-asset basket protocol revenue.

This maintains the static-backing invariant while converting BasketToken LP
fees into claimable underlying protocol revenue without a market sale.
BasketTokens collected as LP fees are already-backed existing supply; they are
not newly minted during collection.

Both terminal revenue paths stop at `protocolRevenue`. They do not pass through
the holder/POL/protocol action-fee split a second time. The treasury may claim
them through the existing isolated revenue path.

Hook fees also stop at `protocolRevenue`. They do not enter the 90/10 LP-fee
split and do not automatically fund more POL. A future treasury allocation may
fund liquidity through an explicit new deposit, but hook revenue is terminal at
the point it is earned under this decision.

### Compounding ranges and price safety

The first implementation should use full-range or deliberately wide static
positions. Narrow automated positions require periodic range changes, swaps,
and price-dependent inventory management that are not necessary to prove the
POL model.

The compounder must not add protocol assets blindly at a caller-manipulated
spot price. The 24-hour schedule is predictable, and a thin new pool can be
manipulated immediately before the first eligible call. Execution therefore
requires an onchain-enforceable price-safety mechanism, including:

- a pool warm-up before automatic POL becomes active;
- a time-separated or time-weighted reference price;
- a maximum accepted deviation between the reference and execution price;
- bounded per-epoch deployment while liquidity is young; and
- explicit maximum token inputs and minimum liquidity minted.

These checks protect accumulated protocol assets from a permissionless caller;
they are not constituent admission rules or attempts to protect a basket
creator from their own configuration.

The required swap-fee hook does not itself provide the POL reference price. Its
custom accounting is limited to the accepted static fee, and the fee cannot be
changed dynamically in response to the spot price. If hook observations are
also used by the price-safety mechanism, that read path must remain independent
from fee calculation and must not grant additional swap-delta behavior.

### Pool initialization and activation

An existing BasketToken market is not required for basket creation, ordinary
minting, or ordinary redemption. It is required for market-price arbitrage and
POL deployment.

Each canonical pool needs an immutable pool key containing its currencies, fee
tier, tick spacing, and the required `StaticsSwapFeeHook`. Before the pool can
be advertised as canonical, its pool ID must be associated with exactly one
basket and constituent and its static hook fee must be recorded. A pool may be
initialized and seeded before automatic POL begins, or the manager may
initialize it atomically with its first eligible position. In either case,
automatic deployment starts only after the configured price-safety warm-up.

No token registry or governance constituent approval is introduced. Pool
activation belongs to the basket's own isolated market configuration. The
exact one-time activation handshake and initial-price source remain deferred.

### Basket lifecycle interaction

POL is risk-increasing while it mints new BasketTokens or sends fresh assets to
an external AMM. Those actions are available only while the basket is Active.

- **Active:** new fee allocation, internal POL minting, position creation,
  optional borrow-to-liquidity execution, hook-fee settlement, LP-fee
  collection, and compounding are available.
- **Quarantined:** no new POL mint or external deployment occurs. Existing
  positions and idle POL remain isolated while the basket is investigated.
  Canonical swaps may continue, but hook-fee settlement may only increase
  terminal protocol revenue and may not reactivate POL deployment. New
  combined borrow-to-liquidity execution is unavailable because its underlying
  borrow and mint actions are unavailable.
- **ExitOnly:** no new POL mint or reinvestment occurs. The protocol may
  permissionlessly execute an approved unwind flow so POL does not obstruct
  basket decommissioning. Hook-fee settlement and BasketToken fee burning
  remain available while the canonical pool continues to trade. Existing
  user-owned v4 positions remain under their owners' control and are not part
  of the protocol unwind.

An exit-only unwind first collects LP fees so the 90/10 fee split remains
observable, then removes LP principal. BasketTokens returned from LP principal
are burned and their represented backing is reclassified as protocol revenue.
Underlying principal and idle underlying POL become terminal basket protocol
revenue. The unwind cannot change user redemption backing except through the
exact supply reduction corresponding to protocol-owned BasketTokens burned.

Migration to a replacement DEX or pool configuration is a timelocked protocol
operation and must preserve the same per-basket accounting boundaries. The
manager has no generic arbitrary-execution or arbitrary-token rescue surface.

### Non-standard constituent behavior

Statics remains permissionless and does not add a token registry. That does
not guarantee that every constituent can settle through Uniswap v4.

A taxed, rebasing, pausable, freezing, callback-enabled, or otherwise
non-standard token may prevent initialization, liquidity addition, fee
collection, or removal for its own pool. Statics records POL activation and
failure state per basket and asset. Failure of POL deployment does not consume
the reserve, alter BasketToken backing, or authorize another basket's assets.

The UI and indexer must distinguish:

```text
POL inactive
POL warming up
POL active
POL out of range
POL compounding unavailable
POL unwind pending
```

Users remain responsible for choosing baskets whose constituents and external
markets behave as expected.

## Accounting Invariants

The implementation must preserve all of the following:

1. Basket backing remains:

   ```text
   vault balance + outstanding principal
       = backing represented by BasketToken supply
   ```

2. POL reserve, LP positions, LP fees, idle manager balances, and terminal
   protocol revenue are excluded from both sides of the backing invariant.

3. Every BasketToken minted for POL receives its complete backing vector in
   `vaultBalances` before it can leave the Diamond.

4. An internal POL mint cannot be called with user funds, select an arbitrary
   receiver, avoid an ordinary user fee, or mint against raw Diamond balances.

5. A POL epoch cannot spend a holder fee reserve, holder claim, protocol
   revenue, another basket's reserve, or another pool's idle inventory.

6. The manager's total prepared and idle accounting for a basket and pool must
   be covered by its measured physical balances and v4 position ownership.

7. Every canonical pool uses the configured `StaticsSwapFeeHook`; a pool
   without that hook cannot be published or funded as canonical POL.

8. Every associated pool and currency's accrued hook-fee accounting is covered
   by the hook's corresponding v4 claim or measured physical balance.

9. Hook revenue from one pool cannot be settled into another basket or asset
   book, including when several pools use the same physical token.

10. For any executed amount whose fee does not round to zero, every successful
    canonical-pool swap charges the configured static hook fee regardless of
    router, trader, liquidity owner, swap direction, or protocol affiliation.

11. An exact-input hook fee is derived from realized output, and an exact-output
    hook fee is derived from realized input. Unexecuted amounts are not charged.

12. Hook fees become terminal protocol revenue exactly once. They cannot enter
    the holder allocation, POL reserve, or LP-fee 90/10 split.

13. LP fee collection cannot reduce position principal.

14. Exactly 90% of each measured LP fee currency remains POL and exactly 10%,
   including split rounding, becomes terminal protocol revenue.

15. Burning either BasketToken revenue source reduces supply and reclassifies
    the exact corresponding backing vector; it cannot create unbacked revenue
    or reduce backing per remaining BasketToken.

16. Underlying hook and LP revenue credited in the Diamond equals the amount
    actually received and reserved, not a nominal hook or manager transfer.

17. Neither primary fee allocation, hook-fee revenue, nor LP-fee revenue is
    recursively allocated through the same split more than once.

18. External LP loss, inactivity, or impermanent loss cannot create a claim on
    basket backing or holder fee reserves.

19. Quarantine and exit-only status prevent new internal POL mints and new
    external liquidity exposure.

20. A pool, hook, or token failure can block only the affected basket-and-pool
    path unless the same pathological physical token is shared elsewhere.

21. Choosing the combined path records the same collateral, proportional
    principal, maturity, and origination economics as the corresponding
    ordinary borrow.

22. A user-liquidity allocation may use only the current call's borrowed
    principal and newly minted BasketTokens. It cannot spend POL, protocol
    revenue, holder rewards, another position's assets, or unreserved custody.

23. Every BasketToken sent to a user v4 position receives its complete backing
    vector and pays the ordinary static mint fee before leaving the Diamond.

24. BasketTokens held by a user v4 position never enter PositionNFT eligible
    principal or claim historical basket rewards.

25. Every user v4 position is minted directly to the requested recipient, and
    every unused user allocation is returned within the same atomic call. The
    manager cannot retain either as POL.

26. User-owned LP fees remain entirely attributable to the user position and
    never enter the 90/10 POL fee split.

27. PositionNFT transfer, loan repayment, extension, and recovery cannot seize,
    transfer, or mutate an independently owned user v4 position.

28. Failure to satisfy any pool, range, amount, deadline, or minimum-liquidity
    bound reverts the entire combined borrow, mint, and liquidity operation.

## Economic Effects

### Expected benefits

- Recurring basket activity builds durable secondary liquidity rather than
  renting it temporarily.
- BasketToken liquidity no longer depends entirely on users sacrificing
  PositionNFT fee yield to act as LPs.
- Every constituent pool creates a direct arbitrage point against the fixed
  Statics conversion and external constituent markets.
- Every swap through a canonical pool creates basket protocol revenue even
  when third parties provide all active liquidity.
- Third-party LPs keep their complete pro-rata LP fee entitlement because the
  Statics hook fee is accounted separately.
- Borrowers may keep their original locked collateral reward eligible while
  deploying borrowed capital into user-owned canonical liquidity.
- Borrower-owned liquidity can deepen canonical markets without requiring
  additional POL expenditure, while its swaps still produce hook revenue.
- The 90% LP-fee share compounds the protocol's market depth.
- The 10% LP-fee share creates an additional realizable protocol revenue stream
  in underlying assets.
- Diverting part of action fees away from the holder denominator reduces the
  reward-weight advantage of maximally looped positions.
- A one-asset fractional basket receives the same mechanism without special
  casing.

### Costs and tradeoffs

- Holder claimable yield is lower than under a model distributing the entire
  non-treasury fee share to PositionNFTs.
- Protocol assets become exposed to AMM inventory changes, range selection,
  external-contract risk, and impermanent loss.
- Multiple constituent pools split total POL and increase gas linearly with
  basket size.
- The hook fee adds to the trader's total execution cost, widens the arbitrage
  threshold, and may cause routing to prefer an unhooked competing pool if the
  fee exceeds the value of canonical depth.
- A multi-hop route through more than one Statics pool pays the hook fee at
  every Statics hop.
- Custom-hook pools require explicit router, indexer, and frontend integration
  and may not receive all aggregator or UniswapX order flow automatically.
- The combined borrow path gives users leveraged LP-fee exposure and exposes
  them to range risk, impermanent loss, and a withdrawal composition that may
  not match their exact constituent debt.
- A user must actively extend or repay the loan; LP fees and LP inventory do
  not automatically service debt or prevent maturity recovery.
- The external v4 position does not travel with the Statics PositionNFT, so a
  buyer of either NFT must understand that the related asset or obligation may
  be held separately.
- A predictable daily deployment requires price-manipulation resistance and
  keeper liveness.
- Permissionless non-standard constituents may be usable in Statics but
  incompatible with the selected external AMM.
- The manager and v4 integration add a separate audit surface even though they
  do not add another user-facing protocol address.

## Alternatives Rejected

### Distribute all basket fees to PositionNFT holders

This maximizes direct holder yield but strengthens the incentive to remove
BasketTokens from external liquidity and worsens the loop-weight arms race.

### Rent liquidity with temporary emissions

External LPs may leave when emissions end. The protocol does not accumulate a
durable market-making asset.

### Recompound 100% of v4 swap fees

This maximizes POL growth but produces no realizable protocol revenue from the
secondary market. The accepted 90/10 split retains most compounding while
creating terminal treasury revenue.

### Send all v4 swap fees to treasury or holders

This prevents the external liquidity position from compounding and weakens the
fee-to-liquidity flywheel.

### Hold the 10% BasketToken fee share in treasury

The treasury would eventually need to sell or redeem those tokens. Burning
them immediately and reclassifying their backing realizes underlying revenue
without selling into protocol-owned liquidity.

### Automatically swap mismatched fee inventory

Automated swaps add oracle, slippage, routing, sandwich, and arbitrary-execution
risks. Unmatched pool inventory can safely carry forward.

### Divide BasketTokens equally among constituent pools

Equal token counts do not provide equal value when constituent weights differ.
Pool allocation must reflect the underlying value assigned to each pool.

### Put Uniswap approvals on `StaticsDiamond`

The Diamond shares physical custody across baskets and Dollar modules. A narrow
manager receiving only prepared POL assets materially reduces the external
approval and integration blast radius without affecting user-facing UX.

### Rely only on Statics-owned LP fee earnings

LP fee earnings scale with Statics' fraction of active liquidity. If external
LPs provide most or all of a canonical pool's depth, Statics would earn little
or nothing from the secondary market. The required hook creates a separate
protocol fee on every canonical-pool swap without confiscating external LP fee
earnings.

### Redirect a percentage of third-party LP fees

Reducing an external LP's earned fee makes canonical Statics pools less
attractive to permissionless liquidity. A separate, published hook fee gives
traders the complete execution cost while preserving the pool's ordinary
pro-rata LP economics.

### Make hook fees dynamic or caller-dependent

Dynamic rates, privileged exemptions, and router-specific treatment increase
integration complexity and make the arbitrage threshold unpredictable. A
static fee applied identically to every swap is easier to quote, audit, and
integrate.

### Require borrowers to provide canonical liquidity

The loan product exists to give users access to the proportional underlying
bundle while their collateral continues earning. Mandatory routing would
replace user agency with a protocol-selected strategy. Ordinary borrowing and
an arbitrary nonzero receiver remain available beside the optional typed path.

### Hold user v4 positions inside the Statics PositionNFT

The locked BasketTokens already secure the proportional debt. Treating the v4
position as additional collateral would entangle external AMM inventory with
loan recovery and make an independently composable asset travel with unrelated
Statics obligations. The v4 NFT is instead minted directly to the user-selected
recipient.

### Apply the POL 90/10 split to user LP earnings

The 90/10 split governs fees earned by protocol-owned positions. User liquidity
is externally owned capital, so its ordinary LP fee entitlement belongs fully
to its owner. Statics earns separately through the mandatory hook fee on every
canonical-pool swap.

### Add a token registry for POL-compatible assets

POL compatibility is an isolated market property, not a constituent admission
requirement. Unsupported external behavior is surfaced per basket and pool.

## Implementation and Verification Requirements

The implementation must include real-flow tests covering at minimum:

- one-asset, three-asset, and maximum-asset basket POL preparation;
- fee-time classification into holder, POL, and protocol books;
- limiting-constituent calculations, rounding, and idle reserve carryover;
- an exactly backed internal POL mint that cannot be reached as a general
  fee-exempt user mint;
- v4 pool initialization, position minting, position increase, fee collection,
  and fee compounding through real local v4 contracts;
- ordinary proportional borrowing to an arbitrary receiver remaining unchanged
  after the combined path is installed;
- one-asset and multi-asset combined borrow, ordinary static-fee mint, and
  canonical liquidity creation in one real value-moving flow;
- exact origination fee, principal, maturity, mint fee, backing increase, and
  per-pool allocation parity between the combined path and equivalent separate
  user actions;
- direct v4 NFT ownership by `lpRecipient`, including a recipient distinct from
  the PositionNFT owner;
- newly minted LP BasketTokens remaining outside PositionNFT reward eligibility
  while the original locked collateral remains eligible;
- complete return of unused BasketTokens, constituents, and PositionManager
  refunds without pollution of POL or manager idle accounting;
- rejection of unassociated pools, duplicate constituent pools, invalid ranges,
  expired deadlines, excessive inputs, and insufficient minted liquidity with
  atomic rollback of the loan and mint;
- user-owned LP fee collection remaining outside the POL 90/10 split while
  swaps against that liquidity still accrue the ordinary hook fee;
- PositionNFT transfer, repayment, extension, expiry, and recovery leaving the
  independently owned v4 NFT untouched;
- default recovery after the combined path preserving exact backing for all
  remaining loose BasketTokens;
- canonical pool association and rejection of unassociated or incorrectly
  paired pool IDs;
- exact-input and exact-output hook fees in both token orderings, including
  partial execution against a price limit and dust-rounding behavior;
- identical hook-fee economics through direct, aggregator-style,
  protocol-originated, and multi-hop routes with no caller exemption;
- a canonical pool funded entirely by third-party liquidity while Statics still
  accrues its configured hook revenue;
- permissionless hook-fee settlement in both currencies without a per-swap
  callback into `StaticsDiamond`;
- underlying hook-fee receipt and BasketToken hook-fee burning with exact
  backing-to-revenue reclassification;
- two pools sharing a physical currency while their hook claims and settlement
  remain isolated by pool and basket;
- measured 90/10 splitting in both token orderings;
- BasketToken LP revenue burning and exact backing-to-revenue reclassification;
- underlying LP revenue returning to Diamond custody and becoming claimable
  only through the basket treasury path;
- unmatched BasketToken and underlying inventory carrying forward without an
  automatic swap;
- a permissionless epoch call, duplicate-call rejection, timestamp advance,
  and any explicit keeper bounty;
- spot-price manipulation and reference-deviation rejection;
- out-of-range, paused, reverted, and non-standard-token pool behavior without
  loss of basket backing or another reserve;
- quarantine stopping new funding without blocking ordinary basket exits;
- exit-only collection, LP removal, BasketToken burn, and terminal revenue
  accounting;
- two baskets sharing one underlying while retaining separate POL books;
- manager reentrancy attempts and proof that external approvals cannot spend
  Diamond custody; and
- combined invariants proving basket backing, global reservations, POL
  isolation, user-allocation isolation, and LP-fee conservation across
  arbitrary action sequences.

Deployment manifests must identify the configured v4 `PoolManager`,
`PositionManager`, manager contract, required hook address and permission
bitmap, canonical pool keys and associations, static hook fee for each pool,
the combined-action selector and helper authorization, and all protocol-owned
position token IDs. The SDK and indexer must expose POL reserve, deployed
liquidity, idle inventory, pending hook fees, cumulative hook revenue, pending
LP fees, cumulative recompounded fees, cumulative protocol LP revenue,
effective pool fee composition, epoch timing, and lifecycle status. User v4
positions are indexed from ordinary PositionManager events and are not listed
as protocol-owned positions.

### Implementation sequencing

The combined path depends on concrete v4 types and is implemented only after:

1. the immutable `StaticsSwapFeeHook` and its real-flow swap tests exist;
2. canonical pool association, initialization, and routing are verified;
3. the liquidity manager can create and manage isolated POL positions; and
4. the manager has a transaction-scoped path that creates a v4 position
   directly for a user without mixing the allocation with POL.

The optional combined action and its invariants follow those prerequisites.
An ordinary user remains able to reproduce the strategy manually at every
stage by borrowing to themselves, minting, and interacting with v4 directly.

## First-Release Calibration

The Robinhood Chain first release uses one narrow protocol-wide calibration:

- eligible primary basket fees split `4,500 / 4,500 / 1,000` basis points
  between PositionNFT holders, POL, and terminal protocol revenue;
- the existing Statics timelock may change all three primary allocation values
  atomically, and their sum must always equal 10,000 basis points;
- primary allocation is protocol-wide and is not snapshotted per basket;
- `StaticsSwapFeeHook` charges one immutable basis point, supplied at hook
  construction and shared by every pool using that hook;
- nonzero hook fees round up in the charged currency, so dust swaps cannot
  bypass the fee through integer truncation;
- the canonical v4 LP fee is 500 millionths, equal to 5 basis points, with tick
  spacing 10;
- the initial protocol positions use the full usable range for tick spacing 10;
- a pool warms for one hour after initialization before POL activation;
- the hook records at most one cumulative-tick observation per minute in a
  64-observation ring, while additional swaps in the same interval still use
  the ordinary static fee without another stored observation;
- activation and POL deployment require a 30-minute time-weighted reference and
  reject execution when the current spot differs from that reference by more
  than 100 basis points;
- initialization is permissionless and accepts the caller's initial price, but
  that price cannot authorize POL until the independent warm-up and observation
  conditions pass;
- for seven days after activation, one epoch may deploy at most 10% of the
  currently available proportional liquidity-reserve slice; later epochs may
  use the full otherwise-valid slice;
- an epoch must prepare at least `1e12` BasketToken shares and nonzero usable
  liquidity in every included canonical pool, or it reverts without advancing
  the epoch; and
- the first release pays no keeper bounty. The named protocol keeper supplies
  normal liveness while every maintenance function remains permissionless.

Pool-safety parameters are one protocol-wide timelocked configuration rather
than per-basket policy. Changing them affects future eligibility checks but
cannot change an existing v4 PoolKey, the immutable hook rate, or an existing
position's tick range. Replacing the hook, pool key, or range requires an
explicit later migration decision.

## Deferred Follow-on Work

The following are intentionally outside the first delivery or become concrete
only after the pinned v4 types exist:

- the final `borrowAndProvideLiquidity` ABI and typed per-pool slippage fields;
- a typed remove-liquidity, redeem, top-up, and repay convenience;
- router, aggregator, and UniswapX integration beyond route-parity tests; and
- a governance-authorized DEX or hook migration procedure.

Those follow-on choices must not weaken the isolation, backing, 50/50 POL
construction, mandatory canonical-pool hook, static and caller-independent
hook-fee economics, 100% terminal treatment of hook fees, 90/10 POL LP-fee
split, optional ordinary borrowing, direct user ownership of combined-path v4
positions, or permissionless epoch model accepted here.

## References

- Uniswap v4 PositionManager guide:
  <https://developers.uniswap.org/docs/protocols/v4/guides/position-manager>
- Uniswap v4 fee collection guide:
  <https://developers.uniswap.org/docs/protocols/v4/guides/managing-liquidity/collect-fees>
- Uniswap v4 concentrated-liquidity overview:
  <https://developers.uniswap.org/docs/get-started/concepts/liquidity-providers/concentrated-liquidity>
- Uniswap v4 hook concepts:
  <https://developers.uniswap.org/docs/protocols/v4/concepts/hooks>
- Uniswap v4 custom accounting guide:
  <https://developers.uniswap.org/docs/protocols/v4/guides/custom-accounting>
- Uniswap v4 hook routing:
  <https://developers.uniswap.org/docs/protocols/v4/concepts/hook-routing>
- Uniswap fee concepts:
  <https://developers.uniswap.org/docs/get-started/concepts/fees>
- Uniswap v4 security framework:
  <https://developers.uniswap.org/docs/protocols/v4/security>
