# Statics architecture

## Contract topology

Statics intentionally exposes one ordinary user address while preserving a
separate Statics Dollar solvency backend.

```text
StaticsTimelock
├── owns StaticsDiamond
└── owns StaticsDollarCoreDiamond

StaticsDiamond
├── EIP-2535 routing, ownership, governance, and custody views
├── PositionNFT ERC-721
├── Statics Basket creation, mint, redeem, lending, and flash loans
├── global staking and checkpointed multi-asset rewards
└── Statics Dollar Risk liquidity, pairing, fee routing, recovery, and typed gateway

StaticsDollarCoreDiamond
├── volatile-series issuance and direct pegged wrappers
├── health, insurance, transitions, and recovery
├── authority for Statics Dollar ERC-20 Permit
└── authority for Statics Dollar Risk Shares ERC-1155

StaticsBasketToken (one address per basket)
└── transferable ERC-20 Permit representation of one static bundle

StaticsToken
└── fixed 1-billion supply, Permit, and holder-authorized burns

StaticsGenesis
├── fixed IDs 1..5,555 and one-time binding to StaticsDiamond
├── transfer-reset activation tiers and one-to-one PositionNFT links
└── deterministic Base64 JSON rendered by StaticsGenesisRenderer + StaticsAvatarSVG

StaticsSwapFeeHook
├── bilateral canonical-pool swap fees
└── hook-owned full-range permanent liquidity

StaticsLiquidityManager
├── immutable Diamond, v4 PositionManager, PoolManager, and Permit2 bindings
├── registered PoolKey validation and token settlement
└── typed user-position minting with NFTs delivered directly to users

```

Users continue to call `StaticsDiamond`. Uniswap v4 calls the hook encoded in
the canonical pool key, while only the Diamond can call the liquidity manager;
neither liquidity contract nor the Genesis metadata contracts are a second general
protocol entrypoint.

The fresh-deployment launcher installs 25 facets and 229 selectors on
`StaticsDiamond`, and 11 facets and 95 selectors on
`StaticsDollarCoreDiamond`. The programmatic manifests live in
`script/dollar/DeployStaticsProtocol.s.sol` and
`script/dollar/DeployCoreBootstrap.s.sol`; deployment tests enumerate every
installed selector, verify its routed facet and that every facet has runtime
code, and assert those fresh-launch totals. Runtime hashes are recorded in
release and rehearsal manifests rather than asserted by the fresh-deployment
manifest test. Later governed upgrades can change the deployed selector set;
the current deployment manifest records that live release state.

## One address without one economic book

`StaticsDiamond` is the action address, PositionNFT contract, and shared
periphery custody address. A single position ID can contain multiple Dollar
series and multiple basket legs, and ERC-721 approval authorizes every attached
module operation.

That shared ownership does not merge economics. The following storage books are
separately namespaced:

- PositionNFT ownership and active-leg state;
- Genesis tier, one-to-one link, and activation-cost state;
- creator, partner, and previous-PositionNFT-owner revenue liabilities;
- global and module-local physical reservations;
- Statics Dollar consumable Risk liquidity, pairing proceeds, migration, and
  insurance ingress;
- pegged-profile fee ingress;
- per-basket backing and collateral;
- canonical-pool registration, lifecycle, and decommission state;
- one immediately withdrawable global staking balance per PositionNFT, at most
  64 selected reward assets per position, and independent hourly 24-to-25-hour
  eligibility rings for an unlimited set of global asset indexes; and
- per-position, per-basket reward indexes, loan tranches, principal, and
  proportional recovery state.

Statics Dollar Core collateral never enters shared periphery custody. Basket
assets never collateralize Statics Dollar, Dollar positions never collateralize
basket loans. Basket and Dollar fees can share the global staking denominator
without sharing backing or debt books.

## Physical-token reservations

The shared Diamond can physically hold the same ERC-20 for Dollar rewards and
several baskets. `LibCustody` therefore records:

