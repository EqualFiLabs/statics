# Statics — Unified Protocol Design Document

## Static Multi-Asset Baskets, Statics Dollar, Position-Owned Finance, and Permanent Liquidity

**Version:** 2.1

**Status:** Implemented architecture

**Last updated:** 2026-07-22

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

Statics is a standalone protocol for immutable multi-asset baskets, a
collateralized Statics Dollar system, position-owned lending, global
multi-asset fee rewards, basket-vector flash loans, and canonical Uniswap v4
liquidity.

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
| Basket collateral | Optional BasketToken deposit leg; collateral itself earns no basket-specific reward |
| Global rewards | One configured staking token and up to 64 governed reward-asset slots |
| Non-swap fee split | 90% to active global stakers and 10% to treasury; unavailable staker allocation goes to treasury |
| Canonical swap fees | Separate input and output hook fees; launch default is 25 BPS on each realized leg |
| Swap-fee split | Launch default 50% permanent liquidity, 10% eligible canonical LPs, 30% global stakers, 10% treasury |
| Canonical native LP fee | Zero |
| Permanent liquidity | Hook-owned full-range liquidity, compounded from matched swap-fee inventory |
| Flash callbacks | May call ordinary basket mint and redemption; nested flash loans remain blocked |
| Upgradeability | EIP-2535 Diamonds owned by one timelock |

### Release qualification

This document describes the implemented architecture, not an audit or a public
deployment record. Production value requires independent review, target-chain
rehearsal, verified contract publication, explicit governance and economic
configuration, and successful default, security-profile, and pinned-fork test
runs against the release commit.

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
- automatic background execution; or
- a protocol-owned PositionManager NFT for canonical permanent liquidity.

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

The current deployment manifests install:

- **22 facets / 184 selectors** on `StaticsDiamond`; and
- **11 facets / 95 selectors** on `StaticsDollarCoreDiamond`.

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
| Staking token | Configured ERC-20 | Reserved by `StaticsDiamond` per position | Denominator for global multi-asset rewards |
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
- Statics Dollar passive or opt-in risk-share legs; and
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

Basket creators pay the exact current native `creationFee()`. Creation records
the creator for discovery but gives that address no administrative authority.

### Aggregate-supply backing

For constituent bundle amount `b[i]` and BasketToken supply `S`, required
backing is:

```text
backing[i](S) = ceil(b[i] * S / 1e18)
```

Mint and redemption use differences between aggregate backing values. This
prevents per-action rounding from accumulating an accounting deficit.

Only basket vault balances back BasketToken supply. Global fees, staking
custody, recovery surplus, Dollar books, and hook liquidity are separate.

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
configured global staking token in a PositionNFT to enter the global reward
denominator.

## Global Staking and Rewards

Statics has one immutable-at-initialization staking-token address. The token
must be a deployed contract and staking transfers must be exact: taxed or
otherwise balance-changing staking tokens are rejected.

`createAndStake` creates a PositionNFT and stakes in one call. `stake` increases
an existing authorized position. Every increase settles the position first,
resets global index remainders, and restarts a **24-hour unstake cooldown**.
`unstake` settles before reducing stake and also requires an exact outbound
transfer.

### Non-swap fee routing

Primary mint and redemption fees, lending origination backing
reclassification, extension fees, measured flash-loan excess, and pegged
profile fees enter the same non-swap ledger. If the asset has an active reward
slot and total stake is nonzero:

```text
staker amount  = floor(gross fee * 9,000 / 10,000)
treasury amount = gross fee - staker amount
```

If the slot is unavailable, retiring, queued, or the staking denominator is
zero, no new staker liability is created and the entire fee accrues to
treasury. Division remainder also accrues to treasury.

### Reward indexes and claims

The ledger has at most 64 occupied reward-asset slots and uses 1e27 index
precision. Positions checkpoint each slot generation. Claims are pull-based,
require PositionNFT authorization, and accept a per-asset minimum received
amount. Claim settlement transfers from the global fee reservation and never
reduces basket backing.

`pendingRewards` and `stakePosition` are authorization-gated because their
values belong to a PositionNFT. `rewardAsset`, `rewardAssetSlot`, queue views,
`stakingToken`, `totalStaked`, `treasuryAccrued`, and
`canAccrueStakerRewards` expose global state.

### Slot retirement and treasury distribution

Governance starts and finalizes reward-slot retirement. Settlement between
those actions is permissionless and bounded by `maxPositions`. Assets arriving
when all slots are occupied are queued for a future replacement. Generation
tracking prevents a replacement asset from inheriting the retired asset's
checkpoints.

