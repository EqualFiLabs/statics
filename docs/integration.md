# Statics integration guide

## Address model

Most applications need:

- the Doppler-created STATICS token, `StaticsGenesis`, and
  `StaticsGenesisVault` for the standalone token/NFT conversion lifecycle;
- `StaticsFeeReceiver`, `GenesisActivationRegistry`, and
  `GenesisLaunchDistributor` for permanent launch-fee ingress, activation, and
  temporary Genesis rewards;
- `IStaticsGenesisIntegration` at `StaticsDiamond` for permanent Genesis
  rewards, Position linkage, and recovery after the governed handoff;
- `StaticsDiamond`, the PositionNFT, basket, global-reward, canonical-liquidity,
  and ordinary Statics Dollar gateway address;
- `StaticsDollarCoreDiamond` for advanced Dollar state and direct operations;
- `StaticsDollar` and `StaticsDollarRiskShares`;
- WETH and the configured Dollar oracle;
- the configured global staking token;
- one `StaticsBasketToken` address per discovered basket;
- the installed `StaticsSwapFeeHook` and `StaticsLiquidityManager` when using
  canonical Uniswap v4 pools.

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
| Flash loans | `src/interfaces/IStaticsFlashLoan.sol` | Quote and execute constituent-vector flash loans |
| Flash receiver | `src/interfaces/IStaticsFlashBorrower.sol` | Required callback interface and return hash |
| PositionNFT | `src/interfaces/IStaticsPosition.sol` plus OpenZeppelin `IERC721` | Create, transfer, approve, inspect metadata, and close positions |
| Basket lifecycle | `src/interfaces/IStaticsGovernance.sol` | Read pauses and status; governance lifecycle operations |
| Custody | `src/interfaces/IStaticsCustody.sol` | Inspect global and account reservation coverage |
| Dollar gateway | `src/dollar/interfaces/IStaticsDollarGateway.sol` | ETH/WETH series operations and pegged wrappers |
| Dollar Risk liquidity | `src/dollar/interfaces/IStaticsDollarRiskLiquidity.sol` | Stake consumable Risk Shares, inspect liquidity, withdraw unconsumed shares, and claim fill proceeds |
| Dollar Core | `src/dollar/core/interfaces/IStaticsDollarCore.sol` | Direct issuance, recombination, health, and recovery |
| Statics Dollar | `src/dollar/interfaces/IStaticsDollar.sol` | ERC-20 transfers, allowances, and EIP-2612 permit |

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

`IStaticsSwapFeeHook` exposes hook fee configuration, pending
permanent-liquidity inventory, and locked liquidity. The installed manager is
used for typed user PositionManager NFT creation; canonical permanent liquidity
is hook-owned and has no protocol PositionManager token ID.

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

`linkGenesis(positionId, genesisId)` requires the same actual owner for both
NFTs; approvals do not authorize linking or unlinking. While linked,
`locked()` is true for both NFTs and owner-changing transfer is prohibited.
The activation multiplier applies only to global STATICS reward weight. It
does not change raw stake, withdrawable principal, collateral, LP rewards, or
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
only for an existing, fully initialized Position with both counts at zero.
Structural membership is available through `isLegActive`; events
`PositionLegAttached`, `PositionLegDetached`, and `PositionStateChanged` support
indexer reconstruction. Position identity is `(chain ID, StaticsDiamond,
positionId)`, with no separate Position Key getter.

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
`canonicalPool(basketId, asset)` for its PoolId, currencies, hook, zero native
LP fee, tick spacing 10, and current spot tick.

The Diamond also supports permissionless **general pools** between two
compatible ERC-20 assets with no basket association. Read
`protocolPool(poolId)` to resolve either class (`BasketCanonical` or
`General`) and `isProtocolPool(poolId)` for a bounded registration check.
`protocolPoolCreator(poolId)` returns the immutable creator. Index
`CanonicalPoolInitialized` and `ProtocolPoolCreated` for discovery; the
Diamond deliberately provides no unbounded pool array.

