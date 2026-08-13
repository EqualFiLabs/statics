# ADR: Genesis Tokenomics and Expanded Swap Revenue

- Status: Accepted and implemented for clean-break deployment
- Date: 2026-08-12
- Scope: STATICS supply, Genesis NFTs, PositionNFT staking weight, transfer
  settlement, canonical swap-fee allocation, creator rewards, StonkBrokers
  distribution, and treasury revenue

## Context

Statics routes protocol revenue to users who supply liquidity, deposit
BasketTokens, and stake STATICS through PositionNFTs. The current implementation
uses an uncapped owner-mintable testnet staking token and a five-way canonical
swap-fee split. Those choices are suitable for integration testing but do not
define the intended launch tokenomics.

The launch model needs a scarce distribution layer without limiting the
scalable PositionNFT account system. It also needs a permanent STATICS sink,
an incentive for useful basket creation, and an explicit strategic-partner
allocation while preserving activity-funded rewards rather than token
emissions.

Genesis NFTs and PositionNFTs solve different problems:

- a Genesis NFT is a scarce launch and staking-enhancement asset; and
- a PositionNFT is a transferable financial portfolio containing stake,
  rewards, baskets, loans, liquidity, Statics Dollar positions, assets, and
  liabilities.

One PositionNFT can already contain several basket legs, loan tranches,
liquidity positions, and Dollar series while selecting up to 64 global reward
assets. A Genesis NFT therefore does not need to enhance several PositionNFTs
simultaneously to support a multi-strategy portfolio.

## Decision

Statics will replace the testnet tokenomics with:

1. a fixed-supply STATICS launch distributed through 5,555 Genesis NFTs;
2. sequential Genesis activation tiers purchased by permanently burning
   STATICS;
3. a one-to-one optional link between one Genesis NFT and one PositionNFT;
4. Genesis-enhanced effective weight inside the existing global reward indexes;
5. transfer-time reward settlement into pull-based previous-owner credits; and
6. a seven-way canonical swap-fee split supporting StonkBrokers and index
   creators.

Genesis ownership never gates protocol access. Users without a Genesis NFT can
create and transfer PositionNFTs, stake STATICS, use baskets, lend, borrow,
provide liquidity, interact with Statics Dollar, and earn ordinary protocol
rewards.

## STATICS supply and distribution

STATICS has a fixed supply of exactly one billion tokens and no continuing
emissions. The working Genesis allocation is:

```text
5,555 Genesis NFTs * 180,018 STATICS = 999,999,990 STATICS
```

The 10-token arithmetic remainder stays in treasury unless the separate launch
distribution specification assigns it differently. No owner, governance,
emission controller, or other authority may mint additional STATICS.

Each Genesis NFT represents one fixed launch allocation. The exact Anvil
distribution, claim timing, custody, and unclaimed-allocation treatment will be
specified separately before implementation. Those launch mechanics must not
introduce continuing mint authority after the fixed distribution is complete.

Every activation burn reduces total supply permanently. Statics does not use
STATICS emissions to fund rewards; protocol activity funds rewards in the
assets actually collected.

## Genesis collection and activation

The Genesis collection has a fixed maximum supply of 5,555 ERC-721 tokens.
Genesis activation progresses sequentially:

```text
Unactivated -> Tier 1 -> Tier 2 -> Tier 3 -> Tier 4
```

Genesis receives the deterministic onchain SVG renderer formerly associated
with PositionNFTs. Genesis metadata includes activation tier and refreshes on
activation and owner-changing transfer. PositionNFT metadata is reduced to
minimal onchain financial-account JSON with no image or replaceable renderer.

Fresh deployment mints IDs 1 through 5,555 to treasury before the Diamond
exists. The collection records its actual constructor caller as a temporary
bootstrap binder. That address may bind the collection to one deployed
protocol exactly once, after which the binder is deleted and transfers become
available subject to the protocol hook.

An unactivated Genesis NFT provides no staking boost. Each transition requires
the current owner to burn the configured amount of STATICS. A holder may cross
several tiers in one transaction by burning the cumulative current cost of
every transition crossed.

For example, activating from Tier 1 through Tier 4 costs:

```text
cost(Tier 1 -> Tier 2)
+ cost(Tier 2 -> Tier 3)
+ cost(Tier 3 -> Tier 4)
```

The activation call includes a caller-selected maximum burn amount and reverts
if the current cumulative cost exceeds that bound. Activation is atomic: the
complete burn and every linked-position reward update succeed together or no
state changes.

The implemented multipliers are 1.10x, 1.15x, 1.20x, and 1.25x. Transition
costs default to 10,000, 20,000, 30,000, and 40,000 STATICS. The timelock may
configure a future transition cost from 1,000 through 100,000 STATICS.
Configuration changes affect future activation only. Governance cannot change
earned tier, reprice or refund a completed burn, change the tier multipliers,
or increase a past reward claim.

