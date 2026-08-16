# Statics Worked Examples

These examples explain how the Statics products fit together. Values are
illustrative, omit token-decimal rounding, and are not promises of liquidity,
profit, yield, or production configuration. Onchain quotes and current
deployment manifests remain authoritative.

## Launching a token and stablecoin basket

Assume a launchpad project has earned 2,000 USDG and also controls project-token
inventory. It defines a basket containing its token and USDG at fixed raw bundle
amounts chosen from the intended initial market ratio.

If governance targets a basket-creation charge near $300, the creator pays the
equivalent configured amount in the network's native asset. That comparison is
economic only: the contract charges an exact native amount and does not use a
dollar oracle for basket creation.

The creator supplies the quoted assets needed for ordinary-fee backing and
permanent seed liquidity. One atomic creation transaction:

1. deploys the BasketToken;
2. records its immutable constituent bundle and lending parameters;
3. initializes a BasketToken/project-token pool;
4. initializes a BasketToken/USDG pool;
5. establishes ordinary redemption backing; and
6. places creator-funded permanent full-range liquidity into both pools.

The result is more than a listing. The project now has a redeemable composite
asset, two canonical markets, mint and redemption paths, arbitrage connections,
basket rewards, self-backed lending, flash liquidity, and a route for future
third-party LPs. Nothing guarantees demand or earnings; activity must occur.

The creator can deliberately start small. For example, it might seed roughly
$2,000 of full-range liquidity in each canonical pool. That will be shallow for
large trades, but it is enough to make both markets executable and expose them
to arbitrage. Under the current launch-default split, 10% of each charged hook
fee leg enters permanent protocol-owned liquidity. Any unavailable canonical-LP,
BasketToken-staker, or STATICS-staker allocation also redirects there. As
matched BasketToken and constituent fee inventory accumulates, the hook adds it
back as permanent full-range liquidity.

The shared USDG constituent also connects this basket to every other Statics
basket and external venue using USDG. If another project launches `BASKET-B`
against USDG, searchers gain routes such as:

```text
BASKET-A -> USDG -> BASKET-B
BASKET-A -> PROJECT-A -> external venue -> USDG -> BASKET-B
flash-borrow basket A vector -> mint/redeem -> several canonical pools -> repay
```

Adding WETH as another common constituent introduces another shared settlement
route. Across many baskets, these links form a multi-pool, multi-asset arbitrage
graph. A new basket can therefore benefit from existing network liquidity and
price discovery rather than depending only on its own direct project-token
pool.

## Depositing a basket and borrowing constituents

Suppose Alice deposits 100 BasketTokens in PositionNFT 42. The basket's loan
configuration is:

```text
LTV:                    95%
Origination fee:         1%
Recovery penalty:        5% of debt shares
```

Alice asks to borrow against 20 shares:

```text
Input shares:                 20.00
Origination fee shares:        0.20
Locked collateral shares:     19.80
Debt shares at 95% LTV:        18.81
```

The fee shares are burned. Their represented constituent backing enters the
global non-swap fee route. The loan transfers the constituent vector represented
by 18.81 basket shares to Alice and records an independent maturity.

After origination, PositionNFT 42 has 99.80 deposited shares: 19.80 are locked
and 80 are unlocked. All 99.80 remaining deposited shares continue in the
basket-reward denominator. The 0.20 burned fee shares no longer earn.

Repayment requires the stored constituent principal vector and unlocks the
19.80 collateral shares. If the loan expires, permissionless recovery burns
only debt plus the configured debt-relative penalty and leaves surplus
collateral in the PositionNFT.

## Recursively increasing basket exposure

Alice can use borrowed constituents to mint more BasketTokens, deposit those
tokens into the PositionNFT, and borrow again:

```text
deposit BasketTokens
    -> borrow proportional constituents
    -> supply any required mint-fee top-ups
    -> mint additional BasketTokens
    -> deposit the new BasketTokens
    -> repeat
```

Each iteration creates a separate loan and pays a new origination fee. Each
remint pays the applicable static basket mint fee. The next borrowing base is
therefore smaller than the prior base even before operational slippage. At 95%
LTV, an ideal zero-fee geometric sequence converges below 20 times the initial
deposited shares and 19 times initial debt; real Statics loops remain lower
because fees, rounding, liquidity, and user-selected depth reduce them.

The strategy increases exposure and basket reward weight, but it also creates
multiple maturities and repayment obligations. A safe interface must show every
loan rather than presenting the loop as a single perpetual position.

## Finishing the loop with canonical liquidity

Instead of reminting and redepositing on the final leg, Alice calls
`borrowAndStakeLiquidity` with one full-range liquidity request for every basket
constituent.

The atomic call:

1. opens an ordinary fee-paying constituent loan;
2. uses part of the retained principal, plus caller-funded mint-fee top-ups, to
   mint BasketTokens;
3. pairs those BasketTokens with the remaining borrowed constituents;
4. creates one full-range v4 LP NFT per canonical pool;
5. transfers the LP NFTs directly into Diamond custody; and
6. associates their pending LP weight with the borrowing PositionNFT.

The earlier deposited BasketTokens remain basket-reward eligible while locked.
The terminal LP positions can be activated permissionlessly in the next block;
only activated liquidity enters the canonical-LP reward denominator. Alice can
therefore have two distinct activity-derived reward legs: basket rewards on
deposited collateral and LP rewards on terminal liquidity.

