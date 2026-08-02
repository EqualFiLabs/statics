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
├── Statics Basket creation, mint, redeem, rewards, lending, and flash loans
└── Statics Dollar staking, rewards, opt-in, pairing, pegged revenue, and typed gateway

StaticsDollarCoreDiamond
├── volatile-series issuance and direct pegged wrappers
├── health, insurance, transitions, and recovery
├── authority for Statics Dollar ERC-20 Permit
└── authority for Statics Dollar Risk Shares ERC-1155

StaticsBasketToken (one address per basket)
└── transferable ERC-20 Permit representation of one static bundle

StaticsSwapFeeHook
└── immutable canonical-pool swap fee and bounded tick observations

StaticsLiquidityManager
├── immutable Diamond, v4 PositionManager, PoolManager, and Permit2 bindings
├── isolated protocol inventory and protocol-owned v4 NFTs
└── typed user-position minting with NFTs delivered directly to users
```

Users continue to call `StaticsDiamond`. Uniswap v4 calls the hook encoded in
the canonical pool key, while only the Diamond can call the liquidity manager;
neither standalone contract is a second general protocol entrypoint.

The canonical deployment installs 20 facets and 170 selectors on
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
- pegged-profile protocol revenue;
- per-basket backing and protocol revenue;
- per-basket, per-asset POL reserves, cumulative fee classification,
  canonical-pool state, compounding epochs, hook settlement, and protocol LP
  fee totals;
- per-basket, per-asset holder reward indexes and claims; and
- per-position, per-basket loan tranches, principal, and recovery surplus.

Statics Dollar Core collateral never enters shared periphery custody. Basket
assets never collateralize Statics Dollar, Dollar positions never collateralize
basket loans, and the two products never share reward denominators.

## Physical-token reservations

The shared Diamond can physically hold the same ERC-20 for Dollar rewards and
several baskets. `LibCustody` therefore records:

```text
globalReservedByToken[token]
reservedByAccount[dollarAccount][token]
reservedByAccount[basketAccount(basketId)][token]
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
pool key with the immutable Statics hook, a 500-pip LP fee, and tick spacing
10. Pool initialization enters a one-hour warm-up; activation requires enough
hook observations for a 30-minute reference and a spot deviation no greater
than the configured one-percent bound.

The three physical locations keep independent books:

```text
StaticsDiamond
├── basket backing and outstanding debt
├── PositionNFT holder-reward reserves
├── terminal basket protocol revenue
└── undeployed per-basket/per-asset POL reserves

StaticsSwapFeeHook
└── per-pool/per-currency measured fee liabilities

StaticsLiquidityManager
├── per-basket/per-token idle POL inventory
└── one protocol PositionManager NFT per basket constituent
```

Raw balances at any location are not shared liquidity. Hook withdrawals debit
only the selected pool liability. Manager movements debit only the selected
basket inventory and must leave its global token inventory covered. This lets
two baskets or pools share a physical token without sharing attribution.

Eligible primary basket fees are classified atomically into holder rewards,
POL reserve, and terminal revenue. Once per 24-hour epoch, anyone may convert a
proportional reserve slice into exactly backed BasketTokens and matched
constituents for full-range POL. During a pool's first seven days the deployed
slice is capped at 10%; compounding below `1e12` BasketToken shares reverts.

The hook independently charges one basis point, rounded up, on realized swap
amounts in the charged currency. Settlement makes 100% of measured hook
receipts terminal basket revenue. The canonical pool's ordinary five-basis-
point LP fee belongs to its liquidity providers. For protocol-owned positions,
floor-rounded 10% of each measured fee currency becomes terminal revenue and
the remainder stays as POL inventory. User-owned v4 positions keep all of
their LP fees while their swaps still pay the separate hook fee.

`borrowAndProvideLiquidity` is an optional typed Diamond action. It originates
the ordinary position-owned loan, burns the ordinary origination fee, uses
retained principal for an ordinary-fee basket mint, and creates one v4 NFT per
constituent directly for the selected recipient. Unused transaction-scoped
principal and PositionManager refunds go to that recipient. The manager keeps
no user inventory, and user v4 NFTs are neither PositionNFT legs nor Statics
collateral.

Quarantine and liquidity pause block new compounding and combined borrowing
without blocking fee settlement. Exit-only baskets can permissionlessly burn
each protocol position, return idle manager inventory, burn returned
BasketTokens into proportional backing revenue, and reclassify remaining POL
reserves as terminal revenue. User-owned v4 NFTs remain under their owners'
control.

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

Price checks bound activation, compounding, and combined entry against the
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

All custody-mutating facets inherit ordinary OpenZeppelin `ReentrancyGuard`.
Under delegatecall, facets on the same Diamond share its fixed namespaced guard
slot, giving cross-facet exclusion without a protocol-specific lock. The user
Diamond and Core Diamond have separate guard state because they are separate
execution and custody boundaries.

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