## Activation reset on Genesis transfer

Activation rewards continued ownership rather than permanently capitalizing
every prior holder's burns into the NFT.

A Genesis NFT cannot transfer while linked to a PositionNFT. Its owner must
unlink it first. Any actual owner-changing Genesis transfer resets its tier to
`Unactivated`; the recipient must burn STATICS to activate it again. Repeated
secondary-market transfers can therefore create repeated STATICS burn demand
by design.

Approval does not reset activation. Unlinking and rebinding under unchanged
ownership do not reset activation. No marketplace, escrow, or beneficial-owner
exemption bypasses the onchain owner-changing transfer rule.

## One-to-one PositionNFT linking

The registry permits:

```text
one Genesis NFT <-> at most one PositionNFT
one PositionNFT <-> at most one Genesis NFT
```

The same address must own both NFTs when linking and must remain their common
owner while the link exists. Multipliers never stack on one PositionNFT.

The registry stores both directions using unambiguous existence encoding:

```text
Genesis token ID -> linked PositionNFT ID
PositionNFT ID   -> linked Genesis token ID
```

Linking an unactivated Genesis is permitted but produces ordinary 1.00x weight
until Tier 1 is activated. Linking creates no STATICS stake and no reward claim.

### Link

Linking performs the following bounded transition over the PositionNFT's
selected global reward assets:

1. verify common ownership and unused registry entries;
2. settle each selection through its current reward index using its old
   registered weight;
3. replace the old denominator weight with the weight derived from the current
   Genesis tier; and
4. record the bidirectional link; and
5. leave every pending-stake maturity schedule unchanged.

### Unlink

Unlinking:

1. settles each selected asset using the current Genesis-enhanced weight;
2. advances its reward checkpoint;
3. replaces boosted denominator weight with ordinary 1.00x weight; and
4. clears both registry entries.

An activated Genesis may then be linked to a different PositionNFT owned by the
same address without resetting its tier.

## Effective STATICS staking weight

Genesis utility changes reward weight, not token ownership:

```text
effective eligible weight
    = eligible STATICS stake * linked Genesis multiplier
```

The user still owns and may withdraw only the actual STATICS deposited in the
PositionNFT. The multiplier creates no tokens, enlarges no fee allocation, and
only changes the linked position's proportional share of an existing
STATICS-staker allocation.

The existing 24-to-25-hour eligibility system remains authoritative:

- pending stake contributes no reward weight;
- linking or activation cannot mature pending stake early;
- a multiplier applies immediately to stake that is already eligible; and
- when pending stake matures, it enters the denominator at the multiplier then
  active for that PositionNFT.

There is no additional link, relink, or multiplier eligibility delay.

## Monotonic indexes and weight transitions

Each selected reward asset keeps its existing cumulative 1e27 reward index.
Fee accrual uses total effective eligible weight as its denominator:

```text
index increase
    = staker fee * 1e27 / total effective eligible weight
```

Before any link, unlink, tier, stake, or ownership transition changes a
position's effective weight, the protocol:

1. settles the completed index interval using the previously registered
   effective weight;
2. advances the position checkpoint to the current index;
3. removes the old effective weight from the reward-book denominator; and
4. adds the new effective weight for subsequent index increases.

The global index remains monotonic. A new multiplier never applies
retroactively to an index interval accumulated under the old multiplier.

Reward books expose permissionless checkpointing in bounded batches of up to
eight assets. A mandatory multi-asset transition reverts with the first stale
book instead of rolling unrelated global maturity buckets inside the owner
transaction. Anyone may checkpoint the reported asset batches and retry. This
keeps each maintenance transaction below the 16 million gas cap without
changing eligibility or reward ownership.

When a linked Genesis advances one or several tiers, the activation transaction
settles its one linked PositionNFT under the old tier before installing the new
tier and effective weight. The existing 64-asset PositionNFT selection bound
also bounds this transition.

## PositionNFT transfer settlement

A PositionNFT continues to transfer its portfolio, including:

- actual staked STATICS and reward-asset selections;
- basket collateral and loans;
- Statics Dollar legs and liabilities;
- custodied liquidity positions; and
- all other attached assets, rights, and obligations unless a module explicitly
  defines a transfer boundary.

The previous owner's Genesis multiplier and global rewards earned before the
transfer do not transfer.

For an actual owner-changing PositionNFT transfer, the transfer hook performs
accounting before changing ownership:

1. settle every selected global reward asset using the previous registered
   weight;
2. move all crystallized global rewards from the PositionNFT into credits owned
   by the previous owner;
