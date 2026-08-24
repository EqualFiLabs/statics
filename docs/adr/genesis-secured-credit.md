# ADR: Genesis secured credit against fixed STATICS backing

- Status: Proposed
- Date: 2026-08-23
- Scope: Genesis secured credit, partial access to isolated STATICS backing, reserve-capitalizing native origination and extension service fees, continued Genesis rewards while encumbered, fixed-term extension, permissionless incentivized recovery, and recovery-surplus distribution
- Amends: `genesis-reserve-backed-vault.md`
- Extends: the self-backed credit lifecycle established by Position-owned BasketToken lending
- Preserves: 5,555 fixed Genesis supply, 180,000 STATICS gross backing per circulating Genesis, fixed 1,000,000,000 STATICS supply, post-epoch native ETH reserve rights, activation multipliers, transfer-reset activation, post-epoch reserve buy-in, permanent reserve accounting, and ordinary Genesis acquisition and redemption

## Context

Each circulating Genesis NFT currently represents:

```text
180,000 STATICS
+
1 / 5,555 of the permanent native ETH reserve
```

The accepted Genesis Vault design isolates 180,000 STATICS for every circulating Genesis and allows that backing to leave only through ordinary Genesis redemption.

The existing ADR therefore states that Genesis STATICS backing may never be borrowed or lent.

Statics already has a self-backed credit model through BasketToken lending. Deposited BasketTokens remain productive while locked, release a bounded portion of their represented underlying assets, maintain fixed principal rather than price-based debt, support repeated paid extensions, and resolve unpaid positions through permissionless recovery without an oracle-priced liquidation.

Genesis can apply the same principle more directly.

A Genesis has a deterministic 180,000-STATICS backing amount. Secured credit can therefore release up to 95% of that backing without consulting:

```text
STATICS / USD price
Genesis marketplace price
ETH price
NFT floor price
TWAP
external oracle
liquidation auction
```

Principal and backing are denominated in the same asset.

The credit facility is not intended to make Genesis economically inactive. The holder remains the beneficial owner while credit is outstanding and continues receiving the Genesis benefits and privileges that would apply if the credit did not exist.

The protocol charges native service fees for opening and extending this secured-liquidity state. No additional STATICS principal accrues as a function of time.

## Decision summary

For:

```text
P = 180,000 STATICS gross Genesis backing

MAX_CREDIT_BPS = 9,500

M = P * 95%
  = 171,000 STATICS

H = P - M
  = 9,000 STATICS
```

a post-epoch Genesis owner may open one secured-credit facility against the NFT.

The owner selects:

```text
0 < principal <= 171,000 STATICS
```

and pays the configured native origination service fee.

Each origination and extension service fee uses the current governed split:

```text
10% -> permanent Genesis ETH reserve backing
90% -> canonical Statics treasury
```

The percentages are configurable through the authorized Statics
administration/governance path, must always total 100%, and do not change either
destination.

The Genesis remains owned by the user but becomes non-transferable while the facility is active.

The vault releases the selected STATICS principal from that Genesis's isolated backing.

The credit lifecycle is:

```text
open
    |
    v
fixed maturity
    |
    +--> repay principal
    |       |
    |       v
    |   credit closes
    |   Genesis unlocks
    |
    +--> accept current extension service fee
    |       |
    |       v
    |   maturity += one service term
    |       |
    |       +--> may repeat
    |
    +--> maturity + grace expires
            |
            v
      permissionless recovery
```

Opening, extending, or repaying secured credit does not reset Genesis activation, remove reward eligibility, remove the activation multiplier, withdraw ETH reserve backing, or transfer ownership.

Recovery ends beneficial ownership. The fixed 9,000-STATICS recovery residual
pays a configured incentive to the permissionless caller and routes the
remainder through the existing activation-weighted Genesis STATICS fee index.

## Post-epoch availability

Genesis secured credit is unavailable during the Genesis Epoch.

While:

```text
block.timestamp < genesisEpochEnd
```

the existing acquisition and redemption rules remain unchanged and Genesis backing cannot be accessed through secured credit.

This preserves the Genesis Epoch's intended early-capital commitment.

Without this restriction, an epoch participant could:

```text
acquire Genesis for 180,000 STATICS
        |
        v
release up to 171,000 STATICS
        |
        v
reuse released STATICS for another epoch acquisition
```

while simultaneously receiving the epoch's intentionally subsidized access to dormant ETH reserve backing.

Secured credit activates only after:

```text
block.timestamp >= genesisEpochEnd
```

and after the required permanent Genesis reward and protocol integration surfaces are installed.

## Credit principal

The credit limit is fixed by the Genesis backing itself:

```text
maximum principal = 171,000 STATICS
```

The holder chooses the principal when opening the facility.

Examples:

```text
small access:

principal = 9,000 STATICS
remaining vault backing = 171,000 STATICS
```

```text
maximum access:

principal = 171,000 STATICS
remaining vault backing = 9,000 STATICS
```

There is no price-based LTV calculation.

There is no governance-set STATICS price.

There is no floating borrow limit.

The 95% maximum is a property of the 180,000-STATICS backing relationship.

The initial implementation permits one principal amount per active Genesis facility. Increasing an existing principal or implementing a revolving redraw balance is outside this decision and may be added separately if needed.

## Origination

Only the current Genesis owner may open secured credit.

Ordinary ERC-721 approvals, marketplace approvals, operator approvals, or transfer-validator authorization do not authorize credit origination.

This prevents a marketplace operator or NFT approval target from opening secured credit against a user's Genesis.

Origination requires:

```text
current Genesis owner == msg.sender

Genesis is post-epoch

no active Genesis credit

principal > 0

principal <= 171,000 STATICS

exact native origination service fee
```

On success:

```text
selected principal
    -> transferred from Genesis Vault to owner

Genesis
    -> remains owned by owner
    -> becomes credit-locked

maturity
    -> current timestamp + service term
```

The native origination payment is protocol service revenue split between
permanent Genesis reserve backing and the canonical Statics treasury.

It does not:

```text
increase Genesis STATICS backing
reduce principal
increase principal
purchase activation
enter the Genesis recovery-reward index
```

Its reserve portion increases `reserveETH` exactly. Its treasury portion is
transferred to the canonical Statics treasury.

Production service-fee amounts require separate economic parameter ratification.

## Credit lock

An active secured-credit facility must make the Genesis non-transferable.

The NFT remains in the owner's wallet. It is not transferred into ordinary Genesis Vault inventory when credit opens.

This avoids three undesirable effects:

1. owner-changing transfer would otherwise reset Genesis activation;
2. vault ownership would otherwise make reward systems treat the NFT as inactive inventory; and
3. ordinary vault inventory accounting would be forced to distinguish purchasable inventory from credit escrow.

`StaticsGenesis.locked(genesisId)` therefore incorporates secured-credit state in addition to existing protocol-link state.

Conceptually:

```text
locked(genesisId)
    =
existing protocol lock
OR
active Genesis secured credit
```

Opening and closing credit must refresh ERC-5192 lock signaling.

While credit is active:

```text
ordinary transfer     -> prohibited
marketplace transfer  -> prohibited
Genesis redemption    -> prohibited
credit recovery       -> permitted through narrow recovery path
```

## Continued beneficial ownership

Secured credit does not suspend Genesis economics.

While credit is active, the holder retains:

```text
Genesis activation tier
activation multiplier
Genesis reward weight
Genesis reward claims
eligible protocol-revenue participation
staking multiplier benefits
native ETH reserve exposure
future Genesis utility
right to restore full unencumbered ownership by repayment
```

This follows the same productive-collateral principle used by BasketToken lending.

Borrowing against a productive asset does not make the collateral economically inactive.

Opening credit therefore does not remove Genesis reward weight.

Extending credit does not remove Genesis reward weight.

Repaying credit does not create a new reward epoch or reset activation.

## Activation during active credit

The current owner may continue to increase Genesis activation while secured credit is active.

Activation:

```text
does not increase credit limit
does not change principal
does not change maturity
does not access additional backing
```

It only changes the normal Genesis activation state and the reward multiplier associated with that Genesis.

An active credit lock therefore prevents transfer but does not prevent ordinary owner-authorized activation.

## STATICS backing accounting

Genesis secured credit changes the required physical-custody invariant without changing the gross economic backing amount.

Define:

```text
C = circulating Genesis NFTs
P = 180,000 STATICS
O = total outstanding Genesis secured-credit principal
```

Gross backing represented by circulating Genesis is:

```text
grossStaticsBacking
    = C * P
```

Required STATICS remaining in isolated vault custody becomes:

```text
requiredStaticsBacking
    = grossStaticsBacking - O
```

The vault must always satisfy:

```text
actual STATICS custody >= logical retained backing

logical retained backing >= requiredStaticsBacking
```

Credit principal is not an unsecured protocol liability. It is a controlled release of the backing represented by the still-locked Genesis.

For a single Genesis with principal `B`:

```text
gross backing          180,000
outstanding principal       -B
                       -------
required retained      180,000 - B
```

At maximum utilization:

```text
180,000 - 171,000
= 9,000 STATICS
```

## Opening accounting

Opening a credit facility for principal `B` atomically:

