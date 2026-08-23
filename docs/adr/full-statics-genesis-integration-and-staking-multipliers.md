# ADR: Full Statics Genesis integration and staking reward multipliers

- Status: Proposed
- Date: 2026-08-23
- Scope: Full Statics Genesis integration, Genesis-to-PositionNFT linkage, mutual transfer locking, permanent Genesis reward distribution, activation callbacks, secured-credit recovery callbacks, and activation-weighted global STATICS staking
- Depends on: `genesis-secured-credit.md`
- Extends: `doppler-genesis-launch-and-staged-rewards.md`
- Amends: the Shared PositionNFT and Global Staking and Rewards sections of `Statics-Design.md`
- Preserves: permanent `GenesisActivationRegistry` state, permanent `StaticsFeeReceiver` ingress, historical launch-distributor claims, fixed Genesis activation multipliers, productive secured-credit behavior, PositionNFT modular accounting, the 64-asset global reward selection bound, and ordinary PositionNFT transferability when no Genesis is linked

## Context

The standalone Genesis launch intentionally separates permanent infrastructure from temporary launch reward plumbing.

The long-lived components are:

```text
StaticsGenesis
StaticsGenesisVault
GenesisActivationRegistry
StaticsFeeReceiver
```

`GenesisLaunchDistributor` is temporary.

When full Statics becomes available, the accepted launch architecture requires full Statics to become the successor distributor for future `StaticsFeeReceiver` attribution and the active Genesis activation consumer, while historical launch claims remain in `GenesisLaunchDistributor`.

The secured-credit architecture adds another requirement. A Genesis may remain economically productive while secured credit is active and may retain:

```text
direct Genesis reward weight
activation tier
activation multiplier
PositionNFT staking multiplier benefits
native ETH reserve exposure
future protocol utility
```

If secured credit is recovered and the Genesis is linked to a PositionNFT, full Statics must settle the Position's Genesis-enhanced reward accounting and remove only the Genesis relationship before the NFT returns to Genesis Vault inventory.

The current Statics Diamond does not yet implement this integration.

The current global staking system also treats raw eligible STATICS stake as reward weight. A Genesis activation multiplier therefore cannot be applied correctly without separating deposited principal from effective reward-distribution weight.

This ADR defines the full-protocol Genesis integration and makes Position-level reward multipliers a first-class property of global STATICS staking.

## Decision summary

Full Statics adds a dedicated `GenesisNFTFacet` at the `StaticsDiamond` address.

The Diamond becomes the permanent downstream integration point for:

```text
Genesis <-> PositionNFT linkage
Genesis direct rewards
GenesisActivationRegistry callbacks
StaticsFeeReceiver successor distribution
Genesis secured-credit recovery callbacks
Genesis recovery-residual distribution
global STATICS staking multiplier transitions
```

A Genesis may link to exactly one PositionNFT.

A PositionNFT may link to exactly one Genesis.

The owner of both NFTs must be identical when linkage is created.

While linked:

```text
Genesis transfer     -> prohibited
PositionNFT transfer -> prohibited
```

The Genesis remains in the user's wallet.

The PositionNFT remains in the user's wallet.

The Genesis activation multiplier becomes the PositionNFT's global STATICS staking reward multiplier.

For global staking:

```text
raw stake != effective reward weight
```

Instead:

```text
effective reward weight
    = floor(raw stake * multiplierBps / 10,000)
```

The multiplier affects reward distribution only.

It does not increase:

```text
STATICS custody
withdrawable stake
loan collateral
voting weight
principal
credit capacity
BasketToken rewards
LP rewards
Risk Share accounting
```

Genesis activation remains canonical in `GenesisActivationRegistry`.

The Diamond never creates a second activation tier or independent multiplier source of truth.

## StaticsFeeReceiver remains permanent

`StaticsFeeReceiver` is unchanged by this decision.

It remains the permanent ingress contract for Doppler STATICS/WETH launch-market revenue.

This ADR does not change:

```text
Doppler fee collection
market binding
reserve-share routing
WETH unwrap and Genesis reserve donation
cumulative attribution accounting
distributor handoff mechanics
```

The full Statics integration consumes the receiver's existing distributor interface.

The lifecycle is:

```text
launch phase

StaticsFeeReceiver
        |
        v
GenesisLaunchDistributor
```

then:

```text
full Statics phase

same StaticsFeeReceiver
        |
        v
StaticsDiamond / GenesisNFTFacet
```

The object that changes is the active distributor, not the receiver.

Full Statics protocol fees from baskets, lending, Dollar flows, hooks, and other Diamond-native modules continue using the existing protocol fee plumbing. They are not routed through `StaticsFeeReceiver` merely because Genesis integration exists.

