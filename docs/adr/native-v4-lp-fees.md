# ADR: Native Uniswap v4 LP compensation

- Status: Accepted and implemented
- Date: 2026-09-13
- Scope: permanent Statics pools, LP compensation, bilateral hook fees, POL revenue, liquidity custody, and exact-output swaps
- Supersedes: `canonical-lp-nft-rewards.md` and the zero-native-fee and custom-LP-reward decisions in `permissionless-protocol-pools.md`

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

Ordinary Uniswap v4 LP positions earn native fees without Statics custody or
reward enrollment. Concentrated and full-range positions use standard
PositionManager ownership and accounting. Statics removes the custom LP reward
facet, interface, storage, indexes, claims, PositionNFT leg, manager increase
path, and `borrowAndStakeLiquidity`. `borrowAndProvideLiquidity` remains and
mints each PositionManager NFT directly to the selected recipient.

The bilateral Statics hook fee remains separate from the native LP fee. Its
initial allocations are:

| Destination | Basket pool | General pool |
| --- | ---: | ---: |
| Permanent liquidity | 1,500 BPS | 4,000 BPS |
| Basket staking | 3,000 BPS | 0 BPS |
| STATICS staking | 3,000 BPS | 3,500 BPS |
| Creator, fixed | 500 BPS | 500 BPS |
| Treasury | 2,000 BPS | 2,000 BPS |
| Total | 10,000 BPS | 10,000 BPS |

Governance may change the four configurable basket shares or three
configurable general shares, which must total 9,500 BPS beside the fixed
creator share. An unavailable basket-staking share redirects to permanent
liquidity. An unavailable STATICS-staking share redirects to treasury.

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

Native fees earned by the hook-owned permanent position are protocol revenue,
not new POL principal. Every liquidity modification separates PoolManager's
`feesAccrued` from its principal delta. The hook takes the fee amount and routes
it only to treasury; it never adds that amount to pending permanent liquidity
or compounds it. If permanent liquidity exists but bilateral POL inventory is
not matched, the post-swap path performs a zero-liquidity-delta collection so
native fees still reach treasury.

Pool donation is forbidden, so an external caller cannot use the ordinary v4
donation path to manufacture reported fees for the permanent position.

## Consequences

- LP compensation follows standard v4 position ownership and range economics.
- The Diamond no longer owns user LP NFTs or exposes LP reward claims.
- PoolId now includes the configured native fee; changing it requires a new
  hook and different pools rather than a governance update to existing keys.
- Native LP fees and bilateral Statics fees must be displayed and quoted as
  distinct charges.
- Decommissioning releases only permanent-liquidity principal to the normal
  unwind receiver; native fees harvested during release route to treasury.