The `ProtocolPoolCreated` event carries the market configuration that is not
encoded in the PoolKey — creator, sorted currencies, tick spacing, the input
and output hook fee rates, the normalized initial price, and the initial tick.
There is no native-LP-fee field because every Statics protocol PoolKey uses
`fee == 0`. Indexers reconstruct and rank markets from `ProtocolPoolCreated`,
`CanonicalPoolInitialized`, `ProtocolPoolFeeRateSet`, `PoolCreationFeeSet`,
`PoolCreationNonceInvalidated`, creator credit and claim events,
`GeneralPoolDecommissioned`, hook permanent-liquidity and fee events, LP
staking and reward events, and PoolManager state. A first-party frontend may
maintain curated token lists and hide spam without changing contract-level
permissionlessness.

Pool initialization and permanent seeding are inseparable from basket creation.
The creator supplies every starting price and paired-asset budget. A successful
creation makes every canonical pool immediately swappable and available to the
typed liquidity paths; no post-launch activation transaction is required.

Display input and output hook fees separately from native v4 LP fees:

```text
native v4 LP fee: 0
launch input hook fee:  50 BPS on the realized input leg
launch output hook fee: 50 BPS on the realized output leg
launch split: 10% permanent liquidity / 25% eligible canonical LPs /
              25% deposited BasketTokens / 15% global Statics stakers /
              5% creator (fixed) / 20% treasury
```

Governance may update the bilateral rates and the configurable allocation
shares; the combined input/output rate is capped at 200 BPS and the
configurable shares always total 9,500 BPS beside the fixed 500-BPS creator
share. Hook fees apply to every canonical swap without caller,
router, flash-receiver, or LP-owner exemption. Treasury receives split dust.
If a pool has no activated staked liquidity, its LP share redirects to
permanent liquidity. If the basket reward route cannot accrue its asset, that
share redirects to permanent liquidity. If the global Statics reward route
cannot accrue its asset, that share redirects to treasury.

Anyone may create a general pool with
`createPool(params, creatorAuthorization)` once permissionless creation is
enabled. Call `quotePool(params)` first to derive the sorted PoolKey, PoolId,
normalized sorted price, the resolved `PoolSwapFeeRate`, the exact
`creationFee`, and the EIP-712 `authorizationDigest`. The creator supplies two
token addresses, a valid `tickSpacing` (1 through 32,767), the initial price as
`sqrtPriceBPerAX96` in raw-unit B-per-A orientation, an initial
`PoolSwapFeeRate` whose `inputFeeBps + outputFeeBps <= 200`, the creator
identity, an unordered `nonce`, and a `deadline`. Statics sorts the currencies
and always constructs the PoolKey with native fee zero and the installed
Statics hook.

General-pool creation is separate from liquidity provision. A successful
`createPool` establishes the PoolId, price, tick spacing, creator, Statics fee
rate, hook registration, and protocol registration; it does not require an
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
`name = "Statics Protocol Pools"`, `version = "1"`, the current `chainId`, and
`verifyingContract = StaticsDiamond`. `SignatureChecker` validates both EOA and
ERC-1271 creators. The signed digest binds the PoolId, normalized price,
`inputFeeBps`, `outputFeeBps`, creator, nonce, and deadline. Three paths apply:
a direct creator (`creator == msg.sender`) may pass empty authorization and
consumes no nonce; while creation is disabled the Diamond owner may designate a
creator without a signature; otherwise the named creator must supply a valid
authorization and its unordered nonce is consumed. Relayed authorizations
deliberately do not bind `msg.sender`, so a copied transaction may pay the fee
and initialize the pool first but can never replace the creator or change the
PoolId, price, or fee rate. Cancel an unused authorization with
`invalidatePoolCreationNonce(nonce)` and check state through
`isPoolCreationNonceUsed(creator, nonce)`.

Distinct tick spacings for the same pair produce distinct PoolIds and
independent markets. A different Statics fee rate or initial price alone does
not create a new PoolId, so a second creation with the same currencies, tick
spacing, zero native fee, and Statics hook reverts as a duplicate.