## Full-protocol topology

```text
                    StaticsFeeReceiver
                           |
                           | future Doppler attribution
                           v
                    StaticsDiamond
                    GenesisNFTFacet
                    /      |       \
                   /       |        \
                  v        v         v
         Genesis direct   Global     Genesis
            rewards       staking    integration
              |          multiplier     |
              |              |          |
              v              v          v
        registered       PositionNFT   StaticsGenesis
        Genesis NFTs     reward books       |
                                           |
                              GenesisActivationRegistry
```

Secured-credit recovery uses the same integration:

```text
StaticsGenesisVault
        |
        | checkpointGenesisRecovery()
        v
StaticsDiamond
        |
        v
StaticsGenesis.recoverToVault()
        |
        | only if linked
        v
StaticsDiamond.onGenesisRecovery()
```

## Genesis integration storage

The Diamond maintains a bijective Genesis-to-Position relationship:

```solidity
mapping(uint256 genesisId => uint256 positionId) linkedPosition;
mapping(uint256 positionId => uint256 genesisId) linkedGenesis;
```

The required invariant is:

```text
linkedPosition[G] = P
    <=>
linkedGenesis[P] = G
```

A valid link additionally requires:

```text
Genesis.ownerOf(G)
==
PositionNFT.ownerOf(P)
```

No Genesis may boost multiple Positions.

No Position may receive multiple Genesis multipliers.

Genesis multipliers do not stack.

## Genesis Position leg

Genesis linkage is represented as a normal modular Position leg.

Add:

```text
GENESIS_MODULE
```

to `LibPosition`.

Linking activates the Genesis leg.

Unlinking or secured-credit recovery deactivates the Genesis leg.

Conceptually:

```text
PositionNFT
├── global STATICS staking
├── BasketToken collateral
├── loans
├── Dollar state
├── LP positions
└── Genesis leg
        |
        v
     Genesis #123
```

Because a linked Position has an active Genesis leg, ordinary Position closure is incompatible with an active Genesis relationship.

The Position must be unlinked before it can be closed.

## Linking authorization

Only the actual owner may create a Genesis link.

ERC-721 approvals are insufficient.

The caller must satisfy:

```text
Genesis.ownerOf(genesisId) == msg.sender

PositionNFT.ownerOf(positionId) == msg.sender
```

The following do not authorize linkage:

```text
Genesis getApproved()
Genesis operator approval
PositionNFT getApproved()
PositionNFT operator approval
marketplace approvals
transfer-validator approval
```

This prevents an approved marketplace or NFT operator from changing a user's staking economics.

## Linking lifecycle

`linkGenesis(positionId, genesisId)` requires:

```text
Genesis exists
Position exists
same current owner
Genesis has no linked Position
Position has no linked Genesis
full Genesis integration ready
```

An active Genesis secured-credit facility does not prevent linkage.

Credit does not remove beneficial ownership, so a credit-locked Genesis may still be attached to the owner's PositionNFT.

Linking creates a reward-settlement boundary:

1. settle every selected global reward asset under the Position's current multiplier;
2. crystallize all rewards earned under that old multiplier into normal Position claimable balances;
3. read the Genesis multiplier from `GenesisActivationRegistry`;
4. replace the Position's effective eligible and pending reward weight using the same raw stake and the Genesis multiplier;
5. preserve all pending-stake eligibility timestamps and bucket maturity;
6. install the Genesis-to-Position mappings;
7. activate the Genesis Position leg;
8. refresh Genesis ERC-5192 lock state;
9. refresh PositionNFT ERC-5192 lock state; and
10. emit the linkage and multiplier transition.

Linking is prospective.

It may not reprice any completed reward interval.

## Mutual transfer locking

Genesis already treats a nonzero `linkedPosition(genesisId)` as a transfer lock.

Full Statics adds the symmetrical PositionNFT rule.

For an owner-changing PositionNFT transfer:

```text
linkedGenesis(positionId) != 0
    -> revert
```

A linked economic pair therefore cannot split ownership:

```text
Genesis #123
     ||
     || linked
     ||
Position #42

owner(Genesis #123)
=
owner(Position #42)
```

The relationship must first be explicitly removed.

## PositionNFT ERC-5192 signaling

The Statics Diamond exposes ERC-5192 lock discovery for PositionNFTs.

Conceptually:

```text
locked(positionId)
    =
linkedGenesis(positionId) != 0
```

Linking emits `Locked(positionId)`.

Unlinking emits `Unlocked(positionId)`.

This allows wallets, marketplaces, and integrators to discover the transfer restriction without relying on a failed transfer.

## Voluntary unlinking

The common owner may unlink the Genesis from the Position.

ERC-721 approvals do not authorize unlinking.