1. validates ownership, eligibility, fee, and absence of an existing facility;
2. reads the current service-fee split;
3. increases `reserveETH` by the exact reserve portion of the native fee;
4. transfers the exact treasury portion to the canonical Statics treasury;
5. establishes the credit lock;
6. records principal `B`;
7. records maturity;
8. increases aggregate outstanding Genesis principal by `B`;
9. reduces recognized retained backing by `B`;
10. transfers exactly `B` STATICS to the Genesis owner; and
11. verifies post-operation solvency and native custody.

The transaction reverts atomically if the fee cannot be split exactly, the
treasury portion cannot be transferred, the reserve portion cannot be
accounted, or the vault cannot transfer the exact principal.

## Service term

The initial secured-credit service term is:

```text
30 days
```

The recovery grace period follows the existing basket-credit premise:

```text
1 hour
```

The credit therefore becomes permissionlessly recoverable after:

```text
maturity + 1 hour
```

The principal itself does not increase with elapsed time.

## Extension service

At or before maturity, the Genesis owner may purchase another service term by
paying the configured native extension service fee in effect when extension is
executed.

The current extension fee is a renewal offer, not a fee term permanently fixed
when credit originates. Paying the exact quoted extension fee is affirmative
acceptance of the next service term.

Like the origination service fee, the extension service fee is a flat native
amount. It is not derived from principal and has no protocol-level economic
cap. The current value must be visible through the extension quote before the
owner submits acceptance.

The extension payment uses the governed reserve/treasury split in effect when
extension executes. A split change affects only future service payments. It
does not reallocate a fee already paid or reduce previously accounted
`reserveETH`.

A future extension-fee change does not modify:

```text
outstanding principal
current maturity
an already-purchased service term
repayment rights
recovery grace
```

It changes only the price at which the owner may purchase a later service term.

A successful extension performs exactly:

```text
maturity += 30 days

reserveETH += current fee reserve portion

current fee treasury portion
    -> canonical Statics treasury
```

It does not calculate a fee from:

```text
principal
STATICS price
Genesis price
utilization percentage
elapsed seconds
remaining term
```

The extension fee purchases another full secured-access service term.

The owner may extend repeatedly.

For example:

```text
current maturity
    + 30 days
    + 30 days
    + 30 days
```

may be purchased through three successful extension calls.

Extensions add time to the current maturity rather than resetting maturity relative to `block.timestamp`.

An extension payment is final.

Repaying before the purchased service period ends does not refund any origination or extension service fee.

At exactly `maturity`, extension remains available. A facility is expired only
when `block.timestamp > maturity`. Once expired, the holder may still repay
until recovery executes but may not purchase another service term.

## Repayment

Repayment returns exactly the outstanding STATICS principal.

There is:

```text
no accumulated STATICS interest
no time-based STATICS fee
no compounding principal
no repayment penalty
```

Repayment may be permissionless because it only reduces risk and always benefits the recorded Genesis owner.

A successful repayment:

1. pulls exactly the stored principal into Genesis Vault;
2. decreases aggregate outstanding Genesis principal by the same amount;
3. restores recognized retained backing by the same amount;
4. closes the credit facility;
5. removes the credit lock;
6. preserves activation and reward state; and
7. leaves the Genesis with its current owner.

Repayment does not refund previously paid native service fees.

## Recovery

After:

```text
block.timestamp > maturity + recoveryGracePeriod
```

recovery becomes permissionless.

Recovery is not an oracle liquidation and does not sell the Genesis into an external market.

The NFT itself returns to ordinary Genesis Vault inventory.

For principal `B`, define:

```text
maximum credit amount = 171,000 STATICS

unused credit amount
    = 171,000 - B

fixed recovery residual
    = 9,000 STATICS

configured recovery caller share
    = recoveryCallerShareBps

caller incentive
    = floor(9,000 * recoveryCallerShareBps / 10,000)

Genesis holder distribution
    = 9,000 - caller incentive
```

The vault already retains:

```text
180,000 - B
```

STATICS.

That amount resolves exactly as:

```text
180,000 - B
    =
(171,000 - B)
+
caller incentive
+
Genesis holder distribution
```

Therefore recovery distributes:

```text
171,000 - B STATICS
    -> defaulting owner

caller incentive
    -> permissionless recovery caller

Genesis holder distribution
    -> existing Genesis STATICS reward index
```

and transfers the Genesis into ordinary vault inventory.

At maximum principal:

```text
B = 171,000

unused credit amount = 0
fixed recovery residual = 9,000
```

At a 9,000-STATICS principal:

```text
B = 9,000

unused credit amount = 162,000
fixed recovery residual = 9,000
```

The holder therefore receives 171,000 STATICS in total economic value from the backing release and recovery settlement regardless of utilization:

```text
principal already received
+
unused credit returned at recovery
=
171,000 STATICS
```

The fixed 9,000-STATICS residual is forfeited when the owner chooses not to
restore the backing and recover the Genesis. It funds the permissionless caller
incentive and the remaining Genesis-holder distribution.

