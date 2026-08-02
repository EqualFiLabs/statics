# ADR: Unified Statics Protocol, Position Fee Index, and Bounded Recursive Lending

> **Amended (2026-07-26).** Statics retains global Statics-token staking for
> primary and protocol fees, and also indexes the canonical hook's dedicated
> basket-staker share over deposited BasketTokens. Borrowed collateral remains
> eligible. Expired loans burn only debt plus a creator-configured proportional
> penalty, unlock the remainder, and split penalty backing 20% to the recovery
> caller and 80% to the protocol fee route. A zero basket creation fee closes
> public genesis to owner-only zero-value creation; a positive fee opens
> exact-fee public creation. Managed recovery holders are explicitly admitted
> and revocable by the Dollar Core owner.

- Status: Accepted as amended
- Date: 2026-07-18; amended 2026-07-19, 2026-07-20, 2026-07-25, and 2026-07-26
- Scope: Protocol unification, Statics Dollar, basket minting and redemption,
  fee distribution, positions, and self-backed lending

## Context

Statics began as a standalone protocol for tokens with a fixed,
creator-defined bundle of underlying assets. The fixed bundle is intended to
create deterministic mint and redemption prices that external arbitrageurs can
compare with secondary market prices without an oracle.

The separately developed Ether Dollar protocol already contains a mature
Diamond periphery for transferable PositionNFT portfolios, lazy fee-index
accounting, opt-in liquidity, and managed series recovery. Building a second
position and rewards system inside Statics would duplicate the same ownership,
checkpoint, custody, and integration machinery while preventing users from
managing both products through one protocol account.

Ether Dollar also belongs naturally within the Statics product identity. Each
Dollar risk series fixes its paired mint and senior collateral terms at series
origination. Oracles govern admission, health, and series transitions, but do
not continuously reprice the ordinary paired mint cost within an originated
series. The product will therefore be rebranded from **Ether Dollar** to
**Statics Dollar** and incorporated into the Statics protocol.

The initial implementation embeds the holder share of mint, redemption, and
flash fees in a per-basket, per-asset fee pot. Existing BasketTokens own that
pot pro rata. A new minter must therefore buy into the historical pot to avoid
diluting existing holders, and a holder normally realizes the accumulated
underlyings by redeeming or selling the BasketToken.

That model has two undesirable consequences for Statics:

1. Historical fee-pot buy-in increases the capital required to mint and makes
   arbitrage progressively more expensive as fees accumulate.
2. Percentage mint and redemption fees scale indefinitely with action size,
   taxing the high-volume arbitrage that Statics is intended to stimulate.

Statics also intends to let a holder access the proportional underlying bundle
through a self-backed loan while retaining eligibility for protocol fee yield.
That position can be recursively leveraged: borrowed underlyings can mint more
BasketTokens, which can be deposited and borrowed against again.

EqualFi's FeeIndex and PositionNFT demonstrate the accounting shape needed to
separate historical fee entitlement from transferable pool principal. Statics
will adopt that accounting idea without importing EqualFi's pool registry,
maintenance accounting, or other product machinery.

## Decision

Statics Dollar and Statics Baskets will be modules of one Statics protocol.
They will share one user-facing `StaticsDiamond`, one PositionNFT namespace,
one authorization model, and one physical-token reservation layer. They will
not share economic ledgers, reward denominators, collateral, debt, or solvency
calculations.

The architecture is:

```text
StaticsDiamond
├── shared PositionNFT ERC-721, ownership, approvals, and position lifecycle
├── shared physical-token reservation and reentrancy accounting
├── Statics Dollar periphery
│   ├── consumable risk-series liquidity and migration
│   ├── fill-created collateral proceeds
│   └── pairing-vault redemption
└── Statics Baskets
    ├── governed genesis and permissionless minting and redemption
    ├── multi-asset fee indexes
    ├── proportional self-backed lending
    └── flash loans

StaticsDollarCoreDiamond
└── Dollar collateral, issuance, health, insurance, and series recovery
```

The Statics Dollar Core remains a narrow backend contract and the permanent
authority for the Dollar and series-specific risk tokens. It binds to the
`StaticsDiamond` as its periphery, fee receiver, managed recovery holder, and
typed user gateway. Keeping Core collateral out of the shared periphery custody
preserves the Dollar solvency boundary without creating a second user account
or rewards system.

