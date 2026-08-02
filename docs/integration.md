# Statics integration guide

## Address model

Most applications need:

- `StaticsDiamond`, the PositionNFT, basket, global-reward, canonical-liquidity,
  and ordinary Statics Dollar gateway address;
- `StaticsDollarCoreDiamond` for advanced Dollar state and direct operations;
- `StaticsDollar` and `StaticsDollarRiskShares`;
- WETH and the configured Dollar oracle;
- the configured global staking token;
- one `StaticsBasketToken` address per discovered basket; and
- the installed `StaticsSwapFeeHook` and `StaticsLiquidityManager` when using
  canonical Uniswap v4 pools.

Do not configure a separate user router, periphery, or PositionNFT address.

## Canonical ABIs

Use compiled ABIs from these sources:

| Surface | Canonical source | Main use |
| --- | --- | --- |
| Static baskets | `src/interfaces/IStaticsBasket.sol` | Create, quote, mint, redeem, and discover |
| Basket collateral | `src/interfaces/IStaticsBasketCollateral.sol` | Deposit, mint, withdraw, redeem, and inspect PositionNFT collateral |
| Basket rewards | `src/interfaces/IStaticsBasketRewards.sol` | Inspect and claim BasketToken and constituent rewards |
| Global rewards | `src/interfaces/IStaticsGlobalRewards.sol` | Stake, select reward assets, claim, distribute treasury fees, and inspect asset books |
| Basket lending | `src/interfaces/IStaticsLending.sol` | Quote, borrow, repay, extend, recover, and inspect loans |
| Canonical liquidity | `src/interfaces/IStaticsBasketLiquidity.sol` | Pool lifecycle, fee configuration, and ExitOnly unwind |
| Borrow-to-liquidity | `src/interfaces/IStaticsBorrowLiquidity.sol` | Atomic ordinary borrow, mint, and external or PositionNFT-owned v4 positions |
| Flash loans | `src/interfaces/IStaticsFlashLoan.sol` | Quote and execute constituent-vector flash loans |
| Flash receiver | `src/interfaces/IStaticsFlashBorrower.sol` | Required callback interface and return hash |
| PositionNFT | `src/interfaces/IStaticsPosition.sol` plus OpenZeppelin `IERC721` | Create, transfer, approve, inspect, and close positions |
| Basket lifecycle | `src/interfaces/IStaticsGovernance.sol` | Read pauses and status; governance lifecycle operations |
| Custody | `src/interfaces/IStaticsCustody.sol` | Inspect global and account reservation coverage |
| Dollar gateway | `src/dollar/interfaces/IStaticsDollarGateway.sol` | ETH/WETH series operations and pegged wrappers |
| Dollar rewards | `src/dollar/interfaces/IStaticsDollarRiskSeriesRewards.sol` | Donate, preview, and claim series rewards |
| Dollar Core | `src/dollar/core/interfaces/IStaticsDollarCore.sol` | Direct issuance, recombination, health, and recovery |
| Statics Dollar | `src/dollar/interfaces/IStaticsDollar.sol` | ERC-20 transfers, allowances, and EIP-2612 permit |

Pairing-vault and advanced Dollar position functions are exposed by the live
facet ABIs under `src/dollar/periphery/facets`. The TypeScript package in
`sdk/` provides common quote helpers and calldata builders. Onchain quotes
remain authoritative.

`IStaticsSwapFeeHook` exposes hook fee configuration, observations, pending
permanent-liquidity inventory, and locked liquidity. The installed manager is
used for typed user PositionManager NFT creation; canonical permanent liquidity
is hook-owned and has no protocol PositionManager token ID.

## Basket creation and discovery

Read `creationFee()` immediately before `createBasket`. A zero value means
public creation is closed: only the Diamond owner may create a genesis basket,
and that call must send zero native value. A positive value opens creation to
all callers that send the exact amount. Public clients should disable the
creation transaction when the value is zero unless the connected account is
the Diamond owner.

