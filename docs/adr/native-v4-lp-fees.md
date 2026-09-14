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
The fee must be less than 1,000,000 pips; a 100% native LP fee is rejected.

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
`feesAccrued` from its principal delta. The hook records that amount as a
PoolManager ERC-6909 claim allocated only to treasury; it never adds native fees
to pending permanent liquidity or compounds them.

Ordinary swaps do not zero-poke permanent positions solely to collect fees.
Automatic POL compounding still modifies the position and therefore realizes
any native LP fees reported by that modification. A separately configured
harvester lets the Diamond realize fees while compounding is idle or one-sided,
and the Diamond can only credit the resulting tokens to protocol treasury
accounting. The caller cannot choose a recipient. Governance can replace the
harvester, while the guardian can pause explicit harvesting and treasury
distribution; only governance can unpause them.

Every permanent-position modification advances Uniswap v4's fee-growth
checkpoint and may crystallize sub-unit rounding dust. Explicit harvesting
avoids adding a zero-liquidity checkpoint to every swap, but it cannot remove
the checkpoints required by automatic POL compounding. That residual is
accepted to preserve keeperless compounding.

Bilateral callback fees also remain as ERC-6909 claims until the next routing
boundary. Claim liabilities are tracked by currency and checked against the
hook's PoolManager claim balance. Matching POL claims are burned atomically when
new permanent liquidity is added, preserving automatic swap-driven compounding
without a keeper. Because eligibility can change while a distribution is
pending, the routing boundary rechecks it: an unavailable basket-staker share
becomes POL and an unavailable Statics-staker share becomes treasury. This keeps
swaps, harvesting, and unwind live after the final eligible staker exits.

The hook delegates only the pure full-range liquidity calculation to an
immutable `StaticsPermanentLiquidityMath` contract so the hook retains explicit
EIP-170 deployment headroom. The calculator holds no assets or protocol state
and has no privileged entrypoint. Deployment records its address and runtime
code hash beside the hook evidence.

Decommissioning reports permanent-liquidity principal, unmatched POL, and
ordinary fee distributions separately. Principal and unmatched POL follow the
pool unwind policy, while eligible staker, creator, and treasury distributions
retain their original destinations. Decommissioning alone does not make a
basket-staker distribution ineligible.

Pool donation is forbidden, so an external caller cannot use the ordinary v4
donation path to manufacture reported fees for the permanent position.

## Consequences

- LP compensation follows standard v4 position ownership and range economics.
- The Diamond no longer owns user LP NFTs or exposes LP reward claims.
- PoolId now includes the configured native fee; changing it requires a new
  hook and different pools rather than a governance update to existing keys.
- Native LP fees and bilateral Statics fees must be displayed and quoted as
  distinct charges.
- Native fee harvesting is operationally optional: delaying it affects only
  treasury revenue, not swaps, user withdrawals, or automatic POL compounding.
- Installation pins the exact runtime hashes of both the hook and liquidity
  manager in addition to their immutable bindings.