Pegged Statics Dollar profiles are direct collateral wrappers, not risk
series. A pegged profile mints and burns Statics Dollar against the configured
pegged collateral at its nominal one-dollar unit conversion while its oracle,
peg band, debt ceiling, mode, and solvency determine whether an action is
available. It creates no Risk Shares, reward book, series transition state, or
PositionNFT leg. Risk Shares and all series machinery are exclusive to
volatile profiles.

For Statics Baskets, the unified protocol will replace embedded holder fee pots
and percentage mint/redemption fees with:

1. flat or threshold-tiered mint and redemption fees denominated in
   basket-equivalent shares;
2. a separate, multi-asset fee index for the canonical hook's basket-staker
   allocation;
3. PositionNFT-owned BasketToken deposits and loans; and
4. proportional underlying loans capped at an immutable 95% protocol LTV.

Basket redemption backing remains static. Accumulated fee rewards are separate
claimable assets and do not change the bundle redeemable by a BasketToken.

### Protocol identity and contract naming

The umbrella protocol and user-facing Diamond are named **Statics**. The
stable-value subsystem is named **Statics Dollar**, and the fixed-bundle
subsystem is named **Statics Baskets**.

Implementation replaces the historical product and contract identifiers with
`StaticsDollar*` names. Token display names are `Statics Dollar` and
`Statics Dollar Risk Shares`; the shared NFT display name is `Statics
Position`. The Risk Shares token represents volatile series only. Exact public
symbols are `USDstx` for the senior Statics Dollar ERC-20 and `ethLEV` for the
volatile-series Risk Share ERC-1155. The global staking token uses `STATICS`.
The PositionNFT symbol remains `etPOS` until separately selected.

### Unified Diamond and Statics Dollar Core

All ordinary protocol actions are exposed through typed facets on the
`StaticsDiamond`. Statics Dollar Core remains directly callable and
permissionless, but integrations should be able to use the unified Diamond for
common Dollar operations, basket operations, position management, borrowing,
repayment, and reward claims.

The existing Dollar Core behavior that exempts every recombination performed
by its configured periphery cannot remain caller-based once the periphery is a
general user gateway. The implementation must replace the blanket
`msg.sender == periphery` exemption with an explicit pairing-vault or managed
recombination path. An ordinary user recombination routed through the
`StaticsDiamond` must have the same economics as an ordinary direct Core
recombination.

The Core and user-facing Diamond have separate storage and independently
scheduled cuts, but they use the same protocol governance authority and form
one protocol. There is no second Statics Basket periphery and no second
position NFT.

Both Diamonds use standard EIP-2535 add, replace, remove, and optional
delegatecall-initialization semantics. Cuts are atomic, but the kernel does not
scan facet bytecode, pin runtime code hashes during dispatch, restrict
initializers to installed self-calls, or add a second upgrade policy. Ownership
transfers in one step using the standard ERC-173 surface.

One OpenZeppelin `StaticsTimelock` owns both Diamonds. Core administration is
therefore authorized by Core Diamond ownership rather than a separate protocol
governor. Profile creation, risk configuration, mode restoration or retirement,
operation resumption, and oracle replacement are direct owner-only operations;
the timelock supplies their delay. The Core does not duplicate that delay with
proposal records, execution windows, or capability locks. The Dollar guardian
is limited to risk-reducing actions: pausing exposure-increasing operations,
reducing debt ceilings, and entering reduce-only mode. It cannot block
proportional holder exits. A profile can be permanently retired only from
reduce-only mode, and retirement is an irreversible runoff state.

Fee, reward, and pairing-redemption parameters on the user Diamond remain
timelock-configurable. They do not have irreversible lock functions. The
timelock starts with a seven-day delay, and OpenZeppelin's self-call-only delay
update remains available through an ordinary scheduled governance operation.

All value-moving facets use ordinary OpenZeppelin `ReentrancyGuard`. Facets on
one Diamond share that Diamond's guard slot under delegatecall, while the Core
and user Diamond retain separate execution locks matching their separate
custody boundaries.

### Shared positions with isolated module books

A single position ID may own any combination of:

- Statics Dollar consumable Risk Share liquidity and fill proceeds;
- deposited Statics BasketTokens from one or more baskets;
- per-basket multi-asset fee checkpoints and claims; and
- per-basket locked collateral, proportional debt, and maturity state.

Position ownership, approvals, transfer, enumeration, and destruction are
shared. Each product module retains namespaced storage beneath the common
position ID. Statics Dollar pairing proceeds accrue only when that series'
supplied Risk Shares are consumed, and basket fees accrue only to eligible
principal in the corresponding basket. Holding one module in a position never
grants a claim on the other module's fees.