A basket has one to sixteen unique ERC-20 assets, nonzero bundle amounts,
independent flat mint and redemption fee tiers, percentage flash, origination,
and extension fees, LTV at or below 9,500 BPS, a recovery penalty, and a loan
duration. The creator-selected penalty must fit inside collateral at the
selected LTV:

```text
ltvBps + ceil(ltvBps * recoveryPenaltyBps / 10_000) <= 10_000
```

Index `BasketCreated`, `BasketConfigured`, and `BasketFeeTiersConfigured`, then
reconcile with `basketCount`, `basket`, `basketIdOf`, and `basketStatus`.
Creator identity is discovery metadata, not administration.

Each flat tier is `(minActionShares, feeShares)`. The protocol scans the whole
array and selects the greatest qualifying threshold; a later duplicate wins.
Arrays may be empty, unordered, or contain duplicate thresholds. `feeShares`
is converted through each constituent's static bundle and is not a percentage
of the requested action.

## Wallet mint and redemption

1. Call `quoteMint(basketId, shares)` and approve each constituent for at least
   its quoted amount.
2. Call `mint` with aligned `maxAmountsIn`. The protocol measures actual
   receipts and requires enough backing and fee for every asset.
3. Call `quoteRedeem`, then `redeem` with aligned `minAmountsOut`. The minimums
   apply to the receiver's observed increases.
4. No constituent approval is needed for redemption; the Diamond burns the
   caller's BasketTokens through the token's protocol authority.

Mint and redemption fees route into global Statics-staker rewards. Holding
BasketTokens in a wallet does not itself earn rewards.

## Basket collateral and global staking

Basket collateral and global staking are separate PositionNFT legs.

To deposit held BasketTokens, approve the Diamond and use
`createAndDepositBasketCollateral` or `depositBasketCollateral`. To source
constituents and mint directly into collateral, use
`createAndMintBasketCollateral` or `mintBasketCollateral`. Unlocked collateral
returns through `withdrawBasketCollateral`; `redeemBasketCollateral` burns
unlocked collateral and returns constituents. A new deposit cannot withdraw in
its deposit block.

Deposited BasketTokens enter an isolated per-basket reward index. The reward
assets are the BasketToken and every basket constituent; no opt-in loop is
required because each basket has at most sixteen assets. Read
`getBasketRewardAssets`, `getBasketRewards`, and `basketRewardState`, then call
`claimBasketRewards`. Locked collateral remains eligible while borrowed.
Withdrawn or recovered shares settle first and stop earning.

To earn global Statics-staker fees, approve the configured `stakingToken()` and
use `createAndStake(amount,
receiver, rewardAssets)` or `stake(positionId, amount)`. A position selects at
most 64 reward assets, while the protocol supports any number globally. Use
`optInRewardAssets` and `optOutRewardAssets` to change the selection. A new
selection and every top-up enter a pending tranche that matures at the next
hourly boundary at least 24 hours later. Existing mature stake remains eligible
and all stake remains withdrawable. Withdrawals consume pending stake first. A
full unstake clears selections but preserves settled claims.

Read `stakePosition`, `positionRewardAssets`, `rewardSelection`, `rewardAsset`,
and `pendingRewards`, then call `claimRewards` with aligned assets and
per-asset minimum outputs. `rewardSelection` reports the exact `eligibleAt`
timestamp and pending/eligible split. Fee accrual or the next position action
rolls due maturity buckets; no separate activation transaction is required.
Position-specific views and actions require ERC-721 ownership or approval.
Anyone may call `distributeTreasuryFees(asset)`, but funds always go to the
configured treasury.

Before accepting a PositionNFT transfer, inspect global stake and claims,
basket collateral and locked shares, loan tranches, and Dollar legs.
`closePosition` succeeds only after every attached protocol leg is empty.

## Basket lending and looping

Only BasketTokens deposited in a PositionNFT can be locked. Call
`quoteBorrow(basketId, sharesIn)`, then `borrow(positionId, basketId, sharesIn,
receiver)`. The quote returns origination fee shares, locked collateral shares,
debt shares, recovery-penalty shares, assets, and proportional principals.

