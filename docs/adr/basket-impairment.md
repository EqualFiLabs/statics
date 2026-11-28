# Basket impairment and healthy-asset exits

## Decision

A Diamond owner may permanently mark a launched basket constituent impaired.
The basket becomes `ExitOnly`: issuance, new borrowing, extensions, collateral
ingress, and basket flash exposure remain disabled through existing active-status
checks. Impairment is basket-specific and does not change swap-pause policy.
There is no flag-clearing or reactivation endpoint.

`IStaticsBasketImpairment` adds an explicit healthy-only exit for wallet holdings
and unlocked position collateral, plus a quote and asset-status getter. Existing
basket interfaces and the basket view tuple retain their identifiers and shape.
Ordinary redemption and its quote reject impaired baskets: callers must explicitly
select the forfeiting exit even if the impaired token later resumes operation.

## Redemption and custody

Burning returns the existing per-share healthy backing, less the configured
redemption fee. It never substitutes another asset for impaired backing. Output
arrays preserve constituent ordering; impaired outputs and their minimums are
zero. If all constituents are impaired, an explicit zero-output burn is allowed.
Skipped constituents receive no external token calls, including balance queries.

Burning permanently forfeits all rights to the impaired backing. No recovery
claims are created. Residual impaired backing stays in its existing per-basket
vault ledger and custody reservation; it is not reclassified as fees or treasury
revenue and cannot be claimed through ordinary redemption later.

Position authorization, reward checkpoints, native-loan locks, and Morpho locks
remain in force. Frozen markets do not have to unwind before healthy vault
redemption; external token freezes may prevent those markets from unwinding.

## Earned rewards

`claimBasketRewards` settles the existing indexes and pays healthy reward
currencies normally. An impaired constituent's entitlement is permanently
forfeited: the claim clears it, returns zero in that currency's existing output
slot, and emits `BasketRewardForfeited`. No calls are made to the impaired token,
including balance queries. Claims containing only forfeited rewards succeed;
claims with no entitlements still revert. A failed healthy transfer rolls back
the entire claim, including forfeitures.

Forfeited reward tokens remain reserved in the fee account. Clearing the claim
creates no recovery right, treasury credit, or redistribution. Existing fee
accrual, rounding-dust allocation, and Morpho loss rules remain unchanged.
Subsequent earnings in an impaired currency are also forfeited on claim, even if
the token resumes operation. Clearing the final entitlement permits the existing
empty-position cleanup.

`getBasketRewards` preserves asset ordering and reports zero for impaired
constituents. `basketRewardState` remains a raw accounting view: its crystallized
claim totals include stored entitlements until claims clear them lazily. The
basket token itself remains a normal reward currency. Impairment affects only
rewards of the marked basket, not the same currency in other baskets or reward
systems.

## Existing obligations and protocol liquidity

Native loans repay only healthy principal after impairment. Impaired principal
is written off when the loan closes, reducing outstanding principal without
crediting vault backing or transferring the impaired token. Recovery preserves
maturity, grace, share burns, and healthy penalty rules; impaired penalties are
zero. Protocol-owned basket-token burns likewise consume healthy backing only.
External Morpho obligations retain upstream health and withdrawal restrictions.