Anyone may call `distributeTreasuryFees(asset)`, but the destination is always
the configured treasury. The caller cannot choose a recipient.

## Position-Owned Basket Lending

Only BasketTokens deposited through the collateral interface can be locked for
borrowing. Deposited and locked BasketTokens earn no separate basket reward.

`borrow` creates an independent tranche owned by the PositionNFT. The
origination fee is represented as a BasketToken-share reduction whose
underlying backing is reclassified into the global fee ledger. The remaining
locked shares determine a proportional constituent debt vector at the
configured LTV. There is no price-oracle liquidation.

Repayment is permissionless and pulls the stored principal vector. Extension
is PositionNFT-authorized, measures the full inbound vector, requires at least
the quote, and routes the complete measured receipt through global non-swap
fees. It does not change principal or collateral.

After maturity plus one hour, recovery is permissionless and removes only the
expired tranche. Recovery does not settle or change global staking rewards.

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

Initialization and activation are owner/timelock-only because both select or
authorize price state. Initialization registers the exact PoolKey with the
hook. Activation requires warm-up, at least two observations, a valid
30-minute reference, and the fixed deviation bound. Checkpointing and manager
sync are permissionless.

The installed hook rejects native currency and nonzero native LP fees for
registered canonical pools. Unregistered pools are not canonical.

### Bilateral hook fees

The hook charges separately against realized input and output legs. The launch
manifest configures 25 BPS on each leg. Governance may update both rates and
the split, but the combined input-plus-output fee cannot exceed 200 BPS and the
split must total 10,000 BPS.

For each charged leg, the launch split is:

```text
50% permanent liquidity
10% eligible canonical LPs
30% global stakers
10% treasury
```

Treasury receives split dust. If a pool has no activated staked liquidity, its
LP share redirects to permanent liquidity. If the staker path cannot accept
the reward asset, that share independently redirects to permanent liquidity.

LP, staker, and treasury shares are transferred immediately to the Diamond's
fee ledger. LP shares accrue through pool-local indexes for both currencies.
The permanent-liquidity share remains in the hook. When both pool
currencies are available, the hook compounds matched inventory into its own
full-range position during swap settlement. Unmatched amounts remain pending;
anyone may call `compoundPermanentLiquidity` later.

The global split is the default, not an immutable pool policy. Timelocked
Diamond governance may set a canonical pool override using the same four-way
POL, canonical-LP, global-staker, and treasury allocation whose shares sum to
10,000 BPS. A mature pool may explicitly select `0/0/8,000/2,000`. Clearing an
override restores the latest global split. Overrides change future allocation
only: pending POL is not released or reclassified, hook-owned liquidity stays
permanent, and existing two-sided pending inventory remains eligible for
compounding. The unavailable canonical-LP and staker fallbacks to POL are
identical under global and pool configurations. No threshold, volume,
liquidity, or oracle rule changes an override automatically.

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
Diamond custody. Eligibility does not depend on whether the NFT originated
from `borrowAndProvideLiquidity`. Initial liquidity becomes reward eligible in
the next block. An in-custody increase preserves the existing eligible weight
and delays only the added liquidity until the next block.

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

Pegged profiles are direct collateral wrappers. Minting pulls nominal
collateral plus a configured fee; redemption burns Statics Dollar and returns
proportional collateral less its configured fee. Pegged fees route entirely to
the global non-swap fee ledger.

### Dollar reward and insurance routing

Dollar Risk Share passive and opt-in rewards remain distinct from global
staking. For an active volatile series in an eligible profile mode, the
configured insurance portion routes to insurance. Of the remaining reward
share, 30% enters the global non-swap fee ledger and 70% enters the series'
opt-in reserve. When the series or profile mode is ineligible, the would-be
reward share routes to insurance instead.

This coexistence does not merge Dollar collateral held by Core with Diamond
custody. Only fees explicitly transferred to the periphery enter shared
reservations.

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
stake. Negative rebases, arbitrary burns, deceptive `balanceOf`, blocklists,
and malicious callbacks can still halt or impair baskets using a hostile token.

## Lifecycle, Pauses, and Recovery

Basket states are `Active`, `Quarantined`, and `ExitOnly`.

