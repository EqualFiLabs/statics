# Statics Value Proposition

Statics is an onchain market-creation, liquidity, credit, stable-asset, and
revenue-sharing protocol. It lets projects turn token inventory and treasury
capital into functioning financial markets, while letting users retain
exposure to assets, earn from their activity, and access liquidity without
giving up that earning position.

Statics is designed so a creator can begin with modest liquidity and build
permanent market depth from use. A project might initially place an illustrative
$2,000 into each BasketToken/constituent pool rather than funding institutional
depth on day one. The Statics hook directs a governed portion of every charged
swap-fee leg into protocol-owned liquidity and also redirects unavailable LP or
staking allocations there. When both sides are available, the hook compounds
that inventory into permanent full-range liquidity. The project cannot withdraw
this POL, but its market benefits from the depth it creates. Growth requires
actual trading and balanced fee inventory; seed liquidity is a starting point,
not a promise of future depth.

Shared constituents make this more powerful than isolated liquidity mining. A
basket containing a project token and USDG creates canonical paths from its
BasketToken into both assets. Every other basket using USDG connects to that
same settlement asset. WETH can serve the same role. As baskets accumulate,
searchers can route through multiple BasketToken/USDG, BasketToken/WETH, and
BasketToken/project-token pools, external venues, ordinary mint and redemption,
and basket-vector flash loans. Each launch expands a multi-pool, multi-asset
arbitrage graph rather than creating only one disconnected pair.

## The complete system

- The standalone Genesis release creates the fixed STATICS supply, a 5,555-NFT
  collection with a mechanical 180,000-STATICS redemption floor plus a
  post-epoch 1/5,555 share of a permanent native ETH reserve, and a
  permanent STATICS/WETH market before the full protocol is ready. Trading
  fees fund treasury operations and permanent liquidity rather than requiring
  treasury token sales.
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
  treasury. Protocol-owned liquidity has no ordinary withdrawal path while the
  pool is active, so activity can build enduring market infrastructure instead
  of temporary rented liquidity.
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
  Dollar legs, and voluntarily custodied canonical LP NFTs. Position metadata
  remains deliberately plain so artwork is associated with the scarce Genesis
  collection rather than scalable financial accounts.

## Participant value

For asset creators and launchpads, Statics turns token inventory and treasury
capital into a redeemable product, canonical liquidity, arbitrage routes,
staking, and credit. The basket-creation charge is a predictable service fee,
while the resulting market can continue producing activity after launch. A
modest bootstrap can grow into deeper permanent liquidity, and choosing common
constituents connects the new basket to existing Statics markets and external
liquidity through shared arbitrage routes.

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
