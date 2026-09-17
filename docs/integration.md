# Statics integration guide

## Address model

Most applications need:

- the Doppler-created STATICS token, `StaticsGenesis`, and
  `StaticsGenesisVault` for the standalone token/NFT conversion lifecycle;
- `StaticsFeeReceiver`, `GenesisActivationRegistry`, and
  `GenesisLaunchDistributor` for permanent launch-fee ingress, activation, and
  temporary Genesis rewards;
- `IStaticsGenesisIntegration` at `StaticsDiamond` only after its later-phase
  selectors are installed for permanent Genesis rewards, Position linkage, and
  recovery;
- `StaticsDiamond` as the Phase 1 PositionNFT, global-reward, general-pool, and
  protocol-revenue address, with basket and Dollar surfaces added later;
- `StaticsDollarCoreDiamond` for Phase 3 Dollar state and direct operations;
- the Phase 3 `StaticsDollar` and `StaticsDollarRiskShares` tokens;
- WETH and the configured Dollar oracle;
- the configured global staking token;
- one `StaticsBasketToken` address per discovered basket after Phase 2; and
- the installed `StaticsSwapFeeHook` for Phase 1 general pools, plus
  `StaticsLiquidityManager` only after the basket/advanced-liquidity selectors
  are installed.

Do not configure a separate user router, periphery, or PositionNFT address.

## Canonical ABIs

Use compiled ABIs from these sources:

| Surface | Canonical source | Main use |
| --- | --- | --- |
| Genesis NFT | `src/interfaces/IStaticsGenesis.sol`, `IERC5192.sol`, and `ICreatorToken.sol` | Ownership, metadata, link locks, optional transfer validation, future protocol binding, and transfer-tier reset callback |
| Genesis vault | `src/interfaces/IStaticsGenesisVault.sol` | Quote epoch/reserve pricing, buy, redeem, donate native reserve, inspect inventory, and verify dual backing |
| Genesis activation | `src/interfaces/IGenesisActivationRegistry.sol` | Permanent tiers, treasury-paid activation costs, multipliers, transfer reset, and consumer handoff |
| Genesis launch fees | `src/interfaces/IStaticsFeeReceiver.sol` and `IGenesisLaunchDistributor.sol` | Authenticated Doppler harvests, permanent WETH reserve funding, reward indexes, claims, and distributor handoff |
| Full Genesis integration | `src/interfaces/IStaticsGenesisIntegration.sol` | Register, link/unlink, inspect direct and Position weights, claim permanent rewards, and inspect recovery readiness |
| Static baskets | `src/interfaces/IStaticsBasket.sol` | Create, quote, mint, redeem, and discover |
| Basket collateral | `src/interfaces/IStaticsBasketCollateral.sol` | Deposit, mint, withdraw, redeem, and inspect PositionNFT collateral |
| Basket rewards | `src/interfaces/IStaticsBasketRewards.sol` | Inspect and claim BasketToken and constituent rewards |
| Global rewards | `src/interfaces/IStaticsGlobalRewards.sol` | Stake, select reward assets, claim, distribute treasury fees, and inspect asset books |
| Basket lending | `src/interfaces/IStaticsLending.sol` | Quote, borrow, repay, extend, recover, and inspect loans |
| Canonical liquidity | `src/interfaces/IStaticsBasketLiquidity.sol` | Pool lifecycle, fee configuration, and ExitOnly unwind |
| Borrow-to-liquidity | `src/interfaces/IStaticsBorrowLiquidity.sol` | Atomic ordinary borrow, mint, and external or PositionNFT-owned v4 positions |
| Flash loans | `src/interfaces/IStaticsFlashLoan.sol` | Quote and execute basket-vector or single-asset flash loans |
| Flash receiver | `src/interfaces/IStaticsFlashBorrower.sol` | Required callback interface and return hash |
| PositionNFT | `src/interfaces/IStaticsPosition.sol` plus OpenZeppelin `IERC721` | Create, transfer, approve, inspect metadata, and close positions |
| Basket and emergency lifecycle | `src/interfaces/IStaticsGovernance.sol` | Read action pauses, basket status, global swap stops, and PoolId quarantine; governance lifecycle operations |
| Custody | `src/interfaces/IStaticsCustody.sol` | Inspect global and account reservation coverage |
| Dollar gateway | `src/dollar/interfaces/IStaticsDollarGateway.sol` | ETH/WETH series operations and pegged wrappers |
| Dollar Risk liquidity | `src/dollar/interfaces/IStaticsDollarRiskLiquidity.sol` | Stake consumable Risk Shares, inspect liquidity, withdraw unconsumed shares, and claim fill proceeds |
| Dollar Risk Shares | `src/dollar/interfaces/IStaticsDollarRiskShares.sol` | ERC-1155 balances, approvals, transfer-freeze state, and Core-only mint, burn, and freeze calls |
| Dollar series migration | `src/dollar/interfaces/IStaticsDollarSeriesMigration.sol` | Aggregate transition processing, PositionNFT settlement, and migration state |
| Dollar Core | `src/dollar/core/interfaces/IStaticsDollarCore.sol` | Direct issuance, recombination, health, and recovery |
| Statics Dollar | `src/dollar/interfaces/IStaticsDollar.sol` | ERC-20 transfers, allowances, and EIP-2612 permit |
| Morpho integration | `src/interfaces/IStaticsMorpho.sol` | Market configuration, tracked collateral, borrowing, repayment, synchronization, and account recovery |