`borrowAndProvideLiquidity` differs intentionally. It sends the LP NFTs to a
chosen external recipient and grants no automatic Statics LP reward
eligibility. A qualifying full-range NFT can be staked separately later.

## Splitting canonical swap fees

Assume a canonical pool collects 100 units of one currency as a charged hook
fee leg under the current launch-default allocation:

```text
Permanent protocol-owned liquidity:  10
Eligible canonical LPs:               25
Deposited BasketTokens:               25
Eligible STATICS stakers:             15
Treasury:                             25
```

Each currency is accounted independently. If that pool has no eligible
canonical LP liquidity, its 25-unit LP allocation redirects to permanent
liquidity. Basket-staker and STATICS-staker allocations independently do the
same when their corresponding denominators cannot accept that asset.

The current launch-default hook rates are 50 basis points on realized input and
50 basis points on realized output. Governance may configure a complete global
or pool-specific rate and split within the protocol's bounds, so integrators
must read effective onchain configuration rather than hardcode this example.

## Earning selected assets with STATICS

Alice stakes 1,000 STATICS and selects TSLA, PLTR, AMD, WETH, and USDG. Bob
stakes 9,000 STATICS but selects only WETH and USDG.

After Alice's stake becomes eligible:

- Alice represents 100% of eligible selected STATICS stake for TSLA, PLTR, and
  AMD if nobody else selected them.
- Alice represents 10% of eligible selected STATICS stake for WETH and USDG.
- Bob does not dilute the reward assets he did not select.

If 100 TSLA enters the non-swap fee ledger while eligible TSLA stake exists,
the current global rule routes 90 TSLA to the selected-staker index and 10 TSLA
to treasury. At a 10% eligible TSLA weight, Alice would accrue 9 TSLA. If no
eligible position selected TSLA, the complete 100 TSLA would accrue to treasury
instead of becoming a historical claim for a later staker.

New stake and new selections wait until the next hourly boundary at least 24
hours later. Existing mature stake remains eligible when Alice opts into
another asset or adds stake, and all STATICS remains withdrawable during the
eligibility wait.

## Arbitraging an overpriced BasketToken

Suppose a BasketToken trades above the total executable cost of its fixed
constituent bundle.

An arbitrageur can:

1. flash-borrow the complete constituent vector;
2. supply any static-mint-fee top-ups;
3. mint BasketTokens through the ordinary public entrypoint;
4. sell a complete BasketToken allocation across canonical or external pools;
5. repay every constituent principal plus the measured flash fee; and
6. keep only the per-asset remainder above configured minimum profit.

The route must cover mint fees, both applicable hook fee legs, flash fees,
rounding, price impact, and gas. Statics' optional
`StaticsFlashArbitrageReceiver` implements only this typed mint-and-sell
direction and retains no balances or arbitrary call authority.

## Arbitraging an underpriced BasketToken

If a BasketToken trades below executable redemption value, an arbitrageur can
flash-borrow a constituent, buy discounted BasketTokens, redeem them for the
fixed constituent vector, sell or retain what is needed for repayment, and keep
only the net remainder.

Statics does not provide a generic underpriced-route executor. Searchers choose
venues, source quotes, and enforce their own deadlines and profit floors.

## Using pegged Statics Dollar collateral

In a pegged USDG profile, a user deposits the quoted USDG principal plus the
configured mint fee and receives the corresponding senior `USDstx`. The profile
creates no junior Risk Shares. Redemption burns `USDstx` and returns
proportional USDG less its configured fee when global health and the pegged-exit
quarantine permit it.

Pegged-profile fees enter the global non-swap fee ledger. A pegged profile is
not allowed to become an alternate exit around an impaired volatile profile;
ordinary pegged redemption reopens only after unresolved transitions are
settled and the configured continuous-health delay completes.

## Using a volatile Statics Dollar profile

In a WETH-backed volatile profile, collateral enters an active series and
issues equal nominal senior `USDstx` and series-specific junior `ethLEV` Risk
Shares. Matching senior and junior claims can ordinarily recombine for
collateral while health permits.

The junior claim absorbs first loss before the senior claim. Supplying
`ethLEV` to a PositionNFT makes it immediately available for pairing-vault
consumption rather than earning a passive reward merely for waiting. When a
Dollar holder exits through supplied Risk liquidity, the consumed supplier
receives the junior collateral residual plus the configured consumption fee
share. Permissionlessly funded series incentives are also released only in
proportion to actual Risk liquidity consumption.

Insurance remains economically relevant when junior value is insufficient to
keep senior claims whole. Profile and series lifecycle rules prevent a healthy
profile from silently masking another profile's impairment.

## Transferring a PositionNFT

If Alice transfers PositionNFT 42 to Bob, Bob receives control over every
attached protocol leg, including deposited and locked BasketTokens, reward
claims, outstanding loan obligations, STATICS stake, Dollar legs, and LP NFTs
voluntarily held by the Diamond. Externally held v4 LP NFTs do not transfer with
the PositionNFT.

The PositionNFT metadata identifies the account but does not visualize its
contents. Bob must inspect `positionState` and the module-specific views before
accepting the NFT; metadata is not a solvency or achievement statement.