The loan belongs to the PositionNFT. Each borrow creates an independent
tranche with its own maturity. The origination fee reclassifies its represented
backing into the global Statics-staker fee ledger. Locked collateral keeps
earning basket rewards.

`repay(loanId)` pulls the stored principal vector and unlocks only that tranche.
`quoteExtension` returns fees derived from stored principal. `extend` accepts a
gross input vector; every measured receipt must meet its quote and the complete
receipt routes through global Statics-staker fees. Extension changes neither
principal nor collateral. `recover` is permissionless after maturity plus one
hour and removes only the expired tranche.

Recovery burns only `debtShares + penaltyShares` and unlocks the remaining
collateral to the PositionNFT. It never seizes a fixed percentage of unused
collateral. The represented backing above written-off principal is the
recovery penalty: 20% goes to the recovery caller and 80% enters the ordinary
protocol fee route. Call `quoteRecovery(loanId)` for the exact recoverable
time, burned and unlocked shares, and per-asset caller and protocol amounts.

At 95% LTV, an ideal zero-fee recursive sequence converges below 20 times
initial deposited shares and 19 times initial debt. External looping helpers
must impose depth, approval, quote-freshness, and slippage limits. Statics has
no arbitrary execution surface.

## Canonical pools and permanent liquidity

There is one canonical hooked pool per basket constituent. Read
`canonicalPool(basketId, asset)` for its PoolId, currencies, hook, zero native
LP fee, tick spacing 10, lifecycle times, and observation state. Status moves
from `Unconfigured` to `Warming` to `Active`.

Pool initialization and activation are timelock-only. Activation requires a
one-hour warm-up, enough observations for a 30-minute reference, and spot
deviation at or below 100 BPS. `checkpointCanonicalPool` and
`syncCanonicalPoolToManager` are permissionless.

Display input and output hook fees separately from native v4 LP fees:

```text
native v4 LP fee: 0
launch input hook fee:  25 BPS on the realized input leg
launch output hook fee: 25 BPS on the realized output leg
launch split: 40% permanent liquidity / 10% eligible canonical LPs /
              20% deposited BasketTokens / 20% global Statics stakers /
              10% treasury
```

Governance may update the bilateral rates and split; their combined rate is
capped at 200 BPS. Hook fees apply to every canonical swap without caller,
router, flash-receiver, or LP-owner exemption. Treasury receives split dust.
If a pool has no activated staked liquidity, its LP share redirects to
permanent liquidity. If the basket or Statics reward route cannot accrue its
asset, that share independently redirects to permanent liquidity.

The global seven-field configuration is the default for pools without an
override. Timelocked governance calls
`setCanonicalPoolFeeConfiguration(basketId, asset, configuration)` with
pool-specific input/output rates capped at 200 combined BPS and
POL/canonical-LP/basket-staker/Statics-staker/treasury shares totaling 10,000
BPS. The Diamond derives
the registered PoolId and does not accept arbitrary IDs. A mature pool may set
both POL and canonical LPs to zero explicitly. `canonicalPoolFeeConfiguration`
returns the complete effective configuration and an `overridden` flag, while
`clearCanonicalPoolFeeConfiguration` restores the latest global rates and
split. Configuration changes do not touch existing pending or locked POL. A
zero-POL pool still compounds previously accumulated two-sided inventory, and
unavailable canonical-LP, basket-staker, or Statics-staker amounts still fall
through to POL. There is no automatic graduation policy.

The hook transfers both staker shares and treasury shares immediately to the
Diamond and
matches its permanent-liquidity shares into hook-owned full-range liquidity.
Unmatched inventory is visible through `pendingPermanentLiquidity`; deployed
liquidity is visible through `lockedLiquidity`. Swaps attempt compounding
atomically, and `compoundPermanentLiquidity` is also permissionless.

There is no primary-fee POL reserve, epoch, ramp, minimum compound size, hook
settlement call, or protocol PositionManager NFT. Do not use the standalone
manager's legacy protocol-position reads as a live Diamond accounting surface.