All 5,555 Genesis NFTs exist from deployment. Integrators call
`quoteGenesisPurchase()` immediately before acquiring a selected vault-owned
token, approve the returned 180,000-STATICS price, and send at least the
returned `requiredNative` with payable `buyGenesis(tokenId, receiver)`. During
the immutable Genesis Epoch `requiredNative` is the native acquisition fee and
the reserve buy-in is waived. After the epoch `requiredNative` is the reserve
buy-in `ceil(reserveETH / 5,554)` plus that fee. The fee always enters the
reserve, and the post-epoch buy-in joins it. The native `value` is a maximum:
any excess is refunded on-chain, and insufficient native reverts atomically.
`quoteGenesisRedemption()` reports the fixed 180,000-STATICS payout and, after
the epoch, the additional `floor(reserveETH / 5,555)` native reserve payout;
`redeemGenesis(tokenId, receiver)` returns both. `donate()` permissionlessly and
irreversibly capitalizes the reserve. A redeemed token becomes ordinary vault inventory
and may be purchased again.

Native acquisition fees are not withdrawable revenue. Each fee increases
accounted `reserveETH` in both epoch states; after the Genesis Epoch, each reserve
buy-in does too. Integrators must use `reserveETH`, not the vault's raw native
balance, for reserve NAV because forced or accidental ETH does not enter protocol
accounting. No governance, treasury, or recipient claim function can withdraw the
accounted reserve.

`getTransferValidator() == address(0)` means ordinary unrestricted ERC-721
transfers. If governance later configures a validator, marketplaces must satisfy
that policy; the vault has no bypass. After the full protocol is bound,
`locked(tokenId)` reflects its Genesis-to-Position registry. A locked Genesis
must be unlinked before either an ordinary transfer or vault redemption.
The collection uses two ERC-2309 consecutive construction batches: IDs 1..5,000
begin in the Genesis Vault, while treasury-reserve IDs 5,001..5,555 begin in the
immutable treasury vesting contract. It therefore does not emit 5,555
individual initial `Unlocked` events; integrators should read
`locked(tokenId)`. The treasury IDs release in ascending order under the same
60-day linear schedule as the treasury STATICS principal. Later link-state
changes emit the standard ERC-5192 `Locked` or `Unlocked` event.

Pairing-vault and advanced Dollar position functions are exposed by the live
facet ABIs under `src/dollar/periphery/facets`. The TypeScript package in
`sdk/` provides common quote helpers and calldata builders. Onchain quotes
remain authoritative.

The staged Phase 1 deployment installs only arbitrary Statics-hooked pools,
their revenue/POL paths, PositionNFT, and global STATICS staking/reward opt-ins.
Phase 2 adds baskets, credit, flash composition, and advanced liquidity; Phase
3 adds Dollar; Phase 4 adds Morpho. The cumulative selector counts are 106,
202, 260, and 287. Integrators must feature-detect complete ERC-165 interfaces
and individual selector routes instead of assuming that a live Diamond exposes
a later phase.

`IStaticsSwapFeeHook` exposes hook fee configuration, pending
permanent-liquidity inventory, and locked liquidity. Phase 1 relies on ordinary
Uniswap v4 periphery for user LP positions and does not install a Statics
liquidity manager. Canonical permanent liquidity is hook-owned and has no
protocol PositionManager token ID.

The standalone STATICS/WETH market is the Doppler pool recorded by the launch
manifest. Applications should use Doppler/Uniswap v4 quoting and routing for
swaps. Registered Genesis rewards are indexed only after the permanent receiver
collects its authenticated 95% beneficiary share from the standard Doppler
initializer; raw receiver balances are not protocol revenue.

After `genesisIntegrationReady()` becomes true, an actual Genesis owner may
call `registerGenesis(genesisId)` once for the permanent reward interval.
Registration does not require Position linkage and follows the token across
later transfers. On an owner-changing transfer, already attributed rewards
settle to `genesisOwnerClaimable(previousOwner, asset)`, activation resets to
Tier 0, and future direct weight follows the new owner. Use
`claimGenesisRewards` for rewards still attached to a held token and
`claimGenesisOwnerRewards` for crystallized prior-owner credits.
`claimAllGenesisRewards` accepts the caller's currently owned Genesis IDs and
claims both categories across STATICS and WETH in one transaction. It may be
called with an empty ID list to claim only prior-owner credits. Every claim
path lazily harvests before settlement while its distributor is active.

`linkGenesis(positionId, genesisId)` requires the same actual owner for both
NFTs; approvals do not authorize linking or unlinking. While linked,
`locked()` is true for both NFTs and owner-changing transfer is prohibited.
The activation multiplier applies only to global STATICS reward weight. It
does not change raw stake, withdrawable principal, collateral, external LP fees, or
direct Genesis rewards. Recovery clears the link and boost but preserves the
PositionNFT, raw stake, pending maturity, claims, and unrelated legs.

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

