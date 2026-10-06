# Basket bootstrap and shared v4 zap

Creators supply project-token payment inventory to isolated, fixed-term
campaigns. Suppliers sell basket underlyings for immediate project-token
payments through firm per-asset reverse Dutch auctions. They receive no LP,
refund or clawback rights. The launch positions become protocol-owned liquidity.

## Creation and funding

Deploy the periphery with `PrepareStaticsBootstrap.deployPeriphery`, supplying
the installed Diamond and a verified WETH runtime hash. The helper does not
broadcast, configure governance or enable external integrations.

Create fixed campaign terms through `BasketBootstrapFactory`. Predict its
address first: this campaign is the payer of the creator's signed creation
intent. Mine intent-owned hook nonces, then call campaign `prepare` with the
creator's EIP-712 or ERC-1271 authorization. Preview and execution share the
prepared token address, actual tick spacing, seed math, backing and fee rounding.
Changed implementation or economics commitments invalidate execution.

`fund`, `fundPayment` and `fundNative` credit explicit launch, project-token
payment and native-fee inventory. Unsolicited balances do not establish readiness.
Campaigns presently accept ordinary project tokens and ordinary constituents.
Project-token constituent backing and payment inventory remain separately
accounted even when they share the same ERC-20 address.

Anyone can activate an immutable per-asset auction when its entire rounded cap
liability is reserved. `quoteFill` and `fill` support partial fills, minimum
payments, expiry and terminal dust. Direct funding shrinks unused commitments.
All received and paid token amounts must be exact.

`finalize` requires complete funding strictly before the creator-set deadline.
It atomically creates the basket, verifies actual canonical POL ownership and
custody, and preserves creator attribution. It does not harvest external
sources or hand off fee rights. Funded but unfinalized campaigns expire too.
`claimTerminalInventory` sends settled terminal inventory to the fixed
beneficiary; successful suppliers keep their payments.

## Exact-output conversion

`StaticsAssetZap.mintBasket` and `purchaseCampaign` share typed Uniswap v4
conversion. Supply explicit currency paths and PoolKeys, per-route limits and
an aggregate input maximum. Native ETH is wrapped using configured WETH.
There is no arbitrary router calldata or PONS/Mosh conversion fallback.

Basket minting quotes requirements at execution, checks user bounds, and mints
directly to the receiver. Campaign purchasing delivers selected underlyings
and pays project tokens directly to the receiver. Conversion, bounds or
settlement failure reverts the complete transaction. Caller-attributable input
leftovers return to the caller; existing balances cannot fund another user.
Restricted BasketTokens are not accepted as raw wallet input; registered v4
routes may acquire restricted constituents or internally net restricted hops.

## Realized revenue

`MeasuredCampaignRevenue` binds once to a creator-approved campaign and exact
constituent. Explicit realized ERC-20 receipts fund the live campaign, then
route to its fixed beneficiary after success or expiry. It does not count
future fees, transfer share principal, or harvest an external protocol.

PONS and Mosh-specific harvesting/share adapters are not enabled. Supporting
them requires verified source and pinned execution evidence for each supported
generation, including share-transfer boundaries and terminal fee checkpoints.
Harvest time is not an acceptable proxy for accrual ownership.
