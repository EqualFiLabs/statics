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
└── Statics Dollar staking, rewards, opt-in, pairing, pegged fee routing, and typed gateway

StaticsDollarCoreDiamond
├── volatile-series issuance and direct pegged wrappers
├── health, insurance, transitions, and recovery
├── authority for Statics Dollar ERC-20 Permit
└── authority for Statics Dollar Risk Shares ERC-1155

StaticsBasketToken (one address per basket)
└── transferable ERC-20 Permit representation of one static bundle

StaticsSwapFeeHook
├── bilateral canonical-pool swap fees and bounded tick observations
└── hook-owned full-range permanent liquidity

StaticsLiquidityManager
├── immutable Diamond, v4 PositionManager, PoolManager, and Permit2 bindings
├── canonical-pool registration
└── typed user-position minting with NFTs delivered directly to users
```

Users continue to call `StaticsDiamond`. Uniswap v4 calls the hook encoded in
the canonical pool key, while only the Diamond can call the liquidity manager;
neither standalone contract is a second general protocol entrypoint.

The canonical deployment installs 22 facets and 183 selectors on
`StaticsDiamond`, and 11 facets and 95 selectors on
`StaticsDollarCoreDiamond`. The programmatic manifests live in
`script/dollar/DeployStaticsProtocol.s.sol` and
`script/dollar/DeployCoreBootstrap.s.sol`; deployment tests enumerate every
installed selector, verify its routed facet and runtime hash, and assert the
exact totals.

## One address without one economic book

`StaticsDiamond` is the action address, PositionNFT contract, and shared
periphery custody address. A single position ID can contain multiple Dollar
series and multiple basket legs, and ERC-721 approval authorizes every attached
module operation.

That shared ownership does not merge economics. The following storage books are
separately namespaced:

- PositionNFT ownership and active-leg state;
- global and module-local physical reservations;
- Statics Dollar staking, passive rewards, opt-in rewards, migration, and
  insurance ingress;
- pegged-profile fee ingress;
- per-basket backing and collateral;
- canonical-pool registration, lifecycle, and decommission state;
- one global staking balance per PositionNFT, at most 64 selected reward assets
  per position, and an unlimited set of independent global asset indexes; and
- per-position, per-basket loan tranches, principal, and recovery surplus.

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
can still create a physical token-wide failure for every basket using it. This
is a permissionless constituent risk, not a reason for a protocol registry.

## Canonical v4 liquidity boundaries

Every configured basket constituent has one canonical BasketToken/constituent
pool key with the immutable Statics hook, a zero native LP fee, and tick spacing
10. Pool initialization enters a one-hour warm-up; activation requires enough
hook observations for a 30-minute reference and a spot deviation no greater
than the configured one-percent bound.

The three physical locations keep independent books:

```text
StaticsDiamond
├── basket backing and outstanding debt
├── global per-asset staking reward reserves
├── global per-asset treasury reserves
├── custody for the configured staking token
└── voluntary custody for reward-eligible PositionManager NFTs

StaticsSwapFeeHook
├── per-pool/per-currency pending POL
└── hook-owned full-range v4 liquidity

StaticsLiquidityManager
├── typed user PositionManager NFT creation
└── typed increases for Diamond-custodied user positions
```

Raw balances at any location are not shared liquidity. The hook charges both
realized swap legs, rounded up, while the pool's native LP fee remains zero.
The default fee is 25 basis points on input and 25 basis points on output, split
50% to POL, 10% to activated canonical LPs, 30% to global stakers, and 10% to
treasury. An unavailable LP or staker allocation is independently redirected
to POL. A registered pool may override the complete six-field configuration;
clearing that override restores the latest global rates and split.

This global configuration is the default. The basket-liquidity facet lets
timelocked governance resolve a registered canonical pool by `basketId` and
constituent, then override its input/output rates and four-way
POL/canonical-LP/staker/treasury split. The two rates may total at most 200 BPS,
the split must total 10,000 BPS, and POL or canonical LPs may explicitly be set
to zero. Clearing the override restores the latest global rates and split.
Overrides never release or reclassify pending POL, never remove permanent
liquidity, and do not alter decommissioning. Unavailable canonical-LP and
staker shares still redirect to POL.

After every swap, matched POL amounts are added as hook-owned full-range
liquidity in the same pool. No caller, administrator, or treasury can withdraw
active-pool POL. On `ExitOnly`, permissionless decommissioning releases it,
burns the released BasketTokens, and reserves the resulting constituents for
the common treasury. User-owned v4 positions remain under their owners'
control and collect no native LP fee. A full-range canonical NFT may instead
be attached to a PositionNFT and held by the Diamond to earn the LP hook share.
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

Quarantine and liquidity pause block new combined borrowing. Exit-only baskets
can permissionlessly decommission each canonical pool and unwind its permanent
hook liquidity. User-owned v4 NFTs remain under their owners' control.

## Liquidity threat model

The hook fee cannot make unhooked competing pools pay Statics. Canonical status,
POL, SDK metadata, and supported routing are the incentive for concentrating
activity in the hooked pool. Concentrated liquidity also carries ordinary
price-range and inventory risk; Statics uses full-range POL and does not swap
mismatched inventory to hide that exposure.

Permissionless baskets may contain taxed, rebasing, callback-capable, or
otherwise hostile tokens. Measured transfer deltas and location-local
reservations prevent nominal accounting from spending another isolated book,
but a token that mutates balances outside transfer semantics can still make
every account using that same physical token insolvent or unusable. Basket and
token reputation remain a user-agency concern; exit-only decommissioning is
the governed containment path.

Price checks bound activation and combined entry against the
hook's time-weighted observations. They do not guarantee fair execution during
oracle manipulation, sequencer failure, extreme volatility, or insufficient
history. Callers must simulate current state and impose amount caps and
deadlines. The manager and hook expose only typed v4 operations and immutable
bindings; neither exposes arbitrary calls, approvals, swaps, or upgradeable
logic.

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
irreversible configuration locks. The delay initializes to seven days and can
change only through a scheduled timelock call to the timelock itself. The
configured multisig proposes and may cancel scheduled operations, while
execution is open after the current delay. The emergency guardian is not a
timelock canceller.

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