## Economic meaning of recovery

A mature unrepaid facility is economically equivalent to the system reacquiring the Genesis for 95% of its fixed STATICS backing.

The defaulting holder:

```text
keeps or receives 171,000 STATICS in aggregate
loses Genesis ownership
loses future Genesis utility
loses future reward multiplier benefits
loses future ETH reserve exposure
loses any NFT market premium
forfeits 9,000 STATICS to the recovery caller and remaining Genesis holders
```

The protocol:

```text
receives the Genesis back into vault inventory
retains no bad debt
requires no liquidation auction
requires no external buyer
requires no price oracle
```

The recovered Genesis may later be acquired through the ordinary post-epoch Genesis purchase path.

That future acquisition again requires:

```text
180,000 STATICS
+
current reserve buy-in
+
current native acquisition fee
```

## Recovery caller incentive and Genesis reward distribution

The fixed:

```text
9,000 STATICS
```

recovery residual is divided between the permissionless recovery caller and
eligible Genesis holders.

The configured caller share must satisfy:

```text
0 < recoveryCallerShareBps < 10,000
```

so recovery always provides a caller incentive while preserving a positive
Genesis-holder distribution.

The residual is not split with:

```text
treasury
protocol-owned liquidity
global STATICS staking
```

The caller incentive is paid directly to `msg.sender`. The remainder uses the
same weighted STATICS fee index already established for Genesis launch rewards.

Eligibility uses the Genesis activation multiplier.

Conceptually:

```text
9,000 STATICS
        |
        +--> configured caller share -> recovery caller
        |
        v
remaining STATICS
        |
        v
existing Genesis weighted reward index
        |
        v
eligible Genesis holders
```

Credit-active Genesis NFTs remain eligible because secured credit does not remove productive reward rights.

The Genesis being recovered must have zero effective weight when its recovery
distribution is handled. If other eligible Genesis weight exists at that
boundary, the recovered Genesis receives none of that indexed amount.

Recovery therefore performs reward and ownership state changes in this order:

1. settle the defaulting Genesis's direct rewards through the recovery boundary;
2. settle every reward index whose effective PositionNFT weight includes the
   defaulting Genesis boost;
3. remove the recovered Genesis's direct reward weight and PositionNFT boost;
4. sever only the recovered Genesis relationship while preserving the
   PositionNFT and all unrelated ledger state;
5. reset Genesis activation through the ordinary owner-changing transition;
6. transfer the Genesis to vault inventory;
7. close the secured-credit accounting;
8. return any unused credit amount to the former owner;
9. pay the configured caller incentive to the recovery caller; and
10. accrue the remaining recovery residual into the existing Genesis weighted
    STATICS reward index.

If no eligible Genesis weight exists after recovery, only the Genesis-holder
portion remains pending in the same Genesis reward distributor until eligible
weight exists. It does not become treasury revenue. The caller incentive is
still paid when recovery executes. Pending value is not permanently attributed
to, or excluded from, any token. It is distributed using the then-current
eligible weights when weight next exists. Consequently, if the recovered
Genesis is later reacquired through the ordinary vault purchase path, its
restored base weight may participate in that later distribution.

## Existing Genesis fee-index integration

`GenesisLaunchDistributor` already maintains the activation-weighted Genesis
reward books fed by the permanent Doppler `StaticsFeeReceiver`.

Genesis recovery reuses those same books:

```text
Doppler
    -> StaticsFeeReceiver
    -> active Genesis reward distributor

StaticsGenesisVault recovery
    -> same active Genesis reward distributor
    -> same STATICS RewardBook and indexRay
```

The active distributor accepts an exact, authenticated STATICS recovery amount
from `StaticsGenesisVault`. It indexes the complete Genesis-holder portion
without applying `genesisRewardShareBps`, because the caller incentive has
already been removed and none of the remainder belongs to treasury.

Immediately before the ownership transition, the vault also invokes a
recovery-only checkpoint on that distributor. The checkpoint harvests currently
collectible Doppler fees, settles the defaulting Genesis, and crystallizes its
direct entitlement to the former owner before its weight is removed. Ordinary
NFT transfers retain the existing storage-only checkpoint behavior.

This is an additional inflow to the existing index, not a second reward ledger,
registry, or distributor.

`GenesisLaunchDistributor` remains replaceable when Statics proper comes
online. Its successor must preserve the same vault-authenticated recovery inflow
and activation-weighted STATICS index behavior. A replacement may not become
active while doing so would make an already-open Genesis credit unrecoverable.
Fee-distributor acceptance occurs before activation-consumer acceptance, and
recovery remains unavailable during that handoff gap. Any zero-weight pending
recovery amount migrates exactly to the successor and remains pending there
until successor-managed eligible weight exists. Distributor activation is
one-time: a detached distributor cannot later be reactivated with stale
registration and activation weights.