Creation also launches one canonical pool for every constituent. Supply
aligned `PoolLaunchParams[]` and `maxAmountsIn[]` arrays in basket-asset order,
plus a `launchDeadline` after which the complete transaction must revert:

- `sqrtPriceAssetPerBasketX96` is always the semantic square-root price of raw
  constituent units per raw BasketToken unit, independent of token decimals
  and Uniswap currency ordering. Use
  `encodeSqrtPriceAssetPerBasketX96(assetAmountRaw, basketAmountRaw)` from the
  SDK instead of applying decimal normalization;
- `pairedAssetAmount` is the creator-funded constituent budget for that pool;
- `maxAmountsIn[i]` caps the creator's measured aggregate constituent debit:
  paired liquidity plus the backing and ordinary mint fee for the aggregate
  BasketTokens seeded across every pool; and
- `launchDeadline` bounds how long the signed price and input limits remain
  executable.

The single `createBasket` transaction deploys the permit-enabled BasketToken,
registers and initializes all PoolKeys, registers them with the installed
manager, mints fully backed BasketTokens through the ordinary fee path, and
locks full-range hook-owned liquidity in every pool. Any failure rolls back the
fee transfer, token deployment, pool initialization, backing, and custody.
There is no separate pool-initialization or manager-sync transaction.
Canonical v4 launch requires exact-transfer-compatible constituents: a taxed
or otherwise nonstandard constituent that changes the requested PoolManager
settlement amount causes the complete creation transaction to revert.

The owner uses this same calldata and funding flow for a zero-fee genesis
basket; there is no privileged bootstrap path. A successfully launched pool is
immediately swappable and available to the typed liquidity paths.

Index `BasketCreated`, `BasketConfigured`, `BasketFeeTiersConfigured`,
`CanonicalPoolInitialized`, `CanonicalPoolSyncedToManager`,
`PermanentLiquiditySeeded`, and `BasketLaunched`, then reconcile with
`basketCount`, `basket`, `basketIdOf`, `basketStatus`, `canonicalPool`, and
hook `lockedLiquidity`. Creator identity is discovery metadata, not
administration.

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
unlocked collateral and returns constituents. Unlocked, undeployed shares have
no separate deposit-block withdrawal gate; loan-locked or Morpho-deployed
shares must first be unlocked or recalled.

Deposited BasketTokens enter a pending tranche for an isolated per-basket
reward index and mature at the next hourly boundary at least 24 hours later.
Top-ups retain weighted pending age, and withdrawals consume pending shares
before eligible shares. The reward assets are the BasketToken and every basket
constituent; no opt-in loop is required because each basket has at most sixteen
assets. Read
`getBasketRewardAssets`, `getBasketRewards`, and `basketRewardState`, then call
`claimBasketRewards`. Locked collateral remains eligible while borrowed.
Withdrawn or recovered shares settle first and stop earning.

To earn global Statics-staker fees, approve the configured `stakingToken()` and
use `createAndStake(amount,
receiver, rewardAssets)` or `stake(positionId, amount)`. A position initially
selects up to 12 reward assets, while the protocol supports any number globally.
Read `maxRewardAssetsPerPosition()` for the current active limit and
`hardMaxRewardAssetsPerPosition()` for the immutable ceiling of 64; do not
hard-code either value in clients. Use `optInRewardAssets` and
`optOutRewardAssets` to change the selection. A new selection and every top-up
enter a pending tranche that matures at the next hourly boundary at least 24
hours later. Existing mature stake remains eligible and undeployed stake has no
cooldown. Stake supplied to Morpho must first be recalled. Withdrawals consume
pending stake first. A full unstake clears selections but preserves settled
claims.

Timelock governance may only raise the active selection limit. Index
`MaxRewardAssetsPerPositionIncreased` and refresh client-side capacity when it
appears.

Read `stakePosition`, `positionRewardAssets`, `rewardSelection`, `rewardAsset`,
and `pendingRewards`, then call `claimRewards` with aligned assets and
per-asset minimum outputs. `rewardSelection` reports the exact `eligibleAt`,
raw pending/eligible stake, and pending/eligible effective weight.
`stakePosition` reports the current `rewardMultiplierBps`; `totalStaked()`
remains raw principal. Fee accrual or the next position action
rolls due maturity buckets; no separate activation transaction is required.
Position-specific views and actions require ERC-721 ownership or approval.
Anyone may call `distributeTreasuryFees(asset)`, but funds always go to the
configured treasury.

Before accepting a PositionNFT transfer, call `positionState(positionId)` and
inspect protocol-specific economics for each discovered Leg. The standardized
state reports the structural nonce, active-Leg count, and unresolved live-loan
count; it does not report valuation or solvency. `isPositionClosable` is true
only for an existing, fully initialized Position with both counts at zero and
no collateral or debt in any historically tracked Morpho market. Structural
membership is available through `isLegActive`; events
`PositionLegAttached`, `PositionLegDetached`, and `PositionStateChanged` support
indexer reconstruction. Position identity is `(chain ID, StaticsDiamond,
positionId)`, with no separate Position Key getter.