| Action | Active | Quarantined | ExitOnly |
| --- | --- | --- | --- |
| Mint, borrow, extend, flash | Subject to action pause | No | No |
| Redeem | Yes | Yes | Yes |
| Repay | Yes | Yes | Yes |
| Mature-loan recovery | Permissionless | Permissionless | Permissionless |
| Pool initialize or activate | Timelock-only | No | No |
| Pool checkpoint | Permissionless if configured | Permissionless if configured | Until decommissioned |
| Pool manager sync | Permissionless if configured | Permissionless if configured | Until decommissioned |
| Hook swap and compounding | Until pool decommission | Until pool decommission | Until unwind decommissions pool |
| Canonical LP NFT stake or increase | Subject to liquidity pause | No | No |
| Pending LP reward activation | Permissionless until pool decommission | Permissionless until pool decommission | Until pool decommissioned |
| LP reward claim or NFT unstake | Yes | Yes | Yes |
| Permanent-liquidity unwind | No | No | Permissionless per constituent |
| Treasury fee distribution | Permissionless trigger | Permissionless trigger | Permissionless trigger |

The guardian may pause exposure-increasing action groups and quarantine an
active basket. Governance releases quarantine, unpauses, or permanently enters
`ExitOnly`. Redemption is not guardian-pausable.

No keeper runs automatically. Claims, pending LP reward activation,
checkpoints, retirement settlement, loan recovery, manual hook compounding,
treasury distribution, and ExitOnly unwind require a caller. Swap execution
itself routes fees and attempts matched permanent-liquidity compounding
atomically.

## Governance and Upgradeability

One `StaticsTimelock` owns both Diamonds. The genesis delay is seven days, the
configured multisig is proposer and canceller, execution is open after delay,
and the emergency guardian is not a timelock canceller.

The timelock controls Diamond cuts, economic configuration, lifecycle release
and decommissioning, canonical pool initialization and activation, hook fee
configuration, reward-slot retirement, and treasury or guardian changes.

Diamond cuts are the sole implementation upgrade mechanism. Facets share the
common OpenZeppelin persistent reentrancy slot under delegatecall. Flash loans
add a separate transient guard domain and acquire the persistent slot only for
their transfer/accounting phases. Selector routing and ERC-165 declarations
must be updated together.

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

Release evidence records both Diamonds and tokens, all facet addresses and
runtime hashes, immutable hook and manager bindings, canonical PoolKeys and
PoolIds, hook input/output rates and split, pending and locked permanent
liquidity, and user PositionManager NFTs discovered from ordinary events. It
does not record nonexistent protocol PositionManager token IDs.

## Security and Trust Assumptions

- Basket creation is permissionless and constitutes no token certification.
- Shared custody increases the importance of exact reservations and hostile
  token analysis.
- PositionNFT transfer moves all attached protocol rights and obligations.
- Dollar safety depends on configured oracle, sequencer, collateral, health,
  and governance parameters.
- Canonical liquidity inherits Uniswap v4, hook, price-manipulation,
  inventory, and impermanent-loss risk.
- Hook-owned permanent liquidity is intentionally non-withdrawable while its
  pool remains active.
- Flash callbacks expand atomic composition but not authority; receivers must
  defend their own pools, approvals, slippage, and minimum profit.
- Timelocked Diamond upgradeability can change protocol behavior after delay.
- Permit signatures authorize allowances, not a complete economic intent.
- Permissionless maintenance has no guaranteed caller or first-release bounty.

## Testing and Assurance

The test pyramid includes focused unit and harness proofs, live value-moving
integration flows, fuzz tests, stateful invariants, deployment rehearsals,
canonical Uniswap v4 tests, and a pinned Robinhood Chain fork shape.

The 2026-07-22 repository snapshot contains 56 Foundry test files with 341
declared `test*` and `invariant*` functions, including 15 fuzz tests and 23
invariants. The last complete default run recorded for this snapshot passed 332
tests, failed 0, and skipped 7; suite-level skips mean declared functions and
reported outcomes do not sum directly. The SDK test run passed 20 tests.

Those counts are evidence for that checkout, not a release waiver. Before
production approval, rerun the complete default and security profiles, the
focused deployment proof, local canonical-pool arbitrage tests, and the pinned
Robinhood fork suite against the exact release commit.

## Implemented, Deferred, and Excluded

### Implemented

- fixed multi-asset BasketTokens and aggregate backing;
- shared PositionNFT and basket collateral;
- global staking, multi-asset fee indexes, governed slots, and treasury fees;
- position-owned vector lending and recovery;
- composable constituent-vector flash loans;
- canonical zero-native-fee v4 pools with bilateral hook fees;
- hook-owned full-range permanent liquidity and ExitOnly unwind;
- typed borrow-to-user-liquidity;
- volatile and pegged Statics Dollar profiles;
- shared custody reservations and measured transfers;
- timelocked EIP-2535 upgradeability; and
- SDK quote and calldata helpers.