The shared position lifecycle tracks whether any module still owns value or an
obligation. A position cannot be burned while it has a Dollar series leg, a
basket leg, claimable rewards, locked collateral, outstanding debt, or pending
recovery state in any module.

Statics Dollar or its risk-series positions do not collateralize Statics
Basket loans. Basket lending remains proportional and self-backed by the same
basket's constituents. Any future cross-product collateral model requires a
separate decision because it would introduce oracle, liquidation, and
cross-module insolvency assumptions.

### Static basket backing

For each basket constituent, one whole BasketToken continues to represent the
configured `bundleAmount`:

```text
base underlying amount = bundleAmount * basketShares / 1e18
```

Minting adds this exact backing and redemption removes this exact backing,
subject only to rounding and the separately calculated action fee. Fee yield
reserves and protocol revenue are not basket redemption backing.

The primary economic accounting invariant for each basket and asset is:

```text
vault balance + outstanding loan principal
    = underlying backing represented by BasketToken supply
```

Fee reserves, protocol revenue, and rounding remainders are tracked outside
both sides of this invariant.

### Flat and threshold-tiered action fees

Mint and redemption use independent fee schedules. Each tier contains a
minimum action size and one flat fee expressed in basket-equivalent shares:

```solidity
struct FeeTier {
    uint256 minActionShares;
    uint256 feeShares;
}
```

The applicable fee is selected from the tier with the greatest
`minActionShares` that does not exceed the requested action size. The selected
fee does not grow within that tier.

For each constituent, the basket-equivalent fee is converted without an oracle:

```text
underlying fee = bundleAmount * feeShares / 1e18
```

Minting pulls the static bundle plus the converted fee. Redemption withholds
the converted fee from the static bundle. Users therefore pay using only the
basket's constituents; no WETH or external fee token is required.

The effective fee rate falls as action size increases. This creates a fixed
hurdle for small arbitrage while allowing high-volume arbitrage to approach the
underlying fixed-bundle price.

Tier schedules should be subadditive so batching is never more expensive than
splitting:

```text
fee(a + b) <= fee(a) + fee(b)
```

If a basket creator chooses a schedule that violates this property, callers
remain free to split their actions. Whether creation-time validation should
enforce subadditivity is deferred.

Basket genesis uses the creation fee as an explicit launch switch. At zero,
only the Diamond owner may create and must send no value. At a positive value,
any caller may create by paying the exact fee. This does not introduce a token
registry, creator allowlist, or constituent certification; it lets governance
keep genesis controlled until the permissionless surface is ready.

Genesis is also the canonical-market launch. The creator, including the
Diamond owner when bootstrapping the first basket, supplies one
constituent-per-BasketToken square-root price and one constituent liquidity
budget for every configured asset, a measured aggregate debit cap for every
constituent, and an execution deadline. Prices are expressed as raw
smallest-unit constituent amounts per raw BasketToken amount.
`createBasket` atomically deploys the BasketToken, initializes and
manager-registers every canonical pool, mints the aggregate pool BasketTokens
through ordinary backing and mint-fee accounting, and locks full-range
permanent liquidity. A basket cannot exist in an unseeded, partially
initialized state. No separate administrator bootstrap or post-creation
initialization surface exists. Constituents whose transfer behavior cannot
settle the exact Uniswap v4 liquidity amount fail launch atomically.

### Multi-asset basket reward index

The canonical hook's basket-staker allocation accrues to a separate reward
reserve. It can be denominated in the BasketToken or any constituent and is
isolated by both basket and reward asset. Primary mint and redemption fees,
loan origination fees, extension fees, and the protocol share of recovery
penalties instead use the global Statics-staker route. The basket reward
accounting shape is:

```text
basketRewardIndex[basketId][asset]
indexedReserve[basketId][asset]
crystallizedReserve[basketId][asset]
totalEligibleShares[basketId]

positionCheckpoint[positionKey][basketId][asset]
positionClaimable[positionKey][basketId][asset]
positionShares[positionKey][basketId]
```

The implementation uses a `1e27` ray for reward-index precision. When a holder
fee is received:

```text
index delta = (fee * 1e27 + prior remainder) / total eligible shares
```

The physical reward asset is reserved before the index advances; increasing an
index without equal reserve backing is not permitted by the accounting model.

Before eligible position shares change, the position settles every constituent:

```text
newly claimable = eligible shares * (global index - checkpoint) / 1e27
```

