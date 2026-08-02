# Statics integration guide

## Address model

Most applications need these addresses:

- `StaticsDiamond`: all PositionNFT, basket, and ordinary Statics Dollar user
  actions;
- `StaticsDollarCoreDiamond`: direct advanced Dollar operations and backend
  state;
- `StaticsDollar`: transferable, permit-enabled senior ERC-20;
- `StaticsDollarRiskShares`: series-specific ERC-1155 risk shares;
- WETH and the configured Dollar oracle; and
- one `StaticsBasketToken` ERC-20 address per discovered basket.

`StaticsDiamond` is also the PositionNFT ERC-721 address and the Dollar gateway
address. Do not configure a separate router, periphery, or PositionNFT address.

## Canonical ABIs

Use the compiled ABIs for the following source interfaces and facets:

| Surface | Canonical source | Main use |
| --- | --- | --- |
| Static baskets | `src/interfaces/IStaticsBasket.sol` | Create, quote, mint, redeem, and discover baskets |
| Basket rewards | `src/interfaces/IStaticsBasketRewards.sol` | Deposit, mint to a position, withdraw, redeem, and claim |
| Basket lending | `src/interfaces/IStaticsLending.sol` | Quote, borrow, repay, extend, recover, and inspect loans |
| Canonical basket liquidity | `src/interfaces/IStaticsBasketLiquidity.sol` | Pool lifecycle, hook settlement, POL, LP fees, and unwind |
| Borrow-to-liquidity | `src/interfaces/IStaticsBorrowLiquidity.sol` | Atomic ordinary borrow, mint, and user-owned v4 positions |
| Basket flash loans | `src/interfaces/IStaticsFlashLoan.sol` | Quote and execute constituent-vector flash loans |
| PositionNFT | `src/interfaces/IStaticsPosition.sol` plus OpenZeppelin `IERC721` | Create, transfer, approve, inspect, and close positions |
| Basket lifecycle | `src/interfaces/IStaticsGovernance.sol` | Read pauses and status; governance lifecycle operations |
| Custody views | `src/interfaces/IStaticsCustody.sol` | Inspect global and module reservation coverage |
| Dollar gateway | `src/dollar/interfaces/IStaticsDollarGateway.sol` | ETH/WETH series operations and pegged wrappers |
| Dollar rewards | `src/dollar/interfaces/IStaticsDollarRiskSeriesRewards.sol` | Donate, preview, and claim series rewards |
| Dollar Core | `src/dollar/core/interfaces/IStaticsDollarCore.sol` | Direct issuance, recombination, health, and recovery |
| Statics Dollar token | `src/dollar/interfaces/IStaticsDollar.sol` | ERC-20 transfers, allowances, and EIP-2612 permit |

Pairing-vault and advanced Dollar position functions are exposed by the live
facet ABIs under `src/dollar/periphery/facets`. The TypeScript package in
`sdk/` provides quote helpers and calldata builders for the common unified
flows. Integrations should still read onchain quotes immediately before sending
transactions.

The standalone read surfaces are `IStaticsSwapFeeHook` and
`IStaticsLiquidityManager`. Use them only for hook liabilities, oracle
observations, immutable bindings, manager inventory, and protocol
PositionManager token IDs. User and maintenance actions still go through
`StaticsDiamond`.

## Basket creation and discovery

Read `creationFee()` from `IStaticsBasketAdmin` immediately before creation and
send that exact native amount with `createBasket`. A definition contains one to
sixteen unique assets, nonzero bundle amounts, independent mint and redemption
fee tiers, flash/origination/extension fees, LTV at or below 9,500 basis points,
and loan duration.

Index `BasketCreated`, `BasketConfigured`, and `BasketFeeTiersConfigured`; use
`basketCount`, `basket`, `basketIdOf`, and `basketStatus` to reconcile indexed
state. The protocol records creator identity for discovery and reputation but
does not grant creator administration over the basket.

Each fee tier is `(minActionShares, feeShares)`. The applicable flat fee is the
entry with the greatest threshold not exceeding the requested action size.
`feeShares` is converted through each constituent's static bundle amount; it is
not a percentage of the action.

## Wallet mint and redemption

1. Call `quoteMint(basketId, shares)` and approve every constituent for at least
   the quoted amount.
2. Call `mint` with per-asset `maxAmountsIn`. The returned values are observed
   inbound amounts, which can differ for non-standard tokens.
3. For redemption, approve no constituent: the Diamond burns BasketTokens from
   the caller directly through its protocol authority.
4. Call `quoteRedeem`, then `redeem` with per-asset `minAmountsOut`. Minimums
   apply to the receiver's observed balance increase.

