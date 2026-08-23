# ADR: Genesis secured credit against fixed STATICS backing

- Status: Proposed
- Date: 2026-08-23
- Scope: Genesis secured credit, partial access to isolated STATICS backing, native origination and extension service fees, continued Genesis rewards while encumbered, fixed-term extension, permissionless recovery, and recovery-surplus distribution
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
    +--> pay extension service fee
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

Recovery ends beneficial ownership.

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

The native origination payment is protocol service revenue.

It does not:

```text
increase reserveETH
increase Genesis STATICS backing
reduce principal
increase principal
purchase activation
enter the Genesis recovery-reward index
```

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
2. establishes the credit lock;
3. records principal `B`;
4. records maturity;
5. increases aggregate outstanding Genesis principal by `B`;
6. reduces recognized retained backing by `B`;
7. transfers exactly `B` STATICS to the Genesis owner; and
8. verifies post-operation solvency.

No ETH reserve accounting changes.

The transaction reverts atomically if the vault cannot transfer the exact principal.

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

Before maturity, the Genesis owner may pay the configured native extension service fee.

A successful extension performs exactly:

```text
maturity += 30 days
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

An expired facility may not be extended. Once maturity has passed, the holder may still repay until recovery executes.

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

fixed recovery distribution
    = 9,000 STATICS
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
9,000
```

Therefore recovery distributes:

```text
171,000 - B STATICS
    -> defaulting owner

9,000 STATICS
    -> Genesis reward index
```

and transfers the Genesis into ordinary vault inventory.

At maximum principal:

```text
B = 171,000

unused credit amount = 0
recovery distribution = 9,000
```

At a 9,000-STATICS principal:

```text
B = 9,000

unused credit amount = 162,000
recovery distribution = 9,000
```

The holder therefore receives 171,000 STATICS in total economic value from the backing release and recovery settlement regardless of utilization:

```text
principal already received
+
unused credit returned at recovery
=
171,000 STATICS
```

The fixed 9,000-STATICS residual is forfeited when the owner chooses not to restore the backing and recover the Genesis.

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
forfeits 9,000 STATICS to remaining Genesis holders
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

## Recovery reward distribution

The complete:

```text
9,000 STATICS
```

recovery amount belongs to eligible Genesis holders.

It is not split with:

```text
treasury
recovery caller
protocol-owned liquidity
global STATICS staking
```

Recovery uses the same weighted-index premise already established for Genesis launch rewards.

Eligibility uses the Genesis activation multiplier.

Conceptually:

```text
9,000 STATICS
        |
        v
Genesis weighted reward index
        |
        v
eligible Genesis holders
```

Credit-active Genesis NFTs remain eligible because secured credit does not remove productive reward rights.

The Genesis being recovered must not participate in its own recovery distribution.

Recovery therefore performs reward state changes in this order:

1. settle the defaulting Genesis's rewards through the recovery boundary;
2. remove its Genesis reward weight;
3. clear any PositionNFT or full-protocol Genesis linkage that cannot survive vault ownership;
4. reset activation through the ordinary owner-changing transition;
5. transfer the Genesis to vault inventory;
6. close the secured-credit accounting;
7. return any unused credit amount to the former owner; and
8. accrue exactly 9,000 STATICS into the remaining Genesis weighted reward index.

If no eligible Genesis weight exists after recovery, the 9,000 STATICS remains reserved to the Genesis reward system until eligible weight exists. It does not become treasury revenue.

## Reward-consumer boundary

`GenesisLaunchDistributor` remains a temporary launch implementation.

Secured credit must not permanently bind Genesis recovery economics to that specific contract.

Instead, the permanent Genesis reward consumer interface must support direct, authenticated Genesis reward accrual from `StaticsGenesisVault`.

The currently active Genesis reward implementation must be able to accept an exact STATICS amount from the vault and index it using the canonical activation-weighted Genesis denominator.

Distributor rotation must preserve this capability.

A replacement consumer may not become active while doing so would make an already-open Genesis credit unrecoverable.

## Protocol linkage

A Genesis may simultaneously participate in full Statics protocol benefits while secured credit is active.

Secured credit therefore does not automatically unlink a Genesis from an associated PositionNFT or other accepted protocol-benefit relationship.

Ordinary repayment leaves those relationships unchanged.

Recovery is different because the NFT becomes vault inventory.

Before or during recovery, any protocol relationship incompatible with vault ownership must be atomically cleared through a narrow protocol callback.

The required post-recovery invariant is:

```text
vault-owned Genesis
    -> no stale PositionNFT link
    -> no stale beneficial-owner reward weight
    -> no active credit
    -> ordinary purchasable vault inventory
```

Failure to clear required protocol state reverts recovery atomically.

## Native service-fee routing

Origination and extension payments are service revenue.

They route to the canonical Statics treasury rather than:

```text
Genesis STATICS backing
Genesis ETH reserve
Genesis recovery rewards
credit principal
```

