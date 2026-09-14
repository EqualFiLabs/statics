# ADR: Creator-led Uniswap v4 pool configuration

- Status: Accepted and implemented
- Date: 2026-09-14
- Scope: Statics basket and general-pool creation, native LP compensation,
  bilateral hook fees, creator authorization, and PoolId identity
- Supersedes: the deployment-wide native LP fee in
  `native-v4-lp-fees.md` and the creator-selected hook-fee decision in
  `permissionless-protocol-pools.md`

## Context

Native Uniswap v4 LP fees compensate ordinary PositionManager liquidity through
standard v4 accounting. Statics bilateral hook fees separately fund permanent
liquidity, staking, creator revenue, and treasury revenue. These are independent
fee layers and must not share one configuration control.

The permanent Statics Diamond has not been deployed, so this is a clean initial
deployment design rather than an in-place pool migration. The standalone
Genesis launch hook is separate and unchanged.

## Decision

Statics recognizes two registered pool classes:

1. A basket canonical pool associates one BasketToken with one constituent and
   is created and permanently seeded atomically during basket creation.
2. A general pool associates any two compatible ERC-20 contracts and is
   initialized without requiring a liquidity seed.

Every registered pool uses the installed `StaticsSwapFeeHook`. The creator
selects the static native v4 LP fee, tick spacing, and initial price. A basket
creator also selects the paired-asset launch amount for each constituent market.
A general-pool creator selects both token addresses and an immutable creator
identity.

Valid creator-selected native fees are `0…999_999` pips. Tick spacing is
`1…32_767`. Native ETH, dynamic LP fees, a 100% LP fee, alternative hooks,
already initialized PoolIds, and duplicate registered PoolIds are rejected.

The Diamond normalizes token order and reciprocal price before quoting. General
pool EIP-712 authorization version 2 binds the resulting PoolId, normalized
initial price, creator, nonce, and deadline. PoolId already commits to both
currencies, native LP fee, tick spacing, and the installed hook.

Changing native fee or tick spacing changes the PoolId. Initial price is not
part of PoolId and cannot create a duplicate pool with an otherwise identical
key. Existing v4 pools cannot change their hook, native fee, or tick spacing.

## Permissionless creation gate

The general-pool creation fee remains the public-creation switch:

| Creation fee | Caller | Result |
| --- | --- | --- |
| `0` | Diamond owner/admin | Allowed with zero value |
| `0` | Any other caller | Revert |
| `> 0` | Any caller | Exact fee required |

Payment does not certify either token, liquidity quality, market price, or
creator reputation. External users may initialize other Uniswap pools, but a
pool not registered through Statics receives no Statics fee routing, creator
accounting, permanent-liquidity accounting, or protocol-pool status.

## Fee authority

Creators do not choose the Statics bilateral hook fee. Deployment initializes
the global default to 25 BPS input and 25 BPS output. The Diamond owner/admin may
change that default, set a registered PoolId override, or clear an override back
to the current default. The existing combined 200 BPS cap applies.

Fee allocation profiles remain protocol-governed. The fixed creator allocation,
POL, basket staking, global Statics staking, fallback routing, and treasury
accounting are unchanged.

The public administration and view surface is:

```solidity
function setDefaultProtocolPoolFeeRate(PoolSwapFeeRate calldata feeRate) external;
function setProtocolPoolFeeRate(PoolId poolId, PoolSwapFeeRate calldata feeRate) external;
function clearProtocolPoolFeeRate(PoolId poolId) external;
function defaultProtocolPoolFeeRate() external view returns (PoolSwapFeeRate memory);
function protocolPoolFeeRate(PoolId poolId) external view returns (PoolFeeRateView memory);
```

`PoolFeeRateView.overridden` distinguishes an explicit rate, including `0/0`,
from inheritance of the mutable global default.

## Pool identity examples

The following are distinct PoolIds:

```text
TOKEN/WETH, fee=500,  tickSpacing=10, Statics hook
TOKEN/WETH, fee=3000, tickSpacing=10, Statics hook
TOKEN/WETH, fee=3000, tickSpacing=60, Statics hook
```

Changing only the requested initial price does not create a distinct PoolId.
Creation reverts if that key is already registered or initialized.

## Consequences

- Creators can choose the native fee appropriate for each market and LP base.
- Ordinary concentrated and full-range positions earn native v4 fees without
  Statics custody or reward enrollment.
- Indexers and interfaces must display native LP fees separately from input and
  output Statics hook fees.
- Deployment no longer accepts `STATICS_NATIVE_LP_FEE_PIPS` or records a global
  canonical LP fee/tick spacing.
- Development or test deployments using the prior hook must redeploy and create
  new pools; existing PoolKeys cannot be migrated in place.

## Non-goals

- Dynamic native LP fees.
- Creator control of bilateral hook fees or fee-allocation profiles.
- Arbitrary hooks or native ETH pools.
- Token endorsement, oracle admission, or automatic Dollar/basket risk roles.
- Retrofitting creator-selected parameters into an existing immutable PoolKey.
- Changing the standalone Doppler Genesis launch architecture.