Unlinking is allowed while Genesis secured credit is active.

If credit remains active:

```text
PositionNFT
    -> becomes independently transferable

Genesis
    -> remains non-transferable because credit is still active
```

Unlinking is a reward-settlement boundary:

1. settle every selected global reward asset under the current Genesis multiplier;
2. crystallize all rewards earned under that multiplier into the Position's normal claimable balances;
3. remove the Position's old effective reward weight;
4. set the Position multiplier to base `1.00x`;
5. install base effective reward weight using the same raw eligible and pending stake;
6. preserve pending-stake eligibility timestamps and bucket maturity;
7. clear both linkage mappings;
8. deactivate the Genesis Position leg;
9. refresh Genesis lock state; and
10. refresh PositionNFT lock state.

Unlinking does not:

```text
unstake STATICS
transfer or automatically claim settled rewards
repay Genesis credit
reset Genesis activation
transfer either NFT
close the Position
modify loans
modify BasketToken collateral
modify LP state
modify Dollar state
```

## Generic global staking multiplier

Global STATICS staking introduces a generic Position-level reward multiplier.

The base multiplier is:

```text
10,000 BPS = 1.00x
```

Genesis activation currently supplies:

```text
Tier 0 -> 10,000 BPS = 1.00x
Tier 1 -> 11,000 BPS = 1.10x
Tier 2 -> 11,500 BPS = 1.15x
Tier 3 -> 12,000 BPS = 1.20x
Tier 4 -> 12,500 BPS = 1.25x
```

Global staking does not contain Genesis-tier logic.

It understands only the Position's current multiplier and a new multiplier supplied through an authorized internal integration path.

Genesis is the initial authorized source of non-base Position multipliers.

There is no public or governance function that arbitrarily sets a Position's multiplier.

## Raw stake versus effective reward weight

Actual STATICS principal remains separately accounted.

For a Position:

```text
raw stake = deposited STATICS
```

For each selected reward asset:

```text
eligibleWeight
    = floor(eligibleStake * multiplierBps / 10,000)

pendingWeight
    = floor(pendingStake * multiplierBps / 10,000)
```

Example:

```text
Alice:
100,000 STATICS
1.00x
=
100,000 reward weight

Bob:
100,000 STATICS
1.25x
=
125,000 reward weight

actual STATICS stake:
200,000

reward denominator:
225,000
```

If 225 units of reward asset are distributed:

```text
Alice -> 100
Bob   -> 125
```

`totalStaked()` continues to report actual deposited STATICS.

It does not report multiplied reward weight.

## Multiplier scope

The Genesis multiplier applies only to global STATICS staking rewards and therefore applies across every reward asset selected by that Position within the existing 64-asset bound.

It does not apply to:

```text
BasketToken position rewards
canonical LP rewards
BasketToken lending collateral
BasketToken loan economics
Dollar Risk liquidity
pairing-vault economics
Genesis direct rewards themselves
```

Genesis direct rewards use their own activation-weighted Genesis denominator.

This separation prevents one multiplier from silently altering unrelated protocol economics.

## Global reward accounting changes

Global reward accounting must track both raw stake and effective reward weight.

Conceptually, each reward book contains:

```text
eligibleStake
pendingStake
eligibleWeight
pendingWeight
```

Each Position selection contains:

```text
eligibleStake
pendingStake
eligibleWeight
pendingWeight
checkpointRay
pendingStartTime
eligibleAt
```

Reward indexes divide by `eligibleWeight`, not raw `eligibleStake`.

Reward settlement multiplies index movement by the Position's effective weight.

## Pending staking buckets

The existing 24-to-25-hour global reward eligibility delay remains unchanged.

Pending staking therefore tracks both pending raw stake and pending effective weight.

The existing hourly bucket structure is extended conceptually to:

```text
pendingStakeBuckets[25]
pendingWeightBuckets[25]
```

When a bucket matures:

```text
raw pending stake
    -> raw eligible stake

pending reward weight
    -> eligible reward weight
```

The reward activation timestamp remains unchanged.

## Reward-weight transitions are settlement boundaries

A multiplier change does not rewrite historical reward accounting.

Instead every multiplier change is an ordinary reward-settlement boundary:

```text
old multiplier
    |
    v
settle all rewards earned at old effective weight
    |
    v
crystallize earned rewards as normal claimable balances
    |
    v
remove old effective weight
    |
    v
install new effective weight from the same raw stake
    |
    v
future rewards accrue at new multiplier
```

For each selected reward asset, at most 64:

1. roll any matured pending buckets;
2. settle all eligible rewards under the current effective weight;
3. crystallize the completed interval into ordinary Position claimable state;
4. synchronize any pending stake that has already matured;
5. remove the Position's old eligible and pending effective weight from aggregate accounting;
6. calculate new eligible and pending effective weight directly from the same raw stake;
7. add the new weight to aggregate accounting;
8. preserve pending eligibility timestamps and bucket maturity; and
9. commit the new Position multiplier.

The implementation must recalculate from raw stake:

```text
newWeight
=
floor(rawStake * newMultiplierBps / 10,000)
```

It must not repeatedly multiply prior effective weight.

Therefore:

```text
1.10x -> 1.15x -> 1.25x
```

produces the same final effective weight as:

```text
1.00x -> 1.25x
```

for the same raw stake.

This avoids cumulative rounding drift.

## Pending stake during multiplier changes

Pending stake is not withdrawn, restarted, or forced to mature when a multiplier changes.

Example:

```text
100,000 STATICS pending
eligible in 8 hours

Genesis multiplier:
1.10x -> 1.25x
```

After settlement and weight replacement:

```text
pending raw stake:
100,000

pending effective weight:
110,000 -> 125,000

eligibleAt:
unchanged
```

The user receives no artificial maturity reset and no retroactive reward capture.

The distinction is:

```text
pending or accrued rewards
    -> settle and crystallize at old multiplier

pending stake
    -> remains pending
    -> same maturity
    -> future weight reflects new multiplier
```

## Activation changes while linked

`GenesisActivationRegistry` remains the source of truth for activation.

Its callback provides the previous and next multiplier.

The Diamond becomes the active activation consumer.

For a registered and linked Genesis, activation performs:

```text
Genesis direct rewards
    -> settle at previous Genesis weight

Position global staking
    -> settle at previous Position multiplier

completed Position rewards
    -> crystallize as normal claims

direct Genesis weight
    -> update to next multiplier

Position effective reward weight
    -> replace with next multiplier
```

Only future reward intervals use the new multiplier.

The registry then commits the new activation tier.

No historical reward interval is repriced.

## Direct Genesis rewards remain distinct

Full Statics preserves direct activation-weighted Genesis rewards as a separate reward rail.

Genesis-to-Position linkage is not required for direct Genesis reward participation.

This preserves the ability for a Genesis holder to receive direct Genesis rewards without opening or using a PositionNFT.

The full distributor therefore preserves explicit O(1) Genesis registration.

Registration requires actual Genesis ownership.

Registration starts at the current full-protocol Genesis reward index and cannot capture historical full-protocol rewards.

A registered Genesis has direct weight equal to `activationRegistry.multiplierBps(genesisId)` while circulating.

A registered vault-held Genesis has direct weight zero.

Registration remains associated with the Genesis token across later ownership changes.

## Historical launch rewards

Historical `GenesisLaunchDistributor` claims are never migrated into the Diamond.

The old distributor remains the canonical source for:

```text
historical crystallized owner claims
historical per-Genesis launch claims
launch-era reward indexes
```

After handoff, it receives no new `StaticsFeeReceiver` attribution.

Full Statics begins a new reward accounting interval for future revenue.

There is no global registration or reward migration batch.

## Full Statics as successor distributor

After handoff:

```text
StaticsFeeReceiver.activeDistributor()
==
StaticsDiamond
```

The Diamond accepts future STATICS and remaining WETH attribution from `StaticsFeeReceiver` and implements the permanent direct Genesis reward rail.

The accepted Genesis-reward-share premise remains downstream policy.

This ADR does not change Doppler collection or reserve routing inside `StaticsFeeReceiver`.

## Storage-only attribution checkpointing

Ordinary Genesis ownership transitions must not depend on pulling arbitrary reward tokens.

The full Genesis distributor therefore preserves the launch distributor's attribution-cursor premise:

```text
cumulative StaticsFeeReceiver attribution
        |
        v
storage-only reward-index checkpoint
        |
        v
later physical token pull
```

An owner-changing Genesis transfer may advance an already-attributed reward index, settle the previous owner, and crystallize liabilities without requiring an ERC-20 transfer during the NFT transfer.

Actual reward claims pull and reserve required custody before paying.

## Genesis reward custody

Once the Diamond becomes the reward distributor, its physical ERC-20 balance is shared with other protocol modules.

Genesis reward custody therefore receives its own accounting domain.

Conceptually:

```text
GENESIS_REWARD_ACCOUNT
=
keccak256("statics.custody.account.genesis.rewards")
```

Reward tokens physically received by the Diamond for Genesis liabilities are reserved to this account.

They may not become:

```text
BasketToken backing
global staking principal
Dollar custody
general unreserved donations
other fee-module liquidity
```

Historical attribution that has been indexed but not yet pulled from `StaticsFeeReceiver` remains an external receivable rather than physical Diamond custody.