The checkpoint is then advanced before shares are added or removed. New
deposits cannot claim historical fees, so no historical fee buy-in is needed.

If no eligible shares exist when a hook fee is received, the basket-staker
share redirects to POL rather than becoming a windfall for the first future
depositor.

Claims decrement the isolated fee reserve before transferring each underlying
asset. Claims do not burn BasketTokens, reduce position principal, or require a
basket redemption.

Flash-loan fee calculation is not changed by this ADR. Flash, mint, redemption,
and basket-loan origination fees enter the global Statics-staker route instead
of an embedded BasketToken fee pot. Origination remains
BasketToken-denominated; burning those shares reclassifies their represented
backing before global distribution.

Loan extension is different. Requiring more BasketTokens makes maintenance
depend on acquiring the collateral token being borrowed against. Extension
fees are therefore paid directly in the loan's outstanding constituent
principals:

```text
required extension fee for asset =
    ceil(outstanding principal for asset * extension fee bps / 10,000)
```

The position owner or approved operator supplies a gross amount for every
constituent. Statics measures the amount actually received, requires it to meet
the quoted fee, reserves the full receipt under the affected basket, and
routes the full receipt through global Statics-staker fees. Extension does not
mint or burn BasketTokens and does not change supply, backing, collateral
shares, reward eligibility, or loan principal.

### Pegged Statics Dollar wrappers

Pegged profiles configure independent static mint and redemption fees. Minting
adds nominal collateral principal and senior Dollar liability to the profile,
mints only Statics Dollar, and records the collateral fee as isolated protocol
revenue. Redemption burns any fungible Statics Dollar against the selected
profile's outstanding senior capacity, removes the corresponding proportional
collateral, withholds the redemption fee as protocol revenue, and transfers the
remainder. Pegged fees do not automatically fund volatile insurance or
position rewards; an external account may fund those systems explicitly.

Pegged redemption is quarantined as soon as any volatile downside transition
starts. The quarantine is permissionlessly checkpointed and remains until all
downside transitions have resolved, every active and historical solvency book
is healthy and oracle-available, and that condition has held continuously for
48 hours. Creating a healthy successor series cannot hide or cure the old
series' deficit. Upside transitions do not trigger this pegged-only quarantine.

This amendment is a clean architectural break. Pegged profiles have no fake
series ID or junior-token compatibility path, and loan extension exposes no
BasketToken-fee compatibility selector. Statics targets fresh deployments; no
storage migration or legacy ABI is retained.

### Volatile fee routing and consumption-only Risk liquidity

Risk Shares earn only when a pairing redemption consumes them. There is no
passive tier, activation delay, opt-in conversion, or automatic series-fee
allocation. Staking a Risk Share makes it immediately available for
proportional consumption; unconsumed shares remain withdrawable.

Eligible volatile-series mint and ordinary recombination fees retain the
configured 70% reward and 30% insurance split. The complete reward share enters
the global Statics non-swap ledger. When the series or profile mode is
ineligible, the would-be reward share routes to insurance. Pegged-profile fees
continue to enter the global Statics ledger without a Risk Share allocation.

The managed pairing path charges one independent initial 50-basis-point fee on
the senior collateral allocation. A fill credits the consumed Risk suppliers
with their complete junior collateral residual plus 80% of that pairing fee;
the remaining 20% tops up profile insurance. A per-epoch collateral index makes
those proceeds claimable without looping over PositionNFTs. The index is
advanced only by an actual fill, so staking without consumption earns nothing
and a later supplier cannot claim proceeds from an earlier fill.

Anyone may permissionlessly fund an active or reduce-only volatile series with
its collateral token, Statics Dollar, or the configured STATICS staking token.
These are the only supported incentive assets; callers cannot supply an
arbitrary token address and no incentive-asset registry exists. The Diamond
reserves the measured receipt for that series. A pairing fill releases the same
fraction of each reserve as the fraction of pre-fill Risk liquidity consumed,
and indexes it over that pre-fill supplier cohort. Funding therefore remains
consumption-linked rather than creating passive yield. A fixed-supply STATICS
emissions treasury or distributor can use the same permissionless funding
functions without giving the Diamond token-minting authority.

Series recovery preserves the supplier's intent: successor Risk Shares enter
the successor consumable pool, while any Statics Dollar or collateral recovery
credits remain claimable from the predecessor leg. Unused incentive reserves
roll into the profile's current healthy active series. If the profile is
permanently retired, a permissionless finalization moves the remaining reserves
into the global Statics reward ledger under its existing staker and treasury
split. Finalization is idempotent and does not alter reserves when a pending
transition is cancelled.

