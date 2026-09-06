# PNFT-managed Morpho collateral

## Status

Accepted for the first Statics Diamond deployment.

## Context

Statics needs to rehearse the production lending integration against the reusable Robinhood testnet Morpho Blue deployment. A Position NFT (PNFT) must be able to place either deposited Basket shares or staked STATICS into a Morpho market, borrow USDstx, and retain the reward treatment already attached to that PNFT. Morpho remains the source of truth for debt, interest, health, liquidation, bad debt, and lender yield.

The live Genesis contracts cannot be changed. The Statics Diamond and its Genesis integration have not been deployed, so their storage and ABI may be extended without migration compatibility code.

## Decision

Each PNFT has one deterministic minimal Morpho account. The account authorizes the Diamond once at construction, records the Diamond as its immutable token-recovery authority, and can be reused across at most sixteen registered markets. The Diamond stores the deployed account address so later facet or compiler changes cannot redirect an existing position. Markets are registered by their exact Morpho `MarketParams` and classified as Basket or staked-STATICS collateral. Registered markets are Active or ExitOnly; Disabled is only the unregistered enum default. ExitOnly permits repayment, recall, withdrawal of surplus, liquidation, synchronization, and raw-token recovery, but no new collateral or borrowing.

The Diamond tracks only the collateral moved from Statics custody for a PNFT. A direct Morpho deposit into a registered market is untracked surplus: it earns no Statics rewards, absorbs liquidation losses before tracked collateral, and can be withdrawn by the PNFT owner only to the extent it exceeds tracked collateral. Deposits into a market the PNFT has never tracked are not included in lifecycle enumeration or the automatic close predicate, but the explicit surplus-withdrawal path remains available.

Raw ERC-20 transfers to an already deployed account are not Morpho collateral. The account accepts both Boolean-returning and legacy no-return token transfers, while the Diamond enforces the caller's minimum-receipt bound. A PNFT cannot close while any historically tracked Morpho market still has tracked collateral, actual collateral, or debt. Immediately before burning a PNFT with a deployed account, the Diamond permanently records its actual final owner as that account's recovery beneficiary. After closure, only that beneficiary—not a former approved operator—may recover raw tokens or withdraw surplus from registered markets; no borrowing, deployment, repayment, or recall authority survives. Pre-deployment transfers to a predicted address remain unsupported because an undeployed prediction may change before account creation. Protocol payouts reject the Diamond and every known Morpho account as receivers.

Basket deposits use the same 24-hour eligibility delay and hourly maturation buckets as global STATICS staking. Moving eligible or pending Basket shares to Morpho does not change their reward state. Staked STATICS likewise keeps its opted-in assets and Operator NFT multiplier while supplied as collateral. Collateral moved to Morpho is unavailable for native Basket borrowing or local unstaking.

All reward-sensitive exits and transitions synchronize tracked collateral against Morpho first. Anyone may call `syncMorpho(positionId, marketId)`. If actual Morpho collateral is below tracked collateral, surplus is consumed first and the remaining loss is removed pro rata from pending and eligible reward balances. Uncrystallized rewards on lost eligible collateral are forfeited. The first successful synchronizer receives the configured portion of forfeited rewards; the default is 5% and governance may configure 0-10%. The remainder is re-indexed to other eligible participants, excluding the liquidated PNFT. If no other eligible weight exists, it goes to protocol treasury. Synchronization is idempotent.

The official liquidation helper calls Morpho liquidation and then synchronizes, but direct permissionless Morpho liquidation remains valid. Morpho bad debt is borne only by Morpho lenders and never by Statics Dollar reserves.

Morpho lenders interact directly with Morpho in this release. A future lender router may provide PNFT lender tracking, funded incentives, pegged mint/redeem paths, and realized-yield accounting. The Diamond exposes the fee ingress now: a configured router may route a performance fee on realized USDstx yield. The fee is capped at 20%, and its allocation is deployment-configured between collection-wide activation-weighted Genesis Operators and protocol treasury. It never accrues to global stakers, Basket stakers, PNFT borrowers, or incentives. With no configured router, the integration is disabled. If registered Operator weight is zero, the Operator allocation goes to treasury.

Oracle implementation and Morpho market creation are outside this change. Registration verifies an already-created market whose loan token is USDstx and whose collateral matches the declared Statics source.

## Consequences

- The PNFT remains the user-facing ownership and authorization boundary while Morpho is the lending ledger.
- Reward accounting changes only when collateral is deposited, withdrawn, or proven lost; moving custody alone does not create a second reward system.
- Liquidators do not need cooperation from Statics, while the explicit helper and keeper bounty make prompt reconciliation economically natural.
- The sixteen-market cap bounds all automatic synchronization loops.
- Closing preserves recovery for raw ERC-20 balances and untracked collateral in registered markets, but preserves no post-close operating authority. Morpho loan-token `supplyShares`, native assets, and NFTs at the account are unsupported, unchecked at close, and have no Statics recovery path in this release; lenders must supply under an address they control.
- A PNFT burned before this revision has no onchain final-owner snapshot and cannot be assigned a recovery beneficiary retroactively; there is no governance override.
- The optional-return transfer fix changes the deterministic account creation hash. Previously deployed accounts remain pinned and immutable, so only accounts deployed from this revision gain legacy no-return token support; undeployed predictions remain unsupported until deployment.
- A future lender router can be added without changing borrower collateral accounts or fee beneficiaries.

## Public surface

- Collateral and debt: `deployMorphoCollateral`, `recallMorphoCollateral`, `withdrawUntrackedMorphoCollateral`, `borrowMorphoUsd`, `repayMorphoUsd`, and `recoverMorphoAccountToken`.
- Reconciliation: `syncMorpho`, `liquidateMorphoAndSync`, and `claimMorphoSyncBounties`.
- Administration: exact market registration, market-mode changes, sync-bounty configuration, and performance-fee configuration.
- Views: deterministic account address, market configuration, per-position allocation, tracked-market pagination, and performance-fee quote.