Wallet-held BasketTokens do not earn indexed fees. They remain ordinary
18-decimal OpenZeppelin ERC-20 Permit tokens and can be transferred or placed in
external liquidity venues.

## Position rewards

Use `createAndMintBasket` to source constituents and atomically create a
PositionNFT, or use `mintBasketToPosition` for an existing position. To deposit
already-held BasketTokens, approve the Diamond and call
`createAndDepositBasket` or `depositBasket`.

New principal checkpoints after its entry fee accrues, so it cannot claim its
own mint fee or historical fees. Deposited shares cannot withdraw in their
deposit block. Query `pendingBasketRewards` and claim with per-asset minimums
through `claimBasketRewards`. Claims transfer constituents without burning or
reducing BasketToken principal.

`withdrawBasket` returns unlocked BasketTokens. `redeemBasketFromPosition`
settles the position, removes principal before accruing the exit fee, burns the
shares in custody, and transfers the net constituents. Locked shares cannot be
withdrawn or redeemed.

ERC-721 ownership and approvals authorize every attached leg. Before accepting
a PositionNFT transfer, inspect its Dollar legs, basket positions, claims,
locked shares, and loan tranches. `closePosition` succeeds only after all legs
and claims are empty.

## Basket lending and looping

Only BasketTokens already deposited in a PositionNFT can be borrowed against.
Call `quoteBorrow(basketId, sharesIn)`, then
`borrow(positionId, basketId, sharesIn, receiver)`. The quote returns the
origination fee shares, locked collateral shares, constituent addresses, and
proportional principal after the basket's configured LTV.

The loan belongs to the PositionNFT rather than the transaction sender.
Transferring the NFT transfers the obligation. Each borrow creates an
independent tranche with its own maturity. Locked collateral stays in the
basket reward denominator.

Repayment pulls the exact principal vector from the payer and unlocks only that
tranche. `quoteExtension(loanId)` returns the constituent addresses and a fee
vector calculated from the tranche's stored outstanding principals. Pass a
gross input vector to `extend(loanId, grossAmountsIn)`. The position owner or
approved operator may gross up an input for a taxed token; every measured
receipt must satisfy its quote and the complete receipt becomes isolated basket
protocol revenue. Extension does not acquire or burn BasketTokens or change
principal, backing, collateral shares, or reward eligibility. `recover` is
permissionless after maturity plus one hour and removes only the expired
tranche.

At 95% LTV, an ideal zero-fee recursive mint/deposit/borrow sequence converges
below 20 times initial deposited shares and 19 times initial debt. A looping
router must impose its own depth, approval, quote-freshness, and slippage limits;
the protocol exposes no arbitrary execution surface.

## Canonical pools and protocol-owned liquidity

There is one canonical hooked pool per basket constituent. Read
`canonicalPool(basketId, asset)` for its PoolId, ordered currencies, immutable
hook, 500-pip LP fee, tick spacing, lifecycle timestamps, spot/reference ticks,
and reference availability. The status sequence is `Unconfigured`, `Warming`,
then `Active`. Initialization and checkpointing are permissionless; activation
requires the one-hour warm-up, enough 30-minute observations, and the fixed
deviation bound.

Display the effective fees as two separate charges:

```text
ordinary v4 LP fee: 500 pips = 5 basis points, paid to active LPs
Statics hook fee:   1 basis point, paid as terminal basket revenue
```

The hook fee rounds nonzero charges up and applies to every canonical swap,
regardless of router, caller, swap direction, protocol affiliation, or LP
owner. Unhooked pools are not canonical and cannot be made to pay this fee.

Index `BasketFeesAccrued` to observe atomic holder/POL/revenue classification.
Read `liquidityReserve` and `cumulativePrimaryFees` per basket and constituent.
`compoundBasketLiquidity` is permissionless when every constituent pool is
active and its 24-hour epoch is ready. `basketLiquidityState` and
`liquidityEpochParameters` expose the epoch, cumulative minted shares,
seven-day 10% young-pool cap, and `1e12` minimum.

Protocol position IDs and idle inventory are read from the installed manager's
`protocolPositionId` and `protocolInventory`. `cumulativeLiquidityFunding`
reports measured Diamond-to-manager constituent movement. Pending LP fees are
not a Diamond balance: derive them from the protocol token ID, PositionManager
position metadata, and StateView fee growth. The SDK's `pendingLpFees` mirrors
v4 Q128 rounding. Collected totals come from `cumulativeProtocolLpFees`; 10% is
floor-rounded into revenue and the remainder stays as POL inventory.