Raw tokens and collateral deposited directly into a registered Morpho market
that the Position never tracked are not enumerable close blockers. When an
already deployed Morpho account's Position closes, its actual final owner keeps
permanent authority only for `recoverMorphoAccountToken` and
`withdrawUntrackedMorphoCollateral`; prior NFT approvals and all borrowing or
collateral-deployment authority end at burn. Transfers to a predicted but
undeployed account remain unsupported. Do not use a PNFT Morpho account as the
`onBehalf` lender for loan-token supply: Morpho `supplyShares` are not checked by
the Statics close predicate and cannot be withdrawn through Statics in this
release. Native assets and NFTs sent to that account are likewise unsupported
and unrecoverable through the current interface.

`tokenURI(positionId)` returns fully onchain Base64 JSON with a Base64 SVG
showing the Statics logo and `POSITION #<positionId>`. The stable image contains
no balance, achievement, yield, debt, health, risk, ownership, or live position
state. Generative onchain SVG identity remains reserved for
`StaticsGenesis.tokenURI`.

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

## Protocol pools and permanent liquidity

There is one canonical hooked pool per basket constituent. Read
`canonicalPool(basketId, asset)` for its PoolId, currencies, hook, configured
native LP fee, creator-selected tick spacing, and current spot tick.

The Diamond also supports permissionless **general pools** between two
compatible ERC-20 assets with no basket association. Read
`protocolPool(poolId)` to resolve either class (`BasketCanonical` or
`General`) and `isProtocolPool(poolId)` for a bounded registration check.
`protocolPoolCreator(poolId)` returns the immutable creator. Index
`CanonicalPoolInitialized` and `ProtocolPoolCreated` for discovery; the
Diamond deliberately provides no unbounded pool array.

The `ProtocolPoolCreated` event carries the creator, sorted currencies, native
LP fee, tick spacing, normalized initial price, and initial tick. Indexers
reconstruct and rank markets from `ProtocolPoolCreated`,
`CanonicalPoolInitialized`, `ProtocolPoolFeeRateSet`, `PoolCreationFeeSet`,
`PoolCreationNonceInvalidated`, creator credit and claim events,
`GeneralPoolDecommissioned`, hook permanent-liquidity and fee events, and
PoolManager state. A first-party frontend may
maintain curated token lists and hide spam without changing contract-level
permissionlessness.

Pool initialization and permanent seeding are inseparable from basket creation.
The creator supplies every starting price and paired-asset budget. A successful
creation makes every canonical pool immediately swappable and available to the
typed liquidity paths; no post-launch activation transaction is required.

Display input and output hook fees separately from native v4 LP fees:

```text
native v4 LP fee: creator selected per pool (static, 0 through 999,999 pips)
default input hook fee:  25 BPS on the realized input leg
default output hook fee: 25 BPS on the realized output leg
launch split: 15% permanent liquidity / 30% deposited BasketTokens /
              30% global Statics stakers /
              5% creator (fixed) / 20% treasury
```

Governance may update the global bilateral default, set or clear PoolId-specific
overrides, and update the configurable allocation shares. The combined
input/output rate is capped at 200 BPS and the
configurable shares always total 9,500 BPS beside the fixed 500-BPS creator
share. Hook fees apply to every canonical swap without caller,
router, flash-receiver, or LP-owner exemption. Treasury receives split dust.
If the basket reward route cannot accrue its asset, that
share redirects to permanent liquidity. If the global Statics reward route
cannot accrue its asset, that share redirects to treasury.

Anyone may create a general pool with
`createPool(params, creatorAuthorization)` once permissionless creation is
enabled. Call `quotePool(params)` first to derive the sorted PoolKey, PoolId,
normalized sorted price, exact `creationFee`, and EIP-712
`authorizationDigest`. The creator supplies two token addresses, a static
`lpFee` from 0 through 999,999 pips, a valid `tickSpacing` from 1 through
32,767, the initial price as `sqrtPriceBPerAX96` in raw-unit B-per-A
orientation, the creator identity, an unordered `nonce`, and a `deadline`.
Statics sorts the currencies and always installs the mandatory Statics hook.
Dynamic-fee pools and the 1,000,000-pip boundary are rejected.

General-pool creation is separate from liquidity provision. A successful
`createPool` establishes the PoolId, price, native LP fee, tick spacing,
creator, hook-fee policy inheritance, hook registration, and protocol
registration; it does not require an
initial permanent-liquidity seed and the market may begin with zero liquidity.
Basket canonical launch retains its own mandatory creator-funded seed.

The `poolCreationFeeAmount` is independent from the basket and PositionNFT
creation fees and doubles as the permissionless-creation switch. When it is
zero, only the Diamond owner may create a pool and `msg.value` must be zero;
when it is nonzero, every caller — including the owner — must pay the exact
amount, which is forwarded atomically to treasury. Read it through
`poolCreationFee()` and configure it independently at deployment via
`POOL_CREATION_FEE_AMOUNT`.

