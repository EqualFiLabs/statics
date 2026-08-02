# Statics SDK

This package mirrors Statics static-basket rounding, builds calldata for the
single user-facing `StaticsDiamond`, and defines an adapter for sourcing or
selling basket constituents.

`splitSwapFee` mirrors the bilateral swap-fee split across permanent liquidity,
activated canonical LPs, global stakers, and treasury. Treasury receives
division dust; unavailable LP and staker allocations independently redirect to
permanent liquidity.

`quoteMint` and `quoteRedeem` select the greatest qualifying static fee tier
and reproduce the aggregate-supply rounding used onchain. They do not model a
historical fee-pot buy-in: basket fees accrue in-kind against the single global
staking balance. Treat onchain `quoteMint` and `quoteRedeem` as authoritative
when building a transaction, particularly after supply changes.

`buildCreateBasketTransaction` returns both permissionless creation calldata
and the native `value` that must accompany it. Callers should read the current
`creationFee()` from the Diamond immediately before preparing the transaction.
The creation parameters include flat mint and redemption fee tiers and a
basket LTV no greater than the immutable 9,500-basis-point protocol maximum.

Position builders cover global staking, optional BasketToken collateral,
pull-based multi-asset reward claims, and position-owned borrowing. Borrowing
calldata always includes a `positionId`; transfer of that ERC-721 moves the
attached staking balance, claim checkpoints, collateral, and loan obligations
together.

Statics Dollar builders cover the typed ETH/WETH deposit and ordinary
recombination gateway exposed by the same Diamond. Permit variants encode an
exact-amount EIP-2612 signature so approval and WETH or ETH recombination occur
in one transaction. Risk Shares still require ERC-1155 operator approval. The
builders do not expose the Core's managed pairing-only recombination selector.

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
manager, PositionManager, and StateView fragments. Governance uses the Diamond
for canonical pool initialization, activation, and fee configuration. Pool
checkpointing, reward and treasury distribution, retirement settlement, and
post-`ExitOnly` unwind retain their permissionless execution paths.

`quoteHookFee` rounds either realized bilateral fee leg up exactly as the hook
does. `effectiveCanonicalFees` reports the zero native LP fee and the separate
input/output hook rates; the launch defaults are 25 basis points on each leg.
`splitSwapFee` applies the default 50% POL, 10% canonical-LP, 30%
global-staker, and 10% treasury allocation after a leg is charged. Callers
supply LP and staker eligibility independently; unavailable shares redirect to
POL. Matched POL is added as hook-owned full-range liquidity during the swap.

`quoteRangeAmounts` mirrors Uniswap v4 `TickMath` and `SqrtPriceMath` input
rounding. `quoteBorrowAndProvideLiquidity` combines those range amounts with
the ordinary Statics loan and mint calculations, including the origination-fee
burn that occurs before mint quoting. Its returned pool caps can be passed to
`buildBorrowAndProvideLiquidityCall`. Re-read the pool price, basket supply,
and onchain quotes immediately before simulation and submission.

User-selected LP positions are ordinary PositionManager NFTs created by the
installed manager. Their position state can be read from PositionManager and
StateView, although canonical pools currently have zero native LP fee.
Qualifying full-range NFTs can be staked into the Diamond with the exported
builders, activated in the next block, increased in place, claimed, and
unstaked without a cooldown. `borrowAndProvideLiquidity` origin is not required.
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
