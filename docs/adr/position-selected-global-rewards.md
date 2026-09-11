# ADR: Position-Selected Global Reward Assets

- Status: Accepted
- Date: 2026-07-23
- Scope: Global fee rewards and PositionNFT staking

## Context

Statics can receive fees in every basket constituent, BasketToken, Statics
Dollar collateral, and canonical pool currency. A global list capped at 64
assets made protocol growth depend on governance retiring and replacing slots.
It also forced every staking action to loop across every admitted asset even
when a user did not want those rewards.

The actual gas bound belongs to the user-owned position that performs the
work, not to the protocol's aggregate asset set.

## Decision

The protocol may create a reward book for any ERC-20 address. Each PositionNFT
only loops across its own selection during stake, unstake, and settlement. The
selection limit has two layers: an active limit that starts at 12 and an
immutable hard ceiling of 64.

Each reward asset maintains:

- its own eligible-stake denominator;
- a 1e27 reward index with independently floored accruals;
- indexed reserve and aggregate claimable accounting; and
- treasury accrual for fees that do not enter the staker index.

Eligible stake for an asset is the sum of stake in positions currently
selected into that asset. A position that selects an asset checkpoints the
current index before its stake joins the denominator, so it cannot capture
historical fees. Opt-out settles earned rewards before removing the position's
stake. Historical claimables remain claimable and do not count against the
active selection limit.

Timelock governance may raise the active limit to any strictly greater value up
to 64. It cannot lower the limit or raise the hard ceiling. This lets governance
expand selection capacity after observing production gas and execution
conditions without introducing a path that can strand positions by shrinking
their permitted set.

The active limit is initialized to 12 when the Statics Diamond is first
deployed and is enforced when adding a selection.

Undeployed global stake has no cooldown; stake supplied to Morpho must first be
recalled. Initial stake, new selections, and top-ups enter a pending tranche for
each selected asset. Pending stake matures at the next hourly boundary at least
24 hours later, producing a bounded 24-to-25-hour wait. Mature stake remains
eligible when more stake is added, and withdrawals consume pending stake first.

Each asset maintains a 25-slot hourly maturity ring. Fee accrual and position
interactions roll due buckets before using the eligible denominator, so no
keeper or activation transaction is required. A bucket records the reward
index at activation. Position settlement uses that activation index for newly
matured stake, preventing rewards accrued during the waiting period from being
claimed later. Repeated pending top-ups preserve waiting time through weighted
time credit without changing already-mature stake.

The position-selected API is:

- `createAndStake(amount, receiver, rewardAssets)` selects initial assets
  atomically;
- `optInRewardAssets` and `optOutRewardAssets` manage selections;
- `positionRewardAssets` and `isRewardAssetOptedIn` expose position state;
- `rewardSelection` exposes pending stake, eligible stake, and exact maturity;
- `rewardAsset(asset)` exposes the asset book;
- `maxRewardAssetsPerPosition()` reports the current active limit;
- `hardMaxRewardAssetsPerPosition()` reports the immutable 64-asset ceiling;
  and
- `increaseMaxRewardAssetsPerPosition(newMax)` raises the active limit through
  owner governance and emits `MaxRewardAssetsPerPositionIncreased`.

Global slot, queue, generation, and retirement entrypoints are removed.

## Fee fallback

For non-swap fees, an asset with no eligible selected stake routes the complete
fee to treasury. Otherwise, 90% enters that asset's staker index and the
remainder enters treasury.

For canonical swap fees, `canAccrueStakerRewards(asset)` is true only when the
asset has eligible selected stake. The hook routes an unavailable staker share
to treasury. This canonical-swap fallback is refined by
`canonical-pool-donation-hardening.md`.

## Consequences

- Statics has no global reward-asset admission cap or retirement ceremony.
- New positions initially select up to 12 reward assets.
- Governance can only expand the active selection limit.
- Work per PositionNFT remains bounded by the 64-asset hard ceiling.
- Different assets may have different eligible denominators.
- Principal is never locked by reward selection or maturity.
- Users choose which fee assets justify their gas and portfolio exposure.
- New selections do not dilute or capture rewards accrued before selection.
- Indexers must follow selection events and asset-address books rather than
  numbered slots and generations.
- The initial Diamond deployment writes the active limit directly during
  protocol initialization.