3. advance the reward checkpoints and clear those PositionNFT claimables;
4. replace boosted denominator weight with ordinary 1.00x weight;
5. clear any Genesis link; and
6. transfer the PositionNFT with its remaining portfolio.

The recipient begins future index intervals at ordinary weight and may later
link an activated Genesis NFT that they own.

An approved operator or marketplace may initiate the PositionNFT transfer, but
the reward credits always belong to the previous onchain owner. Minting,
burning, and same-owner transfers use their appropriate lifecycle rules rather
than pretending to be an owner-changing sale.

## Previous-owner reward credits

PositionNFT transfer performs no arbitrary ERC-20 reward delivery. It records
address-level, per-asset credits instead:

```text
positionTransferRewardCredit[previousOwner][asset] += settled amount
```

Credits:

- support EOAs, Safes, and contract owners;
- aggregate across transferred PositionNFTs;
- remain fully reserved in Diamond fee custody;
- never expire;
- cannot be redirected or confiscated by governance;
- are unaffected by later PositionNFT or Genesis transfers; and
- may be pulled later by the credited owner to a nonzero receiver they choose.

A failed withdrawal leaves the credit unchanged. Users may withdraw assets
separately, so one paused, blocklisting, reverting, taxed, or otherwise
incompatible token cannot block PositionNFT transfer or withdrawal of another
asset.

## Canonical swap fees

Canonical Statics pools continue to use zero native Uniswap v4 LP fees and
separate Statics hook fees on realized input and output legs. The current
intended default rates remain 50 BPS on input and 50 BPS on realized output.

The default allocation is replaced with the following seven-way split:

| Recipient | Allocation |
| --- | ---: |
| Locked liquidity | 10% |
| Eligible canonical LPs | 20% |
| Deposited BasketToken positions | 20% |
| Eligible STATICS stakers | 15% |
| StonkBrokers | 10% |
| Index creator | 5% |
| Statics treasury | 20% |
| **Total** | **100%** |

"Locked liquidity" is the existing hook-owned permanent full-range liquidity,
also referred to as permanent protocol-owned liquidity. Governance may tune the
complete seven-way configuration globally and through full pool-specific
overrides. Every effective allocation must total exactly 10,000 BPS.

This seven-way decision supersedes the five-way 10%/25%/25%/15%/25% launch
split documented in earlier ADRs. It does not supersede their custody,
eligibility, liquidity-position, index, decommissioning, or donation-hardening
decisions.

## Swap-allocation fallbacks

Unavailable allocations resolve deterministically:

```text
no eligible canonical LPs        -> locked liquidity
no eligible BasketToken stake    -> locked liquidity
no eligible STATICS stake        -> Statics treasury
no index creator                 -> Statics treasury
no configured partner recipient  -> Statics treasury
```

Treasury receives allocation and division dust. Fallbacks do not create a
claim for an unavailable class and do not change another class's configured
percentage for future swaps.

Governance-created pools have no index creator or basket-staker book. Their
creator allocation routes to treasury and their BasketToken-staker allocation
routes to locked liquidity. Their other allocations follow the same rules as
basket canonical pools.

## Index creator rewards

The address recorded as creator during basket creation is that basket's index
creator and receives the creator allocation from every associated canonical
pool. Creator identity provides no basket administration, constituent control,
fee-setting authority, upgrade authority, or other privilege.

Creator rewards are pull-based internal credits:

```text
creatorRewardCredit[creator][asset] += creator allocation
```

No creator token transfer occurs during swap settlement. Credits aggregate by
creator and asset across every basket created by that address, never expire,
remain reserved in Diamond custody, and cannot be seized or redirected by
governance. The credited creator may later withdraw selected assets to a
nonzero receiver. A failed withdrawal leaves the credit intact.

Creator identity and credits do not transfer with BasketTokens, PositionNFTs,
Genesis NFTs, or secondary ownership of another protocol object.

Basket creation continues to charge its separately configured native creation
fee. That fee routes 100% to the Statics treasury. The protocol therefore earns
immediate creation revenue while a creator earns recurring revenue only if
their basket generates future swaps.

## StonkBrokers allocation and permissionless distribution

StonkBrokers is the initial strategic partner. Its allocation accrues per asset
in an isolated internal ledger:

```text
partnerAccrued[currentRecipient][asset] += partner allocation
```

No partner token transfer occurs during swap settlement. Anyone may invoke a
recipient-and-asset distribution function. The recipient identifies the
governance-set address whose accrual was snapshotted when fees routed; changing
the current partner does not redirect historical accrual.

For one distribution:

```text
gross partner accrual = partnerAccrued[recipient][asset]
caller tip            = gross partner accrual * distributionTipBps / 10,000
partner payment       = gross partner accrual - caller tip
```

