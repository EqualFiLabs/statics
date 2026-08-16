# Statics — Unified Protocol Design Document

## Static Multi-Asset Baskets, Statics Dollar, Position-Owned Finance, and Permanent Liquidity

**Status:** Living implementation design; current Solidity and deployment
manifests remain authoritative; no production Statics deployment is recorded

---

## Table of Contents

1. [Overview](#overview)
2. [Design Principles and Boundaries](#design-principles-and-boundaries)
3. [System Topology](#system-topology)
4. [Tokens and Ownership Objects](#tokens-and-ownership-objects)
5. [Shared PositionNFT](#shared-positionnft)
6. [Static Basket Model](#static-basket-model)
7. [Basket Minting and Redemption](#basket-minting-and-redemption)
8. [Basket Position Rewards](#basket-position-rewards)
9. [Global Staking and Rewards](#global-staking-and-rewards)
10. [Position-Owned Basket Lending](#position-owned-basket-lending)
11. [Basket Flash Loans](#basket-flash-loans)
12. [Protocol Uniswap v4 Liquidity](#protocol-uniswap-v4-liquidity)
13. [Borrow-to-Liquidity](#borrow-to-liquidity)
14. [Statics Dollar](#statics-dollar)
15. [Custody, Reservations, and Accounting Isolation](#custody-reservations-and-accounting-isolation)
16. [Lifecycle, Pauses, and Recovery](#lifecycle-pauses-and-recovery)
17. [Governance and Upgradeability](#governance-and-upgradeability)
18. [Integration Surfaces](#integration-surfaces)
19. [Deployment Model](#deployment-model)
20. [Security and Trust Assumptions](#security-and-trust-assumptions)
21. [Testing and Assurance](#testing-and-assurance)
22. [Implemented, Production Readiness, and Excluded](#implemented-production-readiness-and-excluded)
23. [Appendix A: Formula Reference](#appendix-a-formula-reference)
24. [Appendix B: Correctness Properties](#appendix-b-correctness-properties)
25. [Appendix C: Terminology](#appendix-c-terminology)

---

## Overview

Statics is a standalone protocol for fixed-composition multi-asset baskets, a
collateralized Statics Dollar system, position-owned lending, global
multi-asset fee rewards, basket-vector flash loans, and canonical Uniswap v4
liquidity. Basket definitions are immutable after creation; the current
testnet Diamonds remain upgradeable under timelock governance.

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
| Basket launch | Token deployment, every canonical pool, ordinary-fee backing, and creator-funded permanent liquidity launch atomically |
| Basket accounting | Static aggregate-supply backing; no NAV or price oracle |
| Position ownership | One shared ERC-721 at `StaticsDiamond` |
| Basket collateral | Optional BasketToken deposit leg; deposited and locked shares earn isolated basket rewards |
| Global rewards | Unlimited global assets; each PositionNFT selects at most 64 reward assets |
| Non-swap fee split | 90% to matured selected global stake and 10% to treasury; unavailable staker allocation goes to treasury |
| Canonical swap fees | Separate input and output hook fees; launch default is 50 BPS on each realized leg |
| Swap-fee split | Launch default 10% permanent liquidity, 25% eligible canonical LPs, 25% deposited BasketTokens, 15% global Statics stakers, 25% treasury |
| Canonical native LP fee | Zero |
| Permanent liquidity | Hook-owned full-range liquidity, compounded from matched swap-fee inventory |
| Dollar Risk incentives | Permissionless series funding in collateral, Statics Dollar, or configured STATICS; released only when supplied Risk liquidity is consumed |
| Flash callbacks | May call ordinary basket mint and redemption; nested flash loans remain blocked |
| Upgradeability | Pre-release EIP-2535 Diamonds owned by one timelock; intended final release removes Diamond-cut authority after governance review |

### Fee-source routing summary

| Source | Initial routing | Fallback or secondary routing |
| --- | --- | --- |
| Basket creation fee | Native asset sent directly to configured treasury | Creation reverts if the exact fee cannot be forwarded |
| Basket mint and redemption fees | Constituent assets enter global non-swap rewards | 90% to matured selected global stake and 10% to treasury; 100% treasury if no eligible stake |
| Basket-loan origination fee | Backing represented by burned fee shares enters global non-swap rewards | Same global 90/10 or treasury-only rule |
| Extension payment, repayment excess, and measured flash excess | Full measured fee receipt enters global non-swap rewards | Same global 90/10 or treasury-only rule |
| Canonical swap hook fee | Effective global or pool-specific rates and five-way split | Unavailable LP and basket-staker shares redirect to POL; an unavailable Statics-staker share redirects to treasury |
| Mature basket-loan recovery penalty | 20% to recovery caller and 80% to global non-swap rewards | Global portion uses the same 90/10 or treasury-only rule |
| Pegged-profile mint and redemption fee | Entire collateral-token fee enters global non-swap rewards | Same global 90/10 or treasury-only rule |
| Active volatile-series fee | Configured insurance share to insurance; complete remaining reward share enters global non-swap rewards | Ineligible series or profile mode sends the complete would-be reward share to insurance |
| Pairing-vault redemption economics | Fixed senior collateral to redeemer; junior residual plus 80% of the pairing fee to consumed Risk liquidity | Remaining 20% of the pairing fee tops up profile insurance |
| Permissionless Dollar Risk incentives | Series-isolated collateral, Statics Dollar, or configured staking-token reserves | Pairing fills release reserves pro rata; unused reserves roll to a healthy successor series or enter global non-swap rewards after profile retirement |
| ExitOnly permanent-liquidity unwind | Released constituent and backing reclassification accrue to global treasury | No position, LP, or staker claim is created |

### Release qualification

This document describes the current implementation model, not an audit,
immutable release record, or production qualification. The source-controlled
Robinhood Chain testnet manifest records a public test deployment, governed
upgrades, verified sources, fixtures, and a genesis basket. It is useful
integration evidence, but its mock collateral,
faucet, two-minute timelock, and test parameters are deliberately not
production defaults. Production value requires independent contract and
governance review, target-chain rehearsal, verified contract publication,
explicit governance and economic configuration, and successful validation
against one exact release commit.

A release qualification record must bind one source commit and design version
to compiler settings, constructor and governance inputs, dependency and
selector manifests, runtime-code hashes, test profiles and timestamps, deployed
addresses, and explorer verification. Checked-in chain-31337 rehearsal
manifests remain local test artifacts. The separate chain-46630 deployment
manifest is public testnet evidence, but it does not qualify a later production
binary or configuration.

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
- a generic arbitrage router, receiver registry, or arbitrary executor;
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
├── Statics Dollar typed gateway, Risk liquidity, and funded incentives
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
        |                           └── hook-owned permanent liquidity
        |
        +-------------------------> StaticsLiquidityManager
                                    └── typed user PositionManager NFT creation
```

### Fresh-deployment shape

The current launcher and deployment tests expect:

- **23 facets / 207 selectors** on `StaticsDiamond`; and
- **11 facets / 95 selectors** on `StaticsDollarCoreDiamond`.

These source expectations are verified through deployment-test loupe
enumeration. Governed upgrades can change the live selector set without
changing either Diamond address, so current deployed state belongs in the
deployment manifest rather than this design document. Structural Position
changes require an explicit storage-compatibility and migration design; they
must not be inferred safe from the fresh-launch selector manifest.

Checked-in Core rehearsal snapshots record the selector shape before and after
the rehearsed terminal governance cut. That rehearsal deliberately removes
`diamondCut` and `transferOwnership` while proving the remaining value paths
still execute; it is separate from Core bootstrap finalization, which validates
wiring and clears bootstrap authority without removing selectors. Regenerate
rehearsal snapshots from the exact release commit before treating them as
release evidence.

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
| Genesis NFT | ERC-721 | Users, treasury, or Genesis Vault inventory | Scarce onchain identity and fixed claim on 180,010 vault-backed STATICS |
| BasketToken | ERC-20 Permit | Users, positions, or external venues | Transferable claim on a fixed constituent bundle |
| PositionNFT | ERC-721 | User-selected owner | Owns staking, basket collateral, loans, and Dollar legs |
| Staking token | Configured ERC-20; testnet `STATICS` also supports Permit | Reserved by `StaticsDiamond` per position | Stake weight; each reward asset uses only opted-in eligible stake as its denominator |
| Statics Dollar (`USDstx`) | ERC-20 Permit | Users and integrations | Senior Dollar claim |
| Risk Shares (`ethLEV`) | ERC-1155 | Users or PositionNFT legs | Series-specific residual Dollar risk |
| User v4 LP NFT | Uniswap PositionManager ERC-721 | User or voluntary `StaticsDiamond` custody | Canonical liquidity and optional hook-fee rewards |

The current canonical pools have zero native LP fee, so user v4 positions do
not earn ordinary native LP fees. Their swaps still pay the Statics hook's
configured input and output fees.

`StaticsToken` has an exact 999,955,550-token genesis supply, ERC-2612 permit,
and holder burns. It has no owner or post-deployment mint authority. The
standalone Genesis release allocates that supply between Genesis backing,
founder liquid tokens, and the permanent STATICS/WETH inventory market.

## Shared PositionNFT

One PositionNFT can own several independent legs:

- a global staking balance and accrued multi-asset claims;
- deposited and locked BasketTokens used as lending collateral;
- independent basket loan tranches;
- immediately consumable Statics Dollar Risk Share liquidity, funded
  incentives, fill proceeds, and series-migration credits;
- pairing-vault state; and
- voluntarily custodied full-range v4 LP NFTs and their hook-fee claims.

ERC-721 ownership and approvals authorize attached legs. Transferring the NFT
transfers its staking balance, reward claims, collateral, obligations, and
control of voluntarily custodied LP NFTs. Integrators must inspect every active
leg before accepting a transfer.

The Diamond implements the pre-ERC Modular Position NFT reporting interface
(`0x212b8e93`). `positionState` reports current existence, a structural nonce,
active-leg count, and unresolved-loan-obligation count. `isLegActive` provides
constant-time membership and `isPositionClosable` applies every aggregate plus
the mint-initialization guard. The nonce starts at one on mint and increments
for Leg attachment, Leg detachment, loan-obligation changes, and Closure. It
does not change for transfer, approval, reward settlement, or loan extension.
Position identity remains the qualified `(chain ID, Diamond, token ID)` tuple;
Statics does not expose a redundant Position Key hash.

Opening a Position NFT requires the exact native amount returned by
`positionCreationFee()`. The initial deployment target is `0.001 ETH`; the
Diamond owner may change the raw amount without an artificial cap, and zero
means free Position creation. Direct creation and every atomic create-and-use
path enforce the same fee and forward it immediately, in full, to the canonical
treasury. The Diamond does not retain or internally accrue this native value.
Adding legs, collateral, stake, liquidity, or debt to an existing Position does
not pay the fee again. Closing a Position and opening another creates a new NFT
and pays the then-current fee.

Each valid PositionNFT exposes simple Base64 JSON through `tokenURI`. It names
the token and describes it as a transferable financial account, but includes
no image or renderer dependency and no live status, achievement, yield, debt,
health, or rarity semantics. Deterministic onchain SVG identity belongs to the
scarce Genesis collection and may reflect its future activation tier.

`closePosition` succeeds only after all balances, claims, collateral, loans,
Dollar legs, custodied LP NFTs, and LP claims are empty. Externally held
Uniswap v4 NFTs are not PositionNFT legs and do not move with a PositionNFT
transfer.

### Reward eligibility comparison

| Reward rail | Weight | Eligibility | Exit behavior |
| --- | --- | --- | --- |
| Basket position rewards | Deposited BasketTokens in one basket | Immediate on deposit; fixed BasketToken-plus-constituents asset set | Entire position-and-basket leg waits until the block after its latest deposit; locked loan collateral stays eligible |
| Global Statics rewards | Configured ERC-20 stake selected into one reward asset | Initial stake, new selections, and top-up deltas mature at an hourly boundary 24–25 hours later | Stake is always withdrawable; withdrawal consumes pending before eligible stake |
| Canonical LP rewards | Full-range liquidity in a voluntarily custodied v4 NFT | Initial and increased liquidity deltas activate in the next block | NFT can leave immediately in any basket lifecycle state; claims remain attached to the PositionNFT |
| Dollar Risk liquidity | Supplied series Risk Shares | No passive eligibility: staking makes shares immediately consumable | Unconsumed effective shares remain withdrawable; pairing consumption creates junior, fee, and proportional funded-incentive proceeds; recovery may create migration credits |

## Static Basket Model

A basket definition contains:

- one to sixteen unique, nonzero ERC-20 asset addresses;
- a nonzero static bundle amount for each asset;
- independent flat mint and redemption fee-tier arrays;
- flash, origination, and extension percentage fees;
- LTV at or below 9,500 BPS;
- a debt-proportional recovery penalty whose maximum rounded charge still fits
  inside the remaining collateral; and
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

`launchBasketPools` and `mintBasketLaunch` are Diamond-self-only implementation
helpers used by `createBasket`; they are not alternative public launch routes.
The creator must approve and fund each constituent for both the paired pool
side and the ordinary mint backing plus fee. Launch requires the hook and
liquidity manager to be installed, exact minimum receipts for every seed, a
fresh deadline, and aggregate per-asset debit caps.

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

Loose BasketToken ownership alone does not earn protocol fees. A user may
deposit BasketTokens into a PositionNFT to earn that basket's configured
canonical swap-fee allocation, or stake the configured global staking token
and select reward assets to enter their global eligible-stake denominators.

## Basket Position Rewards

Every basket has a separate position-reward denominator. Depositing
BasketTokens through `createAndDepositBasketCollateral`,
`depositBasketCollateral`, `createAndMintBasketCollateral`, or
`mintBasketCollateral` immediately adds the deposited shares to that basket's
eligible denominator. The fixed reward-asset set is the BasketToken plus every
constituent, so a sixteen-asset basket has at most seventeen reward books and
requires no reward-asset opt-in loop.

Each deposit first settles the position's existing basket rewards and records
the current block. No shares from that position-and-basket leg may be withdrawn
or redeemed until the next block; a top-up restarts this one-block exit gate
for the complete leg. The gate prevents same-block reward entry and exit. It
does not delay reward eligibility beyond the deposit transaction.

Borrowing locks deposited shares without removing them from the reward
denominator. Only the origination-fee shares burned at loan creation stop
earning. Repayment changes lock state but not reward eligibility. Mature-loan
recovery removes only the burned debt-plus-penalty shares, while ordinary
withdrawal or position redemption removes the shares that leave custody.

Canonical swap fees may reward the BasketToken currency and any constituent.
For each pool and charged currency, the effective pool configuration determines
the basket-staker allocation. If the basket has no deposited eligible shares,
the hook redirects that allocation to permanent liquidity before creating a
position liability. Otherwise, a basket-and-asset 1e27 index distributes it
pro rata. When a basket denominator reaches zero, indexed whole-token value
that never crystallized to a position routes to global treasury accrual.

`getBasketRewardAssets`, `getBasketRewards`, and `basketRewardState` expose the
fixed reward set and accounting. `claimBasketRewards` requires PositionNFT
authorization, transfers from the shared fee reservation, and never reduces
basket redemption backing.

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
reclassification, extension payments, repayment excess, measured flash-loan
excess, the protocol share of mature-loan recovery penalties, pegged-profile
fees, and the global share of eligible volatile-series fees enter the same
non-swap ledger. If the asset has nonzero matured eligible selected stake:

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
cap. Each asset's index denominator is the matured eligible stake of positions
currently selected into that asset. A new selection enters pending state; its
maturity bucket records the then-current index, and the position accrues only
from that activation index. Opt-out settles earned value before removing both
eligible and pending stake.

Claims are pull-based, require PositionNFT authorization, and accept a
per-asset minimum received amount. Claim settlement transfers from the global
fee reservation and never reduces basket backing.

`pendingRewards`, `stakePosition`, `positionRewardAssets`,
`isRewardAssetOptedIn`, and `rewardSelection` are authorization-gated because
their values belong to a PositionNFT. `rewardSelection` reports selected,
eligible, pending, and exact maturity state. `rewardAsset`,
`maxRewardAssetsPerPosition`, `rewardEligibilityDelay`,
`rewardEligibilityBucketSize`, `stakingToken`, `totalStaked`,
`treasuryAccrued`, and `canAccrueStakerRewards` expose global configuration or
state.

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

Statics ships a narrow optional `StaticsFlashArbitrageReceiver` for the
overpriced mint-and-sell direction. A caller supplies a complete allocation
across canonical pools, per-asset net profit floors, and a deadline. The
receiver pulls only static-mint top-ups, uses ordinary fee-paying entrypoints,
approves exact repayment, returns every net profit asset to the caller, and
retains no route balances. It has no owner, arbitrary calls, venue discovery,
or privileged fee path. Underpriced buy-and-redeem routes remain the searcher's
responsibility. Statics provides no receiver allowlist, generic router,
callback privilege, or fee exemption. Cancun transient storage (EIP-1153) is a
deployment prerequisite.

## Protocol Uniswap v4 Liquidity

There is at most one canonical hooked pool per basket constituent. Its
currencies are the BasketToken and constituent, with:

| Parameter | Current value |
| --- | --- |
| Native v4 LP fee | 0 |
| Tick spacing | 10 |

Initialization is atomic with basket creation and uses the creator-supplied
price and asset budget. A successful creation makes the pool immediately
swappable and available to the typed borrow-to-liquidity and canonical LP
reward paths. There is no standalone initialization, activation, checkpoint,
or manager-sync action. Liquidity entry uses current pool state and remains
bounded by caller-supplied token caps and deadlines.

The installed hook rejects native currency and nonzero native LP fees for
registered canonical pools. Unregistered pools are not canonical.

Timelocked governance may also create a protocol pool between any two
compatible ERC-20 assets. Governance selects the pair, raw-unit initial price,
seed ceilings, minimum liquidity, and approved payer; Statics fixes the hook,
zero native LP fee, tick spacing 10, and full-range permanent-liquidity policy.
Registration, PoolManager initialization, funding, and seeding succeed or
revert together. The pool is active immediately, with no TWAP, oracle,
warmup, or activation dependency.

`protocolPool(poolId)` normalizes both `BasketCanonical` and `Governance`
records. Governance registration is market configuration only: it does not
admit assets as basket backing, Dollar collateral, lending assets, or basket
rewards. Discovery is event-indexed rather than stored in an unbounded array.

### Bilateral hook fees

The hook charges separately against realized input and output legs. The launch
manifest configures 50 BPS on each leg. Governance may update both rates and
the split, but the combined input-plus-output fee cannot exceed 200 BPS and the
split must total 10,000 BPS.

For each charged leg, the launch split is:

```text
10% permanent liquidity
25% eligible canonical LPs
25% deposited BasketTokens
15% global Statics stakers
25% treasury
```

Treasury receives split dust. If a pool has no activated staked liquidity, its
LP share redirects to permanent liquidity. If basket staking cannot accept the
reward asset, that share redirects to permanent liquidity. If global Statics
staking cannot accept the reward asset, that share redirects to treasury.

LP, basket-staker, Statics-staker, and treasury shares are transferred
immediately to the Diamond's fee ledger. LP shares accrue through pool-local
indexes for both currencies.
The permanent-liquidity share remains in the hook. When both pool
currencies are available, the hook compounds matched inventory into its own
full-range position during swap settlement. Unmatched amounts remain pending;
anyone may call `compoundPermanentLiquidity` later.

The global fee configuration is the default, not an immutable pool policy.
Timelocked Diamond governance may set a complete seven-field protocol-pool
override containing the input rate, output rate, and the five-way POL,
canonical-LP, basket-staker, Statics-staker, and treasury allocation. The two
rates must still total at most 200 BPS, and the five shares must total 10,000
BPS. Clearing an override restores the latest global rates and split.

Overrides change only future charges and allocation: pending POL is not
released or reclassified, hook-owned liquidity stays permanent, and existing
two-sided pending inventory remains eligible for compounding. The unavailable
canonical-LP and basket-staker fallbacks to POL and the unavailable
Statics-staker fallback to treasury are identical under global and pool
configurations. No threshold, volume, liquidity, or oracle rule changes an
override automatically.

Governance pools have no basket reward recipient. Their configured
basket-staker share redirects to permanent liquidity, while activated LP,
selected Statics-staker, and treasury routes behave like canonical pools.

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

### Protocol-pool LP rewards

Any unsubscribed, nonzero, full-range PositionManager NFT for an active
protocol pool may be attached to a PositionNFT and transferred into voluntary
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

The immutable liquidity manager validates the supplied PoolKey by PoolId
against the Diamond's normalized registry. It has no basket-specific pool
cache. Governance may replace the manager only with one immutably bound to the
same Diamond, PoolManager, PositionManager, and Permit2; replacement revokes
the old PositionManager operator approval before granting the new one.

Governance pools have a separate irreversible decommission path. It stops
swaps, releases hook-owned liquidity and pending inventory into treasury
accounting, and does not burn BasketTokens or touch user LP NFTs. Claims and
unstaking remain available after decommissioning.

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

For both paths, the caller supplies one aligned entry per constituent with its
tick range, exact liquidity, per-currency maximums, and deadline. Every pool
must be active, unique, and associated with the basket
constituent. Any stale price, bad pool, cap, deadline, range, approval, or
principal requirement reverts the loan, mint, and every LP creation.

`borrowAndProvideLiquidity` additionally accepts `lpRecipient`; that address
receives the external NFTs, unused principal, and PositionManager refunds.
`borrowAndStakeLiquidity` has no caller-selected recipient: the Diamond holds
the NFTs, and the current PositionNFT owner receives unused principal and
refunds even when an approved operator submits the call. The manager's
transaction-scoped inventory cannot enter basket backing, global staking,
permanent liquidity, or another user's accounting. Externally delivered v4
NFTs remain independent of later PositionNFT transfer, loan repayment,
extension, recovery, or basket decommissioning.

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

### Health, profile, and series lifecycle

Dollar profile modes are `Inactive`, `Active`, `ReduceOnly`, and `Retired`.
Governance activates configured profiles, may move an active profile into
reduce-only runoff, and may permanently retire it only from `ReduceOnly`.
Retirement is irreversible. Volatile profiles additionally manage series
states `Active`, `RecoveryPending`, `Recoverable`, `Retired`, and `Closed`;
successor creation and old-series recovery never make the claims of two series
interchangeable.

Core evaluates every configured profile independently and reports global health
as `Healthy`, `Impaired`, `Recovering`, or `Unavailable`. A bad or unavailable
profile cannot be masked by surplus in another profile. Global collateral exits
remain latched after impairment and require 48 continuous healthy hours,
advanced by explicit checkpoints, before ordinary exits become available
again.

Pegged redemption has an additional global quarantine. Any unresolved downside
series transition, unavailable health, or impaired profile blocks every pegged
profile from becoming an alternate exit around the unhealthy collateral.
Resolving the old transition does not reopen pegged redemption immediately: a
checkpoint starts its own 48-hour continuous-health delay, and any renewed
failure resets that delay. `peggedRedemptionStatus` is the read surface;
`checkpointPeggedRedemption` advances the latch. No background process advances
either health machine.

### Typed gateway permits

`recombineToWETHWithPermit`, `recombineToETHWithPermit`,
`mintPeggedWithPermit`, and `redeemPeggedWithPermit` bind permit owner to
`msg.sender` and spender to `StaticsDiamond`. The permit tuple carries its
signed allowance value independently from the amount consumed by the action.
An integration may therefore authorize the exact quoted input or a reusable
allowance, including a maximum allowance; the gateway pulls only the action's
validated input. A permit authorizes allowance only and does not bind the
series, profile, receiver, minimum output, or other economic parameters.
Recombination and redemption perform their availability checks before
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
requires that collateral token to implement EIP-2612. The signed allowance
must cover the quoted total pegged input but may be larger and reusable. As
with the other gateway permit paths, a failed permit attempt may fall back to
an existing sufficient caller allowance; the ERC-1155 operator approval is
still required.

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

The current launcher initializes this active-series split to 70% global
non-swap rewards and 30% insurance. It separately initializes pairing
redemption to a 50-BPS fee with 80% of that fee assigned to consumed Risk
suppliers and 20% to insurance. Both configurations remain timelock-controlled
while the Diamonds are upgradeable.

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

Anyone may fund a currently active series under an `Active` or `ReduceOnly`
volatile profile through one of three typed entrypoints:

- `fundRiskCollateralIncentives` pulls the series collateral token;
- `fundRiskDollarIncentives` pulls Statics Dollar; and
- `fundRiskStaticsIncentives` pulls the configured global staking token.

There is no arbitrary reward-token registry on this rail. Each entrypoint
derives its token from protocol configuration, measures the actual receipt, and
adds it to that series's isolated incentive reserve. Funding creates no passive
claim. On each pairing fill, the same suppliers whose Risk liquidity is
consumed receive the corresponding pro-rata fraction of all three reserves;
a complete fill drains the remaining rounding residue. `claimRiskProceeds`
returns collateral, Statics Dollar, and STATICS independently and aggregates
transfers safely if configured token roles coincide.

Unused incentives do not become stranded historical rewards.
`finalizeRiskIncentives` is permissionless and idempotent after a series is
recoverable, closed, or otherwise eligible for finalization. If the profile
continues with a healthy active successor, the reserves roll into that series.
If the profile is permanently retired, they enter the ordinary global non-swap
fee ledger. `processSeriesTransition` performs the same finalization before its
aggregate migration; the standalone finalizer also supports a funded series
with no supplied Risk liquidity to migrate.

Series transitions are processed once at aggregate Diamond custody and settled
per position lazily. Successor Risk Shares corresponding to supplied
predecessor liquidity remain supplied, while recovery-created Dollar and
collateral credits remain claimable from the predecessor leg. A Dollar leg
cannot be closed while Risk liquidity, fill or incentive proceeds, or migration
value remains.

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
pending LP reward activation, basket-loan recovery,
manual hook compounding, treasury distribution, and ExitOnly unwind can remain
pending indefinitely until someone submits a transaction. Basket-loan recovery
pays its caller 20% of the configured penalty backing; Dollar expired-risk
recovery includes its separate quoted keeper bounty. Claims, LP activation,
manual compounding, treasury distribution, and ExitOnly unwind pay
no protocol bounty, so their liveness depends on users, governance, integrators,
or externally motivated keepers. Swap execution itself routes fees and attempts matched
permanent-liquidity compounding atomically, but does not provide liveness when a
pool has no swaps. Production operations must define monitoring, acceptable
delays, escalation ownership, and guardian/governance fallbacks for inactive
keepers and failed unwind attempts.

## Governance and Upgradeability

One `StaticsTimelock` owns both Diamonds. Its constructor selects two minutes
for Robinhood testnet and local development, while Robinhood mainnet and other
chains default to seven days. The configured multisig is proposer and canceller,
execution is open after delay,
and the emergency guardian is not a timelock canceller.

The timelock currently controls Diamond cuts, economic configuration, lifecycle
release and decommissioning, hook fee configuration,
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
| Basket administration | `IStaticsBasketAdmin` |
| Basket collateral | `IStaticsBasketCollateral` |
| Basket position rewards | `IStaticsBasketRewards` |
| Global staking and rewards | `IStaticsGlobalRewards` |
| Basket lending | `IStaticsLending` |
| Basket flash loans | `IStaticsFlashLoan` and `IStaticsFlashBorrower` |
| PositionNFT | `IStaticsPosition` plus ERC-721 interfaces; renderer-free onchain financial-account metadata |
| Genesis NFT and vault | `IStaticsGenesis` and `IStaticsGenesisVault` |
| Standalone Genesis market | `IStaticsV4Hook` and `IStaticsHookController` |
| Basket governance | `IStaticsGovernance` |
| Custody views | `IStaticsCustody` |
| Canonical liquidity | `IStaticsBasketLiquidity` |
| Canonical LP rewards | `IStaticsLiquidityRewards` |
| Borrow-to-liquidity | `IStaticsBorrowLiquidity` |
| Hook reads | `IStaticsSwapFeeHook` |
| Manager reads | `IStaticsLiquidityManager` |
| Dollar gateway | `IStaticsDollarGateway` |
| Dollar Risk liquidity | `IStaticsDollarRiskLiquidity` |
| Dollar Risk incentives | `IStaticsDollarRiskIncentives` |
| Dollar Core | `IStaticsDollarCore` |

Integrators should quote immediately before submission, provide explicit
maximum inputs and minimum outputs, scope approvals to the typed next action,
and reconcile indexed events against current views after reorgs.

`IStaticsBasketLaunchModule` is an internal composition boundary between
`BasketFacet` and `BasketLiquidityFacet`. Its selectors reject every caller
except the Diamond itself and should not be exposed as user launch actions.

## Deployment Model

`script/DeployStatics.s.sol:DeployStatics` is the canonical full-stack
launcher. It deploys the timelock, Dollar oracle adapter, Core facets and
Diamond, Dollar tokens, 23 unified facets and `StaticsDiamond`, and the
immutable v4 hook and manager. A separate timelock ceremony installs the hook
and manager into the Diamond. Basket creation is valid only after that
installation because every basket must launch all of its canonical pools and
permanent liquidity atomically.

Production inputs include:

- broadcaster authorization and RPC;
- multisig, guardian, and treasury;
- a verified deployed `STAKING_TOKEN` contract;
- basket creation fee;
- WETH, ETH/USD feed, sequencer feed, and oracle bounds;
- Dollar collateral ratio, price band, debt ceiling, and metadata URI; and
- the pinned chain manifest's PoolManager, PositionManager, Permit2, hook
  calibration, and runtime hashes.

The target chain must support Cancun/EIP-1153. The launcher selects
`deployments/robinhood-chain-4663.json` on Robinhood mainnet or
`deployments/robinhood-chain-testnet-46630.json` on testnet from
`block.chainid`, and rejects other chains. These files pin external dependency,
runtime-hash, and calibration evidence; neither is a Statics address manifest.
Mainnet fork tests read `ROBINHOOD_MAINNET`, while the dependency-only testnet fork reads
`ROBINHOOD_TESTNET_RPC_URL`. Checked-in chain-31337 broadcasts are local
rehearsal records. No Robinhood mainnet Statics address manifest is recorded.

### Recorded Robinhood Chain testnet deployment

The human-readable [`deployment.md`](deployment.md) summarizes the current
Robinhood Chain testnet integration beta. The machine-readable
[`deployments/robinhood-testnet-46630-statics.json`](deployments/robinhood-testnet-46630-statics.json)
is the canonical address, configuration, operation, source-verification, and
upgrade record. Mutable deployment facts are intentionally not duplicated in
this design document.

The testnet release uses explicit fixtures and test parameters and is not a
production qualification. Production must replace mock collateral and oracle
fixtures, choose a reviewed staking-token policy, verify the intended
governance delay and roles, select economic parameters, and qualify one exact
release revision.

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
- Permit signatures authorize caller allowances, not a complete economic
  intent. Their signed value may exceed the current action input and remain
  reusable; the gateway's tolerant fallback may use an already sufficient
  caller allowance.
- Permissionless Risk incentive funding is restricted to the series collateral,
  Statics Dollar, and configured staking token, but funders still bear series,
  profile, consumption, rollover, and retirement timing risk.
- The public testnet's mock USDG and oracles, faucet, and two-minute timelock
  are fixtures and must not be treated as production trust assumptions.
- Basket-loan recovery and Dollar expired-risk recovery have distinct
  caller-incentive formulas; other basket and liquidity maintenance has no
  guaranteed caller or protocol bounty.
- Repository tests and local analysis are not independent production assurance.

## Testing and Assurance

The test pyramid includes focused unit and harness proofs, live value-moving
integration flows, fuzz tests, stateful invariants, deployment rehearsals,
canonical Uniswap v4 tests, and a pinned Robinhood Chain fork shape.

The repository contains focused source coverage for custody, rewards, lending,
recovery, Dollar profiles, canonical and governed pools, permits, deployment,
selector routing, and testnet fixtures. Test counts and pass totals are release
evidence rather than protocol design and are intentionally not frozen here.

Before production approval, execute and preserve the complete default and
security profiles, focused deployment proofs, local canonical-pool integration
flows, every required pinned Robinhood fork suite, SDK tests, and SDK build
against the exact release commit. Record the timestamp, environment, commands,
outcomes, skips, and commit in the release qualification artifact. A focused
test, skipped environment-gated fork, or successful public testnet transaction
does not substitute for that complete qualification.

## Implemented, Production Readiness, and Excluded

### Implemented

- fixed multi-asset BasketTokens and aggregate backing;
- shared PositionNFT and basket collateral;
- position-selected global multi-asset indexes and treasury fees;
- position-owned self-backed vector lending and debt-proportional recovery;
- composable constituent-vector flash loans;
- atomic creator-funded launch of every basket and canonical constituent pool;
- canonical zero-native-fee v4 pools with bilateral hook fees and governed
  per-pool allocation overrides;
- hook-owned full-range permanent liquidity and ExitOnly unwind;
- isolated BasketToken reward indexes, canonical LP NFT reward custody, and
  typed borrow-to-external or PositionNFT-owned liquidity;
- volatile and pegged Statics Dollar profiles with frontrun-tolerant exact or
  reusable typed permit allowances;
- consumption-only Dollar Risk liquidity with permissionless
  collateral/Statics Dollar/STATICS incentive reserves and deterministic
  successor or retirement handling;
- shared custody reservations, measured transfers, and guardian quarantine;
- timelocked EIP-2535 upgradeability; and
- SDK quote, calldata, permit, canonical-swap, faucet, and
  position-management helpers.

### Production readiness boundaries

- independent contract and governance review;
- final governance powers and the ceremony that removes Diamond-cut authority;
- production staking-token design, timelock verification, collateral profiles,
  and economic parameters;
- a revision-pinned release qualification artifact; and
- production deployment addresses and explorer verification.

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
position accrual = floor(positionEligibleStake * indexDelta / RAY)
```

Otherwise `staker = 0` and `treasury = grossFee`. Each accrual floors
independently; there is no carried division remainder. If eligible stake later
reaches zero, indexed whole-token value that never crystallized to positions is
routed to treasury. Pending selection stake is excluded. When its hourly bucket
matures, the bucket's then-current index becomes its activation checkpoint, and
that stake accrues only from later index growth.

### Basket position rewards

For basket `k`, reward asset `a`, and a routed basket-staker hook allocation:

```text
basketIndexDelta[k][a]
    = floor(basketStakerAmount * RAY / totalDepositedShares[k])
basketIndexRay[k][a] += basketIndexDelta[k][a]
position accrual
    = floor(positionDepositedShares[k] * basketIndexDelta[k][a] / RAY)
```

If `totalDepositedShares[k]` is zero when the hook routes the fee, the
basket-staker allocation redirects to POL instead of entering an index. Locked
loan collateral remains in `positionDepositedShares`; only burned or withdrawn
shares leave the denominator.

### Borrow and extension

```text
feeShares = ceil(sharesIn * originationFeeBps / D)
collateralShares = sharesIn - feeShares
fee underlying_i = B_i(S) - B_i(S - feeShares)
debtShares = ceil(collateralShares * ltvBps / D)
penaltyShares = ceil(debtShares * recoveryPenaltyBps / D)
principal_i = floor(bundle_i * debtShares / Q)
extension quote_i = ceil(stored principal_i * extensionFeeBps / D)
```

Creation and origination require
`debtShares + penaltyShares <= collateralShares`. Exact rounding is defined by
the onchain quote functions and stored tranche values.

After maturity and the one-hour grace period:

```text
burnShares = debtShares + penaltyShares
backingRemoved_i = B_i(S) - B_i(S - burnShares)
penaltyBacking_i = backingRemoved_i - stored principal_i
callerAmount_i = floor(penaltyBacking_i * 2,000 / D)
protocolAmount_i = penaltyBacking_i - callerAmount_i
```

### Flash loan

```text
principal_i = floor(bundle_i * flashShares / Q)
quoted fee_i = ceil(principal_i * flashFeeBps / D)
requested repayment_i = principal_i + quoted fee_i
success requires measured receipt_i >= principal_i
actual fee_i = measured receipt_i - principal_i
```

### Dollar Risk liquidity and incentives

For a pairing fill `F` against effective Risk liquidity `A` immediately before
the fill:

```text
fixedSeniorWad = floor(F * seniorCollateralPerUnitWad / WAD)
fixedSenior = fromWad(collateralDecimals, fixedSeniorWad)
redeemer = floor(fixedSenior * (D - redemptionFeeBps) / D)
pairingFee = fixedSenior - redeemer
insurance = floor(
    pairingFee * (D - redemptionSupplierShareBps) / D
)
risk-supplier collateral = grossCollateral - redeemer - insurance
```

The supplier amount contains the complete junior residual plus the supplier
share of the pairing fee. It is indexed over the pre-fill stored units in that
series epoch.

For each isolated incentive reserve `R` in collateral, Statics Dollar, or
STATICS:

```text
released = R                              if F == A
released = floor(R * F / A)               otherwise
remaining reserve = R - released
```

The full-fill branch drains rounding residue. Released incentives use the same
pre-fill stored-unit denominator as pairing proceeds, so only liquidity exposed
to that consumption receives them. Supplying Risk Shares without a fill creates
no passive reward.

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

At launch, input and output rates are each 50 BPS and the split is
1,000/2,500/2,500/1,500/2,500 for
POL/LP/basket-staker/Statics-staker/treasury. If no activated LP liquidity
exists for the pool, its allocation is added to POL. If either staking route is
unavailable, that allocation is also added to POL. Exact-input and exact-output
swaps map the specified and unspecified
realized legs according to Uniswap v4 settlement.

For an active pool override `(f_in, f_out, p, l, b, s, t)`:

```text
f_in + f_out <= 200
p + l + b + s + t = D
```

The same equations apply using the pool-specific rate selected for the realized
leg and the pool-specific shares. Treasury still receives all rounding
remainder. Clearing the override restores the latest global rates and shares.

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
11. Primary mint, redemption, flash, origination, and extension fees never create basket-specific holder claims; only the configured canonical hook basket-staker allocation enters basket position indexes.
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
28. Basket creation registers, initializes, and permanently seeds exactly one canonical pool per constituent or reverts without creating the basket.
29. Canonical pools are immediately swappable and available to typed liquidity paths after atomic creation and seeding.
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
46. A failed gateway permit never substitutes another owner: the typed action still pulls only from `msg.sender` under ordinary allowance rules, while a successful permit may deliberately preserve allowance above the current action input.
47. Complete pool fee overrides change only future input/output charges and routing, preserve the 200-BPS combined-rate cap, preserve unavailable-LP and unavailable-basket-staker fallbacks to POL, and preserve the unavailable-Statics-staker fallback to treasury.
48. Guardian quarantine contains an active basket but neither releases quarantine nor adjudicates a black-swan physical deficit.
49. Core bootstrap finalization clears bootstrap authority but does not remove Diamond-cut authority.
50. Final V1 immutability requires explicit removal of implementation-upgrade authority; later dependency replacement uses terminal V1 wind-down and a separate V2 rather than live migration.
51. Canonical LP custody entry requires the LP NFT and PositionNFT to have the same current owner.
52. Dollar expired-risk recovery includes its quoted keeper bounty; basket-loan recovery pays its own fixed 20% share of configured penalty backing.
53. `borrowAndStakeLiquidity` keeps borrowed BasketToken collateral basket-reward eligible while activating its newly custodied full-range LP weight no earlier than the next block.
54. Deposited BasketTokens enter their basket denominator immediately but cannot leave before the block after the most recent deposit into that position-and-basket leg.
55. Basket reward assets are bounded to the BasketToken plus its constituents, and an unavailable basket-staker allocation redirects to POL before creating a claim.
56. A PositionNFT cannot close while it controls a custodied LP NFT or an outstanding LP reward claim.
57. Supplied Dollar Risk Shares are immediately consumable; unconsumed effective principal remains withdrawable, no passive reward exists, and only pairing consumption releases junior, fee, and funded-incentive proceeds.
58. Pegged redemption cannot bypass a pending downside transition or impaired profile and reopens only after the dedicated 48-hour continuous-health delay is checkpointed.
59. Owner-created genesis baskets and public exact-fee baskets use the same creator-funded atomic launch path.
60. Basket launch helpers accept calls only from the Diamond itself; every user or owner launch enters through `createBasket`.
61. Dollar Risk incentives accept only the series collateral, Statics Dollar, or configured staking token and reserve measured receipts within the funded series.
62. Partial Risk-liquidity consumption releases each funded reserve pro rata against pre-fill effective liquidity, while a complete fill drains its rounding remainder.
63. Genesis SVG metadata is fully onchain and keeps redemption backing separate from activation-tier presentation.
64. PositionNFT metadata is fully onchain, renderer-free, and contains no live financial or achievement claims.
65. Unused Risk incentives roll into an eligible active successor series or enter global non-swap rewards after permanent profile retirement.
66. The public chain-46630 faucet, mock USDG and oracles, and two-minute timelock are testnet fixtures rather than production defaults.
67. Native PoolManager donations to protocol pools always revert; POL inventory enters only through protocol seeding and swap-fee allocation.

## Appendix C: Terminology

| Term | Meaning |
| --- | --- |
| **BasketToken** | Transferable ERC-20 claim on one basket's fixed constituent bundle |
| **Bundle amount** | Constituent quantity represented by 1e18 BasketToken shares |
| **Basket collateral** | BasketTokens deposited in a PositionNFT and optionally locked for lending |
| **Basket position reward** | Basket-and-asset hook-fee claim indexed over deposited BasketTokens, including locked loan collateral |
| **Global staking token** | Deployment-configured ERC-20 providing position stake weight; each reward asset's denominator includes only positions opted into that asset |
| **Reward book** | Permissionless per-asset 1e27 index state shared by positions that explicitly select that asset |
| **Risk liquidity** | Series Risk Shares supplied to a PositionNFT for immediate proportional consumption by pairing exits |
| **Risk incentive reserve** | Permissionlessly funded series-isolated collateral, Statics Dollar, or STATICS released only as Risk liquidity is consumed |
| **Fee account** | Diamond reservation holding global staker claims and treasury accruals |
| **Staking account** | Diamond reservation holding the configured staking token |
| **Permanent liquidity (POL)** | Hook-owned full-range protocol-pool liquidity seeded at pool creation and expanded from swap-fee allocations |
| **Canonical pool** | BasketToken/constituent v4 pool atomically registered, initialized, seeded, and made usable during basket creation |
| **Bilateral hook fee** | Separate fee applied to realized input and output swap legs |
| **PositionNFT** | Shared ERC-721 owning Statics staking, basket collateral and loans, Dollar legs, and voluntarily custodied LP NFTs and claims |
| **ExitOnly** | Basket state that is terminal under installed facets, blocking new exposure while preserving exits and risk reduction |
| **Actual flash fee** | Measured repayment received above principal |
| **Quarantine** | Guardian containment state blocking new basket exposure while preserving installed-facet exits and risk reduction |
| **Final V1 immutability** | Deliberate removal of Diamond implementation-upgrade authority after final governance review; retained parameter powers remain separately enumerated |
| **Terminal treasury fee** | Global fee-account amount distributable only to the configured treasury |