Hook accrual stays at the hook until anyone calls
`settleCanonicalHookFees`. Read `pendingCanonicalHookFees`,
`cumulativeCanonicalHookSettlement`, and `cumulativeHookRevenue` separately.
Underlying receipts are reserved as terminal basket revenue. BasketToken
receipts are burned and their represented backing becomes terminal revenue.

Quarantine and liquidity pause stop exposure-increasing pool actions while
leaving settlement available. Once governance marks a basket `ExitOnly`,
`unwindBasketLiquidity` can be called once per constituent to burn the protocol
v4 position, return idle inventory, and reclassify remaining POL. Read
`basketLiquidityUnwound` per constituent to track completion.

## Optional borrow-to-liquidity flow

`borrowAndProvideLiquidity(positionId, basketId, sharesIn, pools, lpRecipient)`
is optional; ordinary `borrow` remains available with an arbitrary receiver.
The combined call requires exactly one active, manager-synced canonical pool
per constituent with no duplicates. Every typed pool entry supplies an aligned
tick range, exact liquidity, per-currency maximums, and a deadline.

The call uses the ordinary loan terms and origination-fee burn, quotes an
ordinary-fee basket mint after that burn, uses only the current call's retained
principal, and sends one PositionManager NFT per constituent directly to
`lpRecipient`. It refunds all unused principal and PositionManager input to
that recipient. Any invalid pool, stale price, amount cap, range, deadline, or
principal requirement reverts the loan, mint, and all position creation.

Discover these user positions from `BorrowedLiquidityPositionMinted`,
`BorrowedLiquidityProvided`, the manager's `UserPositionMinted`, and ordinary
PositionManager ERC-721 `Transfer` events. They never appear in
`protocolPositionId` and are not attached to the Statics PositionNFT. A later
PositionNFT transfer, repayment, extension, expiry, recovery, or basket
decommission does not move or seize them. Removing liquidity, redeeming the
BasketToken side, and repaying remain separate user actions; no combined exit
helper is implemented.

## Flash loans and arbitrage routing

`quoteFlashLoan` returns the basket's constituent vector and fees for a
BasketToken-equivalent share amount. The receiver must implement
`IStaticsFlashBorrower.onStaticsFlashLoan`, approve repayment during the
callback, and return the documented callback hash.

Only underlying tokens need external swap liquidity. A mint arbitrage sources
the constituents, mints BasketTokens, and then sells or delivers them. A
redemption arbitrage acquires BasketTokens, redeems them, and routes the
received constituents. Statics never calls user-selected routers.

## Statics Dollar authorization

`StaticsDollar` implements native EIP-2612. Its EIP-712 domain uses the token
name `Statics Dollar`, version `1`, the current chain ID, and the token address.
Read `nonces(owner)` immediately before signing. A permit signature authorizes
an allowance; by itself it does not express a series, output asset, receiver,
or minimum-output instruction.

For a one-transaction Dollar authorization and exit, use the matching permit
entrypoint: `recombineToWETHWithPermit`, `recombineToETHWithPermit`, or
`redeemPeggedWithPermit`. Each function binds the permit owner to `msg.sender`,
the spender to `StaticsDiamond`, and the value to the exact Statics Dollar
amount consumed by that call. The gateway checks exit availability before
consuming the signature. A deferred exit therefore leaves the permit nonce and
allowance untouched.

Permit submission is permissionless and can be frontrun. The gateway tolerates
a failed permit call and proceeds only when the Diamond already has sufficient
allowance, so prior submission of the same valid signature cannot brick the
exit. A freshly executed exact permit leaves zero allowance after successful
recombination; an existing larger approval is reduced by the amount consumed.
Existing `recombineToWETH` and `recombineToETH` calls remain available for
prior ERC-20 approval and for contract wallets that cannot sign EIP-2612
messages.

EIP-2612 covers only Statics Dollar. The matching series risk shares are
ERC-1155 tokens and still require `setApprovalForAll(StaticsDiamond, true)`.

## Statics Dollar gateway

For the initial WETH collateral profile:

- `depositETH` wraps native ETH and mints Statics Dollar plus the current
  series' risk shares to independently selected receivers;
- `depositWETH` pulls WETH approved to the Diamond and performs the same
  issuance;
- `recombineToWETH` pulls matching Statics Dollar and series risk shares and
  returns WETH; and
- `recombineToETH` performs the ordinary recombination and unwraps WETH.

Use the gateway's minimum-output and maximum-share arguments. A health check can
return a deferred status without completing an exit. The gateway leaves no
residual balances or approvals after successful operations.