Creator attribution uses EIP-712 authorization under the domain
`name = "Statics Protocol Pools"`, `version = "2"`, the current `chainId`, and
`verifyingContract = StaticsDiamond`. `SignatureChecker` validates both EOA and
ERC-1271 creators. The signed digest binds the PoolId, normalized price,
creator, nonce, and deadline. Because PoolId commits to the currencies, native
LP fee, tick spacing, and hook, those parameters cannot be changed by a relayer.
Three paths apply:
when the creation fee is nonzero, a direct creator (`creator == msg.sender`) may
pass empty authorization and consumes no nonce; while creation is disabled the
Diamond owner may designate any nonzero creator without a signature; otherwise
the named creator must supply a valid authorization and its unordered nonce is
consumed. Relayed authorizations
deliberately do not bind `msg.sender`, so a copied transaction may pay the fee
and initialize the pool first but can never replace the creator or change the
PoolId or price. Cancel an unused authorization with
`invalidatePoolCreationNonce(nonce)` and check state through
`isPoolCreationNonceUsed(creator, nonce)`.

Distinct native LP fees or tick spacings for the same pair produce distinct
PoolIds and independent markets. An initial-price change alone does not create
a new PoolId, so a second creation with the same currencies, native LP fee,
tick spacing, and Statics hook reverts as a duplicate.

Hook-fee **rate** and fee **allocation** are separate policy dimensions.
Creators do not select the hook fee. New basket and general pools inherit the
live global default, initially 25 BPS input plus 25 BPS output. Timelocked
governance may update it with `setDefaultProtocolPoolFeeRate(feeRate)`, affecting
every non-overridden pool immediately. It may set an exception with
`setProtocolPoolFeeRate(poolId, feeRate)` and restore inheritance with
`clearProtocolPoolFeeRate(poolId)`. Every rate satisfies
`inputFeeBps + outputFeeBps <= 200`. Read the global rate through
`defaultProtocolPoolFeeRate()` and the effective rate plus `overridden` flag
through `protocolPoolFeeRate(poolId)`.

Fee allocation is governed by two global profiles rather than per-pool
configuration. The creator share is permanently fixed at 500 BPS and is not
part of any governance-mutable structure. Governance configures the remaining
9,500 BPS through `setBasketFeeAllocation(allocation)` and
`setGeneralFeeAllocation(allocation)`, readable through `basketFeeAllocation()`
and `generalFeeAllocation()`. Each stored configurable profile must total
exactly 9,500 BPS so that the profile plus the fixed 500-BPS creator share sums
to 10,000 BPS. The initial launch-default profiles are:

```text
                        basket pool    general pool
permanent liquidity     1,500 BPS      4,000 BPS
basket stakers           3,000 BPS      0 BPS
global Statics stakers   3,000 BPS      3,500 BPS
creator, fixed             500 BPS        500 BPS
treasury                 2,000 BPS      2,000 BPS
total                   10,000 BPS     10,000 BPS
```

General pools have no basket-staker share; the profile encodes this explicitly
rather than relying on a runtime fallback. Changing a global allocation profile
affects only subsequent accrual and never rewrites accrued creator credits,
basket rewards, Statics-staker rewards, treasury revenue, or POL
inventory. Changing a PoolId's fee rate does not change the applicable
allocation profile, and vice versa.

Creator revenue equals exactly 500 BPS of the collected Statics bilateral fee
in both pool currencies. It is pull-based: swap execution never calls the
creator. Claim it with
`claimCreatorRevenue(asset, receiver, minReceived)` and read pending amounts
through the creator-credit views. Creator credits never expire, cannot be
confiscated by governance, and survive decommissioning.

The hook records bilateral fees as PoolManager ERC-6909 claims. At the next
routing boundary, non-POL claims move into the Diamond's basket-staker,
Statics-staker, creator, and treasury ledgers. Matching POL claims are burned
atomically to fund hook-owned full-range liquidity on swaps. Unmatched
inventory is visible through `pendingPermanentLiquidity`; deployed liquidity
is visible through `lockedLiquidity`; aggregate claim coverage is visible
through `claimLiability`. There is no public manual compounding entry point.

Native fees earned by the hook-owned position are treasury revenue rather than
POL. Automatic POL compounding necessarily modifies the permanent position and
can realize native fees during a swap. A configured
`permanentLiquidityHarvester()` may additionally call
`harvestPermanentLiquidityFees(poolId)` to realize fees while compounding is
idle or one-sided; the call has no recipient argument. The Diamond books every
realized token to treasury accounting. Governance may replace the harvester,
the guardian may pause explicit harvesting and treasury distribution, and only
governance may unpause them. Delaying explicit harvesting does not block swaps,
user liquidity, or automatic POL compounding.

Native PoolManager donations to a protocol pool always revert in
`beforeDonate`. Integrators must not use Uniswap donation routers with Statics
pools. Protocol seeding and swap-fee allocation are the supported sources of
pending POL.

There is no primary-fee POL reserve, epoch, ramp, minimum compound size, hook
settlement call, protocol PositionManager NFT, or manager-owned protocol
inventory. The standalone manager resolves exact PoolKeys from the Diamond's
protocol-pool registry and executes transaction-scoped PositionManager NFT
mint operations.