## Protocol linkage

A Genesis may simultaneously participate in full Statics protocol benefits while secured credit is active.

Secured credit therefore does not automatically unlink a Genesis from an associated PositionNFT or other accepted protocol-benefit relationship.

Ordinary repayment leaves those relationships unchanged.

Recovery is different because the NFT becomes vault inventory.

Before or during recovery, the recovered Genesis contribution must be
atomically removed through a narrow protocol callback.

The callback settles the PositionNFT with its Genesis-derived boost through the
recovery boundary, then removes only that boost and Genesis connection. It does
not burn, transfer, close, or reset the PositionNFT.

The former owner retains:

```text
the PositionNFT itself
deposited BasketTokens
canonical LP positions
open loans and obligations
accrued and claimable rewards
every unrelated portfolio and accounting entry
```

After recovery, those positions continue under their ordinary unboosted
economics.

The required post-recovery invariant is:

```text
vault-owned Genesis
    -> no stale PositionNFT link
    -> no stale beneficial-owner reward weight
    -> no active credit
    -> ordinary purchasable vault inventory

former owner's PositionNFT
    -> ownership unchanged
    -> underlying ledger items unchanged
    -> recovered Genesis boost removed
    -> continues earning at its remaining effective weight
```

Failure to clear required protocol state reverts recovery atomically.
The one-time protocol binding therefore requires an explicit recovery-callback
capability acknowledgement, and each callback must leave
`linkedPosition(genesisId) == 0` before the NFT can return to vault inventory.

## Native service-fee split

Origination and extension payments are service revenue.

The initial split is:

```text
creditServiceReserveShareBps = 1,000
    -> 10%

creditServiceTreasuryShareBps = 9,000
    -> 90%
```

The authorized Statics administration/governance path may configure both
percentages atomically, subject to:

```text
0 <= creditServiceReserveShareBps <= 10,000

0 <= creditServiceTreasuryShareBps <= 10,000

creditServiceReserveShareBps
    + creditServiceTreasuryShareBps
    == 10,000
```

Neither percentage may be changed independently into an invalid sum.
Every successful change emits the previous and new pair so indexers and clients
can display the active allocation.

For a native service fee `F`:

```text
reserve portion
    = floor(F * creditServiceReserveShareBps / 10,000)

treasury portion
    = F - reserve portion
```

Any integer-division remainder therefore accrues to treasury, while the two
destinations always receive exactly `F` in aggregate.

The reserve portion remains in `StaticsGenesisVault` custody and increases
`reserveETH` by exactly that amount. It becomes permanent backing attributable
across the fixed 5,555 Genesis reserve shares and is subject to the existing
non-withdrawable reserve rules.

The treasury portion routes to the canonical Statics treasury.

No portion routes to:

```text
Genesis STATICS backing
Genesis recovery rewards
credit principal
```

The current total fee, reserve percentage, treasury percentage, reserve
portion, and treasury portion must be exposed by the applicable quote before
payment.

A failed reserve-accounting update or treasury transfer reverts the
corresponding origination or extension without changing credit state.

Production values for:

```text
Genesis origination service fee
Genesis extension service fee
Genesis recovery caller share bps
```

require separate economic ratification.

## ETH reserve protection and service-fee capitalization

Genesis secured credit accesses only the fixed STATICS backing.

It never borrows, encumbers, advances, prices, or distributes the Genesis ETH reserve.

During open credit:

```text
reserveETH increases by the origination fee reserve portion
```

During extension:

```text
reserveETH increases by the extension fee reserve portion
```

During repayment:

```text
reserveETH unchanged
```

During recovery:

```text
reserveETH unchanged
```

A recovered Genesis returns to vault inventory without receiving an ETH reserve redemption payout.

Its fixed 1/5,555 reserve share remains part of the permanent Genesis reserve system.

## Use of released STATICS

Released STATICS remains freely composable. A holder may apply it toward any
purpose, including another Genesis acquisition when the ordinary post-epoch
requirements are satisfied.

Genesis secured credit does not create a self-funding recursive acquisition
loop.

At maximum credit:

```text
STATICS released from one Genesis
    = 171,000

STATICS required for another Genesis
    = 180,000

additional STATICS required
    = 9,000
```

The next acquisition additionally requires the current native reserve buy-in
and acquisition fee, and opening credit against it requires another native
origination service fee.

Each additional Genesis therefore requires fresh STATICS and native capital.
No address-level anti-loop rule is necessary because the released principal
alone cannot fund the next acquisition.

## Pauses and liveness

Governance may pause new Genesis credit origination.

Repayment must remain available while origination is paused.

Permissionless recovery and its configured caller incentive must remain
available while origination is paused.