This is a clean break. Passive, opt-in, arbitrary-reward, automatic series-fee,
and reward-gate fields and compatibility aliases remain removed. The periphery
storage namespace advances for fresh deployment.

### PositionNFT ownership

Loose BasketTokens remain ordinary permit-enabled ERC-20 tokens. They are
freely transferable and suitable for external liquidity, but they do not accrue
position fee yield.

Statics Dollar likewise implements native EIP-2612. Permit authorization lives
on the standalone token and does not create a gateway-specific signature
system or a general relayed-action surface.

A user becomes fee eligible by depositing BasketTokens into a PositionNFT. The
deposit either creates a new position or credits an existing position. Statics
will also support minting BasketTokens directly into a position so users do not
need a separate mint, approval, and deposit sequence.

The PositionNFT's stable position key may own both Statics Dollar state and
Statics Basket state. For a basket leg it owns:

- deposited and eligible BasketToken shares;
- per-asset fee-index checkpoints;
- accrued and claimable fee yield;
- locked lending collateral;
- underlying basket debt; and
- loan maturity state.

Transferring the PositionNFT transfers every Dollar and basket leg attached to
the position, including assets, fee history, and obligations. Fee history
therefore travels with the position rather than with loose BasketTokens.

The PositionNFT ERC-721 interface is implemented by facets on the
`StaticsDiamond`. The Diamond is both the NFT contract address and the protocol
action address; a separate PositionNFT contract is not deployed. Individual
BasketTokens, the Statics Dollar token, and the series-specific Dollar risk
token retain their required separate token addresses.

Newly deposited shares are subject to a one-block minimum position age or an
equivalent one-block withdrawal restriction. This prevents a single-transaction
flash borrower from depositing immediately before a known fee accrual and
withdrawing immediately afterward. This basket-leg rule does not replace the
longer Statics Dollar reward-eligibility gate. These are economic eligibility
rules, not token-admission or administrative safety restrictions.

All fee settlement is lazy and interaction-driven. There is no keeper or timed
background process: deposits, withdrawals, claims, transfers affecting
eligibility, borrows, repayments, and recoveries perform the required
settlement themselves.

### Position lending

A position may lock deposited BasketTokens as collateral without removing them
from fee-index eligibility. This preserves the product promise that a user can
access liquidity while continuing to earn basket fee yield.

Borrowing returns the proportional underlying bundle:

```text
borrowed asset amount =
    bundleAmount * debtShares / 1e18

debtShares =
    ceil(collateralShares * LTV / 10_000)

penaltyShares =
    ceil(debtShares * recoveryPenaltyBps / 10_000)
```

Borrowers cannot select only one constituent from a multi-asset basket. Keeping
debt composition proportional to collateral composition makes the loan
self-backed and avoids price-oracle and cross-asset liquidation machinery.

The protocol-wide maximum LTV is immutable at 9,500 basis points. A basket may
choose a lower LTV and its creator chooses the recovery penalty. Creation
requires debt plus penalty to fit inside collateral at the configured LTV.
LTV below 100% leaves that recovery capacity and bounds recursive borrowing.

Physical vault liquidity must always cover the backing required by unlocked,
redeemable supply:

```text
vault balance >= bundle backing required by unlocked BasketTokens
```

Borrowing decreases vault balance and increases outstanding principal by equal
underlying amounts. Repayment reverses those entries and unlocks the collateral.
Locked collateral remains included in `totalEligibleShares` throughout the
loan.

Recovery settles the position's basket reward indexes, burns only
`debtShares + penaltyShares`, and unlocks the rest of the tranche's collateral.
Only burned shares leave the reward denominator. The backing removed beyond
written-off principal is the realized penalty. Twenty percent is paid to the
permissionless recovery caller and eighty percent enters the global protocol
fee route. Already-crystallized claims remain attached to the PositionNFT.

### Bounded recursive looping

A position owner may use the following loop:

1. deposit BasketTokens into the PositionNFT;
2. lock them and borrow the proportional underlying bundle;
3. use the borrowed bundle to mint more BasketTokens;
4. deposit the newly minted BasketTokens into the same or another position; and
5. repeat.

Minting returns the borrowed underlyings to basket custody while creating newly
backed supply. The newly deposited shares can then support the next loan layer.

Ignoring fees and rounding, initial collateral `C` and LTV `L` produce:

```text
total deposited shares = C / (1 - L)
total outstanding debt = C * L / (1 - L)
```