Only a general pool may use `decommissionGeneralPool(poolId)`, an owner-only
terminal transition. The creator cannot decommission a pool. The call stops
later swaps and managed LP actions, sends permanent-liquidity principal and
unmatched POL to treasury accounting, preserves ordinary fee allocations, and
leaves all user PositionManager NFTs untouched. Existing creator credits
remain claimable. Decommissioning is irreversible for that PoolKey; a
replacement market requires a different supported PoolKey, which generally
means a different tick spacing. Basket canonical pools retain their separate
`ExitOnly` unwind and are never processed with general-pool decommission
accounting.

When a basket is `ExitOnly`, anyone may call `unwindBasketLiquidity` once per
constituent. It decommissions the pool, releases hook liquidity, burns returned
BasketTokens, and routes released value to global treasury accrual. User-owned
PositionManager liquidity is never decreased or burned by unwind.

## Native LP fees

User-owned full-range or concentrated PositionManager NFTs earn the configured
native v4 LP fee through standard Uniswap accounting. Statics does not custody
these NFTs or expose LP reward activation, claim, increase, or unstake methods.
Native fees earned by the hook-owned permanent position are collected after
swaps and routed only to treasury; they never enter pending POL or compounding.

## Optional borrow-to-liquidity flow

`borrowAndProvideLiquidity(positionId, basketId, sharesIn, pools, lpRecipient)`
is optional; ordinary `borrow` remains available. The combined call requires
one active registered canonical pool per constituent with no duplicates.
Each entry supplies an aligned tick range, exact liquidity, per-currency
maximums, and a deadline.

The call uses ordinary lending and mint fees, spends only the current call's
retained principal, and sends one PositionManager NFT per constituent directly
to `lpRecipient`. All unused input is refunded there. Any invalid pool, stale
price, cap, range, deadline, or principal requirement reverts the entire flow.

Discover positions from `BorrowedLiquidityPositionMinted`,
`BorrowedLiquidityProvided`, manager `UserPositionMinted`, and ordinary
PositionManager `Transfer` events. They remain owned by `lpRecipient` and are
independent of PositionNFT transfer, repayment, extension, recovery, and pool
decommissioning.

## Flash loans and arbitrage routing

Statics exposes two typed flash-loan modes backed by the Diamond's physical
ERC-20 balances. Flash principal does not debit basket vaults or custody
reservations. Each requested amount must fit within its starting physical
balance. Successful repayment must preserve the Diamond's starting unreserved
balance, cover the reservations that exist after callback composition, and add
the quoted fee.

`quoteFlashLoan` returns principal and basket-specific fees for the basket's
complete constituent vector. The basket defines the vector, but does not limit
the physical liquidity source to its own vault. A receiver implements
`IStaticsFlashBorrower.onStaticsFlashLoan`, approves exact principal plus fees,
and returns `keccak256("IStaticsFlashBorrower.onStaticsFlashLoan")`.

`maxFlashLoan(asset)` returns the Diamond's full raw ERC-20 balance, including
balances represented by custody reservations. `quoteFlashLoanAsset` applies
the protocol-wide `singleAssetFlashFeeBps` with ceiling rounding.
`flashLoanAsset` invokes
`IStaticsFlashAssetBorrower.onStaticsFlashLoanAsset` and requires the distinct
`keccak256("IStaticsFlashAssetBorrower.onStaticsFlashLoanAsset")` success value.
It does not use a basket ID. Governance may update the single-asset fee through
the Diamond timelock.

The callback may call ordinary `mint` and `redeem`. Those paths retain all fees,
approvals, minimums, and lifecycle checks. Nested flash loans remain blocked.
Disbursement must debit the Diamond and credit the receiver by exactly the
quoted principal; outbound-tax and sender-extra-tax tokens are incompatible.

Repayment collects exact principal plus quoted fee using measured sender and
receiver deltas. Only that newly earned fee enters custody and the global
non-swap reward/treasury ledger. Callback failure, an invalid hash, a receiver
minimum-profit revert, an inexact token transfer, or insufficient repayment
reverts all protocol and external-pool changes atomically.

An overpriced route can borrow constituents, mint, sell BasketTokens across
canonical pools, repay every asset, and retain per-asset profit. An underpriced
route can borrow the complete constituent vector, use selected constituents to
buy discounted BasketTokens across their canonical pools, redeem the acquired
BasketTokens, repay every asset, and retain per-asset profit. Both routes must
account for basket fees, flash fees, rounding, price impact, and both hook fee
legs before enforcing minimum profit.

Statics ships the optional, narrowly typed
`StaticsFlashArbitrageReceiver` with two entrypoints:

- `executeMintAndSell` accepts a complete BasketToken allocation across the
  basket's canonical pools and pulls only the constituent top-ups required by
  the static mint fee.
- `executeBuyAndRedeem` accepts one exact constituent-input cap per canonical
  pool. Each nonzero input must fit within that asset's flash principal. The
  receiver redeems only the BasketTokens acquired by those swaps; it cannot use
  a caller top-up or a pre-existing BasketToken balance to complete the route.

Both entrypoints require a deadline and a net minimum profit for every
constituent. They use ordinary fee-paying basket entrypoints, settle swaps
directly with the configured v4 PoolManager, approve exact flash repayment,
return profits to the caller, preserve pre-existing balances, and retain no
route balances.