Fee routing must be exact.

A failed treasury transfer reverts the corresponding origination or extension without changing credit state.

Production values for:

```text
Genesis origination service fee
Genesis extension service fee
```

require separate economic ratification.

## ETH reserve isolation

Genesis secured credit accesses only the fixed STATICS backing.

It never borrows, encumbers, advances, prices, or distributes the Genesis ETH reserve.

During open credit:

```text
reserveETH unchanged
```

During extension:

```text
reserveETH unchanged
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

## Recursive use

A holder may use released STATICS to acquire additional assets, including another Genesis if ordinary post-epoch acquisition requirements are satisfied.

The protocol does not attempt to identify or prohibit recursive Genesis acquisition.

This mirrors the accepted BasketToken lending principle that 95% self-backed credit can be composed recursively.

Genesis recursion remains bounded by:

```text
95% maximum STATICS access
finite 5,555 Genesis supply
post-epoch ETH reserve buy-in
native acquisition fees
native credit service fees
available STATICS liquidity
market price of STATICS
```

No additional anti-loop rule is introduced.

## Pauses and liveness

Governance may pause new Genesis credit origination.

Repayment must remain available while origination is paused.

Permissionless recovery must remain available while origination is paused.

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
totalOutstandingGenesisCredit()
```

A credit view should report at minimum:

```text
owner
principal
maturity
recoverableAt
active
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

fixed Genesis recovery distribution
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

opening credit does not modify reserveETH

extension does not modify principal

extension does not modify retained STATICS backing

extension does not modify reserveETH

extension increases maturity by exactly one service term

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

recovery clears incompatible protocol linkage

recovery returns exactly 171,000 - principal STATICS
to the former owner

recovery allocates exactly 9,000 STATICS
to Genesis rewards

recovered Genesis receives none of its own
9,000-STATICS recovery distribution

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
    -> continue earning rewards
    -> extend
    -> repay
    -> transfer Genesis

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
    -> link cleared
    -> activation reset
    -> NFT becomes vault inventory

small principal
    -> expire
    -> recover
    -> unused 95% capacity returned to borrower
    -> exactly 9,000 STATICS indexed to Genesis rewards

maximum principal
    -> expire
    -> recover
    -> zero unused capacity returned
    -> exactly 9,000 STATICS indexed to Genesis rewards

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
    -> reserve accounting remains independent

paused origination
    -> new credit reverts
    -> repayment remains live
    -> mature recovery remains live
```

Boundary tests must explicitly cover:

```text
block.timestamp == maturity - 1

block.timestamp == maturity

block.timestamp == maturity + 1

block.timestamp == recoverableAt

block.timestamp == recoverableAt + 1
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
- Recovery has a fixed NFT destination: `StaticsGenesisVault`.
- Any privileged foreclosure surface may transfer a recoverable Genesis only to its immutable vault.
- Recovery cannot select an arbitrary NFT receiver.
- Recovery cannot select an arbitrary STATICS reward receiver.
- Service-fee configuration cannot alter principal already outstanding.
- Reward-consumer failure cannot silently misaccount the 9,000-STATICS recovery amount.
- All principal, repayment, unused-credit, and recovery-reward transfers use exact-transfer accounting.
- No oracle, NFT marketplace, external liquidation venue, arbitrary executor, or keeper-selected recipient enters the solvency boundary.

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

extend
    -> purchase another service term
    -> preserve principal and benefits

repay
    -> restore backing
    -> remove credit lock
    -> retain Genesis

fail to repay
    -> receive 95% of STATICS backing in aggregate
    -> surrender Genesis
    -> forfeit 5% of backing to remaining Genesis holders
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
Next service deadline
Recovery date
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

### Distribute all retained backing after a small-principal default

Rejected.

The recovery penalty is fixed at:

```text
9,000 STATICS
```

or 5% of the Genesis gross STATICS backing.

Unused credit capacity belongs to the former owner and is returned during recovery.

### Give the recovery caller part of the 9,000 STATICS

Rejected for the initial design.

The complete recovery amount belongs to eligible Genesis holders.

Recovery remains permissionless with a fixed outcome.

### Bind recovery rewards permanently to GenesisLaunchDistributor

Rejected.

The launch distributor is intentionally replaceable.

Recovery uses the permanent Genesis reward-consumer boundary and preserves the same activation-weighted index semantics across distributor rotation.

### Enable secured credit during the Genesis Epoch

Rejected.

The Genesis Epoch intentionally requires early STATICS commitment in exchange for subsidized access to accumulating ETH reserve exposure.

Allowing immediate 95% backing access would materially alter that launch bargain.

### Prevent recursive Genesis acquisition

Rejected.

The system already accepts bounded recursive self-backed credit for BasketTokens.

Post-epoch reserve buy-in, service fees, available liquidity, fixed NFT supply, and the 95% maximum provide natural constraints without address-level use restrictions.