At the 95% maximum:

```text
maximum deposited shares = 20C
maximum outstanding debt = 19C
net position equity       = C
```

At 100% LTV, the series has no finite bound. Static fees might slow a loop, but
they are not a valid bound because a basket can configure a zero fee and a
dominant position can receive part of its own fee back through the fee index.
The immutable LTV maximum provides the bound independently of fee policy.

Flat mint fees, rounding, available physical liquidity, and user-selected loop
depth make realized leverage lower than the mathematical maximum. A router may
quote and execute multiple iterations, but the core protocol does not require a
special loop transaction for the state machine to work.

Locked shares remain fully eligible for holder fee yield rather than being
netted against their proportional debt. Allowing recursive positions to
increase fee weight is intentional. It creates leveraged exposure to the fee
stream and corresponding default obligations.

## Required transition ordering

All transitions are interaction-driven. The contracts do not activate
positions, settle rewards, route insurance, process series transitions, mature
loans, or recover expired debt without a caller. User-benefiting transitions
are performed by the user or an approved operator; recovery and maintenance
transitions that need third-party execution must remain permissionless and
carry a sufficient caller incentive where gas would otherwise be uncompensated.

The implementation must preserve the following ordering:

### Mint to a wallet

1. Calculate the static bundle and applicable flat fee.
2. Pull both from the caller.
3. Add the static bundle to basket backing.
4. Split and accrue the fee to existing eligible positions and protocol revenue.
5. Mint BasketTokens to the receiver.

### Mint directly to a position

1. Perform the wallet-mint accounting through fee accrual.
2. Settle the receiving position at the current indexes.
3. Mint into custody and add the new position shares.
4. Set each position checkpoint to the current global index.

The new principal does not receive the fee charged for its own entry.

### Redeem from a wallet

1. Burn the caller's BasketTokens.
2. Remove the static bundle from basket backing.
3. Withhold and accrue the applicable flat fee.
4. Transfer net constituents to the receiver.

### Redeem from a position

1. Settle historical position rewards.
2. Remove the redeemed shares from eligible principal.
3. Burn the shares and perform redemption accounting.
4. Accrue the redemption fee over the remaining eligible shares.

Shares being redeemed do not receive a rebate from their own exit fee.

### Borrow and repay

Borrowing settles the position before locking collateral but does not change
eligible principal. Repayment restores the underlying principal and unlocks the
BasketTokens, again without changing eligible principal.

### Recover

Recovery settles the position, removes recovered collateral from eligible
principal, clears outstanding debt, burns debt plus penalty shares, and unlocks
the remaining collateral. It distributes 20% of the penalty backing to the
caller and routes 80% through protocol fees. It does not confiscate the unused
LTV buffer.

### Statics Dollar Core fee ingress

1. Statics Dollar Core calculates the fee and completes the corresponding local
   collateral accounting.
2. Core transfers the exact fee assets to the `StaticsDiamond`.
3. Core calls the typed Dollar fee-receiver facet with the series, token,
   amount, and fee kind.
4. The Dollar module verifies Core as the caller and attributes the fee among
   its local reward, insurance, and protocol-revenue books.
5. The shared custody layer increases `globalReservedByToken` by the amount
   retained as a module liability. Any amount routed out during the callback
   must leave both the physical balance and local accounting atomically.

If the transfer, callback, local attribution, or global reservation fails, the
entire Core action reverts. A raw token balance arriving without successful
attribution does not create a reward index or a module claim.

### Statics Dollar gateway recombination

1. The approval entrypoints use an existing Statics Dollar allowance. The
   permit entrypoints first checkpoint exit availability, then attempt an
   exact-amount EIP-2612 permit from `msg.sender` to `StaticsDiamond`.
2. The gateway pulls the matching Dollar and series-specific risk amount into
   `StaticsDiamond`. Risk shares still require ERC-1155 operator approval.
3. It calls the ordinary Core recombination path on behalf of the user.
4. Core applies the same recombination fee and health rules used by a direct
   user call.
5. The gateway transfers the resulting net collateral to the requested
   receiver and leaves no unaccounted residual.

A permit failure is tolerated only so a permissionlessly pre-submitted permit
cannot brick the combined call; the subsequent exact `transferFrom` still
requires sufficient allowance. Deferred exits return before permit execution,
leaving the signature nonce and allowance unchanged.

The pairing vault uses a separate explicit Core path because its gross
collateral is split between the Dollar redeemer, consumed Risk suppliers, and
insurance. Being called by the configured periphery is not by itself sufficient
to select that fee treatment.