When pulled, it is immediately reserved.

## Secured credit while linked

Opening Genesis secured credit does not alter the Position relationship.

Therefore:

```text
open credit
    -> no Position multiplier change

extend credit
    -> no Position multiplier change

repay credit
    -> no Position multiplier change
```

The Genesis continues providing its activation multiplier while the holder remains its beneficial owner.

A holder may link an already credit-active Genesis to an owned Position.

A holder may voluntarily unlink a credit-active Genesis.

## Recovery callback

Secured-credit recovery invokes the protocol callback only when:

```text
linkedPosition(genesisId) != 0
```

The Diamond's `onGenesisRecovery()` is callable only by the canonical `StaticsGenesis` contract.

For a linked Genesis it:

1. resolves the linked Position;
2. verifies that the recorded Position owner equals the recovering Genesis owner;
3. settles every selected global staking reward asset under the Genesis multiplier;
4. crystallizes all completed rewards into the Position's ordinary claimable balances;
5. removes the Position's Genesis-enhanced effective reward weight;
6. installs base `1.00x` effective reward weight using the same raw eligible and pending stake;
7. preserves pending-stake eligibility timestamps and maturity buckets;
8. clears both Genesis-to-Position mappings;
9. deactivates the Genesis Position leg;
10. updates Position lock state; and
11. returns the required recovery acknowledgement.

It does not:

```text
transfer PositionNFT ownership
burn the PositionNFT
unstake STATICS
transfer or automatically claim settled Position rewards
repay loans
modify BasketToken collateral
modify LP positions
modify Dollar legs
clear unrelated claims
```

`StaticsGenesis` then verifies:

```text
linkedPosition(genesisId) == 0
```

before continuing recovery.

## Recovery direct-reward ordering

The complete full-protocol recovery flow is:

```text
StaticsGenesisVault
        |
        | checkpointGenesisRecovery()
        v
StaticsDiamond
        |
        +-> harvest/checkpoint current Genesis revenue
        +-> settle direct rewards for defaulting Genesis
        +-> crystallize direct entitlement to former owner
        |
        v
StaticsGenesis.recoverToVault()
        |
        | if linked
        v
StaticsDiamond.onGenesisRecovery()
        |
        +-> settle Position staking @ old multiplier
        +-> crystallize Position rewards
        +-> replace effective weight with 1.00x
        +-> preserve pending stake maturity
        +-> clear Genesis <-> Position link
        +-> deactivate Genesis Position leg
        |
        v
GenesisActivationRegistry.onGenesisTransfer()
        |
        v
StaticsDiamond.onGenesisTransition()
        |
        +-> settle direct Genesis reward interval
        +-> remove direct Genesis reward weight
        +-> crystallize old-owner entitlement
        |
        v
activation resets
Genesis -> Genesis Vault
        |
        v
credit accounting closes
        |
        +-> unused credit -> former owner
        +-> caller incentive -> recovery caller
        +-> Genesis distribution -> StaticsDiamond
                                      |
                                      v
                              Genesis reward index
```

The recovered Genesis must have zero direct Genesis reward weight before the recovery distribution is indexed.

It therefore cannot receive any portion of its own recovery penalty.

## Recovery with no linked Position

If:

```text
linkedPosition(genesisId) == 0
```

then `onGenesisRecovery()` is not invoked.

Recovery remains independent of Position integration.

Direct Genesis reward settlement and activation-reset behavior still occur through the active reward distributor and activation registry.

This preserves the reduced recovery coupling established by secured credit.

## Full-protocol handoff ceremony

Genesis integration exists in the Diamond before it becomes active.

Linking remains disabled until the full handoff is complete.

The handoff is:

1. deploy and validate `StaticsDiamond` with `GenesisNFTFacet`;
2. configure canonical Genesis, Vault, activation-registry, fee-receiver, treasury, STATICS, and numeraire relationships;
3. propose `StaticsDiamond` as the next `StaticsFeeReceiver` distributor;
4. have the Diamond accept the distributor role;
5. allow `StaticsFeeReceiver` to harvest currently collectable revenue to the previous distributor and migrate any pending Genesis recovery amount;
6. finalize `GenesisLaunchDistributor` reward indexes;
7. propose `StaticsDiamond` as `GenesisActivationRegistry` consumer;
8. have the Diamond accept the activation-consumer role;
9. bind `StaticsGenesis.protocol()` to `StaticsDiamond`;
10. verify the full Genesis integration; and
11. enable new full-protocol Genesis registration and Position linking.

During a temporary handoff interval where the active fee distributor is the Diamond but the active activation consumer is not yet the Diamond, `genesisRecoveryReady()` remains false.

Accordingly:

```text
new Genesis credit origination -> unavailable
Genesis recovery               -> unavailable
Genesis credit repayment       -> available
```

This preserves the secured-credit handoff safety model.

## Integration readiness

The Diamond exposes two conceptually distinct readiness states.

Recovery-distributor readiness requires:

```text
feeReceiver.activeDistributor() == StaticsDiamond

activationRegistry.activeConsumer() == StaticsDiamond
```

Position-link readiness additionally requires:

```text
genesis.protocol() == StaticsDiamond
```

This prevents Position linkage before the full protocol relationship is installed.

## Future facet upgrades

Once `StaticsDiamond` becomes the active distributor and activation consumer, future governed facet upgrades do not change the integration address.

Therefore:

```text
StaticsFeeReceiver.activeDistributor()
GenesisActivationRegistry.activeConsumer()
StaticsGenesis.protocol()
```

may all remain permanently pointed at the same Diamond while the implementation is upgraded through ordinary pre-immutability Diamond governance.

No reward-distributor rotation is required merely to update `GenesisNFTFacet`.

## Storage compatibility

Global staking storage must distinguish pre-feature base-weight positions from post-feature multiplied positions without requiring an unbounded migration.

Before Genesis multipliers exist, every staking Position is economically `1.00x`.

The implementation may therefore use bounded lazy initialization.

For each reward book on first post-upgrade touch:

```text
eligibleWeight = eligibleStake
pendingWeight = pendingStake

for each of 25 buckets:
    pendingWeightBucket[i] = pendingStakeBucket[i]
```

For each Position selection on first post-upgrade touch:

```text
eligibleWeight = eligibleStake
pendingWeight = pendingStake
```

For each Position:

```text
stored multiplier == 0
    -> interpreted as 10,000 BPS
```

Any new storage fields must be appended in a storage-compatible manner or introduced under an explicitly versioned namespaced layout.

No implementation may silently reorder existing struct fields.

The migration path must remain bounded per touched reward asset and Position.

No global Position or reward-asset iteration is permitted.

## Required external surface

The full integration should expose at minimum the semantic equivalents of:

```text
genesisCollection()

linkGenesis(positionId, genesisId)
unlinkGenesis(positionId, genesisId)

linkedPosition(genesisId)
linkedGenesis(positionId)

registerGenesis(genesisId)
genesisRegistered(genesisId)
genesisRewardWeight(genesisId)

positionRewardMultiplierBps(positionId)

pendingGenesisRewards(genesisId, asset)
claimGenesisRewards(genesisId, asset, receiver)
claimGenesisOwnerRewards(asset, receiver)

acceptGenesisDistributorRole()
acceptGenesisActivationConsumerRole()

 genesisRecoveryCallback()
onGenesisRecovery(genesisId, previousOwner)

checkpointGenesisRecovery(genesisId, expectedOwner)
accrueGenesisRecovery(amount)
migratePendingGenesisRecovery(successor)
acceptPendingGenesisRecovery(amount)

genesisRecoveryVault()
genesisRecoveryAsset()
genesisRecoveryReady()

genesisIntegrationReady()
```

Exact ABI organization may differ, but these semantic capabilities are required.

## Views

Global reward views must distinguish actual stake from effective reward weight.

`StakePositionView` should expose the semantic equivalent of:

```text
stakedBalance
rewardMultiplierBps
claimAssetCount
optedInAssetCount
```

Reward-asset and Position-selection views should expose:

```text
eligibleStake
eligibleWeight
pendingStake
pendingWeight
eligibleAt
```

The frontend must be able to display:

```text
STATICS staked:       100,000
Genesis multiplier:     1.25x
Effective weight:     125,000
```

without reconstructing protocol accounting offchain.

## Required invariants

Implementation and verification must establish at minimum:

1. `linkedPosition[G] == P` if and only if `linkedGenesis[P] == G`.
2. A linked Genesis and PositionNFT always have the same owner.
3. One Genesis cannot link to multiple Positions.
4. One Position cannot link to multiple Genesis NFTs.
5. A linked Genesis cannot transfer.
6. A linked PositionNFT cannot transfer.
7. A linked Position cannot close.
8. Genesis linkage does not transfer custody of either NFT.
9. Genesis linkage cannot capture historical Position rewards.
10. Genesis activation cannot retroactively reprice a completed Position reward interval.
11. Every multiplier change settles and crystallizes the completed reward interval before effective weight changes.
12. Raw STATICS stake is unchanged by multiplier changes.
13. `totalStaked()` remains actual STATICS principal.
14. Effective weight is derived from raw stake and the current multiplier.
15. Repeated multiplier transitions do not compound rounding errors.
16. Multiplier changes do not reset pending staking maturity.
17. Pending raw stake and pending effective weight mature in the same eligibility bucket.
18. A Genesis multiplier affects only global STATICS staking.
19. Genesis direct reward weight remains separate from Position staking weight.
20. A registered vault-held Genesis has zero direct reward weight.
21. An owner-changing Genesis transfer crystallizes the previous owner's direct rewards.
22. Historical launch claims remain claimable after handoff.
23. No new fee-receiver revenue accrues to `GenesisLaunchDistributor` after handoff.
24. Pending Genesis recovery value migrates exactly during distributor handoff.
25. Opening Genesis credit does not alter Position multiplier or linkage.
26. Extending Genesis credit does not alter Position multiplier or linkage.
27. Repaying Genesis credit does not alter Position multiplier or linkage.
28. Voluntary unlinking during active credit removes the Position boost but leaves the credit intact.
29. Linked credit recovery settles and crystallizes every affected Position reward asset before removing the multiplier.
30. Recovery preserves Position ownership.
31. Recovery preserves all unrelated Position ledger state.
32. Recovery clears both Genesis-to-Position mappings.
33. Recovery deactivates only the Genesis Position leg.
34. Recovery preserves pending-stake eligibility timestamps while replacing its effective weight with base weight.
35. The recovered Genesis has zero direct reward weight before its recovery distribution is indexed.
36. A recovered Genesis cannot earn its own recovery distribution.
37. Unlinked Genesis recovery does not depend on the protocol callback.
38. Genesis reward custody cannot be consumed by unrelated Diamond modules.
39. No lifecycle operation requires iteration over all Genesis NFTs.
40. No lifecycle operation requires iteration over all PositionNFTs.
41. Position multiplier work is bounded by the existing 64 selected global reward assets.
42. Pending-bucket multiplier work remains bounded by the existing fixed hourly bucket count.
43. `StaticsFeeReceiver` behavior and accounting remain unchanged by this integration.

## Required tests

At minimum, add real-flow coverage for:

```text
Tier-0 Genesis
    -> link Position
    -> 1.00x remains
```

```text
Tier-4 Genesis
    -> link Position with mature stake
    -> old rewards settle at 1.00x
    -> completed rewards become claimable
    -> future rewards use 1.25x
```

```text
linked Genesis
    -> activate to higher tier
    -> old interval settles and crystallizes
    -> future interval uses new multiplier
```

```text
linked Genesis
    -> pending STATICS stake
    -> activate tier
    -> pending weight changes
    -> eligibleAt unchanged
```

```text
linked Genesis
    -> attempt Genesis transfer
    -> revert
```

```text
linked Genesis
    -> attempt PositionNFT transfer
    -> revert
```

```text
linked Genesis
    -> attempt Position close
    -> revert
```

```text
unlink
    -> settle boosted rewards
    -> crystallize claims
    -> multiplier returns to 1.00x
    -> pending stake keeps same maturity
    -> both NFTs independently transferable unless another lock applies
```

```text
registered but unlinked Genesis
    -> continues direct Genesis rewards
```

```text
registered Genesis transfer
    -> old owner reward crystallization
    -> activation reset
    -> new owner future weight = 1.00x
```

```text
credit-active linked Genesis
    -> open
    -> extend
    -> repay
    -> Position multiplier unchanged
```

```text
credit-active linked Genesis
    -> permissionless recovery
    -> boosted Position rewards settled and crystallized
    -> Position multiplier returns to 1.00x
    -> pending stake maturity unchanged
    -> link cleared
    -> unrelated Position state preserved
```

The recovery Position should contain realistic unrelated state such as:

```text
STATICS stake
BasketToken collateral
open loan
selected reward assets
LP position or claim state
```

and prove those remain unchanged.

Also test:

```text
unlinked credit recovery
    -> Diamond callback not called
```

and:

```text
linked credit recovery
    -> callback acknowledges but fails to clear link
    -> complete recovery reverts
```

The latter already exists at the standalone boundary and should also be exercised against the real Diamond.

## Reward multiplier fuzzing

Fuzz across:

```text
raw stake
all five Genesis multiplier tiers
pending / mature stake mixtures
1 to 64 selected reward assets
multiple activation transitions
stake increase
stake decrease
full unstake
opt-in
opt-out
link
unlink
relink
```

Verify:

```text
raw accounting conservation
aggregate reward-weight conservation
no historical reward capture
no multiplier rounding drift
settled claims preserved across weight changes
claimable <= indexed reward liabilities
```

## Formal-verification targets

The Genesis formal-verification suite should eventually prove:

```text
Position effective weight
=
floor(raw eligible stake * multiplier / 10,000)
```

for every selected reward book after synchronization.