When a basket is `ExitOnly`, anyone may call `unwindBasketLiquidity` once per
constituent. It decommissions the pool, releases hook liquidity, burns returned
BasketTokens, and routes released value to global treasury accrual. User-owned
PositionManager liquidity is never decreased or burned by unwind. NFTs in
voluntary Diamond custody remain immediately withdrawable by their PositionNFT
owners.

## Canonical LP NFT rewards

Approve an unsubscribed, full-range canonical PositionManager NFT to
`StaticsDiamond`, then call `stakeLiquidityPosition(positionId, tokenId)`.
The LP NFT owner must also own the PositionNFT. The Diamond takes custody and
records the live liquidity as pending until the next block; anyone may then
call `activateLiquidityPosition(tokenId)`.

Activated liquidity receives the pool's LP share in both pool currencies.
`claimLiquidityRewards` is pull based and applies independent minimum outputs.
`unstakeLiquidityPosition` is available immediately, under pause, and in every
basket lifecycle state. It crystallizes rewards before returning the NFT, so
claims remain available through the PositionNFT even after exit.

Use `increaseStakedLiquidity` with an exact liquidity delta, currency caps,
deadline, and refund receiver to add liquidity without leaving custody. The
existing activated amount keeps earning while only the added delta waits until
the next block. To decrease, collect, or burn, first unstake and use the normal
PositionManager surface. Staking requires PositionManager approval; increases
also require bounded currency approvals to the Diamond.

## Optional borrow-to-liquidity flow

`borrowAndProvideLiquidity(positionId, basketId, sharesIn, pools, lpRecipient)`
is optional; ordinary `borrow` remains available. The combined call requires
one active, manager-synced canonical pool per constituent with no duplicates.
Each entry supplies an aligned tick range, exact liquidity, per-currency
maximums, and a deadline.

The call uses ordinary lending and mint fees, spends only the current call's
retained principal, and sends one PositionManager NFT per constituent directly
to `lpRecipient`. All unused input is refunded there. Any invalid pool, stale
price, cap, range, deadline, or principal requirement reverts the entire flow.

Discover positions from `BorrowedLiquidityPositionMinted`,
`BorrowedLiquidityProvided`, manager `UserPositionMinted`, and ordinary
PositionManager `Transfer` events. They remain external until explicitly
staked; borrowing through this function provides no reward privilege. Once
staked, custody and claims follow the selected PositionNFT while repayment,
extension, and recovery remain independent.

`borrowAndStakeLiquidity(positionId, basketId, sharesIn, pools)` is the
PositionNFT-owned alternative. It requires full-range pool entries and mints
each v4 NFT directly to the Diamond, recording it as pending LP weight under
the same PositionNFT. The current PositionNFT owner receives every unused
principal and PositionManager refund even if an approved operator submits the
call. Anyone may activate the NFT in the next block. The original deposited
BasketTokens remain basket-reward eligible, so the position can earn both
basket rewards and canonical LP rewards. Any failure in borrowing, minting,
pool validation, NFT custody, or reward registration reverts the entire call.

## Flash loans and arbitrage routing

`quoteFlashLoan` returns principal and quoted fees for the basket's complete
constituent vector. A receiver implements
`IStaticsFlashBorrower.onStaticsFlashLoan`, approves requested repayment during
the callback, and returns the documented callback hash.

The callback may call ordinary `mint` and `redeem`. Those paths retain all fees,
approvals, minimums, and lifecycle checks. Nested flash loans remain blocked.
Disbursement must debit the Diamond and credit the receiver by exactly the
quoted principal; outbound-tax and sender-extra-tax tokens are incompatible.

Repayment requests principal plus quoted fee but credits a measured balance
delta. Success requires at least principal; actual fee equals measured receipt
minus principal and enters the global non-swap fee ledger. Callback failure,
an invalid hash, a receiver minimum-profit revert, or insufficient principal
reverts all protocol and external-pool changes atomically.