## Isolation requirements

Every balance, reserve, index, remainder, principal, checkpoint, claim, and loan
must be keyed by the affected basket and asset where applicable. The diamond's
physical token balance is shared custody, but no basket may use another
basket's internally attributed backing or fee reserves.

Because Statics Dollar rewards and Statics Basket custody may contain the same
ERC-20 token, the unified Diamond must also maintain a protocol-wide physical
reservation total:

```text
globalReservedByToken[token]
    = Dollar reward and insurance liabilities held by the Diamond
    + BasketToken position principal held by the Diamond
    + basket backing held by the Diamond
    + basket and canonical-LP reward reserves
    + global Statics-staker and treasury reserves
    + other explicitly accounted module liabilities
```

Each module updates both its detailed local ledger and the shared reservation
total. No module may classify a raw token balance as available merely because
that balance is absent from its own local storage. A transfer, claim, borrow,
recovery, insurance route, or revenue withdrawal must decrease only the
calling module's local attribution and the matching global reservation.

Statics Dollar Core collateral remains physically held and accounted by the
separate `StaticsDollarCoreDiamond`; it is not part of the shared periphery
balance. Statics Dollar series books and Statics Basket books remain separate
even when they refer to the same ERC-20 token or the same PositionNFT.

Permissionless basket creation and arbitrary token selection remain product
decisions. A badly configured or hostile basket can make itself unusable, but
its accounting must not impair other baskets. Governance's protocol-level
remediation remains the ability to mark a basket exit-only.

## Consequences

### Positive

- Statics Dollar and Statics Baskets become one protocol with one user-facing
  Diamond, one position identity, and one integration surface.
- Dollar Risk liquidity and recovery reuse the shared PositionNFT instead of
  creating a competing Statics position system.
- A single transferable position can contain Dollar series exposure and
  multiple independent basket exposures.
- Historical fee buy-in is eliminated.
- Large mint and redemption actions approach the static bundle price, improving
  the economics of external arbitrage.
- Users can realize fee yield without selling or redeeming BasketTokens.
- PositionNFT collateral continues earning yield while supporting a loan.
- Recursive looping is intentionally supported and has a finite protocol-level
  bound.
- Debt and collateral use the same proportional asset vector, avoiding price
  oracles and conventional price-triggered liquidation.
- Fee entitlements, collateral, and debt can transfer together through the
  PositionNFT.
- Loose BasketTokens remain simple, permit-enabled ERC-20 assets.

### Negative

- The unified Diamond has a larger selector, storage, and shared-custody
  surface than either standalone periphery.
- Every module that can hold an ERC-20 must participate correctly in the shared
  physical-token reservation ledger.
- Loose BasketTokens do not directly earn fee-index rewards.
- Users must place BasketTokens in protocol custody to become yield eligible.
- Each fee accrual and settlement is multi-asset and therefore scales with the
  number of basket constituents.
- Leveraged positions can capture more of the fee stream than unleveraged
  positions and may encourage competition toward the maximum LTV.
- PositionNFT buyers must evaluate all transferred Dollar and basket legs,
  debts, locked collateral, and claimable rewards.
- Tier schedules can create transaction-splitting incentives when configured
  without subadditivity.

### Neutral

- Statics Dollar Core remains a separate backend and solvency boundary even
  though the `StaticsDiamond` is the ordinary user-facing gateway.
- Dollar and basket positions share ownership but do not cross-subsidize,
  cross-collateralize, or share reward denominators.
- Fee entitlement travels with the PositionNFT, not with loose BasketTokens.
- External AMMs and other integrations holding loose BasketTokens do not accrue
  unclaimable multi-asset rewards.
- Fee claims and maturity recovery require user or permissionless caller
  transactions; nothing executes automatically.

## Alternatives rejected

### Operate Statics Dollar and Statics Baskets as separate protocols

Separate peripheries would duplicate position ownership, reward checkpointing,
custody reservation, upgrade administration, and frontend approvals. Users
would be unable to transfer or manage their Dollar and basket exposures as one
portfolio. The products are therefore combined under the Statics protocol.

### Add a second Statics PositionNFT beside the Dollar PositionNFT

Two position NFTs behind two Diamonds preserve code-level separation but create
the integration fragmentation this architecture is intended to remove. A
shared position ID with namespaced module books provides one ownership surface
without pooling the products' economics.

### Force Dollar and basket rewards into one generic index

