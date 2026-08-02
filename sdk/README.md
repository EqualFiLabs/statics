# Statics SDK

This package mirrors Statics static-basket rounding, builds calldata for the
single user-facing `StaticsDiamond`, and defines an adapter for sourcing or
selling basket constituents.

`splitSwapFee` mirrors the bilateral swap-fee split across permanent liquidity,
activated canonical LPs, deposited BasketToken positions, global Statics
stakers, and treasury. Treasury receives division dust; unavailable LP,
basket-staker, and Statics-staker allocations independently redirect to
permanent liquidity.

`quoteMint` and `quoteRedeem` select the greatest qualifying static fee tier
and reproduce the aggregate-supply rounding used onchain. They do not model a
historical fee-pot buy-in: basket fees accrue in-kind against the single global
staking balance. Treat onchain `quoteMint` and `quoteRedeem` as authoritative
when building a transaction, particularly after supply changes.

`buildCreateBasketTransaction` returns both permissionless creation calldata
and the native `value` that must accompany it. Callers should read the current
`creationFee()` from the Diamond immediately before preparing the transaction.
The creation parameters include flat mint and redemption fee tiers, a basket
LTV no greater than the immutable 9,500-basis-point protocol maximum, and a
recovery penalty that fits inside the collateral remaining at that LTV.
Callers also provide a launch deadline; use a short quote lifetime so stale
initial prices cannot be executed later.

Position builders cover global staking, optional BasketToken collateral,
pull-based multi-asset reward claims, and position-owned borrowing. Borrowing
calldata always includes a `positionId`; transfer of that ERC-721 moves the
attached staking balance, claim checkpoints, collateral, and loan obligations
together.

Global Statics stake is always withdrawable. A selected reward asset begins
with pending stake and becomes eligible at the next hourly boundary at least
24 hours later. Mature stake remains eligible when a position is increased;
only the new amount enters the pending tranche. Read `rewardSelection` for the
exact timestamp and pending/eligible split. The next fee or position
interaction rolls due buckets automatically, so integrations never submit a
separate activation transaction.

Statics Dollar builders cover the typed ETH/WETH deposit and ordinary
recombination gateway exposed by the same Diamond. Permit variants carry the
signed EIP-2612 allowance value independently from the operation amount, so
integrations can authorize an exact input or a reusable allowance in the same
transaction. Risk Shares still require ERC-1155 operator approval. The
builders do not expose the Core's managed pairing-only recombination selector.
Pegged USDG minting and USDstx redemption have the same atomic permit path via
`buildMintPeggedWithPermitCall` and `buildRedeemPeggedWithPermitCall`.
`buildErc20PermitTypedData` supplies the matching EIP-712 message; integrations
must read the token name and current owner nonce immediately before signing.

For an atomic pegged-collateral exit, decode
`quoteMintPeggedAndRecombine` as `PeggedMintAndRecombineQuote`, require an
eligible, available quote, and refresh it before submission. Use
`buildQuoteMintPeggedAndRecombineCall`, `buildMintPeggedAndRecombineCall`, or
`buildMintPeggedAndRecombineWithPermitCall`. The caller authorizes pegged
collateral and Risk Shares; temporary Statics Dollar is
minted directly to the Diamond and requires no user allowance. The route accepts
only an active series belonging to the selected volatile profile and uses
ordinary recombination, never recovery or arbitrary external execution. Bound
the call with `maximumPeggedCollateralIn` and
`minimumVolatileCollateralOut`; the permit builder authorizes only the pegged
ERC-20 and does not replace ERC-1155 operator approval. Execution returns
`(status, peggedCollateralIn, volatileCollateralOut)`. A non-available status
has zero amounts, consumes neither permit nor custody, and preserves the Core
health checkpoint; index `PeggedMintAndRecombineDeferred` for those attempts.

The routing interface intentionally supports only underlying tokens. It does
not require initial BasketToken liquidity. A caller can source constituents,
mint at the Diamond, and deliver the resulting BasketToken to any external
venue or counterparty. Redemption works in reverse: redeem first, then route
only the received constituents.

The SDK never selects a venue, hardcodes a router, or submits transactions.
Lifecycle helpers expose quarantine, release, and permanent decommissioning;
`allowsExposureIncrease` maps the basket status to user-facing action gating.