The receiver is permissionless but is not a generic router: it has no owner,
allowlist, arbitrary target-and-calldata execution, callback privilege, or fee
exemption. It does not route through external venues or search for profitable
allocations. Searchers remain responsible for fresh executable quotes, gas,
allocation selection, and minimums. Cancun/EIP-1153 is required.
Basket-to-basket, asset-to-asset, and cross-mode nested flash loans are all
blocked.
See `docs/adr/composable-flash-loan-callbacks.md`.

## Statics Dollar authorization

`StaticsDollar` implements EIP-2612 with name `Statics Dollar`, version `1`,
the current chain ID, and token address. A permit authorizes only an allowance;
it does not bind a series, receiver, output asset, or minimum.

Use `recombineToWETHWithPermit`, `recombineToETHWithPermit`,
`redeemPeggedWithPermit`, or `mintPeggedAndRecombineWithPermit` for an atomic
token authorization and exit. The permit payload carries the signed allowance
value independently from the amount consumed by the operation, so integrations
may authorize either the exact input or a reusable allowance. The atomic
mint-and-recombine variant permits the pegged collateral token rather than
Statics Dollar. `mintPeggedWithPermit` likewise requires the configured
collateral token to implement EIP-2612.
Matching Risk Shares remain ERC-1155 tokens and require
`setApprovalForAll(StaticsDiamond, true)` for gateway transfers. Successful
transition finalization freezes ordinary transfers for the predecessor's
recoverable series ID. The freeze also prevents gateway entrypoints from
pulling that expired ID, but a holder may still recombine directly through Core
because Core burns from that holder without an ERC-1155 transfer. The matching
Core recovery path can instead burn predecessor claims and mint successor
claims. A series retired directly with its profile remains unfrozen,
transferable, and ordinary-recombinable via Core (and the gateway for profile
1) during runoff.

Core binds to the freeze-capable `STATICS_DOLLAR_RISK_V1` token kind. Use the
canonical launcher to deploy the Risk Shares token, Core, and `StaticsDiamond`
as one coordinated stack. A separately deployed, unbound Genesis contract may
still perform its documented one-shot binding after the stack is handed off.

`topUpInsurance` accepts profiles that are not permanently retired. Volatile
top-ups credit profile-level reserve, including during `ReduceOnly`; pegged
top-ups immediately increase proportional redemption collateral. Permanent
volatile reserve is contingent transition capital, not present solvency backing,
and cannot authorize new issuance until assigned. Retirement atomically routes
pending periphery insurance into Core before deciding its disposition. Reserve
joins the current live paired series only when that series is the profile's sole
senior generation. If historical senior claims remain or no current paired claim
exists, the non-claimant reserve enters global non-swap rewards instead; fixed
historical recovery books never gain later reserve. An empty pegged profile
routes terminal surplus globally. Retirement does not wait for claims or reserve consumption. Later
volatile fees enter global rewards directly, and post-retirement top-ups revert.

Permit submission is permissionless. The gateway tolerates a pre-submitted
valid permit and still requires allowance-backed `transferFrom`. It checks exit
availability before permit execution; later failure rolls the permit back with
the transaction.

## Statics Dollar gateway

For volatile WETH profiles, use `depositETH` or `depositWETH` to mint Statics
Dollar and current-series Risk Shares to independently selected receivers. Use
`recombineToWETH` or `recombineToETH` to burn matching claims and exit when the
health state permits and the series ID remains transferable. After transition
finalization, the gateway cannot pull the frozen predecessor ID. A holder may
still use direct Core recombination for runoff, or Core recovery for successor
rollover. Respect maximum-share and minimum-output parameters.

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

`mintPeggedAndRecombineWithPermit` authorizes the signed pegged-collateral
allowance through that token's EIP-2612 permit and consumes only the quoted
input. It still requires ERC-1155 operator approval. A pre-submitted permit is
tolerated when the caller already has sufficient allowance, matching the
gateway's other permit variants.

Advanced integrations may call Core directly. Ordinary Core and gateway
recombination use the same economics. `recombineManaged` is reserved for the
configured Diamond's pairing and recovery machinery.

`createAndStakeRiskShares` and `stakeRiskShares` place Dollar Risk Shares into
immediately consumable pairing liquidity owned by a PositionNFT. There is no
passive tier, activation call, cooldown, or standing Risk reward. Pairing uses
`redeem` or `redeemToETH` and may fill partially against available liquidity.
Each fill proportionally consumes every supplier, credits the junior collateral
residual plus 80% of the pairing fee, and routes the remaining 20% to insurance.
`unstakeRiskShares` returns only unconsumed shares; `claimRiskProceeds` settles
fill proceeds, funded incentives, and series-recovery credits. The claim returns
separate collateral, Statics Dollar, and STATICS amounts even when two roles
resolve to the same physical token; the Diamond aggregates coincident-token
transfers internally.

When full consumption closes an epoch, the final stored leg settled from that
epoch receives every raw-token unit not already crystallized by the index;
settlement order therefore selects the terminal-residue recipient. Every index
tracks funded and crystallized amounts so terminal settlement is exact.