An overpriced route can borrow constituents, mint, sell BasketTokens across
canonical pools, repay every asset, and retain per-asset profit. An underpriced
route can borrow a constituent, buy discounted BasketTokens, redeem, repay, and
retain underlying profit. Both routes must account for basket fees, flash fees,
rounding, price impact, and both hook fee legs before enforcing minimum profit.

Statics provides no production receiver, router, allowlist, callback privilege,
or fee exemption. Use purpose-built typed receivers with exact approval scope,
verified pool keys, slippage bounds, repayment checks, and minimum-profit
enforcement. Cancun/EIP-1153 is required. See
`docs/adr/composable-flash-loan-callbacks.md`.

## Statics Dollar authorization

`StaticsDollar` implements EIP-2612 with name `Statics Dollar`, version `1`,
the current chain ID, and token address. A permit authorizes only an allowance;
it does not bind a series, receiver, output asset, or minimum.

Use `recombineToWETHWithPermit`, `recombineToETHWithPermit`,
`redeemPeggedWithPermit`, or `mintPeggedAndRecombineWithPermit` for an exact
token authorization and exit. The atomic mint-and-recombine variant permits the
pegged collateral token rather than Statics Dollar. `mintPeggedWithPermit`
likewise requires the configured collateral token to implement EIP-2612.
Matching Risk Shares remain ERC-1155 tokens and require
`setApprovalForAll(StaticsDiamond, true)`.

Permit submission is permissionless. The gateway tolerates a pre-submitted
valid permit and still requires allowance-backed `transferFrom`. It checks exit
availability before permit execution; later failure rolls the permit back with
the transaction.

## Statics Dollar gateway

For volatile WETH profiles, use `depositETH` or `depositWETH` to mint Statics
Dollar and current-series Risk Shares to independently selected receivers. Use
`recombineToWETH` or `recombineToETH` to burn matching claims and exit when the
health state permits. Respect maximum-share and minimum-output parameters.

For pegged profiles, `previewPeggedMint`, `mintPegged`, and
`mintPeggedWithPermit` pull nominal collateral plus the independent mint fee.
`previewPeggedRedemption`, `redeemPegged`, and `redeemPeggedWithPermit` burn
Statics Dollar and return proportional collateral less the redemption fee.
Pegged profiles create no Risk Shares or series reward denominator. Their fees
route through global rewards; inspect `treasuryAccrued` and global reward views,
not removed per-profile protocol-revenue getters.

### Atomic pegged mint-and-recombine exit

A holder of active volatile-series Risk Shares can source the matching senior
claim from any valid pegged profile and recombine both claims atomically:

1. Call `quoteMintPeggedAndRecombine(peggedProfileId, volatileProfileId,
   seriesId, riskAmount)` and require `eligible == true` and `exitStatus ==
   Available`.
2. Approve the quoted `totalPeggedCollateralIn` to `StaticsDiamond` and grant
   that address ERC-1155 operator approval for Risk Shares.
3. Call `mintPeggedAndRecombine` with `maximumPeggedCollateralIn`,
   `minimumVolatileCollateralOut`, and the intended receiver.

The quote also returns the pegged principal and fee, exact Statics Dollar amount,
volatile output and fee, and both collateral-token addresses. Refresh it before
submission because profile fees, oracle state, and series health may change.
Once a recorded recovery delay has matured, the quote reports the execution
that will clear that latch as available without requiring a separate checkpoint.

No Statics Dollar approval is needed: the gateway mints the exact senior amount
directly to the Diamond and immediately burns it with the caller's Risk Shares
through ordinary Core recombination. The selected series must be `Active` and
belong to `volatileProfileId`; recoverable and retired series are not routed
through this operation. The execution functions return `(status,
peggedCollateralIn, volatileCollateralOut)`. An unavailable execution returns
its non-`Available` status with zero amounts before permit or custody, emits
`PeggedMintAndRecombineDeferred`, and preserves the global impairment checkpoint
and recovery delay. Output slippage is checked against the receiver's observed
volatile-token balance increase.