```text
globalReservedByToken[token]
reservedByAccount[dollarAccount][token]
reservedByAccount[basketAccount(basketId)][token]
reservedByAccount[feeAccount][token]
reservedByAccount[stakingAccount][token]
```

Every attributed ingress increases both the module account and global total.
Every egress releases only the calling account's authorization, caps the
Diamond's observed debit, and proves the remaining physical balance still
covers the global total. Raw balances are never treated as module liquidity.

Internal accounting isolates hostile baskets from one another. A token that
rebases, burns the Diamond's balance externally, or lies through `balanceOf`
can still create a physical token-wide failure for every basket using it. The
creation switch does not certify constituents, and this shared-token risk is
not a reason for a protocol registry.

## Genesis effective-weight transitions

Global reward books separately track actual eligible/pending STATICS and
effective eligible/pending weight. Fee accrual increases each asset's monotonic
index using total effective eligible weight as the denominator. An unactivated
or unlinked position contributes exactly its actual stake; linked activation
tiers contribute 1.10x, 1.15x, 1.20x, or 1.25x weight without creating a token
claim above actual stake.

Link, unlink, activation, and stake changes first settle the completed index
interval at the old registered weight, preserve any pending-stake maturity
timestamp, then replace denominator weight for future index increases.
Permissionless checkpointing processes due nonempty maturity buckets in batches
of at most eight assets; elapsed empty epochs fast-forward without making a book
stale. The one-to-one link, 64-active-selection bound, and bounded maintenance
batches keep weight-changing transactions below the 16 million gas target.

Neither NFT can transfer while linked. After explicit unlinking, an
owner-changing PositionNFT transfer changes only ERC-721 authority: stake,
selections, checkpoints, accrued rewards, assets, and liabilities remain keyed
to the PositionNFT and move with it. The transfer neither changes a reward
denominator nor calls arbitrary reward tokens. Creator rewards use a pull-based
liability, while partner accrual is snapshotted by recipient and may be
distributed permissionlessly with a bounded caller tip.

## Canonical v4 liquidity boundaries

Every configured basket constituent has one canonical BasketToken/constituent
pool key with the immutable Statics hook, a zero native LP fee, and tick spacing
10. Basket creation atomically deploys the BasketToken, initializes every
constituent pool, registers every key with the manager, mints the aggregate
pool BasketTokens through ordinary backing and fee accounting, and seeds
full-range permanent liquidity from creator-supplied assets. All pool and
custody changes roll back if any constituent cannot launch. The same path is
used for owner-created genesis baskets and public exact-fee creation.
Creation includes a caller-selected deadline and measured aggregate
constituent-debit caps. Launch prices use raw smallest-unit constituent amounts
per raw BasketToken amount, so decimal normalization belongs in the client
quote rather than the protocol. Canonical v4 launch supports constituents that
settle the exact requested transfer amount; incompatible transfer-tax behavior
reverts the entire genesis transaction.

Each launched pool is immediately swappable and available to the typed
borrow-to-liquidity and canonical LP reward paths. Callers bound execution with
token amount caps and deadlines.

The three physical locations keep independent books:

```text
StaticsDiamond
├── basket backing and outstanding debt
├── per-basket BasketToken and constituent reward indexes
├── global per-asset staking reward reserves
├── global per-asset treasury reserves
├── custody for fixed-supply STATICS
└── voluntary custody for reward-eligible PositionManager NFTs

StaticsSwapFeeHook
├── per-pool/per-currency pending locked liquidity
└── hook-owned full-range v4 liquidity

StaticsLiquidityManager
├── normalized protocol-pool validation by PoolId
├── typed user PositionManager NFT creation
└── typed increases for Diamond-custodied user positions
```

