# Shared basket conversion

One immutable `StaticsBasketConversionHook` serves registered basket/quote
PoolIds. One zap and one typed router use the same fixed-bundle execution
library. Existing General and Basket AMM hooks remain separate.

Conversion buys exact BasketToken output and sells exact BasketToken input.
It uses real constituent swaps and the existing Diamond mint/redemption paths.
There is no oracle, NAV calculation, LP inventory, rebalance, or additional outer
conversion charge. Mint/redemption fees follow the existing governed non-swap
fee route. Ordinary underlying/secondary swaps charge their own pool fees.

## Identity and authorization

The existing basket-market registry holds each permanent PoolKey, basket ID,
quote and lifecycle. An appended conversion flag defaults false for all existing
AMM records. AMM resolution excludes conversion entries: they receive no range
gauge, managed POL, or AMM fee administration. Existing swap quarantine controls
accept conversion identities. A decommissioned identity cannot be registered again.

The conversion facet's constructor binds the shared hook, zap, router and
PoolManager. Registration follows the existing pool-creation fee; zero makes
creation owner-only. The Diamond registers and initializes the deterministic
zero-fee, tick-spacing-one PoolKey. External initialization and liquidity
addition revert. Its initialization price is a PoolManager placeholder, not
a basket valuation or quote.

Registration requires an active finalized basket and non-basket ERC-20
constituents/quote. WETH is supported; native ETH, nested baskets and basket
quote/intermediate currencies are excluded. Conversion is an optional separate
market creation action, not a change to basket launch.

## Settlement

Underlying swaps run within one PoolManager unlock. Required assets go directly
from PoolManager to Diamond custody. The shared Diamond guard protects requoting,
exact fresh-arrival checks, per-basket reservation and the existing retained
principal mint. Donations and old adapter inventory cannot substitute for arrival.
A consumed callback commitment binds PoolId, basket, shares, receiver and amounts.

Sells burn real shares and redeem real available backing. Wallet hook sells
explicitly prefund through the supported router and normal Diamond allowance;
the Diamond authorizes exactly that PoolManager inbound transfer. The hook uses
existing receiver/amount-bound claims and directional settlement budgets.
Zap wallet sells additionally require the zap's explicit distributor approval
and an ordinary allowance. Distributor approval does not grant mint capability.

Conversions cannot sell staked collateral or manufacture physical backing from
outstanding receivables. Insufficient available backing reverts atomically.
Impairment, quarantine, decommissioning and existing action pauses remain
effective. Impaired exits use explicit `redeemImpaired`, with existing forfeiture.

## Routing and integration

Caller routes are primary. Each constituent has a quote-to-constituent V4 path
of at most four hops, with typed PoolKeys and per-hop hook data. Sells traverse
the path backwards. Zero-hop quote constituents are valid. Validation rejects
cycles, native/basket intermediates, mismatched keys, and every pool using the
conversion hook. Every swap must fill exactly; deadline, constituent bounds and
aggregate bounds remain caller-controlled.

Optional presets are governed by the current Diamond owner, stored only on the
shared hook and keyed by PoolId/direction. The zap reads that same source.
Presets store execution paths, not users' amount bounds. Empty paths clear a
preset. No registered route is required for caller-supplied execution.

The typed router executes one to four same-basket/quote swap steps and requires
the selected conversion market to appear. It can atomically mint then sell to
an ordinary AMM, or buy there then redeem. Final wallet spending and minimum
quote/basket receipts are bounded. Profitable self-funded cycles use zero
prefunding, zero maximum quote input and positive minimum quote output.
No arbitrary target calls or canonical-arbitrage validation exceptions are added.

Ordinary launch/secondary AMMs retain gauges, bribes, staking and credit
composition. The atomic borrow-to-gauge helper is a separate feature.

## Release

Deploy the Phase 2 facet bundle from the conversion candidate, then add the
conversion facet's six selectors and interface declaration. The updated AMM
resolver is inlined into its importing facets; an already installed older
Phase 2 bundle must receive those candidate facet replacements before conversion
registration. Installing only the new facet against an old bundle is insufficient.
Preserve the original Phase 2 fixtures and execute its existing qualification gate.

Deploy and fully verify the hook, zap, router and bound facet with solc 0.8.33,
Cancun, optimizer 200, no IR and IPFS metadata. Freeze and reproduce exact source,
creation/runtime bytes, constructor arguments, permission bits and selectors.
Prepare the Diamond cut and explicit zap distributor approval for owner execution.
Verify the configuration, selector routing and distributor approval after execution.
No deployment or owner transaction is implied by local qualification.

Qualify fresh pinned Robinhood fork execution and mined conversion transactions,
including 2/3/4/7/16 constituents and eligible reward histories. Receipt gas must
retain 10% headroom below the 16,777,216 target transaction cap. Bounds apply to
the tested liquidity, routes and histories; arbitrary token behavior, liquidity
depth or gauge-boundary density does not have a universal gas guarantee.

## Local qualification and release

Run the local conversion tests and real-PoolManager invariant normally. Fork work
loads the canonical private RPC environment in the same shell. Then run
`scripts/basket-conversion/run-fork.py`; it checks chain ID, block number and block
hash before executing the maintained Robinhood strategy suite.

`scripts/basket-conversion/execution.py` exports production-contract fixtures and
mines user transactions exclusively on fresh loopback Anvil instances. Its full
matrix covers 2, 3, 4, 7 and 16 constituents; hook/zap buys and sells; both AMM
arbitrage directions; first and repeated execution after 0, 1 and 26 hours. The
four-asset fixture includes USDG as a zero-hop constituent. Other constituents use
the real pinned USDG markets. Secondary basket AMM mispricing is constructed in
the fixture, with recorded liquidity; it is not a claim of live arbitrage profit.
Each trade targets 100 USDG of basket shares at the initial conversion quote.
Arbitrage fixtures use 1e15 full-range secondary liquidity plus a 1e13 gauge leg.
Exports record each underlying PoolId and its active liquidity at preparation.
Repeated trades use the resulting pool state without restoring its price.

`scripts/basket-conversion/release.py <new-isolated-directory>` runs the original
Phase 2 freeze, bytecode reproduction and Cast/Anvil rehearsal unchanged, then
adds the conversion upgrade, strategy and receipt gates. The conversion extension
has 52 facets and 362 selectors (51/356 before extension). Every qualified user
transaction must consume less than 90% of 16,777,216 gas. The gate checks actual
receipt status, gas, transaction and call-trace binding; exact shared hook identity;
constructor/immutable values and CREATE2 permission bits; metadata and reproduced
creation/runtime bytecode. Evidence is candidate-specific; prototype results do
not satisfy this gate.

Use `DeployStaticsBasketConversion` to deploy the shared hook, zap, router and
constructor-bound facet only. It does not cut the Diamond or approve distributors.
`PrepareStaticsBasketConversionUpgrade.buildSafeJson` accepts the complete reviewed
Phase 2 facet parts, replaces installed selectors that still point to older facet
implementations, adds the six conversion selectors and interface, and separately
approves the zap as a distributor. For a Phase 1 installation, first prepare the
existing Phase 2 cut from this candidate, then the conversion batch. Neither
preparation helper broadcasts transactions. The existing General hook stays in use.
