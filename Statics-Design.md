# Statics — Unified Protocol Design Document

## Static Multi-Asset Baskets, Statics Dollar, Position-Owned Finance, and Permanent Liquidity

**Version:** 2.2

**Status:** Living implementation design; no public Statics deployment is recorded

**Last updated:** 2026-07-24

**Source revision reviewed:** `a8ecbb805a961a0e2da5c3d495fac7888ce92a1a`

---

## Table of Contents

1. [Overview](#overview)
2. [Design Principles and Boundaries](#design-principles-and-boundaries)
3. [System Topology](#system-topology)
4. [Tokens and Ownership Objects](#tokens-and-ownership-objects)
5. [Shared PositionNFT](#shared-positionnft)
6. [Static Basket Model](#static-basket-model)
7. [Basket Minting and Redemption](#basket-minting-and-redemption)
8. [Global Staking and Rewards](#global-staking-and-rewards)
9. [Position-Owned Basket Lending](#position-owned-basket-lending)
10. [Basket Flash Loans](#basket-flash-loans)
11. [Canonical Uniswap v4 Liquidity](#canonical-uniswap-v4-liquidity)
12. [Borrow-to-Liquidity](#borrow-to-liquidity)
13. [Statics Dollar](#statics-dollar)
14. [Custody, Reservations, and Accounting Isolation](#custody-reservations-and-accounting-isolation)
15. [Lifecycle, Pauses, and Recovery](#lifecycle-pauses-and-recovery)
16. [Governance and Upgradeability](#governance-and-upgradeability)
17. [Integration Surfaces](#integration-surfaces)
18. [Deployment Model](#deployment-model)
19. [Security and Trust Assumptions](#security-and-trust-assumptions)
20. [Testing and Assurance](#testing-and-assurance)
21. [Implemented, Deferred, and Excluded](#implemented-deferred-and-excluded)
22. [Appendix A: Formula Reference](#appendix-a-formula-reference)
23. [Appendix B: Correctness Properties](#appendix-b-correctness-properties)
24. [Appendix C: Terminology](#appendix-c-terminology)

---

## Overview

Statics is a standalone protocol for fixed-composition multi-asset baskets, a
collateralized Statics Dollar system, position-owned lending, global
multi-asset fee rewards, basket-vector flash loans, and canonical Uniswap v4
liquidity. Basket definitions are immutable after creation; the current
pre-release Diamonds remain upgradeable under timelock governance.

Most user actions and shared custody live behind one upgradeable
`StaticsDiamond`. Statics Dollar collateral, issuance, health, insurance, and
recovery remain behind a separate `StaticsDollarCoreDiamond`. Every basket has
its own transferable ERC-20 BasketToken, but the basket action surface and
custody remain at the common Diamond address.

Basket backing, debt, recovery, Dollar books, global fees, staking custody, and
canonical liquidity are separately accounted. Fee sources may intentionally
aggregate by asset in the global reward ledger; this does not merge basket
backing or let one basket consume another basket's assets.

### Key characteristics

| Property | Design |
| --- | --- |
| Basket composition | One to sixteen unique ERC-20 constituents with immutable bundle amounts |
| Basket share token | Separate 18-decimal ERC-20 Permit token for each basket |
| Basket accounting | Static aggregate-supply backing; no NAV or price oracle |
| Position ownership | One shared ERC-721 at `StaticsDiamond` |
| Basket collateral | Optional BasketToken deposit leg; deposited and locked shares earn isolated basket rewards |
| Global rewards | Unlimited global assets; each PositionNFT selects at most 64 reward assets |
| Non-swap fee split | 90% to active global stakers and 10% to treasury; unavailable staker allocation goes to treasury |
| Canonical swap fees | Separate input and output hook fees; launch default is 25 BPS on each realized leg |
| Swap-fee split | Launch default 40% permanent liquidity, 10% eligible canonical LPs, 20% deposited BasketTokens, 20% global Statics stakers, 10% treasury |
| Canonical native LP fee | Zero |
| Permanent liquidity | Hook-owned full-range liquidity, compounded from matched swap-fee inventory |
| Flash callbacks | May call ordinary basket mint and redemption; nested flash loans remain blocked |
| Upgradeability | Pre-release EIP-2535 Diamonds owned by one timelock; intended final release removes Diamond-cut authority after governance review |

### Release qualification

This document describes the implementation at the pinned source revision, not
an audit, immutable release record, or public deployment record. Production
value requires an independent contract and governance review, target-chain
rehearsal, verified contract publication, explicit governance and economic
configuration, and successful default, security-profile, deployment, and
pinned-fork test runs against the exact release commit.

A release qualification record must bind one source commit and design version
to compiler settings, constructor and governance inputs, dependency and
selector manifests, runtime-code hashes, test profiles and timestamps, deployed
addresses, and explorer verification. Historical internal reviews, rehearsal
manifests, and X-Ray reports predate the pinned revision and do not qualify it.

## Design Principles and Boundaries

### Principles

- Preserve fixed basket quantities rather than converting baskets into
  ERC-4626 vaults or price-based funds.
- Keep one user-facing Diamond and one shared PositionNFT while retaining
  module-local and basket-local accounting.
- Measure real token balance deltas at every custody boundary.
- Use typed public entrypoints; do not add arbitrary target-and-calldata
  execution.
- Keep ordinary fees, approvals, slippage checks, and lifecycle restrictions
  active during composed operations.
- Make risk-reducing maintenance permissionless where the recipient and
  accounting result are fixed.

### Explicit boundaries

Statics does not provide:

- an asset allowlist or compatibility certification;
- NAV accounting, oracle-priced basket minting, or ERC-4626 semantics;
- cross-basket backing, debt netting, or cross-product collateralization;
- privileged flash-loan callbacks or fee exemptions;
- a production arbitrage router, receiver registry, or arbitrary executor;
- a guarantee that arbitrary ERC-20 behavior is compatible;
- automatic background execution;
- a protocol-owned PositionManager NFT for canonical permanent liquidity; or
- live in-place replacement of immutable V1 hook, PoolManager, or manager
  dependencies after final immutability.

## System Topology

```text
Users and integrators
        |
        v
StaticsDiamond
├── EIP-2535 dispatch and governance
├── PositionNFT ERC-721
├── basket creation, mint, redeem, collateral, lending, and flash loans
├── global staking, reward claims, and treasury fee distribution
├── Statics Dollar typed gateway and periphery accounting
├── shared custody reservations
└── canonical pool lifecycle and borrow-to-liquidity
        |
        +-------------------------> StaticsDollarCoreDiamond
        |                           ├── collateral and issuance
        |                           ├── health and transitions
        |                           ├── insurance and recovery
        |                           └── risk-series state
        |
        +-------------------------> StaticsSwapFeeHook
        |                           ├── bilateral swap fees
        |                           ├── observations
        |                           └── hook-owned permanent liquidity
        |
        +-------------------------> StaticsLiquidityManager
                                    └── typed user PositionManager NFT creation
```

### Canonical deployment shape

The current launcher and deployment tests expect:

- **21 facets / 183 selectors** on `StaticsDiamond`; and
- **11 facets / 95 selectors** on `StaticsDollarCoreDiamond`.

These are source-revision expectations verified through loupe enumeration, not
facts about a public deployment. The checked-in Core rehearsal snapshots record
11 facets / 95 selectors before finalization and 10 / 93 afterward; the latter
is historical because current bootstrap finalization validates and clears
bootstrap authority without removing selectors. Regenerate both snapshots from
the exact release commit before using them as qualification evidence.

`StaticsDiamond` is simultaneously the basket action address, PositionNFT
address, Statics Dollar gateway, Core periphery, Core fee receiver, and managed
recovery holder. There is no separate user router or PositionNFT proxy.

### Economic isolation

For every asset, the Diamond distinguishes:

- each basket's backing, debt, and recovery accounting;
- Statics Dollar periphery reservations;
- global fee liabilities and treasury accrual;
- configured staking-token custody; and
- unreserved donations.

Global rewards intentionally aggregate eligible fees from multiple baskets and
Dollar profiles by reward asset. That aggregation is confined to the fee
account and never increases BasketToken redemption backing.

## Tokens and Ownership Objects

| Object | Standard | Owner or holder | Purpose |
| --- | --- | --- | --- |
| BasketToken | ERC-20 Permit | Users, positions, or external venues | Transferable claim on a fixed constituent bundle |
| PositionNFT | ERC-721 | User-selected owner | Owns staking, basket collateral, loans, and Dollar legs |
| Staking token | Configured ERC-20 | Reserved by `StaticsDiamond` per position | Stake weight; each reward asset uses only opted-in eligible stake as its denominator |
| Statics Dollar | ERC-20 Permit | Users and integrations | Senior Dollar claim |
| Risk Shares | ERC-1155 | Users or PositionNFT legs | Series-specific residual Dollar risk |
| User v4 LP NFT | Uniswap PositionManager ERC-721 | User or voluntary `StaticsDiamond` custody | Canonical liquidity and optional hook-fee rewards |

The current canonical pools have zero native LP fee, so user v4 positions do
not earn ordinary native LP fees. Their swaps still pay the Statics hook's
configured input and output fees.

## Shared PositionNFT

One PositionNFT can own several independent legs:

- a global staking balance and accrued multi-asset claims;
- deposited and locked BasketTokens used as lending collateral;
- independent basket loan tranches;
- immediately consumable Statics Dollar Risk Share liquidity and its fill
  proceeds; and
- pairing-vault state.

ERC-721 ownership and approvals authorize attached legs. Transferring the NFT
transfers its staking balance, reward claims, collateral, and obligations.
Integrators must inspect every active leg before accepting a transfer.

`closePosition` succeeds only after all balances, claims, collateral, loans,
and Dollar legs are empty. User-owned Uniswap v4 NFTs are not PositionNFT legs
and do not move with a PositionNFT transfer.

## Static Basket Model

A basket definition contains:

- one to sixteen unique, nonzero ERC-20 asset addresses;
- a nonzero static bundle amount for each asset;
- independent flat mint and redemption fee-tier arrays;
- flash, origination, and extension percentage fees;
- LTV at or below 9,500 BPS; and
- a loan duration.

The percentage fees are capped at 10,000 BPS. Flat fee-tier values are
BasketToken-denominated quantities, not percentages. Tier arrays may be empty,
unordered, or contain duplicate thresholds. Selection scans all entries and
uses the greatest threshold not exceeding the action size; a later entry wins
when thresholds are equal. Clients should not assume sorted or unique tiers.

When `creationFee()` is zero, public creation is closed and only the Diamond
owner may create a basket with zero native value. A positive fee opens creation
to any caller that pays the exact amount. The fee is therefore both the public
admission switch and the required payment; zero never means free public
creation. Creation records the creator for discovery but gives that address no
administrative authority. This switch does not approve or certify constituent
tokens.

Creation requires one launch-price and paired-asset budget per constituent.
The price is expressed semantically as the square root of constituent units per
BasketToken, independent of Uniswap currency ordering. The aligned
`maxAmountsIn` value caps the creator's complete debit for that constituent:
the paired-asset amount plus the backing and ordinary mint fee required for the
aggregate BasketTokens placed across all canonical pools.

The single creation call deploys the permit-enabled BasketToken, registers and
initializes every canonical PoolKey, registers every pool with the installed
liquidity manager, mints the aggregate pool BasketTokens through ordinary
backing and fee accounting, and seeds hook-owned full-range permanent
liquidity. The owner uses exactly the same funded path for a controlled genesis
basket. If any constituent fails, the native creation fee, token deployment,
pool state, backing, reservations, and permanent liquidity all roll back.
There is no valid unseeded or partially launched basket state.

### Aggregate-supply backing

For constituent bundle amount `b[i]` and BasketToken supply `S`, required
backing is:

```text
backing[i](S) = ceil(b[i] * S / 1e18)
```

Mint and redemption use differences between aggregate backing values. This
prevents per-action rounding from accumulating an accounting deficit.

Only basket vault balances back BasketToken supply. Global fees, basket and LP
reward reserves, staking custody, Dollar books, and hook liquidity are
separate.

## Basket Minting and Redemption

### Minting

`quoteMint` returns each asset's backing increase plus the selected flat fee.
The caller supplies per-asset maximums. The Diamond measures inbound receipts,
credits only the backing increase to the basket vault, moves the measured fee
to the global fee account, and mints the requested BasketTokens.

The ordinary collateral paths are:

- `createAndMintBasketCollateral`; and
- `mintBasketCollateral`.

They apply the same quote and fee rules as wallet minting.

### Redemption

`quoteRedeem` returns each asset's backing reduction less the selected flat
fee. The Diamond burns BasketTokens, reduces basket backing, transfers the
receiver's net assets subject to per-asset minimums, and moves the fee to the
global fee account.

The position path is `redeemBasketCollateral`. Locked collateral cannot be
withdrawn or redeemed.

BasketToken ownership alone does not earn protocol fees. Users must stake the
configured global staking token in a PositionNFT and select reward assets to
enter those assets' eligible-stake denominators.

## Global Staking and Rewards

Statics has one immutable-at-initialization staking-token address. The token
must be a deployed contract and staking transfers must be exact: taxed or
otherwise balance-changing staking tokens are rejected.

`createAndStake` creates a PositionNFT, selects its initial reward assets, and
stakes in one call. `stake` increases an existing authorized position.
`optInRewardAssets` and `optOutRewardAssets` manage that position's selections.
Stake is always withdrawable. Initial stake, new selections, and top-ups enter
a per-asset pending tranche that matures at the next hourly boundary at least
24 hours later. Mature stake remains eligible when a position is increased.
Fee accrual and position interactions roll the affected asset's bounded
maturity ring before updating its index. Each matured bucket records its
activation index so pending stake cannot capture historical fees. `unstake`
removes pending stake before eligible stake and requires an exact outbound
transfer. A full unstake clears the selection list while preserving already
settled claims.

### Non-swap fee routing

Primary mint and redemption fees, lending origination backing
reclassification, extension fees, measured flash-loan excess, and pegged
profile fees enter the same non-swap ledger. If at least one position selected
the asset and has stake:

```text
staker amount  = floor(gross fee * 9,000 / 10,000)
treasury amount = gross fee - staker amount
```

If the asset has no eligible selected stake, no new staker liability is created
and the entire fee accrues to treasury. The 90/10 allocation remainder belongs
to treasury. Index division floors `staker amount * 1e27 / eligibleStake`, while
`indexedAmount` records the complete staker allocation; whole-token value that
never crystallizes to a position is routed to treasury only when that asset's
eligible stake returns to zero.

### Reward indexes and claims

The ledger can create a reward book for any asset and uses 1e27 index
precision. Each PositionNFT may select at most 64 assets, so every
position-owned action remains bounded without imposing a protocol-wide asset
cap. Each asset's index denominator is the stake of positions currently
selected into that asset. A new selection checkpoints the current index and
does not receive historical rewards. Opt-out settles earned value before
removing the position's stake from the denominator.

Claims are pull-based, require PositionNFT authorization, and accept a
per-asset minimum received amount. Claim settlement transfers from the global
fee reservation and never reduces basket backing.

`pendingRewards`, `stakePosition`, `positionRewardAssets`, and
`isRewardAssetOptedIn` are authorization-gated because their values belong to a
PositionNFT. `rewardAsset`, `maxRewardAssetsPerPosition`, `stakingToken`,
`totalStaked`, `treasuryAccrued`, and `canAccrueStakerRewards` expose global
state. Anyone may distribute accrued treasury fees, but the receiver is always
the configured treasury.

Anyone may call `distributeTreasuryFees(asset)`, but the destination is always
the configured treasury. The caller cannot choose a recipient.

## Position-Owned Basket Lending

Only BasketTokens deposited through the collateral interface can be locked for
borrowing. Deposited and locked BasketTokens earn their basket's share of
canonical hook fees in both the BasketToken and constituent assets.

`borrow` creates an independent tranche owned by the PositionNFT. The
origination fee is represented as a BasketToken-share reduction whose
underlying backing is reclassified into the global fee ledger. The remaining
locked shares determine debt shares at the configured LTV and a
creator-selected recovery penalty proportional to that debt. Debt plus penalty
must fit inside collateral. There is no price-oracle liquidation.

Repayment is permissionless and pulls the stored principal vector. Extension
is PositionNFT-authorized, measures the full inbound vector, requires at least
the quote, and routes the complete measured receipt through global non-swap
fees. It does not change principal or collateral.

After maturity plus one hour, recovery is permissionless and removes only the
expired tranche. Recovery burns debt plus penalty shares, clears the stored
principal vector, and unlocks all remaining collateral. For each constituent:

```text
penalty backing = backing removed by debt plus penalty shares - stored principal
caller bounty = floor(penalty backing * 20%)
protocol amount = penalty backing - caller bounty
```

Because principal is bounded by the self-backed collateral vector and LTV is at
most 95%, an unpaid loan does not create bad debt or a claim on another basket.
Only the configured debt-proportional penalty is charged: 20% pays the
permissionless recovery caller and 80% enters the ordinary global protocol-fee
route. Recovery settles basket rewards first, removes only burned shares from
their denominator, and preserves already-crystallized claims.

At 95% LTV, an ideal zero-fee recursive mint, deposit, and borrow sequence
converges below 20 times initial deposited shares and 19 times initial debt.
Routers must impose their own depth, quote-freshness, approval, and slippage
limits.

## Basket Flash Loans

Flash loans borrow the basket's configured constituent vector for a
BasketToken-equivalent share amount. `quoteFlashLoan` returns principal and a
quoted fee for every constituent.

`FlashLoanFacet` uses OpenZeppelin `ReentrancyGuardTransient`. Short persistent
guard phases protect disbursement and repayment accounting, while the receiver
callback runs outside the common persistent guard. Therefore a callback may
call the ordinary public `mint` and `redeem` entrypoints. Those calls receive
no privilege and pay all normal basket and hook fees. The transient guard still
rejects nested `flashLoan` calls.

Outbound disbursement must debit the Diamond and credit the receiver by exactly
the quoted principal. Outbound-tax and sender-extra-tax assets are incompatible
and revert atomically.

After the callback returns the required hash, the Diamond requests principal
plus quoted fee and measures its actual receipt. Success requires:

```text
measured receipt >= principal
actual fee = measured receipt - principal
```

The basket vault is restored by exactly the principal. Actual excess, which
may differ from the quote for an inbound-tax token, enters the global non-swap
fee ledger. A callback revert, invalid return hash, nested flash attempt, or
insufficient measured principal reverts the entire transaction.

### Arbitrage composition

An overpriced multi-asset route can borrow the constituent vector, pay the
ordinary mint fee, mint BasketTokens, divide them among canonical pools, sell
them, and retain profit only after every constituent repayment and minimum
profit is covered.

An underpriced single-asset route can borrow the constituent, buy discounted
BasketTokens, redeem through the ordinary basket entrypoint, and recognize
profit only after redemption, flash, price-impact, rounding, and bilateral hook
fees.

Searchers must deploy purpose-built receivers with typed pools, exact approval
scope, slippage bounds, repayment checks, and minimum-profit enforcement.
Statics provides no receiver allowlist, generic router, callback privilege, or
fee exemption. Cancun transient storage (EIP-1153) is a deployment prerequisite.

## Canonical Uniswap v4 Liquidity

There is at most one canonical hooked pool per basket constituent. Its
currencies are the BasketToken and constituent, with:

| Parameter | Current value |
| --- | --- |
| Native v4 LP fee | 0 |
| Tick spacing | 10 |
| Warm-up | 1 hour |
| Reference window | 30 minutes |
| Maximum spot/reference deviation | 100 BPS |

Initialization is atomic with basket creation and uses the creator-supplied
price and asset budget. The new pool is immediately swappable in `Warming`
state. Activation remains owner/timelock-only because it authorizes
price-sensitive protocol exposure; it requires warm-up, at least two
observations, a valid 30-minute reference, and the fixed deviation bound.
Checkpointing is permissionless. There is no standalone initialization or
manager-sync action.

The installed hook rejects native currency and nonzero native LP fees for
registered canonical pools. Unregistered pools are not canonical.

### Bilateral hook fees

The hook charges separately against realized input and output legs. The launch
manifest configures 25 BPS on each leg. Governance may update both rates and
the split, but the combined input-plus-output fee cannot exceed 200 BPS and the
split must total 10,000 BPS.

For each charged leg, the launch split is:

```text
40% permanent liquidity
10% eligible canonical LPs
20% deposited BasketTokens
20% global Statics stakers
10% treasury
```

Treasury receives split dust. If a pool has no activated staked liquidity, its
LP share redirects to permanent liquidity. If either basket or Statics staking
cannot accept the reward asset, that share independently redirects to
permanent liquidity.

LP, basket-staker, Statics-staker, and treasury shares are transferred
immediately to the Diamond's fee ledger. LP shares accrue through pool-local
indexes for both currencies.
The permanent-liquidity share remains in the hook. When both pool
currencies are available, the hook compounds matched inventory into its own
full-range position during swap settlement. Unmatched amounts remain pending;
anyone may call `compoundPermanentLiquidity` later.

The global split is the default, not an immutable pool policy. Timelocked
Diamond governance may set a canonical pool override using the same five-way
POL, canonical-LP, basket-staker, Statics-staker, and treasury allocation whose
shares sum to 10,000 BPS. Clearing an
override restores the latest global split. Overrides change future allocation
only: pending POL is not released or reclassified, hook-owned liquidity stays
permanent, and existing two-sided pending inventory remains eligible for
compounding. The unavailable canonical-LP, basket-staker, and Statics-staker
fallbacks to POL are identical under global and pool configurations. No
threshold, volume, liquidity, or oracle rule changes an override automatically.

Permanent liquidity is hook-owned and locked while the pool is active. It has
no PositionManager token ID, 24-hour epoch, seven-day ramp, minimum epoch size,
or primary basket-fee reserve. Fees earned by the hook's position are collected
back into its pending inventory and may be compounded again.

### Exit-only unwind

After a basket enters `ExitOnly`, anyone may call `unwindBasketLiquidity` once
per constituent. The flow marks the pool decommissioned, releases full-range
hook liquidity and pending inventory to the Diamond, burns returned
BasketTokens, reduces their represented backing, and accrues the released
constituent and backing reclassification to global treasury fees. User-owned
PositionManager NFTs are untouched.

### Canonical LP rewards

Any unsubscribed, nonzero, full-range PositionManager NFT for an active
canonical pool may be attached to a PositionNFT and transferred into voluntary
Diamond custody only when the LP NFT and PositionNFT have the same current
owner. PositionNFT authorization or ERC-721 approval alone does not substitute
for that ownership match. Eligibility does not depend on whether the NFT
originated from `borrowAndProvideLiquidity`. Initial liquidity becomes reward
eligible in the next block. An in-custody increase preserves the existing
eligible weight and delays only the added liquidity until the next block.

There is no LP unstake cooldown. The PositionNFT owner may withdraw the NFT in
the staking block or in any basket lifecycle state. Withdrawal settles earned
rewards to the PositionNFT before returning the NFT, so a later reward-token
failure cannot trap the external position. Unclaimed rewards remain attached
to the PositionNFT, and transferring that PositionNFT transfers claim and
custody authority. Users must unstake before decreasing or burning the v4 NFT.

## Borrow-to-Liquidity

`borrowAndProvideLiquidity` is an optional typed convenience path. It performs
an ordinary position-owned borrow, applies the ordinary origination fee,
calculates an ordinary basket mint from retained principal, and creates one
user-owned PositionManager NFT per supplied canonical pool.

Those NFTs receive no automatic reward eligibility. The recipient may later
stake any qualifying full-range NFT through the ordinary canonical LP reward
entrypoint.

`borrowAndStakeLiquidity` is the PositionNFT-owned alternative. It accepts the
same one-pool-per-constituent construction but requires full-range positions,
mints the NFTs directly to the Diamond, and records them as pending LP legs
under the borrowing PositionNFT. The current PositionNFT owner receives unused
principal and PositionManager refunds even when an approved operator calls.
LP weight activates in the next block, while the locked BasketToken collateral
continues earning basket rewards. Borrowing, minting, custody, and reward
registration revert atomically.

The caller supplies aligned pool keys, tick ranges, exact liquidity,
per-currency maximums, a deadline, and `lpRecipient`. Every pool must be active,
manager-synced, unique, and associated with the basket constituent. Any stale
price, bad pool, cap, deadline, range, approval, or principal requirement
reverts the loan, mint, and every LP creation.

Unused inputs are returned to `lpRecipient`. The manager's transaction-scoped
inventory cannot enter basket backing, global staking, permanent liquidity, or
another user's accounting. User v4 NFTs remain independent of later
PositionNFT transfer, loan repayment, extension, recovery, or basket
decommissioning.

## Statics Dollar

Statics Dollar is a collateralized system with:

- a fungible, permit-enabled senior ERC-20;
- ERC-1155 Risk Shares for volatile collateral series;
- optional pegged profiles that mint no Risk Shares; and
- a typed Diamond gateway over a separate Core Diamond.

The initial volatile profile uses configured WETH and a Chainlink-compatible
ETH/USD adapter with explicit staleness, range, and sequencer checks. Volatile
profiles issue equal nominal amounts of Statics Dollar and series Risk Shares.
Recombination burns matching claims and returns collateral when the health
state permits.

Expired volatile-series risk recovery is separately permissionless. It burns
the required senior and Risk Share claims, settles the expired recovery book,
and may issue successor pairs according to the selected recovery mode. Unlike
basket-loan recovery, this Dollar path includes a positive quoted keeper bounty
in the collateral paid to its caller; the managed periphery path forwards the
same caller amount. Minimum keeper output remains caller-bounded.

Pegged profiles are direct collateral wrappers. Minting pulls nominal
collateral plus a configured fee; redemption burns Statics Dollar and returns
proportional collateral less its configured fee. Pegged fees route entirely to
the global non-swap fee ledger.

### Typed gateway permits

`recombineToWETHWithPermit`, `recombineToETHWithPermit`,
`mintPeggedWithPermit`, and `redeemPeggedWithPermit` bind permit owner to
`msg.sender`, spender to `StaticsDiamond`, and value to the exact token amount
consumed. Recombination and redemption perform their availability checks before
attempting permit, so a deferred exit does not consume the signature in that
transaction.

EIP-2612 submission is permissionless. The gateway therefore tolerates a failed
permit attempt and continues into the ordinary caller-funded allowance pull.
Prior submission of the same signature cannot brick the typed action; an
invalid, expired, or replayed signature still fails unless `msg.sender` already
granted sufficient allowance. This fallback cannot consume another owner's
allowance because every pull remains bound to `msg.sender`. Volatile
recombination additionally requires the caller's ERC-1155 Risk Share operator
approval. Non-permit entrypoints remain available for prior approvals and
contract wallets.

### Atomic pegged mint and ordinary recombination

A Risk Share holder may exit an active volatile series without first sourcing
Statics Dollar externally. Call
`quoteMintPeggedAndRecombine(peggedProfileId, volatileProfileId, seriesId,
riskAmount)`. An executable quote has `eligible == true` and `exitStatus ==
Available`; it identifies both collateral tokens and returns the exact temporary
Dollar amount, pegged principal and mint fee, total pegged input, volatile
output, and recombination fee.

Before allowance-backed execution:

1. approve `StaticsDiamond` for at least `totalPeggedCollateralIn` of the quoted
   pegged token;
2. call `setApprovalForAll(StaticsDiamond, true)` on Statics Dollar Risk Shares;
   and
3. call `mintPeggedAndRecombine` with a fresh maximum pegged input, minimum
   volatile output, and receiver.

No Statics Dollar approval is required. The gateway mints the exact Dollar
amount directly to the Diamond, pulls the caller's matching Risk Shares, and
burns both claims through ordinary Core recombination in the same transaction.
The caller never receives the temporary Dollar. Any mint, transfer, health,
series, slippage, output-measurement, or residual-custody failure reverts the
complete operation.

`mintPeggedAndRecombineWithPermit` replaces only the pegged-token approval and
requires that collateral token to implement EIP-2612. Its signature value is
the exact quoted total pegged input. As with the other gateway permit paths, a
failed permit attempt may fall back to an existing sufficient caller allowance;
the ERC-1155 operator approval is still required.

The selected series must be `Active` and belong to `volatileProfileId`.
Recoverable and retired series are deliberately excluded: this typed route uses
ordinary recombination only and never enters managed or expired-risk recovery.
Both execution variants return `(status, peggedCollateralIn,
volatileCollateralOut)`. After validating the request's non-health-sensitive
shape, execution checkpoints global health before any pegged mint preview,
permit, or custody. A non-`Available` checkpoint emits
`PeggedMintAndRecombineDeferred` and returns its status with both amounts zero.
That non-reverting deferral preserves the impairment latch and full recovery
delay while consuming neither a permit nor user tokens. A matured recovery quote
reports `Available` because the next execution checkpoint will clear the latch
at the same boundary.

Available execution continues through the ordinary atomic lifecycle, and
`minimumVolatileCollateralOut` is enforced against the receiver's observed
token-balance increase. Index `PeggedMintAndRecombineDeferred` and
`PeggedMintedAndRecombined` for discovery, then reconcile balances and current
Core state.

### Dollar reward and insurance routing

For an active volatile series in an eligible profile mode, the configured
insurance portion routes to insurance and the complete remaining reward share
enters the global Statics non-swap fee ledger. Risk Share positions receive no
mint-fee, ordinary-recombination-fee, donation, or passive allocation. When the
series or profile mode is ineligible, the would-be global reward share routes
to insurance instead.

This coexistence does not merge Dollar collateral held by Core with Diamond
custody. Only fees explicitly transferred to the periphery enter shared
reservations.

### Risk Share positions and pairing liquidity

`createAndStakeRiskShares` and `stakeRiskShares` place Risk Shares into
immediately consumable pairing liquidity owned by a PositionNFT. There is no
pending tranche, reward gate, passive tier, or separate opt-in action.
`unstakeRiskShares` returns unconsumed effective principal at any time.

`PairingVaultFacet.redeem` and `redeemToETH` let a Statics Dollar holder
recombine against available supplied Risk Shares. The flow may fill partially,
uses the explicit managed Core path, and enforces caller-supplied minimum fill,
minimum collateral-per-Dollar rate, and deadline. The fixed senior allocation
goes to the redeemer. Consumed suppliers receive their complete junior
collateral residual plus 80% of the pairing fee; the remaining 20% tops up
insurance. A series-and-epoch index records only proceeds created by an actual
fill, preventing a later supplier from claiming earlier proceeds without
looping over PositionNFTs.

Series transitions are processed once at aggregate Diamond custody and settled
per position lazily. Successor Risk Shares corresponding to supplied
predecessor liquidity remain supplied, while recovery-created Dollar and
collateral credits remain claimable from the predecessor leg. A Dollar leg
cannot be closed while Risk liquidity, fill proceeds, or migration value
remains.

## Custody, Reservations, and Accounting Isolation

For each ERC-20 at `StaticsDiamond`:

```text
globalReserved(token)
  = dollarAccount(token)
  + feeAccount(token)
  + stakingAccount(token)
  + sum over all basketAccount(basketId, token)

physical balance(token) >= globalReserved(token)
```

Each basket account covers that basket's vault backing, outstanding debt
accounting, and recovery state according to the module's equations. Moving a
reservation between accounts does not change the global total.

Every inbound transfer measures the Diamond's actual balance increase. Every
outbound transfer caps the Diamond's debit and, when the public function offers
a minimum, separately checks the receiver's observed increase. These rules
support some fee-on-transfer assets without claiming universal compatibility.

Other physical locations are intentionally outside the Diamond equation:

- `StaticsDollarCoreDiamond` holds Core collateral and insurance;
- `StaticsSwapFeeHook` holds pending and locked permanent-liquidity assets;
- `StaticsLiquidityManager` may hold only transaction-scoped user LP inputs;
  and
- Uniswap v4 `PoolManager` holds pool liquidity under v4 accounting.

Direct donations are unreserved and do not inflate backing, fee claims, or
stake. Normal protocol operations, including unpaid self-backed loans, preserve
full physical reservation backing and define no socialized-loss waterfall.
Negative rebases, arbitrary burns, deceptive `balanceOf`, blocklists, external
custody failures, or compromised code or governance can nevertheless create a
black-swan physical deficit or halt baskets sharing a token.

A deficit is an invariant violation and security incident, not an expected
credit outcome. Custody checks fail closed where observed backing is
insufficient. Offchain monitoring can compare token balances with
`globalReservedByToken`; the guardian can pause exposure-increasing actions and
manually quarantine every affected basket that remains `Active`. Quarantine is
containment, not recapitalization or claim adjudication: only timelocked
governance can release it or enter `ExitOnly`, and no claimant class is intended
to absorb another class's loss during ordinary operation.

## Lifecycle, Pauses, and Recovery

Basket states are `Active`, `Quarantined`, and `ExitOnly`.

| Action | Active | Quarantined | ExitOnly |
| --- | --- | --- | --- |
| Mint, borrow, extend, flash | Subject to action pause | No | No |
| Redeem | Yes | Yes | Yes |
| Repay | Yes | Yes | Yes |
| Mature-loan recovery | Permissionless | Permissionless | Permissionless |
| Pool activate | Timelock-only after launch warm-up | No | No |
| Pool checkpoint | Permissionless if configured | Permissionless if configured | Until decommissioned |
| Hook swap and compounding | Until pool decommission | Until pool decommission | Until unwind decommissions pool |
| Canonical LP NFT stake or increase | Subject to liquidity pause | No | No |
| Pending LP reward activation | Permissionless until pool decommission | Permissionless until pool decommission | Until pool decommissioned |
| LP reward claim or NFT unstake | Yes | Yes | Yes |
| Permanent-liquidity unwind | No | No | Permissionless per constituent |
| Treasury fee distribution | Permissionless trigger | Permissionless trigger | Permissionless trigger |

The guardian may pause exposure-increasing action groups and quarantine an
active basket. Governance releases quarantine, unpauses, or enters the
`ExitOnly` state, which is terminal under the currently installed facets.
Redemption is not guardian-pausable.

No keeper runs automatically and no maintenance caller is guaranteed. Claims,
pending LP reward activation, checkpoints, basket-loan recovery,
manual hook compounding, treasury distribution, and ExitOnly unwind can remain
pending indefinitely until someone submits a transaction. Basket-loan recovery
and those maintenance actions pay no caller bounty; their liveness currently
depends on users, governance, integrators, or externally motivated keepers.
Dollar expired-risk recovery is the exception and includes a quoted keeper
bounty. Swap execution itself routes fees and attempts matched
permanent-liquidity compounding atomically, but does not provide liveness when a
pool has no swaps. Production operations must define monitoring, acceptable
delays, escalation ownership, and guardian/governance fallbacks for inactive
keepers and failed unwind attempts.

## Governance and Upgradeability

One `StaticsTimelock` owns both Diamonds. The current Robinhood testnet delay is
15 minutes; the production launch delay remains intended to be seven days. The
configured multisig is proposer and canceller, execution is open after delay,
and the emergency guardian is not a timelock canceller.

The timelock currently controls Diamond cuts, economic configuration, lifecycle
release and decommissioning, canonical pool activation, hook fee configuration,
and treasury or guardian changes. Reward-asset selection is a PositionNFT owner
action and requires no governance admission or retirement.

Diamond cuts are the sole implementation upgrade mechanism. Facets share the
common OpenZeppelin persistent reentrancy slot under delegatecall. Flash loans
add a separate transient guard domain and acquire the persistent slot only for
their transfer/accounting phases. Selector routing and ERC-165 declarations
must be updated together. Dollar Core bootstrap finalization validates wiring,
pins the periphery as the initial managed recovery holder, and clears bootstrap
authority. The Core owner may explicitly add or revoke other managed recovery
holders; revocation returns the holder's expired positions to ordinary
permissionless recovery. Finalization does not make either Diamond immutable.

The intended release lifecycle is upgradeable development followed by an
independent contract and governance audit, reduction of retained powers,
transfer to final governance, and a final reviewed cut that removes Diamond-cut
authority from both Diamonds. Final qualification must prove that no retained
selector, initializer, ownership path, or storage mutation can recreate
implementation-upgrade authority. "Immutable" then means facet routing and
implementation code are fixed; any deliberately retained parameter or emergency
powers must be enumerated separately.

The hook, PoolManager, PositionManager, Permit2, and liquidity-manager bindings
are version-level dependencies. V1 does not implement live in-place replacement
of those immutable integrations. Before final immutability, an audited Diamond
upgrade may correct integration logic. Afterward, a critical dependency failure
is handled by guardian containment, terminal V1 `ExitOnly` wind-down and
liability settlement where executable, followed by a separately deployed and
governed V2. Users and external LPs are not force-migrated, and V1 assets or
liabilities do not silently move to V2.

Runtime code hashes in deployment manifests are offchain release evidence; the
Diamond does not enforce facet bytecode hashes during dispatch.

## Integration Surfaces

### Primary addresses

- `StaticsDiamond`: baskets, PositionNFT, global rewards, custody views,
  lending, flash loans, canonical liquidity, borrow-to-liquidity, and Dollar
  gateway;
- `StaticsDollarCoreDiamond`: advanced Dollar state and operations;
- `StaticsDollar` and `StaticsDollarRiskShares`;
- one BasketToken address per basket;
- immutable `StaticsSwapFeeHook`; and
- immutable `StaticsLiquidityManager`.

### Canonical interfaces

| Surface | Interface |
| --- | --- |
| Baskets | `IStaticsBasket` |
| Basket collateral | `IStaticsBasketCollateral` |
| Global staking and rewards | `IStaticsGlobalRewards` |
| Basket lending | `IStaticsLending` |
| Basket flash loans | `IStaticsFlashLoan` and `IStaticsFlashBorrower` |
| PositionNFT | `IStaticsPosition` plus ERC-721 interfaces |
| Basket governance | `IStaticsGovernance` |
| Custody views | `IStaticsCustody` |
| Canonical liquidity | `IStaticsBasketLiquidity` |
| Borrow-to-liquidity | `IStaticsBorrowLiquidity` |
| Hook reads | `IStaticsSwapFeeHook` |
| Manager reads | `IStaticsLiquidityManager` |
| Dollar gateway | `IStaticsDollarGateway` |
| Dollar Risk liquidity | `IStaticsDollarRiskLiquidity` |
| Dollar Core | `IStaticsDollarCore` |

Integrators should quote immediately before submission, provide explicit
maximum inputs and minimum outputs, scope approvals to the typed next action,
and reconcile indexed events against current views after reorgs.

## Deployment Model

`script/DeployStatics.s.sol:DeployStatics` is the canonical full-stack
launcher. It deploys the timelock, Dollar oracle adapter, Core facets and
Diamond, Dollar tokens, 21 unified facets and `StaticsDiamond`, and the
immutable v4 hook and manager. A separate timelock ceremony installs the hook
and manager into the Diamond.

Production inputs include:

- broadcaster authorization and RPC;
- multisig, guardian, and treasury;
- a verified deployed `STAKING_TOKEN` contract;
- basket creation fee;
- WETH, ETH/USD feed, sequencer feed, and oracle bounds;
- Dollar collateral ratio, price band, debt ceiling, and metadata URI; and
- the pinned chain manifest's PoolManager, PositionManager, Permit2, hook
  calibration, and runtime hashes.

The target chain must support Cancun/EIP-1153. Robinhood Chain fork tests read
`ROBINHOOD_MAINNET`, with `ROBINHOOD_RPC_URL` retained as a legacy fallback.
`deployments/robinhood-chain-4663.json` pins external dependency and calibration
evidence only; it is not a Statics address manifest. Checked-in chain-31337
broadcasts are local rehearsal records. No public Statics deployment or
explorer verification is recorded.

Release evidence records both Diamonds and tokens, all facet addresses and
runtime hashes, immutable hook and manager bindings, canonical PoolKeys and
PoolIds, hook input/output rates and split, pending and locked permanent
liquidity, and user PositionManager NFTs discovered from ordinary events. It
does not record nonexistent protocol PositionManager token IDs. A qualifying
release must package those facts with the exact source revision, design version,
compiler profile and settings, selector-manifest and dependency-manifest hashes,
test timestamps and profiles, governance configuration, and verification
receipts as one revision-pinned record.

## Security and Trust Assumptions

- Basket creation is owner-only while `creationFee()` is zero and exact-fee
  permissionless while it is positive. Neither state constitutes token
  certification.
- Shared custody increases the importance of exact reservations and hostile
  token analysis; a physical reservation deficit is a black-swan incident,
  contained through fail-closed checks and guardian quarantine rather than a
  routine socialized-loss waterfall.
- PositionNFT transfer moves all attached protocol rights and obligations.
- Dollar safety depends on configured oracle, sequencer, collateral, health,
  and governance parameters.
- Canonical liquidity inherits Uniswap v4, immutable-dependency,
  price-manipulation, inventory, and impermanent-loss risk.
- Hook-owned permanent liquidity is intentionally non-withdrawable while its
  pool remains active.
- Flash callbacks expand atomic composition but not authority; receivers must
  defend their own pools, approvals, slippage, and minimum profit.
- Timelocked Diamond upgradeability can change protocol behavior after delay
  until final upgrade authority is deliberately removed.
- Permit signatures authorize allowances, not a complete economic intent; the
  gateway's tolerant fallback may use an already sufficient caller allowance.
- Most basket and liquidity maintenance has no guaranteed caller or bounty;
  Dollar expired-risk recovery is the implemented keeper-bounty exception.
- Recovery surplus remains isolated but has no implemented V1 beneficiary or
  disposition path.
- Historical internal audits, release-QA notes, and X-Ray reports do not cover
  the pinned revision and are not independent production assurance.

## Testing and Assurance

The test pyramid includes focused unit and harness proofs, live value-moving
integration flows, fuzz tests, stateful invariants, deployment rehearsals,
canonical Uniswap v4 tests, and a pinned Robinhood Chain fork shape.

The pinned source revision contains 59 Foundry test files with 374 functions
detected by `forge test --list --json`, including 15 fuzz-named tests and 29
invariants. Static SDK inspection finds 26 declared tests in one tracked SDK
test file. These are source counts; abstract or suite-level selection means
detected declarations and executed outcomes need not sum directly.

Validation run on 2026-07-23 against the pinned revision recorded:

```text
Default Foundry profile:  365 passed, 0 failed, 7 skipped across 59 suites
Security Foundry profile: 365 passed, 0 failed, 7 skipped across 59 suites
SDK:                      26 passed; TypeScript build passed
```

The skipped tests are external Base or Robinhood fork flows whose RPC
environment was unavailable. The 2026-07-19 internal audit and release-QA
record, and the X-Ray snapshot, cover earlier commits with older facet,
selector, and test counts and do not qualify this revision. Before production
approval, repeat and preserve the complete profiles, focused deployment proof,
local canonical-pool arbitrage tests, required pinned Robinhood fork suite, SDK
tests, and SDK build against the exact release commit. Record the timestamp,
environment, profile, skips, and full commit in the release qualification
artifact.

## Implemented, Deferred, and Excluded

### Implemented

- fixed multi-asset BasketTokens and aggregate backing;
- shared PositionNFT and basket collateral;
- position-selected global multi-asset indexes and treasury fees;
- position-owned self-backed vector lending and debt-proportional recovery;
- composable constituent-vector flash loans;
- canonical zero-native-fee v4 pools with bilateral hook fees and governed
  per-pool allocation overrides;
- hook-owned full-range permanent liquidity and ExitOnly unwind;
- isolated BasketToken reward indexes, canonical LP NFT reward custody, and
  typed borrow-to-external or PositionNFT-owned liquidity;
- volatile and pegged Statics Dollar profiles with frontrun-tolerant typed
  permit actions;
- shared custody reservations, measured transfers, and guardian quarantine;
- timelocked EIP-2535 upgradeability; and
- SDK quote, calldata, and position-management helpers.

### Deferred pre-release decisions and operations

- acceptable maintenance delays, monitoring, and incident runbooks;
- final governance powers, independent governance audit, and the ceremony that
  removes Diamond-cut authority;
- additional production collateral profiles and economic parameters;
- supported front-end routing venues;
- a revision-pinned release qualification artifact; and
- post-audit deployment addresses and explorer verification.

### Intentionally excluded

- an asset registry or allowlist;
- ERC-4626 basket conversion;
- price-based basket accounting;
- cross-basket or cross-product collateralization;
- a routine socialized-loan-loss waterfall;
- fee-free or privileged flash receivers;
- a generic arbitrage/execution router;
- protocol PositionManager NFTs for permanent liquidity;
- automatic background execution;
- live in-place V1 migration of immutable v4 dependencies after finality; and
- silent compatibility branches for nonconforming tokens.

## Appendix A: Formula Reference

Let `D = 10,000`, `Q = 1e18`, and `RAY = 1e27`.

### Static backing

```text
B_i(S) = ceil(bundle_i * S / Q)
mint base_i   = B_i(S + shares) - B_i(S)
redeem base_i = B_i(S) - B_i(S - shares)
```

### Flat action fee

For selected tier value `feeShares`:

```text
fee_i = ceil(bundle_i * feeShares / Q)
mint input_i = mint base_i + fee_i
redeem output_i = redeem base_i - fee_i
```

### Global non-swap fee

For reward asset `a`, when `eligibleStake[a] > 0`:

```text
staker = floor(grossFee * 9,000 / D)
treasury = grossFee - staker
indexDelta[a] = floor(staker * RAY / eligibleStake[a])
indexRay[a] += indexDelta[a]
indexedAmount[a] += staker
position accrual = floor(positionStake * indexDelta / RAY)
```

Otherwise `staker = 0` and `treasury = grossFee`. Each accrual floors
independently; there is no carried division remainder. If eligible stake later
reaches zero, indexed whole-token value that never crystallized to positions is
routed to treasury.

### Borrow and extension

```text
feeShares = ceil(sharesIn * originationFeeBps / D)
collateralShares = sharesIn - feeShares
fee underlying_i = B_i(S) - B_i(S - feeShares)
proportional_i = floor(bundle_i * collateralShares / Q)
principal_i = floor(proportional_i * ltvBps / D)
extension quote_i = ceil(stored principal_i * extensionFeeBps / D)
```

Exact rounding is defined by the onchain quote functions and stored tranche
values.

### Flash loan

```text
principal_i = floor(bundle_i * flashShares / Q)
quoted fee_i = ceil(principal_i * flashFeeBps / D)
requested repayment_i = principal_i + quoted fee_i
success requires measured receipt_i >= principal_i
actual fee_i = measured receipt_i - principal_i
```

### Bilateral hook fees

For a realized charged leg `x` and its configured rate `f`:

```text
charged = ceil(x * f / D) for a nonzero charge
POL = floor(charged * polShareBps / D)
LP = floor(charged * liquidityProviderShareBps / D)
basket staker = floor(charged * basketStakerShareBps / D)
Statics staker = floor(charged * staticsStakerShareBps / D)
treasury = charged - POL - LP - basket staker - Statics staker
```

At launch, input and output rates are each 25 BPS and the split is
4,000/1,000/2,000/2,000/1,000 for
POL/LP/basket-staker/Statics-staker/treasury. If no activated LP liquidity
exists for the pool, its allocation is added to POL. If either staking route is
unavailable, that allocation is also added to POL. Exact-input and exact-output
swaps map the specified and unspecified
realized legs according to Uniswap v4 settlement.

For an active pool override `(p, l, b, s, t)`,
`p + l + b + s + t = D`, and the same equations apply using the pool-specific
shares. Treasury still receives
all rounding remainder. The override does not contain or modify the input and
output fee rates.

## Appendix B: Correctness Properties

1. `StaticsDiamond` remains the single basket, PositionNFT, and Dollar gateway address.
2. Each BasketToken has one immutable constituent vector and static bundle.
3. Required basket backing is derived from aggregate supply.
4. Only the basket vault contributes to BasketToken redemption backing.
5. One basket cannot debit another basket's local reservation.
6. Every successful checked custody operation enforces that global reservations do not exceed the Diamond's observed physical token balance.
7. Global reservations equal Dollar, fee, staking, and basket-account reservations.
8. Inbound accounting credits measured receipts, not requested amounts.
9. Outbound accounting never exceeds its named reservation and authorized debit.
10. Flat fee tiers select the greatest qualifying threshold; later duplicates win.
11. Basket fees never create basket-specific holder claims.
12. Non-swap fees conserve across global staker and treasury books.
13. No staker liability is created unless that asset has nonzero matured eligible stake.
14. Reward opt-in and top-ups wait until an hourly boundary at least 24 hours later.
15. Every matured bucket records its activation index and cannot receive historical accrual.
16. Global stake is always withdrawable; pending stake is removed before eligible stake.
17. Treasury distribution has a fixed configured recipient even though triggering is permissionless.
18. Basket collateral cannot be withdrawn or redeemed while locked.
19. Every loan tranche retains an independent principal vector and maturity.
20. Repayment unlocks only the repaid tranche.
21. Extension changes maturity but not principal, collateral, or global stake.
22. Flash disbursement is exact and cannot spend another reservation.
23. A flash callback may enter ordinary mint and redemption but cannot nest a flash loan.
24. Successful flash settlement restores principal exactly to basket vault accounting.
25. Measured flash excess, not merely the quote, is routed as a non-swap fee.
26. Failed callbacks or repayment checks leave no partial protocol or pool state.
27. Canonical pools use the installed hook, zero native LP fee, and tick spacing 10.
28. Basket creation initializes, manager-registers, and permanently seeds exactly one canonical pool per constituent or reverts without creating the basket.
29. Canonical pools are immediately swappable while Warming, but activation cannot bypass timelock ownership, warm-up, observations, or deviation checks.
30. Hook input and output fees apply without caller or flash-receiver exemption.
31. Every swap-fee leg conserves across POL, canonical LP, basket staker, global Statics staker, and treasury routing.
32. Hook permanent liquidity cannot be released before pool decommissioning.
33. Hook permanent liquidity has no protocol PositionManager token ID.
34. ExitOnly unwind cannot decrease, burn, or seize user PositionManager NFTs held in voluntary custody.
35. Borrow-to-liquidity inventory cannot enter permanent-liquidity or global-staking books.
36. Pegged profile fees route through the global non-swap ledger.
37. Volatile Dollar insurance and reward routing remain profile- and series-state aware.
38. Dollar Core collateral remains outside Diamond custody reservations.
39. PositionNFT transfer moves control of attached protocol legs and voluntarily custodied v4 NFTs, but not externally held v4 NFTs.
40. Diamond cuts and ERC-165 declarations remain synchronized.
41. Newly staked or increased LP liquidity cannot earn before the next block.
42. Existing activated LP liquidity keeps earning while an increase delta waits for activation.
43. LP NFTs can always exit custody; earned claims remain attached to their PositionNFT.
44. Pool eligible liquidity equals the activated liquidity recorded for its custodied NFTs.
45. Mature-loan recovery burns only debt plus the creator-configured penalty, clears principal, unlocks remaining collateral, and splits penalty backing 20% to the caller and 80% to protocol fees.
46. A failed gateway permit never substitutes another owner: the typed action still pulls only from `msg.sender` under ordinary allowance rules.
47. Pool fee-allocation overrides change only future routing and preserve the same unavailable-LP, unavailable-basket-staker, and unavailable-Statics-staker fallbacks to POL.
48. Guardian quarantine contains an active basket but neither releases quarantine nor adjudicates a black-swan physical deficit.
49. Core bootstrap finalization clears bootstrap authority but does not remove Diamond-cut authority.
50. Final V1 immutability requires explicit removal of implementation-upgrade authority; later dependency replacement uses terminal V1 wind-down and a separate V2 rather than live migration.
51. Canonical LP custody entry requires the LP NFT and PositionNFT to have the same current owner.
52. Dollar expired-risk recovery includes its quoted keeper bounty; basket-loan recovery pays its own fixed 20% share of configured penalty backing.
53. `borrowAndStakeLiquidity` keeps borrowed BasketToken collateral basket-reward eligible while activating its newly custodied full-range LP weight no earlier than the next block.
54. Staked Dollar Risk Shares are immediately consumable; unconsumed effective principal remains withdrawable and only a pairing fill creates supplier proceeds.

## Appendix C: Terminology

| Term | Meaning |
| --- | --- |
| **BasketToken** | Transferable ERC-20 claim on one basket's fixed constituent bundle |
| **Bundle amount** | Constituent quantity represented by 1e18 BasketToken shares |
| **Basket collateral** | BasketTokens deposited in a PositionNFT and optionally locked for lending |
| **Global staking token** | Deployment-configured ERC-20 providing position stake weight; each reward asset's denominator includes only positions opted into that asset |
| **Reward book** | Permissionless per-asset 1e27 index state shared by positions that explicitly select that asset |
| **Fee account** | Diamond reservation holding global staker claims and treasury accruals |
| **Staking account** | Diamond reservation holding the configured staking token |
| **Permanent liquidity (POL)** | Hook-owned full-range canonical liquidity funded from swap-fee allocations |
| **Canonical pool** | Governance-initialized BasketToken/constituent v4 pool registered with the installed hook |
| **Bilateral hook fee** | Separate fee applied to realized input and output swap legs |
| **PositionNFT** | Shared ERC-721 owning Statics staking, collateral, loan, and Dollar legs |
| **ExitOnly** | Basket state that is terminal under installed facets, blocking new exposure while preserving exits and risk reduction |
| **Actual flash fee** | Measured repayment received above principal |
| **Recovery surplus** | Basket-scoped reserved backing excess left after mature-loan collateral burn clears its stored principal; V1 currently exposes no disposition path |
| **Quarantine** | Guardian containment state blocking new basket exposure while preserving installed-facet exits and risk reduction |
| **Final V1 immutability** | Deliberate removal of Diamond implementation-upgrade authority after final governance review; retained parameter powers remain separately enumerated |
| **Terminal treasury fee** | Global fee-account amount distributable only to the configured treasury |
