# ADR: Native Uniswap v4 LP compensation

- Status: Partially superseded by `creator-led-pool-configuration.md` and
  `managed-protocol-owned-liquidity.md`
- Date: 2026-09-13
- Scope: permanent Statics pools, LP compensation, bilateral hook fees, POL revenue, liquidity custody, and exact-output swaps
- Supersedes: `canonical-lp-nft-rewards.md` and the zero-native-fee and custom-LP-reward decisions in `permissionless-protocol-pools.md`
- Superseded decision: one immutable deployment-wide native LP fee; the native
  v4 accounting and compensation decisions remain current

## Context

Statics protocol pools previously disabled the native Uniswap v4 LP fee and paid
full-range LPs through a separate Diamond-custodied reward system. That design
duplicated native pool accounting, required users to surrender PositionManager
NFT custody, restricted compensated liquidity to full range, and expanded the
PositionNFT and Diamond selector surface.

The permanent Statics Diamond has not been deployed. This is therefore the
initial permanent-pool design, not an upgrade migration. The already deployed
standalone Genesis launch is a separate system and is unchanged.

## Decision

Every permanent Statics pool uses one immutable native LP fee selected when
`StaticsSwapFeeHook` is deployed. The launch default is 3,000 pips (0.30%). The
deployment manifest supplies the default, `STATICS_NATIVE_LP_FEE_PIPS` may
override it for a deployment run, and pool construction reads the hook value.
Registration rejects a PoolKey whose fee differs from the hook value.
The fee must be less than 1,000,000 pips; a 100% native LP fee is rejected.

Ordinary Uniswap v4 LP positions earn native fees without Statics custody or
reward enrollment. Concentrated and full-range positions may use standard
PositionManager ownership and accounting. Statics removes the former
full-range-only LP reward system and `borrowAndStakeLiquidity`.
`borrowAndProvideLiquidity` remains and mints each PositionManager NFT directly
to the selected recipient.

Phase 1 later adds a separate opt-in public range gauge. A user may transfer an
approved PositionManager NFT to the immutable liquidity manager, bind it to a
transferable Statics PositionNFT, and earn explicitly funded range incentives.
That managed path has its own reward index and lifecycle methods, but it does
not replace, redirect, or duplicate native Uniswap LP fees.

The bilateral Statics hook fee remains separate from the native LP fee. Its
initial allocations are:

| Destination | Basket pool | General pool |
| --- | ---: | ---: |
| Managed protocol-owned liquidity | 1,500 BPS | 4,000 BPS |
| Basket staking | 3,000 BPS | 0 BPS |
| STATICS staking | 3,000 BPS | 3,500 BPS |
| Creator, fixed | 500 BPS | 500 BPS |
| Treasury | 2,000 BPS | 2,000 BPS |
| Total | 10,000 BPS | 10,000 BPS |

Governance may change the four configurable basket shares or three
configurable general shares, which must total 9,500 BPS beside the fixed
creator share. General pools have managed POL disabled by default, in which
case its share redirects to Treasury without creating POL inventory. An
unavailable basket-staking share redirects to active POL or Treasury when POL
funding is disabled. An unavailable STATICS-staking share redirects to
Treasury.

## Exact-output semantics

The permanent hook uses the same complete-fill accounting as the launch hook.
For fee rate `f` over denominator `D = 10,000`:

```text
exact-input fee  = ceil(gross amount * f / D)
exact-output fee = ceil(net amount * f / (D - f))
```

After the swap, the hook verifies that the specified delta equals the requested
amount plus its specified-leg fee. A partial specified fill reverts. The
unspecified exact-output leg uses the same net-to-gross formula.

## Protocol-owned liquidity fees

The current POL portfolio design is specified in
[`managed-protocol-owned-liquidity.md`](./managed-protocol-owned-liquidity.md).
The hook records the bilateral POL share as a PoolManager claim and exposes
exact settlement into the Diamond's PoolId-specific custody account. It does
not own or modify a liquidity position.

The governed operator manages explicit ordinary PositionManager NFTs through
`StaticsLiquidityManager`. Native fees are collected and reserved as Treasury
revenue before any principal decrease, close, or rebalance. Refunds and
principal always return to protocol custody. A general pool must be activated
by its immutable creator before future swaps can fund POL.

STATICS-staker fees are indexed during the authenticated swap callback. Their
PoolManager claims may settle later, but later stake changes cannot reassign
ownership. Creator, basket-staker, Treasury, and POL claims retain their
separate settlement paths.

Pool donation is forbidden, so an external caller cannot use the ordinary v4
donation path to manufacture reported fees for the permanent position.

## Consequences

- LP compensation follows standard v4 position ownership and range economics.
- The Diamond no longer owns user LP NFTs or exposes LP reward claims.
- PoolId now includes the configured native fee; changing it requires a new
  hook and different pools rather than a governance update to existing keys.
- Native LP fees and bilateral Statics fees must be displayed and quoted as
  distinct charges.
- Revenue and POL inventory settlement are operationally optional. Delaying
  them affects only distribution liquidity and POL deployment, not swaps or
  user withdrawals.
- Installation pins the exact runtime hashes of the hook and liquidity manager
  in addition to their immutable bindings.