`fundRiskCollateralIncentives`, `fundRiskDollarIncentives`, and
`fundRiskStaticsIncentives` are permissionless and accept only the three
canonical assets inferred from protocol configuration. They may fund an Active
series under an Active or ReduceOnly profile even before Risk liquidity is
supplied. The measured receipt becomes a series-isolated reserve. Each pairing
fill releases `reserve * fill / liquidityBeforeFill`, with a complete fill
draining the rounding remainder. `riskIncentives` exposes current reserves and
their terminal disposition.

`finalizeRiskIncentives` is permissionless and idempotent. After a completed
series transition it rolls unused reserves into the profile's current healthy
active series. After permanent profile retirement it routes them through the
global non-swap reward ledger. Normal `processSeriesTransition` invokes the same
logic, while the standalone selector handles campaigns whose series has no
supplied Risk Shares to migrate.

## Custody checks

Use `globalReservedByToken` and `reservedByAccount` with
`dollarCustodyAccount`, `feeCustodyAccount`, `stakingCustodyAccount`, and each
`basketCustodyAccount(basketId)`. For every token:

```text
global reserved
  = dollar + fees + staking + sum(basket accounts)
physical Diamond balance >= global reserved
```

Unsolicited token transfers are unreserved. Risk incentive funding through the
typed selectors is reserved under the Dollar account. Core collateral and hook
permanent liquidity live at separate physical addresses and are not part of
this Diamond equation.

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
  `RewardAssetOptedIn`, `RewardAssetOptedOut`, `RewardAssetDustRouted`, and
  `MaxRewardAssetsPerPositionIncreased`;
- lending and flash: `LoanOriginated`, `LoanRepaid`, `LoanExtensionFeePaid`,
  `LoanExtended`, `LoanRecovered`, and `BasketFlashLoan`;
- Dollar Risk Shares token: `SeriesTransfersFrozen`;
- Dollar Risk incentives: `RiskIncentivesFunded`, `RiskIncentivesReleased`,
  `RiskIncentivesRolledOver`, `RiskIncentivesRoutedGlobal`,
  `RiskProceedsAccrued`, `RiskProceedsSettled`,
  `RiskProceedsResidueAssigned`, and `RiskProceedsClaimed`;
- Dollar series migration: `SeriesTransitionProcessed`,
  `PositionMigrationSettled`, and `MigrationRoundingWrittenOff`;
- Dollar Core transition and recovery: `Recombined`, `CollateralExitDeferred`,
  `SeriesTransitionStarted`, `SeriesTransitionCancelled`,
  `RiskSharesReturned`, `ReturnedRiskSharesReclaimed`,
  `SeriesTransitionFinalized`, `ReturnedRiskClaimed`,
  `RecoverySeniorRedeemed`, `ExpiredRiskRecovered`, and `SeriesClosed`;
- Morpho: `MorphoIntegrationInitialized`, `MorphoMarketRegistered`,
  `MorphoMarketModeChanged`, `MorphoAccountDeployed`,
  `MorphoCollateralDeployed`, `MorphoCollateralRecalled`,
  `MorphoSurplusWithdrawn`, `MorphoBorrowed`, `MorphoRepaid`,
  `MorphoSynchronized`, `MorphoLiquidatedAndSynchronized`,
  `MorphoSyncBountyClaimed`, `MorphoAccountTokenRecovered`, and
  `MorphoPerformanceFeeRouted`;
- canonical lifecycle: `LiquidityIntegrationInstalled`,
  `CanonicalPoolInitialized`, `CanonicalPoolSyncedToManager`,
  `SwapFeeConfigurationChanged`, and `BasketLiquidityUnwound`;
- hook: `SwapLegFeeAccrued`, `PermanentLiquidityAdded`,
  `PermanentLiquidityFeesCollected`, `PermanentLiquidityReleased`,
  and `PoolDecommissioned`;
- user v4 positions: `BorrowedLiquidityPositionMinted`,
  `BorrowedLiquidityProvided`, manager `UserPositionMinted`, and PositionManager
  `Transfer`;
- lifecycle: `BasketQuarantined`, `BasketQuarantineReleased`,
  `BasketDecommissioned`, `ActionsPaused`, `ActionsUnpaused`,
  `ProtocolSwapsPauseSet`, and `ProtocolPoolQuarantineSet`;
- shared positions: ERC-721 `Transfer` and `Approval`, `PositionCreated`,
  `PositionClosed`, `PositionLegAttached`, `PositionLegDetached`, and
  `PositionStateChanged`; and
- Dollar gateway and routing: `ETHDeposited`, `WETHDeposited`,
  `RecombinedToWETH`, `RecombinedToETH`, `RecombinationDeferred`,
  `PeggedMintedThroughGateway`, `PeggedMintedAndRecombined`,
  `PeggedMintAndRecombineDeferred`, `PeggedRedeemedThroughGateway`,
  `PeggedRedemptionDeferred`, `PoolFeeIndexed`, and `PeggedProfileFeeRouted`.

Events are discovery and history records, not substitutes for onchain state.
Reconcile after reorgs and immediately before value-moving actions.
