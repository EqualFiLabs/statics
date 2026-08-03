# Statics Value Proposition

Statics is an onchain market-creation, liquidity, credit, stable-asset, and
revenue-sharing protocol. It lets projects turn token inventory and treasury
capital into functioning financial markets, while letting users retain
exposure to assets, earn from their activity, and access liquidity without
giving up that earning position.

## The complete system

- Projects launch isolated, fixed-composition baskets containing
  creator-selected assets, such as a launch token and USDG. A predictable
  creation fee gives Statics a listing-like front-door revenue model, except
  the project receives functioning financial infrastructure rather than only
  discovery.
- Every basket creates a permit-enabled, redeemable BasketToken and one
  canonical BasketToken/constituent market per asset. Differences between the
  basket's fixed redemption bundle, canonical pool prices, and external markets
  create opportunities for ordinary and flash-loan arbitrage.
- Users deposit BasketTokens into PositionNFTs and earn routed activity fees in
  both BasketTokens and underlying constituents. BasketTokens held outside a
  deposited position remain transferable but do not earn this allocation.
- Deposited BasketTokens become self-backed collateral. Users borrow the
  represented constituents while the locked BasketTokens continue earning
  basket rewards.
- Users can recursively borrow, mint more BasketTokens, deposit again, and
  repeat. LTV below 100%, origination fees, mint fees, available liquidity,
  independent loan maturities, and permissionless recovery bound the loop.
- On the final borrowing leg, a user can mint BasketTokens, pair them with the
  remaining borrowed constituents, and stake the resulting full-range canonical
  LP positions. Earlier deposited collateral continues earning basket rewards
  while the terminal LP can add a separate canonical-LP reward stream after
  next-block activation.
- Canonical Uniswap v4 pools provide public liquidity and standard routing
  surfaces. The Statics hook charges configurable fees on realized input and
  output, compounds permanent protocol-owned liquidity, and routes revenue
  among eligible LPs, deposited BasketTokens, eligible STATICS stakers, and
  treasury.
- Statics Dollar adds a stable monetary layer. Pegged profiles provide direct
  collateral wrappers. Volatile profiles issue senior `USDstx` and junior
  `ethLEV` Risk Shares; the junior claim absorbs first loss and can supply exit
  liquidity. Isolated profiles, series rollover, insurance, health latches, and
  recovery protect the senior system without merging every collateral type
  into one risk pool.
- STATICS staking gives PositionNFTs opt-in exposure to selected fee assets
  generated across the protocol. Stakers receive the actual collected tokens
  through independent per-asset indexes rather than requiring every reward to
  be converted into a common payout asset.
- PositionNFTs are transferable protocol accounts. One position can control
  STATICS stake, basket collateral, reward claims, independent loans, Statics
  Dollar legs, and voluntarily custodied canonical LP NFTs. Its deterministic
  onchain avatar provides stable visual identity without presenting balances,
  achievements, yield, debt, or health as cosmetic traits.

## Participant value

For asset creators and launchpads, Statics turns token inventory and treasury
capital into a redeemable product, canonical liquidity, arbitrage routes,
staking, and credit. The basket-creation charge is a predictable service fee,
while the resulting market can continue producing activity after launch.

For users, Statics makes holding productive without requiring them to abandon
their underlying exposure to access liquidity. A user can deposit a basket,
earn its routed activity fees, borrow its constituents, recursively acquire
additional basket exposure, and finish by supplying canonical liquidity.

For arbitrageurs and market makers, immutable bundle definitions and ordinary
mint and redemption create explicit conversion paths between BasketTokens,
their constituents, canonical pools, and external venues. Statics supplies
typed flash liquidity and a narrow mint-and-sell receiver without granting a
fee exemption or arbitrary execution authority.

For Statics Dollar users, the protocol separates a transferable senior dollar
from collateral-specific risk. Pegged collateral supplies direct backing;
volatile collateral uses series-specific junior Risk Shares, insurance, and
recovery rather than hiding every profile inside one shared solvency book.

For the protocol, each new market can generate upfront revenue and recurring
activity. Revenue can fund treasury, permanent liquidity, canonical LPs,
deposited BasketTokens, and STATICS stakers according to the applicable governed
route.

## Business model

The business model has two layers:

1. Upfront service revenue from basket creation, PositionNFT creation, and
   other origination events.
2. Recurring revenue from basket minting and redemption, lending, loan
   extension and recovery, flash loans, Statics Dollar activity, and canonical
   pool swaps.

The basket-creation fee can play a role similar to a paid token listing while
delivering a larger product. A creator is paying to establish a backed asset,
conversion paths, canonical liquidity, reward rails, and credit—not merely to
appear in a directory. Governance configures the fee in the network's native
asset; any dollar comparison is an economic target rather than an onchain
dollar peg.

No reward is automatic or guaranteed. A launched basket is immediately usable,
but earnings require routed activity, externally funded incentives, or both.
Creators choose assets permissionlessly when creation is enabled, and users
remain responsible for evaluating constituent behavior and basket reputation.

## Economic flywheel

```text
More asset launches
    -> more baskets and canonical liquidity
    -> more trading and arbitrage
    -> more minting, lending, and fee revenue
    -> more participant rewards and protocol-owned liquidity
    -> stronger markets and incentives
    -> more launches and capital
```

## Summary

> **Statics turns arbitrary assets and project treasury inventory into
> isolated, redeemable financial markets with liquidity, arbitrage, fee
> earning, self-backed credit, recursive capital efficiency, stable-dollar
> issuance, and protocol-wide revenue sharing—all coordinated through
> transferable PositionNFT accounts.**

For creators, Statics is a way to make a token financially useful. For users,
it is a way to hold exposure, earn from activity, and access liquidity
simultaneously. For market makers and arbitrageurs, it creates predictable
venues and conversion paths. For the protocol, it combines listing-like launch
revenue with recurring revenue from continuing economic activity.
