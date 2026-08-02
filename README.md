# Statics

Statics is one protocol for Statics Dollar and isolated static baskets.
It combines fixed multi-asset redemption bundles, arbitrage-oriented action
fees, global multi-asset staking rewards, constituent flash loans, and
proportional self-backed lending.

## Architecture

The ordinary integration address is `StaticsDiamond`. It is simultaneously:

- the typed user action surface for Statics Dollar and Statics Baskets;
- the ERC-721 contract for every Statics PositionNFT;
- the custody address for Dollar periphery assets and basket assets; and
- the upgradeable EIP-2535 Diamond governed through `StaticsTimelock`.

`StaticsDollarCoreDiamond` remains a separate backend and custody boundary for
Dollar collateral, issuance, health, insurance, transitions, and recovery.
`StaticsDollar` is an 18-decimal OpenZeppelin ERC-20 Permit token. Each basket
deploys its own permit-enabled `StaticsBasketToken` ERC-20 for transfers and
external liquidity. Statics is not ERC-4626: one
BasketToken represents a creator-defined vector of assets, not shares of a
single-asset vault with a changing conversion rate.

See [architecture](docs/architecture.md), [integration](docs/integration.md),
and [deployment](docs/deployment.md) for the complete contract map.

## Static baskets and fees

Basket creation is closed to public callers while the native-currency creation
fee is zero; only the Diamond owner may create genesis baskets in that state,
and it must send zero value. Setting a positive fee opens creation to anyone
who pays the exact amount. This is a launch admission switch, not a token
registry or constituent certification. The creator selects the immutable
constituent vector, mint and redemption fee tiers, flash-loan fee, lending
fees, LTV, and loan duration.

Minting deposits the static constituent bundle plus a flat fee selected from
the greatest qualifying action-size threshold. Redemption burns BasketTokens
and returns the static bundle less the selected flat fee. Previously accrued
fees do not change either quote and new minters do not buy into historical
yield.

Basket mint, redemption, flash-loan, lending, and Dollar fees no longer reward
holders of an individual BasketToken. Each fee asset enters the global fee
ledger. Users stake the configured Statics staking token in a PositionNFT and
select up to 64 reward assets for that position. The protocol can index any
number of reward assets globally; each asset uses only the stake of positions
that selected it as its denominator. New selections start at the current index
and cannot capture historical fees. Non-swap fees without eligible selected
stake accrue entirely to the common Statics treasury.

Canonical Uniswap v4 pools use a zero native LP fee. The hook charges both the
input and output assets, routes the configured staker and treasury shares into
the global ledger, and immediately converts matched POL shares into hook-owned
full-range liquidity. That liquidity has no ordinary withdrawal path and is
released only after the associated basket enters `ExitOnly` and its pool is
decommissioned.

The global swap-fee configuration is the default for every canonical pool.
Timelocked governance may override both bilateral fee rates and the
POL/canonical-LP/staker/treasury split for one pool, including zero POL and zero
canonical-LP allocation for a mature pool. Existing pending POL can still
compound and existing permanent liquidity remains locked. Clearing the
override restores the complete then-current global default; unavailable
canonical-LP and staker shares continue to fall through to POL.

Flash loans expose only basket constituents. Statics deliberately contains no
embedded swap router and requires no initial BasketToken liquidity; an
arbitrageur sources and sells constituents through external venues.

## Positions and liquidity access

A single transferable PositionNFT can own Statics Dollar series legs and
multiple independent basket legs. Position transfer moves every attached
reward checkpoint, claim, locked balance, loan, and maturity. A position cannot
close while any module leg remains live.

Basket lending locks eligible BasketTokens in their existing position and
releases the proportional constituent vector at the basket's configured LTV.
The immutable protocol ceiling is 95%; a basket may choose less. Origination
fees reclassify BasketToken backing into the global fee ledger. Extension fees
are paid directly in every outstanding constituent principal and enter the
same ledger. Basket collateral does not earn a separate basket-specific reward
stream.
Multiple independent loan tranches allow bounded recursive mint-deposit-borrow
loops without resetting older maturities.

Repayment restores the exact constituent principal and unlocks only its loan
tranche. After maturity plus the recovery grace period, recovery is
permissionless and removes only that tranche's collateral and accounting.

## Statics Dollar

The same `StaticsDiamond` exposes typed ETH and WETH deposits and ordinary
recombination to WETH or ETH. `StaticsDollarCoreDiamond` remains directly
callable for advanced integrations. Ordinary direct and Diamond-routed
recombination use identical fee economics. Only the explicit managed path used
by pairing and recovery machinery receives managed treatment.

Statics Dollar implements EIP-2612. The permit recombination entrypoints bind
an exact Dollar allowance to the caller and consume it during the same WETH or
ETH exit transaction. The series risk shares still require ERC-1155 operator
approval; approval-based recombination remains available for contract wallets
and other callers that cannot produce an EIP-2612 signature.

Pegged collateral profiles are direct nominal wrappers: they mint only Statics
Dollar, create no risk series, and charge independent mint and redemption fees
in the collateral token. Any fungible Statics Dollar can redeem against a
profile's proportional capacity. Pegged fees enter the global fee ledger:
eligible fees use the standard 90% staker and 10% treasury split, while fees
without eligible selected stake fall back to the common Statics treasury.
Downside series transitions quarantine every pegged exit until all
Core books have remained healthy for 48 continuous hours.

Dollar risk shares can be staked into the shared PositionNFT, activated after
the Dollar reward gate, moved between passive and opt-in reward tiers, and
processed through series transition and recovery flows without creating a
second position system.

## Basket lifecycle

- `Active`: minting, redemption, borrowing, extension, flash loans, repayment,
  and recovery are available subject to action pauses.
- `Quarantined`: the guardian blocks new exposure immediately. Repayment,
  recovery, and exits remain available; timelocked governance can release or
  permanently decommission the basket.
- `ExitOnly`: minting, borrowing, extension, and flash loans remain disabled in
  the installed facets. Redemption bypasses the global redemption pause, and
  repayment and permissionless recovery remain open.

The Diamond remains upgradeable, so `ExitOnly` is terminal in the installed
lifecycle logic rather than an immutable restriction on future governance.

## Permissionless assets and measured accounting

Every basket backing balance, basket and global reward reserve, loan, and
treasury reserve is kept in an isolated custody account. A global physical
reservation total prevents one module from spending tokens attributed to
another module. Direct donations remain unallocated and cannot inflate any
internal book.

Token movements use observed balance deltas. Inbound transfers credit what the
Diamond actually receives; each operation then enforces the economic minimum
it needs. Outbound transfers authorize a maximum Diamond debit and separately
apply the caller's minimum-received bound. This permits measured fee-on-transfer
behavior while preventing one transfer from consuming another module's
reservation. Rebases, arbitrary external burns, deceptive `balanceOf`
implementations, blocklists, pauses, and callbacks remain constituent risks
that integrations should surface through basket reputation.

See [SECURITY.md](SECURITY.md) for the complete authority, custody, and
liveness assumptions.

## Development

Read `AGENTS.md` and `ETHSKILLS.md` before changing Solidity. Focused tests are
preferred during development:

```bash
forge test --match-path test/path/ToTest.t.sol
npm test --prefix sdk
npm run build --prefix sdk
```

For a local full-stack launch or an explicitly authorized production launch,
follow [docs/deployment.md](docs/deployment.md). No public deployment is
recorded by this repository.