Before approval-based recombination, approve the Diamond to spend Statics
Dollar. Alternatively, sign the exact EIP-2612 authorization and use the
matching permit recombination entrypoint. Both paths require
`setApprovalForAll(Diamond, true)` on the risk-share ERC-1155. Staking existing
risk shares requires the same ERC-1155 operator approval.

For a pegged collateral profile:

- `previewPeggedMint`, `mintPegged`, and `mintPeggedWithPermit` quote and pull
  the nominal collateral principal plus its independent mint fee, then mint
  only Statics Dollar;
- `previewPeggedRedemption`, `redeemPegged`, and
  `redeemPeggedWithPermit` burn fungible Statics Dollar and return the profile's
  proportional collateral less its redemption fee; and
- `peggedRedemptionStatus` reports whether redemption is available, impaired,
  oracle-unavailable, recovering, or blocked by a downside transition.

Approve the pegged collateral token to `StaticsDiamond` before minting and
approve Statics Dollar before redemption, or use the matching permit entrypoint
when that ERC-20 implements EIP-2612. Pegged profiles never create Risk Shares,
series books, staking legs, or reward denominators. Direct Core and Diamond
wrapper operations have identical quotes and fees. The gateway checks health
before taking redemption custody or consuming its permit and restores all
unreserved balances and Core approvals after a successful operation.

Mint and redemption fees accrue under
`peggedProtocolRevenue(profileId, collateralToken)`. The common protocol
treasury returned by `IStaticsBasketAdmin.treasury()` may call
`claimPeggedProtocolRevenue`; these balances never enter series or basket holder
reward indexes.

Advanced integrations may call `StaticsDollarCoreDiamond` directly. Ordinary
Core `recombine` and gateway recombination charge identical fees. Never call
`recombineManaged` for an ordinary user exit; it is authorized only for the
configured Diamond's pairing and recovery machinery.

Dollar risk shares can be sent into positions with `createAndStake` or `stake`.
Passive eligibility begins only after `activateLeg` succeeds following the
24-hour gate. `optIn` supplies pairing liquidity and accepts its associated
economics. Pairing redemption uses the explicit `PairingVaultFacet.redeem` or
`redeemToETH` path and can partially fill against available opt-in liquidity.

## Event index

Index these event families for user state:

- basket creation and actions: `BasketCreated`, `BasketConfigured`,
  `BasketFeeTiersConfigured`, `BasketMinted`, `BasketRedeemed`;
- basket rewards: `BasketPositionDeposited`, `BasketPositionWithdrawn`,
  `BasketPositionRedeemed`, `BasketFeesAccrued`, `BasketRewardsClaimed`;
- lending and flash loans: `LoanOriginated`, `LoanRepaid`,
  `LoanExtensionFeePaid`, `LoanExtended`, `LoanRecovered`, `BasketFlashLoan`;
- primary fee allocation: `BasketFeeAllocationChanged` and
  `BasketFeesAccrued`;
- canonical pool lifecycle: `LiquidityIntegrationInstalled`,
  `CanonicalPoolInitialized`, `CanonicalPoolCheckpointed`,
  `CanonicalPoolActivated`, and `CanonicalPoolSyncedToManager`;
- hook revenue: hook-side `SwapFeeAccrued` and `PoolFeesWithdrawn`, then
  Diamond-side `CanonicalHookFeesSettled` and
  `HookBasketTokenRevenueReclassified`;
- POL: `LiquidityManagerInstalled`, `BasketLiquidityPoolFunded`,
  `BasketLiquidityCompounded`, `ProtocolLpFeesCollected`,
  `LpBasketTokenRevenueReclassified`, and `BasketLiquidityUnwound`;
- user v4 positions: `BorrowedLiquidityPositionMinted`,
  `BorrowedLiquidityProvided`, manager `UserPositionMinted`, and ordinary
  PositionManager `Transfer`;
- lifecycle: `BasketQuarantined`, `BasketQuarantineReleased`,
  `BasketDecommissioned`, `ActionsPaused`, `ActionsUnpaused`;
- shared positions: standard ERC-721 `Transfer` and `Approval` plus
  `PositionCreated` and `PositionClosed`; and
- Dollar gateway: `ETHDeposited`, `WETHDeposited`, `RecombinedToWETH`,
  `RecombinedToETH`, `RecombinationDeferred`, `PeggedMintedThroughGateway`,
  `PeggedRedeemedThroughGateway`, `PeggedRedemptionDeferred`,
  `PeggedProfileFeeAccrued`, and `PeggedProtocolRevenueClaimed`.

Events are discovery and history records, not a substitute for current onchain
views. Reconcile indexed state after reorgs and before any value-moving action.