Raw balances at any location are not shared liquidity. The hook charges both
realized swap legs, rounded up, while the pool's native LP fee remains zero.
The default fee is 50 basis points on input and 50 basis points on output,
split 10% to locked liquidity, 20% to activated protocol-pool LPs, 20% to
deposited BasketToken positions, 15% to eligible STATICS stakers, 10% to
StonkBrokers, 5% to the basket's index creator, and 20% to treasury.
Unavailable LP and basket-staker allocations independently redirect to locked
liquidity. An unavailable STATICS-staker allocation, missing partner, or
missing creator redirects to treasury. A registered pool may override the
complete nine-field configuration; clearing that override
restores the latest global rates and split.

This global configuration is the default. Basket-specific entrypoints resolve
a canonical pool by `basketId` and constituent, while protocol-pool entrypoints
address either pool class directly by PoolId. Timelocked governance may
override input/output rates and the seven-way locked-liquidity/canonical-LP/
basket-staker/STATICS-staker/partner/creator/treasury split. The two rates may
total at most 200 BPS, the split must total 10,000 BPS, and locked liquidity or canonical
LPs may explicitly be set to zero. Clearing the override restores the latest
global rates and split.
Overrides never release or reclassify pending locked liquidity, never remove permanent
liquidity, and do not alter decommissioning. Unavailable canonical-LP and
basket-staker shares still redirect to locked liquidity; unavailable global Statics-staker
shares redirect to treasury. Governance pools have no basket reward book, so
their basket-staker allocation always redirects to locked liquidity before fee delivery.

Protocol pools reject native Uniswap v4 donations in `beforeDonate`. This
prevents third parties from injecting an opposite-side asset into pending locked liquidity
and forcing hook-owned inventory to compound at a manipulated spot price.
Protocol seeding and swap-fee routing remain the only locked liquidity inventory sources.

The normalized registry recognizes existing basket canonical pools without a
storage migration and stores governance-created pools in a separate namespace.
Governance creates a fixed-policy PoolKey between any two compatible ERC-20s,
initializes it, and permanently seeds full-range liquidity from an approved
payer in one transaction. Registration does not admit either asset as basket
backing, Dollar collateral, or a borrowable asset.

After every swap, matched locked liquidity amounts are added as hook-owned full-range
liquidity in the same pool. No caller, administrator, or treasury can withdraw
active-pool locked liquidity. On `ExitOnly`, permissionless decommissioning releases it,
burns the released BasketTokens, and reserves the resulting constituents for
the common treasury. User-owned v4 positions remain under their owners'
control and collect no native LP fee. A full-range NFT for either protocol-pool
class may instead be attached to a PositionNFT and held by the Diamond to earn
the LP hook share.
New and increased liquidity activates in the next block; there is no exit
cooldown.

`borrowAndProvideLiquidity` is an optional typed Diamond action. It originates
the ordinary position-owned loan, burns the ordinary origination fee, uses
retained principal for an ordinary-fee basket mint, and creates one v4 NFT per
constituent directly for the selected recipient. Unused transaction-scoped
principal and PositionManager refunds go to that recipient. The manager keeps
no user inventory. User v4 NFTs remain external unless their owner later opts
into the separate PositionNFT custody-and-reward entrypoint; origin through
this function is not an eligibility condition.

`borrowAndStakeLiquidity` performs the same bounded borrow, ordinary-fee mint,
and one-pool-per-constituent construction, but mints full-range v4 NFTs directly
into Diamond custody as PositionNFT legs. The current PositionNFT owner is the
refund beneficiary even when an approved operator submits the call. New LP
weight activates in the next block. The deposited BasketToken collateral
continues earning its isolated basket rewards while locked, so this path can
earn both the basket-staker and canonical-LP hook allocations without changing
loan economics.

Quarantine and liquidity pause block new combined borrowing. Exit-only baskets
can permissionlessly decommission each canonical pool and unwind its permanent
hook liquidity. User-owned v4 NFTs remain under their owners' control.

## Liquidity threat model

The hook fee cannot make unhooked competing pools pay Statics. Canonical status,
locked liquidity, SDK metadata, and supported routing are the incentive for concentrating
activity in the hooked pool. Concentrated liquidity also carries ordinary
price-range and inventory risk; Statics uses full-range locked liquidity and does not swap
mismatched inventory to hide that exposure.