Fee **rate** and fee **allocation** are separate policy dimensions. The swap
fee rate is PoolId-local: general-pool creators select the initial
`PoolSwapFeeRate` at creation, and timelocked governance may later adjust any
PoolId's rate with `setProtocolPoolFeeRate(poolId, feeRate)` within the same
`inputFeeBps + outputFeeBps <= 200` bound enforced by the hook. Read the
current rate through `protocolPoolFeeRate(poolId)`.

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
permanent liquidity     1,000 BPS      3,500 BPS
eligible Statics LPs     2,500 BPS      2,500 BPS
basket stakers           2,500 BPS      0 BPS
global Statics stakers   1,500 BPS      1,500 BPS
creator, fixed             500 BPS        500 BPS
treasury                 2,000 BPS      2,000 BPS
total                   10,000 BPS     10,000 BPS
```

General pools have no basket-staker share; the profile encodes this explicitly
rather than relying on a runtime fallback. Changing a global allocation profile
affects only subsequent accrual and never rewrites accrued creator credits, LP
rewards, basket rewards, Statics-staker rewards, treasury revenue, or POL
inventory. Changing a PoolId's fee rate does not change the applicable
allocation profile, and vice versa.

Creator revenue equals exactly 500 BPS of the collected Statics bilateral fee
in both pool currencies. It is pull-based: swap execution never calls the
creator. Claim it with
`claimCreatorRevenue(asset, receiver, minReceived)` and read pending amounts
through the creator-credit views. Creator credits never expire, cannot be
confiscated by governance, and survive decommissioning.

The hook transfers both staker shares and treasury shares immediately to the
Diamond and
matches its permanent-liquidity shares into hook-owned full-range liquidity.
Unmatched inventory is visible through `pendingPermanentLiquidity`; deployed
liquidity is visible through `lockedLiquidity`. Swaps attempt compounding
atomically, and `compoundPermanentLiquidity` is also permissionless.

Native PoolManager donations to a protocol pool always revert in
`beforeDonate`. Integrators must not use Uniswap donation routers with Statics
pools. Protocol seeding and swap-fee allocation are the supported sources of
pending POL.

There is no primary-fee POL reserve, epoch, ramp, minimum compound size, hook
settlement call, protocol PositionManager NFT, or manager-owned protocol
inventory. The standalone manager resolves exact PoolKeys from the Diamond's
protocol-pool registry and executes transaction-scoped PositionManager NFT
mint and increase operations.

Only a general pool may use `decommissionGeneralPool(poolId)`, an owner-only
terminal transition. The creator cannot decommission a pool. The call stops
later swaps and managed LP actions, releases permanent liquidity to treasury
accounting, and leaves all user PositionManager NFTs untouched. Existing
creator credits and previously earned rewards remain claimable and staked NFTs
remain withdrawable. Decommissioning is irreversible for that PoolKey; a
replacement market requires a different supported PoolKey, which generally
means a different tick spacing. Basket canonical pools retain their separate
`ExitOnly` unwind and are never processed with general-pool decommission
accounting.

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
one active registered canonical pool per constituent with no duplicates.
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

Statics ships the optional, narrowly typed
`StaticsFlashArbitrageReceiver.executeMintAndSell` route for overpriced
baskets. The caller supplies a complete BasketToken allocation across the
basket's canonical pools, a deadline, and a net minimum profit for every
constituent. The receiver pulls only the small constituent top-ups required by
the static mint fee, uses the ordinary fee-paying `mint` entrypoint, settles
swaps directly with the configured v4 PoolManager, approves exact flash
repayment, returns profits to the caller, and retains no route balances.

The receiver is permissionless but is not a generic router: it has no owner,
allowlist, arbitrary target-and-calldata execution, callback privilege, or fee
exemption. It does not implement the underpriced buy-and-redeem direction or
search for profitable allocations. Searchers remain responsible for fresh
quotes, gas, allocation selection, and minimums. Cancun/EIP-1153 is required.
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
  `RewardAssetOptedIn`, `RewardAssetOptedOut`, and `RewardAssetDustRouted`;
- lending and flash: `LoanOriginated`, `LoanRepaid`, `LoanExtensionFeePaid`,
  `LoanExtended`, `LoanRecovered`, and `BasketFlashLoan`;
- Dollar Risk incentives: `RiskIncentivesFunded`, `RiskIncentivesReleased`,
  `RiskIncentivesRolledOver`, `RiskIncentivesRoutedGlobal`,
  `RiskProceedsAccrued`, and `RiskProceedsClaimed`;
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
  `BasketDecommissioned`, `ActionsPaused`, and `ActionsUnpaused`;
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