Ordinary Genesis redemption remains unavailable for a credit-locked Genesis until the credit is repaid or recovered.

Extension may have an independent pause if required by the existing protocol pause model, but pausing extension must never prevent principal repayment.

A pause cannot confiscate credit collateral.

## Views

The implementation should expose at minimum:

```text
creditLimit(genesisId)
credit(genesisId)
creditActive(genesisId)
creditRecoverableAt(genesisId)
quoteGenesisCredit(principal)
quoteGenesisCreditExtension(genesisId)
quoteGenesisCreditRecovery(genesisId)
totalOutstandingGenesisCredit()
recoveryCallerShareBps()
creditServiceReserveShareBps()
creditServiceTreasuryShareBps()
```

Origination and extension quotes should report at minimum:

```text
total native service fee
reserve share bps
treasury share bps
native reserve portion
native treasury portion
```

A credit view should report at minimum:

```text
owner
principal
maturity
recoverableAt
active
```

A recovery quote should report at minimum:

```text
unused credit returned to former owner
fixed recovery residual
caller incentive
Genesis holder distribution
recoverableAt
```

Genesis Vault accounting should additionally expose:

```text
gross circulating STATICS backing
outstanding Genesis credit principal
net required STATICS backing
```

so integrations can distinguish gross Genesis claims from STATICS currently retained in the vault.

## Required invariants

Implementation and invariant testing must prove at minimum:

```text
Genesis gross backing per circulating NFT
    == 180,000 STATICS

maximum Genesis credit principal
    == 171,000 STATICS

fixed Genesis recovery residual
    == 9,000 STATICS

0 < recoveryCallerShareBps < 10,000

recovery caller incentive
    == floor(9,000 STATICS
        * recoveryCallerShareBps / 10,000)

Genesis holder recovery distribution
    == 9,000 STATICS - recovery caller incentive

recovery caller incentive
    + Genesis holder recovery distribution
    == 9,000 STATICS

one active credit facility per Genesis

credit principal > 0

credit principal <= 171,000 STATICS

credit cannot open before genesisEpochEnd

only current Genesis owner can originate credit

ordinary ERC-721 approval cannot originate credit

active credit prevents ordinary Genesis transfer

active credit prevents ordinary Genesis redemption

active credit does not reset activation tier

active credit does not reduce reward multiplier

active credit does not remove Genesis reward eligibility

creditServiceReserveShareBps
    + creditServiceTreasuryShareBps
    == 10,000

creditServiceReserveShareBps <= 10,000

creditServiceTreasuryShareBps <= 10,000

initial credit service fee split
    == 1,000 bps reserve + 9,000 bps treasury

service fee reserve portion
    == floor(service fee
        * creditServiceReserveShareBps / 10,000)

service fee treasury portion
    == service fee - service fee reserve portion

service fee reserve portion
    + service fee treasury portion
    == exact service fee paid

opening credit increases reserveETH by exactly
the quoted origination fee reserve portion

extension does not modify principal

extension does not modify retained STATICS backing

extension increases reserveETH by exactly
the quoted extension fee reserve portion

extension increases maturity by exactly one service term

extension is available at block.timestamp == maturity

extension is unavailable when block.timestamp > maturity

paying the exact current extension quote purchases the next term

the current extension quote exposes the complete flat native fee

each current service-fee quote exposes the complete
reserve and treasury split

an extension-fee change does not modify an already-purchased term

a service-fee split change does not reallocate past payments
or reduce previously accounted reserveETH

service fees never increase STATICS principal

repayment restores exactly stored principal

repayment closes credit without resetting activation

repayment does not modify reserveETH

gross backing
    == circulatingGenesis * 180,000 STATICS

required retained backing
    == gross backing - total outstanding Genesis credit principal

vault STATICS custody
    >= recognized retained backing

recognized retained backing
    >= required retained backing

recovery cannot execute before maturity plus grace

recovery returns the NFT to ordinary vault inventory

recovery decreases circulating Genesis by exactly one

recovery clears the recovered Genesis credit

recovery settles every PositionNFT reward index affected
by the recovered Genesis boost before removing that boost

recovery severs the recovered Genesis connection

recovery preserves PositionNFT ownership and every
unrelated PositionNFT ledger item

recovery returns exactly 171,000 - principal STATICS
to the former owner

recovery pays exactly the quoted caller incentive
to msg.sender

recovery indexes exactly the quoted Genesis holder
distribution through the existing Genesis STATICS reward book

recovered Genesis receives none of its own
Genesis holder recovery distribution

if eligible Genesis weight is zero, the Genesis holder
distribution remains pending and never routes to treasury

recovery pays zero ETH reserve value

recovery does not modify reserveETH

recovered Genesis is purchasable only through
ordinary post-epoch acquisition rules
```