Permissionless baskets may contain taxed, rebasing, callback-capable, or
otherwise hostile tokens. Measured transfer deltas and location-local
reservations prevent nominal accounting from spending another isolated book,
but a token that mutates balances outside transfer semantics can still make
every account using that same physical token insolvent or unusable. Basket and
token reputation remain a user-agency concern; exit-only decommissioning is
the governed containment path.

Combined basket liquidity entry uses the current v4 pool state to calculate
required token amounts. Callers must simulate current state and impose amount
caps and deadlines. The manager and hook expose only typed v4 operations and
immutable bindings; the manager verifies every PoolKey against the Diamond's normalized
registry and neither contract exposes arbitrary calls, approvals, swaps, or
upgradeable logic.

## Upgradeability model

Both Diamonds use the same EIP-2535 kernel. Diamond cuts are the only proxy
upgrade mechanism. There is no UUPS, transparent, beacon, or ERC-1967 proxy.

The PositionNFT facet inherits OpenZeppelin `ERC721Upgradeable` because a facet
constructor would initialize the facet's storage rather than Diamond storage.
The upgradeable variant supplies a delegatecall-safe initializer and fixed
ERC-7201 storage namespace; it does not deploy another proxy. Standalone
Statics Dollar and BasketToken contracts use ordinary OpenZeppelin `ERC20` and
`ERC20Permit` constructors.

Custody-mutating basket, lending, rewards, and liquidity facets inherit
ordinary OpenZeppelin `ReentrancyGuard`. Under delegatecall, those facets on the
same Diamond share its fixed namespaced persistent slot, giving cross-facet
exclusion without a protocol-specific lock. `FlashLoanFacet` instead uses
OpenZeppelin `ReentrancyGuardTransient`: nested flash loans remain excluded in
the transient domain while an ordinary guarded mint or redemption may execute
during the explicit receiver callback. Flash disbursement and repayment each
acquire the common persistent slot, so callback-capable token transfers cannot
enter another persistent value path while balance deltas are being measured.
The user Diamond and Core Diamond have separate persistent guard state because
they are separate execution and custody boundaries.

The kernel follows standard EIP-2535 cut semantics: the owner may add, replace,
or remove selectors and may optionally delegatecall an initializer in the same
transaction. A failed initializer reverts the entire cut. The kernel rejects
selector collisions and invalid facet addresses, but it does not inspect facet
bytecode, pin code hashes during dispatch, whitelist initializer selectors, or
maintain a second upgrade policy beside ownership.

## Governance boundary

The canonical launcher deploys one OpenZeppelin-based `StaticsTimelock` as owner
of both Diamonds. Core administration derives from the Core Diamond owner; it
does not maintain a second protocol-governor role, internal proposal queue, or
irreversible configuration locks. The timelock constructor selects two minutes
for Robinhood testnet and local development, while Robinhood mainnet and other
chains default to seven days. After deployment, the delay can change only
through a scheduled timelock call to the timelock itself. The configured multisig proposes
and may cancel scheduled operations, while execution is open after the current
delay. The emergency guardian is not a timelock canceller.

The basket guardian can immediately pause exposure-increasing actions and
quarantine baskets. Only timelocked governance can unpause, release quarantine,
or mark a basket `ExitOnly`. The Dollar guardian can pause profile operations,
reduce a debt ceiling, or enter reduce-only mode, but cannot block proportional
holder exits, create profiles, restore operations, increase risk, or change an
oracle. A Dollar profile can be permanently retired only from reduce-only mode;
retirement preserves runoff exits and cannot be reversed.
Periphery fee, reward, and redemption parameters remain repeatedly configurable
by the timelock and cannot be irreversibly locked.

## Canonical source boundary

This repository contains every tracked contract, test, script, dependency, and
SDK source required to build and run Statics. The historical Dollar repository
is recorded only as pinned provenance in `docs/source-provenance.md`; no source,
build, test, deployment, or runtime path imports or symlinks to it.