It should also prove recovery conservation and post-recovery isolation:

```text
linked Genesis recovery
    ->
Position owner unchanged
raw Position stake unchanged
completed boosted rewards crystallized
Genesis multiplier removed
Genesis link removed
unrelated Position legs unchanged
```

and:

```text
recovered Genesis direct weight == 0
before recovery residual index increases
```

## Deployment changes

Fresh full-protocol deployment must install `GenesisNFTFacet` and its selectors.

The deployment configuration must bind:

```text
StaticsGenesis
StaticsGenesisVault
GenesisActivationRegistry
StaticsFeeReceiver
canonical treasury
```

and validate their cross-reported relationships.

The fresh `StaticsDiamond` facet and selector counts must be updated.

Production deployment must not enable Genesis linking until the handoff ceremony has completed successfully.

## Documentation changes

When implementation lands, update `Statics-Design.md` so that:

- Genesis appears as an optional PositionNFT leg;
- PositionNFT transferability explicitly excludes Genesis-linked Positions;
- global staking distinguishes raw stake from effective reward weight;
- multiplier changes are documented as reward-settlement boundaries;
- Genesis activation describes its Position staking multiplier;
- the full Genesis reward handoff replaces the temporary launch-distributor description;
- `StaticsFeeReceiver` is identified as permanent ingress while the distributor changes from `GenesisLaunchDistributor` to `StaticsDiamond`; and
- secured-credit recovery describes the concrete Diamond callback rather than a future integration requirement.

## Out of scope

This ADR does not add:

```text
changes to StaticsFeeReceiver
multiple Genesis NFTs per Position
one Genesis boosting multiple Positions
stackable multiplier sources
governance-assigned arbitrary Position multipliers
Genesis boosts to BasketToken rewards
Genesis boosts to LP rewards
Genesis boosts to Dollar Risk rewards
revolving Genesis credit
Genesis custody inside the Diamond
automatic Position creation during Genesis linking
migration of historical launch claims into the Diamond
```

Any of these requires a separate decision.

## Rejected alternatives

### Change StaticsFeeReceiver for full Statics

Rejected.

The receiver is already the permanent launch-market ingress and already supports distributor rotation. Full Statics changes the active downstream distributor, not the receiver.

### Keep raw stake and reward weight identical

Rejected.

Genesis activation cannot provide a staking multiplier without corrupting the distinction between deposited STATICS principal and reward-distribution weight.

### Multiply rewards only at claim time

Rejected.

The reward index denominator must account for boosted Positions when revenue is distributed. Claim-time multiplication would create unbacked reward liabilities.

### Mutate historical reward weight in place

Rejected.

Every multiplier transition instead settles and crystallizes the completed reward interval before replacing effective weight for future accrual.

### Restart pending-stake maturity after a multiplier change

Rejected.

Changing reward weight is not a new deposit and must not erase already-earned eligibility time.

### Withdraw pending stake during a multiplier change

Rejected.

Pending stake is principal awaiting reward eligibility, not pending reward income. It remains staked with the same maturity while its effective future weight changes prospectively.

### Add Genesis-specific branches throughout global staking

Rejected.

Global staking should support a generic Position reward multiplier. Genesis supplies that multiplier through a narrow integration boundary.

### Let Genesis and PositionNFT transfer independently while linked

Rejected.

Ownership could diverge while the Position retained another holder's Genesis benefit.

### Automatically transfer both NFTs together

Rejected.

This would create coupled ERC-721 transfer behavior, marketplace complexity, approval ambiguity, and unnecessary external calls.

Explicit unlinking is simpler.

### Permit ERC-721 operators to link or unlink

Rejected.

Marketplace approvals should not grant authority to alter staking economics.

### Apply Genesis multiplier to every Position reward rail

Rejected.

Basket rewards, LP rewards, Dollar Risk accounting, and global STATICS staking use distinct economic denominators.

This ADR changes only global STATICS staking.

### Migrate launch-distributor claims into the Diamond

Rejected.

Historical launch claims already have a canonical accounting system and can remain pull-based indefinitely.

### Require a global Genesis registration migration

Rejected.

A 5,555-token handoff batch would create an unnecessary liveness boundary.

Full-protocol registration remains O(1) and begins prospectively.

### Move Genesis into Diamond custody while linked

Rejected.

The Genesis remains a user-held ERC-721. Link state and mutual transfer locks provide the required relationship without creating another custody system.

### Compound prior effective weight when tiers change

Rejected.

Every effective weight is recalculated from raw stake and the current multiplier to avoid cumulative rounding drift.

### Make the Diamond recovery callback mandatory for every Genesis

Rejected.

Unlinked Genesis recovery has no Position state to settle and should remain independent of the Diamond callback.