## Canonical liquidity

The package exports the Diamond liquidity and global-reward ABI plus hook,
manager, PositionManager, and StateView fragments.
`buildCreateBasketTransaction` requires one semantic
constituent-per-BasketToken square-root price, paired-asset amount, and measured
complete input cap per constituent, plus a launch deadline. Prices are ratios of
raw smallest token units, not decimal-normalized display units. Use
`encodeSqrtPriceAssetPerBasketX96(assetAmountRaw, basketAmountRaw)` to construct
them. The creation transaction initializes, manager-registers, backs, and
permanently seeds every canonical pool. There is no standalone initialization
or manager-sync builder. Constituents must settle the exact Uniswap v4 transfer
amount; incompatible transfer-tax behavior reverts the complete launch.

Governance uses the Diamond for post-warm-up activation and fee configuration.
Pool checkpointing, reward and treasury distribution, retirement settlement,
and post-`ExitOnly` unwind retain their permissionless execution paths.

Canonical single-pool browser swaps use `buildQuoteV4ExactInputSingleCall`
against Robinhood's v4 Quoter and `buildV4ExactInputSingleSwap` against its
Universal Router. The swap builder emits the deployed Robinhood router's
exact-input-single encoding, including the per-hop minimum-price field, and
settles only the exact input while requiring the configured minimum output.
After the wallet grants the one-time ERC-20 allowance to Permit2,
`buildPermit2PermitTypedData` and the optional Permit2 command make each router
allowance and swap atomic. The signed token, amount, and router are required to
match the swap exactly.

`quoteHookFee` rounds either realized bilateral fee leg up exactly as the hook
does. `effectiveCanonicalFees` reports the zero native LP fee and the separate
input/output hook rates; the launch defaults are 25 basis points on each leg.
`splitSwapFee` applies the default 40% POL, 10% canonical-LP, 20%
basket-staker, 20% global Statics-staker, and 10% treasury allocation after a
leg is charged. Callers supply each reward destination's eligibility
independently; unavailable shares redirect to POL. Matched POL is added as
hook-owned full-range liquidity during the swap.

`quoteRangeAmounts` mirrors Uniswap v4 `TickMath` and `SqrtPriceMath` input
rounding. `quoteBorrowAndProvideLiquidity` combines those range amounts with
the ordinary Statics loan and mint calculations, including the origination-fee
burn that occurs before mint quoting. Its returned pool caps can be passed to
`buildBorrowAndProvideLiquidityCall` or, for full-range PositionNFT custody and
next-block LP reward activation, `buildBorrowAndStakeLiquidityCall`. Re-read
the pool price, basket supply, and onchain quotes immediately before simulation
and submission.

`quoteBorrow` returns the debt and creator-configured recovery-penalty shares
as well as the collateral and principal vector. `quoteRecovery` mirrors the
supply-sensitive backing reduction, unlocks collateral above debt plus
penalty, and splits the realized penalty 20% to the caller and 80% to the
protocol route. Onchain quotes remain authoritative.

User-selected LP positions are ordinary PositionManager NFTs created by the
installed manager. Their position state can be read from PositionManager and
StateView, although canonical pools currently have zero native LP fee.
Qualifying full-range NFTs can be staked into the Diamond with the exported
builders, activated in the next block, increased in place, claimed, and
unstaked without a cooldown. `borrowAndProvideLiquidity` origin is not required.
`borrowAndStakeLiquidity` instead creates those full-range positions directly
in Diamond custody under the borrowing PositionNFT; borrowed collateral keeps
earning its separate basket rewards.
Hook-owned permanent liquidity is observed through `lockedLiquidity` and
`pendingPermanentLiquidity`; it has no protocol PositionManager token ID.
User v4 NFTs are discovered from PositionManager `Transfer` and manager
`UserPositionMinted` events. They belong to the selected LP recipient and
remain independent of PositionNFT transfers, repayment, extension, and
recovery.

`robinhoodChain` is generated from
`deployments/robinhood-chain-4663.json` before SDK builds and tests. It is the
only SDK address binding for Robinhood's PoolManager, PositionManager, StateView,
Quoter, Universal Router, Permit2, and WETH deployment.