`mintPeggedAndRecombineWithPermit` authorizes only the exact pegged collateral
input through that token's EIP-2612 permit. It still requires ERC-1155 operator
approval. A pre-submitted permit is tolerated when the caller already has
sufficient allowance, matching the gateway's other permit variants.

Advanced integrations may call Core directly. Ordinary Core and gateway
recombination use the same economics. `recombineManaged` is reserved for the
configured Diamond's pairing and recovery machinery.

Dollar Risk Shares use the overloaded Dollar staking functions
`createAndStake(seriesId, amount, receiver)` and `stake(positionId, seriesId,
amount)`. This is distinct from global ERC-20 staking. Passive eligibility
starts after `activateLeg` following its 24-hour gate. `optIn` supplies pairing
liquidity. Pairing redemption uses the explicit `PairingVaultFacet.redeem` or
`redeemToETH` path and may partially fill against available opt-in liquidity.

## Custody checks

Use `globalReservedByToken` and `reservedByAccount` with
`dollarCustodyAccount`, `feeCustodyAccount`, `stakingCustodyAccount`, and each
`basketCustodyAccount(basketId)`. For every token:

```text
global reserved
  = dollar + fees + staking + sum(basket accounts)
physical Diamond balance >= global reserved
```

Direct donations are unreserved. Core collateral and hook permanent liquidity
live at separate physical addresses and are not part of this Diamond equation.

## Event index

Index these event families, then reconcile with current views:

- baskets: `BasketCreated`, `BasketConfigured`, `BasketFeeTiersConfigured`,
  `BasketMinted`, and `BasketRedeemed`;
- collateral: `BasketCollateralDeposited`, `BasketCollateralWithdrawn`, and
  `BasketCollateralRedeemed`;
- global rewards: `StakingPositionCreated`, `Staked`, `Unstaked`,
  `RewardStakeScheduled`, `RewardBucketMatured`,
  `PositionRewardEligibilityActivated`, `GlobalFeeAccrued`,
  `PositionRewardSettled`, `RewardClaimed`, `TreasuryFeesDistributed`,
  `RewardAssetOptedIn`, `RewardAssetOptedOut`, and `RewardAssetDustRouted`;
- lending and flash: `LoanOriginated`, `LoanRepaid`, `LoanExtensionFeePaid`,
  `LoanExtended`, `LoanRecovered`, and `BasketFlashLoan`;
- canonical lifecycle: `LiquidityIntegrationInstalled`,
  `CanonicalPoolInitialized`, `CanonicalPoolCheckpointed`,
  `CanonicalPoolActivated`, `CanonicalPoolSyncedToManager`,
  `SwapFeeConfigurationChanged`, and `BasketLiquidityUnwound`;
- hook: `SwapLegFeeAccrued`, `PermanentLiquidityAdded`,
  `PermanentLiquidityFeesCollected`, `PermanentLiquidityReleased`,
  `PoolDecommissioned`, and `TickObservationRecorded`;
- user v4 positions: `BorrowedLiquidityPositionMinted`,
  `BorrowedLiquidityProvided`, manager `UserPositionMinted`, and PositionManager
  `Transfer`;
- lifecycle: `BasketQuarantined`, `BasketQuarantineReleased`,
  `BasketDecommissioned`, `ActionsPaused`, and `ActionsUnpaused`;
- shared positions: ERC-721 `Transfer` and `Approval`, `PositionCreated`, and
  `PositionClosed`; and
- Dollar gateway and routing: `ETHDeposited`, `WETHDeposited`,
  `RecombinedToWETH`, `RecombinedToETH`, `RecombinationDeferred`,
  `PeggedMintedThroughGateway`, `PeggedMintedAndRecombined`,
  `PeggedMintAndRecombineDeferred`, `PeggedRedeemedThroughGateway`,
  `PeggedRedemptionDeferred`, `PoolFeeIndexed`, and `PeggedProfileFeeRouted`.

Events are discovery and history records, not substitutes for onchain state.
Reconcile after reorgs and immediately before value-moving actions.