## Required lifecycle tests

Real-flow tests must cover at minimum:

```text
post-epoch Genesis acquisition
    -> open small credit
    -> 10% of origination fee enters reserveETH
    -> 90% of origination fee reaches treasury
    -> continue earning rewards
    -> extension fee changes
    -> current principal and purchased term remain unchanged
    -> exact current extension quote accepted
    -> extend
    -> 10% of extension fee enters reserveETH
    -> 90% of extension fee reaches treasury
    -> repay
    -> transfer Genesis

governed service-fee split
    -> configure a new valid reserve/treasury pair
    -> previous and new pair emitted
    -> existing reserveETH remains unchanged
    -> next origination uses the new split
    -> next extension uses the new split
    -> unauthorized configuration reverts
    -> invalid pair whose sum is not 10,000 reverts

service-fee split boundary
    -> configure 0 bps reserve and 10,000 bps treasury
    -> exact payment reaches treasury
    -> configure 10,000 bps reserve and 0 bps treasury
    -> exact payment enters reserveETH
    -> use a fee that does not divide evenly by 10,000
    -> reserve receives the floored portion
    -> treasury receives the complete remainder
    -> no native value is stranded

post-epoch Genesis acquisition
    -> activate Genesis
    -> open maximum credit
    -> accrue rewards while credit active
    -> repay
    -> activation remains unchanged

Genesis linked to full-protocol benefits
    -> open credit
    -> continue receiving eligible multiplier benefits
    -> repay
    -> link remains valid

Genesis linked to full-protocol benefits
    -> open credit
    -> expire
    -> recover
    -> boosted PositionNFT indexes settled
    -> link cleared
    -> PositionNFT ownership and ledger items preserved
    -> PositionNFT continues with Genesis boost removed
    -> activation reset
    -> NFT becomes vault inventory

small principal
    -> expire
    -> recover
    -> unused 95% capacity returned to borrower
    -> quoted caller incentive paid to recovery caller
    -> 9,000 minus caller incentive indexed to Genesis rewards

maximum principal
    -> expire
    -> recover
    -> zero unused capacity returned
    -> quoted caller incentive paid to recovery caller
    -> 9,000 minus caller incentive indexed to Genesis rewards

no eligible Genesis reward weight
    -> expire credit
    -> recover
    -> caller incentive paid immediately
    -> Genesis holder distribution remains pending
    -> eligible weight returns
    -> pending distribution enters the existing STATICS reward index

active Genesis reward distributor
    -> open credit
    -> rotate to Statics-proper distributor
    -> expire credit
    -> recover through successor's same authenticated inflow

multiple Genesis credits
    -> independent maturities
    -> independent repayment
    -> independent recovery

credit-active Genesis
    -> marketplace transfer attempt reverts

credit-active Genesis
    -> redemption attempt reverts

credit-active Genesis
    -> activation increase succeeds

credit-active Genesis
    -> reserve donation
    -> reserve donation and service-fee capitalization remain exact

paused origination
    -> new credit reverts
    -> repayment remains live
    -> mature incentivized recovery remains live
```

Boundary tests must explicitly cover:

```text
block.timestamp == maturity - 1

block.timestamp == maturity
    -> extension succeeds

block.timestamp == maturity + 1
    -> extension reverts
    -> repayment remains available

block.timestamp == recoverableAt
    -> recovery reverts

block.timestamp == recoverableAt + 1
    -> recovery succeeds
```

Fuzz and invariant suites must combine:

```text
Genesis acquisitions
Genesis redemptions
credit originations
credit extensions
credit repayments
credit recoveries
activation changes
reward accrual
reward claims
reserve donations
ordinary transfers
PositionNFT linkage
multiple simultaneous Genesis facilities
```

## Security properties

The implementation must preserve the following boundaries:

- The vault itself enforces the 95% maximum. No external protocol module may choose a larger principal.
- A compromised marketplace approval cannot originate credit.
- Credit cannot cause the vault to debit another Genesis's required backing.
- Credit never exposes native ETH reserve custody.
- Only the authorized Statics administration/governance path may change the service-fee split.
- Service-fee governance may change only the reserve/treasury percentages and must preserve a 10,000-bps total.
- Service-fee governance cannot change the fixed reserve or treasury destinations, reallocate past payments, or withdraw accounted `reserveETH`.
- Origination and extension atomically account the exact reserve portion and transfer the exact treasury portion before completing credit state changes.
- Recovery has a fixed NFT destination: `StaticsGenesisVault`.
- Any privileged foreclosure surface may transfer a recoverable Genesis only to its immutable vault.
- Recovery cannot select an arbitrary NFT receiver.
- Recovery pays the configured caller incentive only to `msg.sender`; the caller cannot select another incentive receiver.
- Recovery routes the Genesis-holder portion only into the active existing Genesis STATICS reward index.
- Recovery cannot modify, confiscate, or erase unrelated PositionNFT ledger state.
- Service-fee configuration cannot alter principal already outstanding.
- Reward-distributor failure cannot silently misaccount the Genesis-holder portion of the 9,000-STATICS recovery residual.
- Native service-fee rounding cannot strand value or cause aggregate allocations to differ from the exact payment.
- All principal, repayment, unused-credit, caller-incentive, and Genesis-reward transfers use exact-transfer accounting.
- No oracle, NFT marketplace, external liquidation venue, or arbitrary recipient enters the solvency boundary.