### Deferred product decisions

- keeper incentives for recovery and maintenance;
- additional production collateral profiles and economic parameters;
- supported front-end routing venues; and
- post-audit deployment addresses.

### Intentionally excluded

- an asset registry or allowlist;
- ERC-4626 basket conversion;
- price-based basket accounting;
- cross-basket or cross-product collateralization;
- fee-free or privileged flash receivers;
- a generic arbitrage/execution router;
- protocol PositionManager NFTs for permanent liquidity; and
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

When the asset has an active slot and `totalStaked > 0`:

```text
staker = floor(grossFee * 9,000 / D)
treasury = grossFee - staker
index increment ~= staker * RAY / totalStaked
position accrual = floor(positionStake * indexDelta / RAY)
```

Otherwise `staker = 0` and `treasury = grossFee`.

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
staker = floor(charged * stakerShareBps / D)
treasury = charged - POL - LP - staker
```

At launch, input and output rates are each 25 BPS and the split is
5,000/1,000/3,000/1,000 for POL/LP/global-staker/treasury. If no activated LP
liquidity exists for the pool, its allocation is added to POL. If staker
routing is unavailable, that allocation is also added to POL. Exact-input and
exact-output swaps map the specified and unspecified
realized legs according to Uniswap v4 settlement.

For an active pool override `(p, l, s, t)`, `p + l + s + t = D`, and the same
four equations apply using the pool-specific shares. Treasury still receives
all rounding remainder. The override does not contain or modify the input and
output fee rates.

## Appendix B: Correctness Properties

1. `StaticsDiamond` remains the single basket, PositionNFT, and Dollar gateway address.
2. Each BasketToken has one immutable constituent vector and static bundle.
3. Required basket backing is derived from aggregate supply.
4. Only the basket vault contributes to BasketToken redemption backing.
5. One basket cannot debit another basket's local reservation.
6. Global reservations never exceed the Diamond's physical token balance.
7. Global reservations equal Dollar, fee, staking, and basket-account reservations.
8. Inbound accounting credits measured receipts, not requested amounts.
9. Outbound accounting never exceeds its named reservation and authorized debit.
10. Flat fee tiers select the greatest qualifying threshold; later duplicates win.
11. Basket fees never create basket-specific holder claims.
12. Non-swap fees conserve across global staker and treasury books.
13. No staker liability is created without an active asset slot and nonzero stake.
14. Reward generation changes cannot inherit retired-asset checkpoints.
15. Stake increases and decreases settle existing index state before denominator changes.
16. Global-token unstaking cannot occur before 24 hours from the latest global stake increase.
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
28. Pool initialization and activation require timelock ownership.
29. Activation cannot bypass warm-up, observations, or deviation checks.
30. Hook input and output fees apply without caller or flash-receiver exemption.
31. Every swap-fee leg conserves across POL, canonical LP, global staker, and treasury routing.
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

## Appendix C: Terminology

| Term | Meaning |
| --- | --- |
| **BasketToken** | Transferable ERC-20 claim on one basket's fixed constituent bundle |
| **Bundle amount** | Constituent quantity represented by 1e18 BasketToken shares |
| **Basket collateral** | BasketTokens deposited in a PositionNFT and optionally locked for lending |
| **Global staking token** | Deployment-configured ERC-20 whose position balances form the global reward denominator |
| **Reward slot** | Governed 1e27 index state for one globally distributed fee asset |
| **Fee account** | Diamond reservation holding global staker claims and treasury accruals |
| **Staking account** | Diamond reservation holding the configured staking token |
| **Permanent liquidity (POL)** | Hook-owned full-range canonical liquidity funded from swap-fee allocations |
| **Canonical pool** | Governance-initialized BasketToken/constituent v4 pool registered with the installed hook |
| **Bilateral hook fee** | Separate fee applied to realized input and output swap legs |
| **PositionNFT** | Shared ERC-721 owning Statics staking, collateral, loan, and Dollar legs |
| **ExitOnly** | Permanent basket state blocking new exposure while preserving exits and risk reduction |
| **Actual flash fee** | Measured repayment received above principal |
| **Terminal treasury fee** | Global fee-account amount distributable only to the configured treasury |
