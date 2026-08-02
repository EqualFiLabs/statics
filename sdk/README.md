# Statics SDK

This package mirrors Statics static-basket rounding, builds calldata for the
single user-facing `StaticsDiamond`, and defines an adapter for sourcing or
selling basket constituents.

`classifyPrimaryFee` mirrors the atomic holder, protocol-owned-liquidity, and
protocol-revenue split. Its terminal protocol amount receives division dust
and the holder share whenever no PositionNFT leg is reward eligible.

`quoteMint` and `quoteRedeem` select the greatest qualifying static fee tier
and reproduce the aggregate-supply rounding used onchain. They do not model a
historical fee-pot buy-in: basket fees accrue separately to eligible
PositionNFT legs. Treat onchain `quoteMint` and `quoteRedeem` as authoritative
when building a transaction, particularly after supply changes.

`buildCreateBasketTransaction` returns both permissionless creation calldata
and the native `value` that must accompany it. Callers should read the current
`creationFee()` from the Diamond immediately before preparing the transaction.
The creation parameters include flat mint and redemption fee tiers and a
basket LTV no greater than the immutable 9,500-basis-point protocol maximum.

Position builders cover creating positions, depositing or minting BasketTokens
into positions, claiming indexed rewards, and position-owned borrowing.
Borrowing calldata always includes a `positionId`; transfer of that ERC-721
moves the attached reward eligibility and loan obligations together.

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

The package exports the complete Diamond liquidity ABI plus read-only hook,
manager, PositionManager, and StateView ABI fragments. Use the Diamond for
pool lifecycle, settlement, POL compounding, LP-fee collection, unwind, and
`borrowAndProvideLiquidity`. The hook and manager fragments are observability
surfaces; neither is a general user action address.

`quoteHookFee` rounds the one-basis-point hook charge up exactly as the hook
does. `splitProtocolLpFee` quotes an isolated first collection, while
`nextProtocolLpFeeSplit` uses cumulative collected and revenue-debit totals so
repeated dust-sized collections still converge to the floor-rounded 10%
protocol-revenue share. The balance remains with the nominal 90% POL share.
`effectiveCanonicalFees` reports the 500-pip LP fee and hook fee separately;
the initial values display as five LP basis points plus one hook basis point.

`quoteRangeAmounts` mirrors Uniswap v4 `TickMath` and `SqrtPriceMath` input
rounding. `quoteBorrowAndProvideLiquidity` combines those range amounts with
the ordinary Statics loan and mint calculations, including the origination-fee
burn that occurs before mint quoting. Its returned pool caps can be passed to
`buildBorrowAndProvideLiquidityCall`. Re-read the pool price, basket supply,
and onchain quotes immediately before simulation and submission.

Protocol position IDs come from `protocolPositionId`. Pending LP fees are
derived from PositionManager position metadata and StateView fee growth with
`pendingLpFees`; cumulative collections and revenue come from the Diamond.
User v4 NFTs are discovered from ordinary PositionManager `Transfer` events
and `UserPositionMinted`, not from the protocol-position mapping. They belong
to the selected LP recipient and remain independent of PositionNFT transfers,
repayment, extension, and recovery.

`robinhoodChain` is generated from
`deployments/robinhood-chain-4663.json` before SDK builds and tests. It is the
only SDK address binding for Robinhood's PoolManager, PositionManager, StateView,
Quoter, Universal Router, Permit2, and WETH deployment.