Statics Dollar series books have series transitions, proportional Risk
consumption, and fill-created collateral proceeds. Basket books have a
creator-defined asset vector, multi-asset rewards, and self-backed debt.
Generalizing both into one reward structure would obscure their different
invariants. They share position ownership and physical reservation accounting,
not one economic book.

### Move Statics Dollar Core collateral into the unified Diamond

This would produce one physical custody address but would make permissionless
basket execution and Dollar solvency part of the same runtime failure domain.
Typed gateway facets provide one-address user integration while the separate
Core preserves a narrow collateral, issuance, health, and recovery boundary.

### Continue embedding holder fees in BasketToken backing

This preserves the strongest ERC-20 composability because fee value travels
with every BasketToken. It also requires new minters to buy into historical
fees and forces holders to redeem or sell to realize them. That conflicts with
the desired arbitrage and claimable-yield behavior.

### Keep percentage mint and redemption fees

Percentage fees are simple but impose a constant marginal tax on arbitrage.
High-volume transactions never approach the static bundle price.

### Charge fees in WETH or another external token

An external fee token requires an additional balance, approval, and pricing
decision. Basket-denominated fees can be converted directly into the configured
constituents without an oracle.

### Settle rewards on every BasketToken transfer

Transfer-aware dividend accounting would make every ERC-20 transfer scale with
the basket's asset count. AMMs and other contracts would accrue rewards they may
be unable to claim or distribute correctly. It also couples ordinary token
transfer availability to the fee-accounting system.

### Allow 100% LTV

At 100% LTV, recursive mint-deposit-borrow loops do not have a finite geometric
bound. Fees are configuration-dependent and cannot safely serve as the bound.

### Allow selective constituent borrowing

Borrowing only selected constituents creates changing collateral and debt
values and would require oracle, liquidation, and bad-debt assumptions that the
proportional self-backed design avoids.

### Represent baskets as ERC-4626 vaults

ERC-4626 describes a single-asset share vault with a changing conversion rate.
Statics instead represents a fixed multi-asset bundle and deliberately
separates claimable fee yield from redemption backing.

## Deferred parameters and follow-up decisions

This ADR does not select:

- the final public symbol for the PositionNFT;
- concrete mint or redemption fee thresholds and fee-share amounts;
- whether tier subadditivity is enforced onchain or only surfaced by quotes;
- router limits on loop depth and execution slippage.

Those decisions must preserve the accounting, isolation, ordering, and maximum
LTV established here.

The current implementation resolves the operational choices as follows: the
typed gateway exposes ETH/WETH deposit and ordinary ETH/WETH recombination;
the canonical hook initializes to 40% POL, 10% canonical LPs, 20% deposited
BasketTokens, 20% global Statics stakers, and 10% treasury; already-claimable
rewards remain attached after loan recovery; the basket creator selects LTV
and recovery penalty within the protocol bound; and expired-loan penalty
backing pays 20% to the recovery caller and 80% to the protocol fee route.

## Implementation acceptance criteria

The eventual implementation must prove at minimum that:

- one PositionNFT can hold Statics Dollar legs and multiple Statics Basket legs
  without merging their reward or debt accounting;
- a position cannot be burned while any Dollar or basket module retains value,
  debt, a claim, or pending recovery state under its position ID;
- an ordinary Statics Dollar recombination has identical fee economics whether
  called directly on Core or through the `StaticsDiamond` gateway;
- only the explicit pairing or managed recombination path receives the Dollar
  periphery fee treatment;
- every module liability contributes to `globalReservedByToken`, and no module
  can spend a token balance reserved by another module;
- Statics Dollar rewards do not accrue to basket principal and basket fees do
  not accrue to Dollar principal;
- a new position cannot claim fees accrued before its deposit;
- minting directly to a position does not rebate that mint's fee to the new
  principal;
- redeemed position shares do not receive their own redemption fee;
- every claim is fully backed and decreases only its basket-asset reserve;
- one basket cannot consume another basket's backing or fee reserve, including
  when both baskets use the same underlying token;
- locked collateral remains fee eligible through borrow and repay;
- recovery removes only burned debt and penalty shares from fee eligibility and
  unlocks the remainder;
- recovery never charges more than the configured percentage of debt;
- the recovery caller receives 20% of penalty backing and no principal;
- proportional borrowing preserves economic backing and unlocked-supply
  liquidity invariants;
- no configured basket can exceed 95% LTV;
- recursive looping converges under the maximum LTV; and
- same-transaction flash deposits cannot capture and immediately withdraw fee
  yield.