## Economic consequences

Genesis becomes both a redeemable asset and a productive secured-liquidity primitive.

A holder may:

```text
hold Genesis
    -> retain 180,000-STATICS redemption claim
    -> retain ETH reserve exposure
    -> earn Genesis rewards
    -> receive activation-weighted benefits

open secured credit
    -> access up to 171,000 STATICS
    -> preserve those Genesis benefits
    -> pay a native service fee
    -> capitalize the governed reserve portion
    -> route the remainder to treasury

extend
    -> purchase another service term
    -> preserve principal and benefits
    -> capitalize the governed reserve portion
    -> route the remainder to treasury

repay
    -> restore backing
    -> remove credit lock
    -> retain Genesis

fail to repay
    -> receive 95% of STATICS backing in aggregate
    -> surrender Genesis
    -> forfeit 5% of backing to the recovery caller
       and remaining Genesis holders
```

This materially reduces the need for a long-term Genesis holder to sell or redeem solely to access liquidity.

It also changes the Genesis STATICS sink from a strictly idle backing sink into an elastic secured-liquidity source.

At maximum credit utilization, one Genesis retains:

```text
9,000 STATICS
```

inside isolated vault backing while:

```text
171,000 STATICS
```

is accessible to its owner.

This is deliberate.

Genesis scarcity, activation, reward utility, ETH reserve exposure, and the right to recover the NFT provide the holder's incentive to maintain the credit facility rather than abandon it.

## Product terminology

User-facing terminology should describe this system as:

```text
Genesis Secured Credit
```

rather than a variable-rate lending market.

Recommended concepts are:

```text
Credit limit
STATICS accessed
Service term
Origination service fee
Extension service fee
Reserve allocation
Treasury allocation
Next service deadline
Recovery date
Recovery caller incentive
Repay
```

The interface should not display a synthetic APR because no STATICS debt accrues according to an annualized interest formula.

## Rejected alternatives

### Transfer Genesis into vault custody at origination

Rejected.

An owner-changing transfer would conflict with existing activation-reset and reward ownership semantics and would force the vault to distinguish credit escrow from purchasable inventory.

Keeping the NFT with its owner and applying a protocol-enforced lock preserves beneficial ownership directly.

### Disable Genesis rewards while credit is active

Rejected.

Statics already treats productive BasketToken collateral as reward-eligible while locked for lending.

Genesis secured credit follows the same principle.

The service explicitly preserves Genesis benefits and privileges while its backing is accessed.

### Use NFT floor price or STATICS/USD value

Rejected.

Principal and backing are both STATICS-denominated.

External price information adds liquidation and oracle risk without improving solvency.

### Accrue STATICS interest over time

Rejected.

The stored principal remains constant.

Time is purchased through separate native service fees.

### Refund service fees after early repayment

Rejected.

Origination and extension fees purchase access to the secured-credit service for the applicable term.

Choosing to stop using the service early does not reverse the completed service purchase.

### Route all credit service fees to treasury

Rejected.

Genesis secured credit relies on permanent reserve exposure as part of the
holder's reason to retain and maintain the NFT. The initial 10% reserve share
lets credit usage itself capitalize that backing, while the 90% treasury share
preserves protocol service revenue.

Governance may later adjust the percentages as one valid pair totaling 100%,
but cannot change either destination or reallocate reserve already capitalized.

### Distribute all retained backing after a small-principal default

Rejected.

The recovery penalty is fixed at:

```text
9,000 STATICS
```

or 5% of the Genesis gross STATICS backing.

Unused credit capacity belongs to the former owner and is returned during recovery.

### Bind recovery rewards permanently to GenesisLaunchDistributor

Rejected.

The launch distributor is intentionally replaceable when Statics proper comes
online.

Recovery feeds the currently active distributor's existing activation-weighted
STATICS fee index. A successor preserves that same authenticated vault inflow
without introducing a second reward system.

### Enable secured credit during the Genesis Epoch

Rejected.

The Genesis Epoch intentionally requires early STATICS commitment in exchange for subsidized access to accumulating ETH reserve exposure.

Allowing immediate 95% backing access would materially alter that launch bargain.