The caller tip comes exclusively from the StonkBrokers allocation. The initial
default is 1% of distributed partner accrual, equivalent to 0.1% of total swap
fees at a 10% partner allocation. This default may be reduced before mainnet.
Governance may configure the tip up to a maximum of 5% of partner accrual.

Distribution is permissionless and processes one asset at a time. A zero
accrual returns zero. Successful distribution clears the processed accrual,
pays the tip to the caller, pays the remainder to the fixed partner, and emits
the asset, gross amount, caller, tip, recipient, and net amount. A failed token
transfer reverts without clearing accrual.

If no valid partner recipient is configured when a swap allocation is routed,
the partner share accrues to treasury instead of becoming an orphaned partner
liability.

## Non-swap fee routing

This decision does not change the default non-swap fee policy:

```text
90% -> eligible selected STATICS stake
10% -> Statics treasury
```

If an asset has no eligible selected STATICS weight, its complete non-swap fee
routes to treasury. Basket minting, redemption, lending, flash loans, Statics
Dollar operations, and other sources continue to use their existing typed fee
routes unless a later decision explicitly changes them.

## Custody and execution boundaries

Partner accrual, creator credits, previous-owner transfer credits, STATICS
reward claims, LP claims, basket-staker claims, and treasury accrual are
separate liabilities over the shared fee custody reservation. Each route must
update its internal liability before any external transfer and may debit only
its own recorded amount.

Swap execution must not call creator or partner recipients. PositionNFT
transfer must not call arbitrary reward tokens. Pull-based withdrawal and
permissionless partner distribution isolate incompatible token behavior from
the critical swap and ERC-721 transfer paths.

All withdrawals use measured custody transfers, reentrancy protection, and
caller-supplied minimum received amounts where the receiver controls execution.
A failed external transfer must restore the complete internal credit or accrual
through transaction reversion.

## Governance boundaries

While Statics remains upgradeable, the timelock may configure:

- future tier-transition burn costs;
- the global and pool-specific seven-way swap splits totaling 10,000 BPS;
- the StonkBrokers recipient; and
- the partner distribution tip within its cap.

Governance cannot:

- mint STATICS after fixed launch distribution;
- restore burned STATICS;
- change the implemented tier multipliers;
- downgrade an earned tier except through the mandatory reset caused by a
  Genesis ownership transfer;
- transfer or seize creator credits, previous-owner reward credits, or partner
  accrual outside their defined routes; or
- make Genesis ownership a requirement for ordinary protocol use.

Final parameter defaults and bounds must be recorded in the release
qualification and deployment manifests before mainnet.

## Consequences

- STATICS becomes a fixed-supply, activity-funded revenue-sharing token.
- Genesis scarcity, burn-funded activation, and transfer resets create a
  recurring deflationary incentive without restricting protocol access.
- One-to-one linking bounds every activation and transfer-time reward update to
  one PositionNFT and at most 64 selected assets.
- A PositionNFT remains a broad transferable portfolio, but prior-owner global
  rewards and Genesis multipliers do not transfer with it.
- Pull-based credits keep arbitrary ERC-20 behavior out of PositionNFT transfer
  and canonical swap execution.
- Index creators receive performance-linked revenue while the protocol keeps
  100% of the upfront creation fee.
- StonkBrokers distribution has an explicit permissionless liveness incentive.
- Earlier five-way swap-split documentation is superseded by this decision.
- The existing owner-mintable testnet STATICS token, public testnet deployment,
  and five-way hook configuration are historical integration fixtures, not
  compatibility requirements for the greenfield release.

## Deferred parameters and mechanics

The following launch choices remain deferred to release qualification:

- Anvil distribution, claims, custody, and unclaimed Genesis allocations;
- final basket creation fee;
- final StonkBrokers tip default before mainnet.

Deferred parameter selection does not reopen the accepted architectural
decisions: fixed supply, no emissions, no unactivated boost, sequential
burn-funded tiers, transfer reset, one-to-one linking, effective-weight index
accounting, pull-based credits, the seven recipient classes, and
permissionless tipped partner distribution.

## Superseded alternatives

Statics will not implement:

- Genesis-gated protocol access or basket-creation rights;
- a baseline boost for an unactivated Genesis NFT;
- one Genesis boosting several PositionNFTs simultaneously;
- several Genesis multipliers stacking on one PositionNFT;
- permanent activation surviving Genesis transfer;
- multiplier application after reward allocation rather than inside the
  effective-weight denominator;
- retroactive multiplier application to completed index intervals;
- token emissions to fund staking rewards;
- inline reward-token delivery during PositionNFT transfer; or
- push-based creator or partner transfers during swap execution.
