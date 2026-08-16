# ADR: Standalone Genesis launch with a permanent V4 inventory curve

- Status: Accepted direction; implementation pending
- Date: 2026-08-15
- Scope: standalone STATICS and Genesis issuance, fixed Genesis backing,
  six-band one-sided Uniswap v4 distribution, bilateral hook fees,
  permanent fee-funded liquidity, and later Statics Diamond integration
- Supersedes: the unmerged Genesis-tokenomics direction on
  `feat/genesis-tokenomics` and this ADR's earlier single-position launch design

## Context

Statics needs a launchable Genesis product before the complete Statics Diamond
is ready. The release must establish the STATICS token, the 5,555-token Genesis
collection, a fully backed fixed-price conversion between the two, and a
canonical Uniswap v4 market that survives the later launch of the full
protocol.

EqualFi Labs must not need to sell a discretionary treasury allocation of
STATICS to fund development. Users acquire STATICS from the canonical market.
EqualFi Labs earns operating revenue from explicit trading fees. Genesis
redemption backing and market liquidity are not operating revenue.

Genesis NFTs and STATICS are two convertible forms of the same fixed genesis
supply. A circulating Genesis NFT is a claim on a fixed amount of STATICS held
by the Genesis Vault. An unminted or vault-owned Genesis slot leaves its paired
STATICS in liquid-token form.

The full Statics Diamond, PositionNFTs, baskets, Statics Dollar, lending, and
global reward indexes are outside the deployment boundary of this release.
The launch contracts must nevertheless preserve a clean control and fee-routing
path for later Diamond integration.

## Decision summary

Statics will launch through the canonical STATICS/WETH Uniswap v4 pool from the
first trade. There is no separate bonding-curve contract, graduation event, or
market migration.

The 810,045,000-STATICS public allocation will be placed into six permanent,
one-sided concentrated-liquidity positions. Each position covers one valuation
decade. Inventory is deliberately distributed across attainable valuation
regions instead of warehousing most public supply above $10 billion FDV.

| Reference FDV range | Share | STATICS |
| --- | ---: | ---: |
| $100,000 to $1 million | 3% | 24,301,350 |
| $1 million to $10 million | 7% | 56,703,150 |
| $10 million to $100 million | 20% | 162,009,000 |
| $100 million to $1 billion | 25% | 202,511,250 |
| $1 billion to $10 billion | 30% | 243,013,500 |
| $10 billion to $100 billion | 15% | 121,506,750 |
| **Total public inventory** | **100%** | **810,045,000** |

Because each Genesis NFT is paired with 180,010 STATICS, the same allocation
can be expressed as the 4,500 public Genesis backing units:

| Reference FDV range | Share | Genesis-equivalent inventory |
| --- | ---: | ---: |
| $100,000 to $1 million | 3% | 135 NFTs |
| $1 million to $10 million | 7% | 315 NFTs |
| $10 million to $100 million | 20% | 900 NFTs |
| $100 million to $1 billion | 25% | 1,125 NFTs |
| $1 billion to $10 billion | 30% | 1,350 NFTs |
| $10 billion to $100 billion | 15% | 675 NFTs |
| **Total public inventory** | **100%** | **4,500 NFTs** |

The launch uses a standalone refactor of the existing Statics swap-fee hook,
including its bilateral input/output fee accounting and bounded per-pool split
configuration. The initial STATICS/WETH allocation of every collected hook fee
is:

```text
Permanent auto-compounding liquidity: 25%
Statics treasury:                     75%
All other allocations:                 0%
```

The six launch positions are immutable market principal. The 25% fee
allocation creates separate, fee-funded, full-range permanent liquidity. These
two forms of liquidity must never share an accounting bucket.

## Contract topology

The standalone release consists of:

1. `StaticsToken`;
2. `StaticsGenesis`;
3. `StaticsGenesisVault`;
4. `StaticsV4Hook`;
5. `StaticsHookController`; and
6. a one-time authorized launch path coordinated through the hook and
   controller.

None of these contracts requires the Statics Diamond to exist.

`StaticsV4Hook` reuses the existing Statics hook's fee collection, split,
exact-transfer, pool-registration, and permanent-liquidity machinery. It does
not reuse the existing immutable `staticsDiamond` dependency unchanged.

`StaticsHookController` is the hook's permanent integration endpoint. It
provides two-step transferable control, records pull-based revenue liabilities,
and exposes the bounded configuration operations accepted by the hook. Its
initial controller is the Statics launch multisig or treasury governance. The
full Statics Diamond or its timelock may later accept control without changing
the hook, PoolKey, launch positions, or historical fee claims.

The implementation may combine the one-time launch coordinator with the
controller if doing so reduces code and authority without weakening atomic
initialization or custody separation.

## Exact paired supply

The fixed Genesis conversion price is:

```text
P = 180,010 STATICS per Genesis NFT
```

The Genesis maximum supply is:

```text
N = 5,555 Genesis NFTs
```

The complete STATICS genesis supply is mechanically derived from those values:

```text
STATICS_GENESIS_SUPPLY
    = N * P
    = 5,555 * 180,010
    = 999,955,550 STATICS
```

There is no arithmetic remainder and no additional allocation outside these
5,555 paired units. `StaticsToken` has no post-deployment mint authority.
Future burns may reduce `totalSupply`, but nothing may increase it above the
genesis supply.

## Genesis allocations

The paired units are divided as follows:

| Economic allocation | Genesis state | STATICS state |
| --- | ---: | ---: |
| Treasury NFT founder allocation | 555 NFTs held by treasury | 99,905,550 held as Genesis Vault backing |
| Treasury token founder allocation | 500 NFTs held as vault inventory | 90,005,000 liquid STATICS held by treasury |
| Public allocation | 4,500 NFTs reserved for lazy mint | 810,045,000 STATICS held by the permanent launch market |
| **Total** | **5,555 NFTs** | **999,955,550 STATICS** |

At genesis, the collection has:

```text
minted supply:           1,055
treasury-owned NFTs:       555
vault inventory NFTs:      500
unminted public NFTs:     4,500
circulating NFTs:          555
```

The 555 treasury NFTs are fully backed at deployment:

```text
555 * 180,010 = 99,905,550 STATICS
```

The vault's logical backing ledger is initialized to exactly that amount. The
500 vault-owned NFTs are inventory, not circulating redemption liabilities,
and do not increase required backing while held by the vault.

The treasury's 90,005,000 STATICS is a founder allocation equivalent to 500
paired units in liquid-token form. It is not hook revenue, sale proceeds,
Genesis backing, or market liquidity.

## Token-form and NFT-form conservation

Before activation burns or accidental donations, the system maintains:

```text
vault backing
    = circulating Genesis NFTs * P

liquid STATICS outside Genesis backing
    = (N - circulating Genesis NFTs) * P

vault backing + liquid STATICS
    = STATICS_GENESIS_SUPPLY
```

Each paired unit exists in one of two forms:

```text
Token form
    180,010 liquid STATICS
    + one Genesis slot that is unminted or held by the vault

NFT form
    one circulating Genesis NFT
    + 180,010 STATICS held as immutable redemption backing
```

Vault purchase converts token form into NFT form. Redemption converts NFT form
back into token form. Neither operation creates revenue or changes aggregate
economic value.

## Public issuance and vault inventory

While unminted public supply remains, a successful public vault purchase will:

1. collect exactly `P` STATICS;
2. increase logical Genesis backing by exactly `P`; and
3. lazy-mint the next public Genesis NFT to the selected receiver.

The 4,500 public NFTs are lazy-minted before the vault recycles its 500 genesis
inventory NFTs. Once all 5,555 token IDs have been minted, a later purchase may
select a vault-owned inventory NFT, deposit `P`, and receive that NFT. Normal
issuance and inventory-sale flows preserve exact backing equality.

No Genesis NFT is sold directly for ETH or WETH.

## Fixed redemption and mechanical floor

The current owner of a circulating Genesis NFT may return it to the Genesis
Vault and receive exactly `P` STATICS to a valid receiver.

Redemption performs one atomic transition:

1. the NFT enters vault inventory;
2. circulating supply decreases by one;
3. logical backing decreases by exactly `P`; and
4. exactly `P` STATICS leaves the vault.

Redemption remains available even if new issuance is paused. Treasury,
governance, controllers, and future protocol modules may not withdraw, borrow,
burn, stake, lend, route, or otherwise use Genesis backing.

The fixed claim gives every Genesis NFT a mechanical base value of `P` STATICS.
Its practical external-market floor is the realizable market value of `P`
STATICS less gas, marketplace costs, and execution slippage. It is not a fixed
ETH, WETH, or fiat-denominated floor.

Later tier, boost, trait, or protocol utility may support a premium over this
base claim but must not change the redemption amount.

## Activation burns

Future Genesis activation may burn liquid STATICS, but it may never consume
Genesis Vault backing. Activation therefore reduces `totalSupply` without
reducing existing redemption liabilities.

Burns preserve the `P`-STATICS claim for every circulating NFT because its
backing is already isolated. They reduce future token-form conversion capacity:
after sufficient burns, some unminted or vault-owned Genesis slots may be unable
to circulate simultaneously unless another NFT is first redeemed.

This is an intentional deflationary consequence. The collection has a maximum
supply of 5,555, but activation burns may make simultaneous circulation of the
entire maximum economically impossible.

Transfer-related activation reset, PositionNFT linking, and reward-weight
transitions belong to later full-protocol integration. Those mechanics may not
weaken or complicate the fixed redemption claim.

## Canonical V4 inventory curve

The canonical launch market is:

```text
STATICS / WETH
```

The pool is initialized at a committed opening `sqrtPriceX96` with no WETH and
exactly 810,045,000 STATICS distributed across six adjacent launch positions.
Native Uniswap v4 concentrated-liquidity math remains the sole swap-pricing
mechanism. The hook does not implement a parallel bonding-curve equation
through custom accounting.

The shape is informed by Doppler Multicurve and current Bankr launches. Doppler
demonstrates that layered concentrated positions can shape how inventory becomes
available as price advances. Statics adopts that market-structure lesson without
adopting Doppler's Airlock, token factory, migration, governance, fee contracts,
or Diamond assumptions.

The previously considered 3%/95%/2% structure was rejected after modeling. It
distributed approximately 98% of public inventory by $100 million FDV, making
large quoted valuations cheap to reach only after nearly exhausting public
inventory. The later reach-oriented variants had the inverse defect: they left
more than 70% of public inventory above $10 billion FDV, making ordinary public
distribution depend on extraordinary adoption.

The accepted Balanced curve places meaningful inventory in every decade:

- **Opening discovery:** 3% below $1 million limits the cheapest capture.
- **Early market:** 7% from $1 million to $10 million continues price discovery
  without making most public inventory cheaply available.
- **Growth market:** 20% from $10 million to $100 million establishes broad
  ownership before institutional-scale valuations.
- **Established market:** 25% from $100 million to $1 billion provides real
  depth instead of a thin path to a headline valuation.
- **Large-cap market:** 30% from $1 billion to $10 billion makes this the
  largest distribution region while preserving continued inventory.
- **Exhaustion tail:** 15% from $10 billion to $100 billion protects against
  range exhaustion without requiring that region for ordinary distribution.

### Accepted reference price and tick model

The accepted model uses tick spacing 10 and the following reference values:

```text
STATICS genesis supply:       999,955,550
Public market inventory:      810,045,000
STATICS per Genesis unit:         180,010
Reference ETH price:             $1,624.95
```

The USD fully diluted valuations below are modeling coordinates, not onchain
oracle guarantees. The committed ticks set STATICS/WETH prices. Their realized
USD values move with the external WETH/USD price.

When STATICS is `currency0`, the accepted reference schedule is:

| Position | Reference tick-aligned FDV range | Tick range | Share | Genesis units | STATICS |
| --- | ---: | --- | ---: | ---: | ---: |
| B1 | $100,036 to $999,658 | `-166040 / -143020` | 3% | 135 | 24,301,350 |
| B2 | $999,658 to $9,999,580 | `-143020 / -119990` | 7% | 315 | 56,703,150 |
| B3 | $9,999,580 to $100,025,777 | `-119990 / -96960` | 20% | 900 | 162,009,000 |
| B4 | $100,025,777 to $999,557,647 | `-96960 / -73940` | 25% | 1,125 | 202,511,250 |
| B5 | $999,557,647 to $9,998,573,243 | `-73940 / -50910` | 30% | 1,350 | 243,013,500 |
| B6 | $9,998,573,243 to $100,015,709,113 | `-50910 / -27880` | 15% | 675 | 121,506,750 |

If STATICS is `currency1`, each range is negated and reversed: a token0 range
`[tickLower, tickUpper]` becomes `[-tickUpper, -tickLower]`. The initialization
tick is transformed the same way. The launch manifest must record the resolved
token order, six ranges, opening tick, and exact `sqrtPriceX96`; callers must
not infer ordering from this table.

The tick table is the accepted implementation and test baseline. Before public
deployment, the release manifest must explicitly ratify either this exact table
or a uniformly re-derived table that preserves the accepted reference FDV
boundaries at a newly approved WETH/USD reference. Once the pool initializes,
the actual ticks and opening price are permanent.

At each complete band boundary, cumulative public distribution is:

| Approximate FDV | Public inventory sold | Genesis-equivalent units | Public STATICS distributed |
| ---: | ---: | ---: | ---: |
| $1 million | 3% | 135 | 24,301,350 |
| $10 million | 10% | 450 | 81,004,500 |
| $100 million | 30% | 1,350 | 243,013,500 |
| $1 billion | 55% | 2,475 | 445,524,750 |
| $10 billion | 85% | 3,825 | 688,538,250 |
| $100 billion | 100% | 4,500 | 810,045,000 |

Using the reference boundaries and native concentrated-liquidity math, modeled
net WETH principal required to reach selected FDVs is approximately:

| Target FDV | Net market principal | Public inventory sold |
| ---: | ---: | ---: |
| $100 million | $5.31 million | 30.0% |
| $1 billion | $69.35 million | 55.0% |
| $2.52 billion | $278.14 million | 71.2% |
| $4 billion | $424.77 million | 76.9% |
| $10 billion | $837.86 million | 85.0% |

These estimates measure net directional principal before bilateral fees and
before the 25% fee-funded permanent-liquidity allocation deepens the market.
They are reference economics, not a promise of external WETH/USD value, trading
volume, time to reach a boundary, or proceeds available to treasury.

The launch requires no treasury WETH contribution and no third-party liquidity.
WETH-to-STATICS purchases are possible immediately. STATICS-to-WETH sales are
possible only to the extent the positions have accumulated WETH through prior
purchases or fee-funded permanent liquidity has supplied it. The system never
creates an unfunded WETH redemption promise.

There is no guaranteed raise, sellout, terminal price, or time to sell. If the
extreme tail is ever exhausted, the complete public inventory has been purchased
through an extraordinary price path. Exhaustion does not trigger migration or
mint additional supply.

The canonical PoolId, hook, launch positions, price history, and liquidity
remain in place when the full Statics protocol launches.

## Atomic launch initialization

The hook and controller will commit the expected launch configuration before
the pool is publicly tradable. The authorized launch transaction must
atomically:

1. bind the expected PoolManager, WETH, STATICS, hook, PoolKey, fee setting,
   tick spacing, opening `sqrtPriceX96`, and authorized initializer;
2. verify the hook holds exactly the 810,045,000-STATICS public inventory
   assigned for launch;
3. initialize the canonical pool at the committed price;
4. create B1-B6 with their committed ranges and unique salts;
5. settle exactly 24,301,350, 56,703,150, 162,009,000, 202,511,250,
   243,013,500, and 121,506,750 STATICS into B1-B6 respectively, subject only
   to explicitly accounted V4 rounding dust;
6. verify that the six positions consume exactly 810,045,000 STATICS before
   accounted rounding dust;
7. verify that no WETH was required; and
8. permanently close the launch-initialization authority.

The hook's `afterInitialize` path authenticates the initializer, PoolKey,
opening price, and committed launch configuration. It then synchronously opens
a PoolManager unlock and installs all six positions from the hook's
`unlockCallback`, where the resulting STATICS delta is settled. Position
creation does not call `modifyLiquidity` directly from `afterInitialize`,
because PoolManager liquidity modification requires an unlocked manager. If the
unlock, any position, or settlement fails, the complete pool initialization
reverts.

A wrong sender, PoolKey, price, range, salt, inventory amount, token order, or
repeated initialization must revert the complete transaction. Release testing
must measure this as a cold standalone transaction and prove the complete
atomic path consumes no more than the 16,000,000-gas transaction target. The
launch must not be split into publicly tradable partially initialized states to
work around a failed gas bound.

Launch positions are hook-owned direct PoolManager positions rather than
withdrawable user PositionManager NFTs. No controller, treasury, or later
Diamond function may decrease their liquidity.

## Reuse of the Statics hook

The new hook is a standalone refactor, not a new fee model. It carries forward
the reviewed behavior of the existing `StaticsSwapFeeHook` and the expanded
seven-way split developed on the superseded Genesis-tokenomics branch:

- zero native Uniswap v4 LP fee;
- explicit specified-leg and realized-unspecified-leg hook fees;
- exact-input and exact-output support;
- immutable combined fee ceiling;
- bounded global defaults and per-pool overrides;
- exact debit, receipt, settlement, and allowance checks;
- pool registration and canonical initialization protection;
- fee allocation with rounding remainder assigned deterministically;
- pull-based creator and partner liabilities;
- permissionless processing where the processor cannot redirect proceeds; and
- fee-funded permanent-liquidity accounting.

The current hook's immutable `staticsDiamond` authority and direct Diamond
reward-interface calls are not reusable in the standalone release. They are
replaced by `StaticsHookController` and pull-based liabilities. A reverting
treasury, partner, creator, reward module, or token receiver must not block a
swap.

The complete per-pool allocation vocabulary remains available for later use:

```text
permanent auto-compounding liquidity
liquidity providers
basket-token stakers
STATICS stakers
partner
index creator
Statics treasury
```

Only permanent liquidity and treasury are nonzero for the initial STATICS/WETH
configuration.

## Bilateral fee behavior

The pool uses zero native Uniswap v4 LP fees. The hook charges independently on
both economic legs:

```text
specified/input leg
    fee = configured input rate applied to specified input

realized/output leg
    fee = configured output rate applied to realized output
```

Equivalent direction-correct handling applies to exact-output swaps. The
implementation must preserve the existing Statics distinction between specified
and unspecified currency rather than assume token0 is always the input.

The exact input and output fee rates remain deployment parameters. Their sum may
not exceed the immutable 200-basis-point ceiling inherited from the current
hook design. This ADR does not adopt Bankr's fee rates or anti-snipe fee decay;
Bankr is a reference for multicurve launch structure and fee-funded locked
liquidity, not a parameter authority for Statics.

## Initial fee allocation

Every fee amount collected on either leg is allocated at accrual time:

```text
lockedLiquidity = floor(collectedFee * 2,500 / 10,000)
treasury         = collectedFee - lockedLiquidity
```

Assigning the arithmetic remainder to treasury ensures the two allocations
always equal the exact fee collected.

The resulting initial per-pool configuration is:

| Allocation | Share |
| --- | ---: |
| Permanent auto-compounding liquidity | 25% |
| Statics treasury | 75% |
| Liquidity providers | 0% |
| Basket-token stakers | 0% |
| STATICS stakers | 0% |
| Partner | 0% |
| Index creator | 0% |

Treasury revenue accrues as a pull-based per-recipient, per-asset liability.
The treasury therefore receives STATICS-denominated revenue from STATICS fee
legs and WETH-denominated revenue from WETH fee legs. Claiming one asset cannot
affect another asset's liability.

Recipient changes affect future accrual only. Previously accrued credit remains
owned by the recipient credited at accrual time.

`partnerRecipient == address(0)` means disabled and requires a zero partner
share. The initial STATICS/WETH pool has no partner or index-creator allocation.

## Fee-funded permanent liquidity

The hook retains 25% of every bilateral fee leg in a pool-local pending-liquidity
ledger. After each swap, it attempts to convert the available STATICS and WETH
into full-range V4 liquidity owned by the hook.

The hook may consume only the amounts recorded in that pool's pending ledger.
If one currency cannot yet be paired, the unmatched amount remains pending and
is retried after later swaps or through a permissionless compound function.
Callers receive no ownership, principal, or fee claim for triggering
compounding.

Fee-funded liquidity is permanent for the canonical STATICS/WETH pool. It may
not be removed, reassigned to treasury, counted as operating revenue, or used as
Genesis backing. The implementation must not carry forward a generic
decommission-and-release path that can release this pool's permanent liquidity.

The launch positions and fee-funded full-range position use distinct salts,
records, and accounting:

```text
six launch positions
    source: 810,045,000-STATICS public allocation
    purpose: initial distribution and permanent market principal

fee-funded full-range position
    source: 25% of bilateral trading fees
    purpose: deepen permanent two-sided market liquidity over time
```

## Economic boundaries

The release maintains four non-interchangeable economic buckets.

### Genesis backing

```text
circulating Genesis NFTs * P
```

This custody serves only valid redemption.

### Launch-market principal

This is the six launch positions' original 810,045,000 STATICS and the WETH
those positions accumulate through swaps. It is permanent market liquidity,
not revenue.

### Fee-funded permanent liquidity

This is the 25% fee allocation, pending pairing balances, and the full-range
liquidity created from them. It is market liquidity, not revenue.

### Treasury fee revenue

This is the 75% fee allocation credited to treasury as pull-based STATICS and
WETH liabilities. It is the standalone release's operating revenue stream.

No asset amount may be counted in more than one bucket.

## Later Statics Diamond integration

The full protocol will integrate by:

- recognizing the existing fixed-supply STATICS token;
- recognizing the existing Genesis collection and vault claim;
- preserving the existing STATICS/WETH PoolId and all permanent liquidity;
- accepting control through the controller's two-step transfer path;
- configuring later fee allocations and reward routes within immutable bounds;
  and
- adding PositionNFT linking, activation, staking-weight, baskets, lending,
  Statics Dollar, and reward-index behavior without migrating Genesis backing.

The later controller may tune future STATICS/WETH allocations from the initial
25%/75% split to the full protocol's governed seven-way allocation. It cannot
redirect historical treasury liabilities or unlock previously compounded
liquidity.

Genesis ownership remains optional for full-protocol access. The redemption
claim is intrinsic to Genesis and independent of future PositionNFT utility.

## Immutability and configuration boundary

The following values or guarantees are immutable:

- STATICS genesis supply and absence of mint authority;
- Genesis maximum supply;
- `P`;
- the 555/500/4,500 genesis allocation counts;
- the 3%/7%/20%/25%/30%/15% public-market inventory allocation;
- the STATICS token used for backing;
- prohibition on withdrawing Genesis backing;
- independence of redemption value from activation tier;
- PoolManager and WETH used by the canonical market;
- canonical PoolKey after initialization;
- the combined hook-fee ceiling;
- permanence of all six launch positions; and
- permanence of fee-funded STATICS/WETH liquidity.

The opening price, tick spacing, and exact region endpoints must be fixed before
public trading opens. Governance may configure future per-pool hook fee rates,
allocations, recipients, and approved pool integrations only within immutable
bounds.

## Security invariants

Implementation and release validation must prove at minimum:

1. `totalSupply` begins at exactly 999,955,550 STATICS and never increases.
2. Genesis minted supply never exceeds 5,555.
3. Genesis backing is at least `circulatingGenesis * P` after every transition.
4. Normal purchase and redemption preserve backing equality.
5. The 555 treasury NFTs are fully backed at deployment.
6. The 500 vault-owned NFTs create no liability until they leave inventory.
7. Redemption pays exactly `P` or reverts atomically.
8. No administrative path can consume or withdraw Genesis backing.
9. The launch transaction requires exactly 810,045,000 STATICS and zero WETH.
10. B1-B6 receive exactly 24,301,350, 56,703,150, 162,009,000, 202,511,250,
    243,013,500, and 121,506,750 STATICS respectively, subject only to explicitly
    accounted rounding dust.
11. The six launch positions sum to exactly 810,045,000 STATICS and 4,500 paired
    units while preserving the 3%/7%/20%/25%/30%/15% band allocation.
12. A wrong initializer, PoolKey, hook, opening price, range, salt, token order,
    or inventory amount reverts atomically.
13. The canonical pool cannot be initialized twice or initialized early by an
    unauthorized caller.
14. Launch-position liquidity never decreases.
15. Fee-funded permanent liquidity never decreases.
16. Launch principal, fee-funded liquidity, treasury liabilities, and Genesis
    backing remain separately solvent and are never double-counted.
17. Price and inventory movement follow native V4 concentrated-liquidity math
    under all valid swap sequences and rounding boundaries.
18. The pool cannot pay more WETH principal than its positions and pending
    ledgers actually hold.
19. Every specified-leg and realized-output-leg fee is backed by an exact token
    debit and receipt.
20. The 25% liquidity allocation plus 75% treasury allocation equals every fee
    collected, including rounding remainder.
21. Pending compounding balances plus treasury liabilities never exceed hook and
    controller custody for either asset.
22. Unmatched compounding balances remain recoverably pending without blocking
    swaps.
23. Permissionless compounding and processing cannot redirect proceeds or earn
    unauthorized claims.
24. A reverting treasury or future recipient cannot block swaps.
25. Controller transfer cannot alter historical claims or permanent liquidity.
26. Direct token or NFT donations can only overcollateralize custody and cannot
    create withdrawable revenue or unearned claims.
27. Activation burns cannot debit or reduce Genesis backing.
28. The complete cold standalone initialization, six-position installation,
    and settlement transaction does not exceed the 16,000,000-gas target.

Stateful invariant tests must exercise arbitrary sequences of public issuance,
inventory purchase, NFT transfer, redemption, direct donation, exact-input
swaps, exact-output swaps, treasury claims, compounding, controller transfer,
and later burn integration.

Real V4 integration tests must prove atomic launch from zero WETH, the exact
six-position inventory placement, purchases through every band transition,
both swap directions after WETH enters the pool, bilateral fee collection,
25%/75% allocation, pull-based treasury claims, repeated compounding, and
conservation of every market asset. A separate cold standalone gas regression
must measure the complete launch transaction against the 16,000,000-gas target.

## Alternatives considered

### Separate constant-product bonding curve followed by graduation

Rejected. Livo's `ConstantProductBondingCurve` demonstrates a conventional
standalone curve, but Statics does not need a separate reserve contract,
graduation threshold, migration transaction, or second market. The canonical V4
pool can hold the sale inventory and perform price discovery directly.

### One wide concentrated-liquidity launch position

Rejected. It is simple, but constant liquidity front-loads the cheapest
inventory. The earlier version of this ADR used this model. Doppler Multicurve's
analysis and the resulting inventory model support a small discovery tranche,
a broad main market, and a small tail instead.

### Three adjacent positions with 3%/95%/2% inventory

Rejected. This curve distributes approximately 98% of public inventory by
$100 million FDV and leaves only 2% to carry the market from $100 million toward
$100 billion. It therefore nearly exhausts public distribution too early and
creates a thin, cheaply moved large-valuation market.

### Reach-oriented curve with most inventory above $10 billion

Rejected. Holding more than 70% of public inventory above $10 billion makes
ordinary distribution depend on extraordinary demand. Upper-tail inventory is
needed to avoid range exhaustion, but it should not contain most paired public
supply. The Balanced curve leaves 15%, or 675 Genesis-equivalent units, above
$10 billion.

### Adopt Doppler/Airlock directly

Rejected. Doppler is a valuable market-structure and implementation reference,
but Statics already has bilateral fee collection, split accounting, permanent
liquidity, pool registration, and future protocol-specific allocation channels.
Adopting Airlock would add token-factory, migration, beneficiary, and governance
machinery that Statics does not require.

### Graduate into a conventional pool at a chosen FDV

Rejected. The broad main region already supplies ordinary concentrated-liquidity
pricing after discovery. The extreme tail avoids an operational handoff. The
same PoolId remains canonical from launch onward.

### Route 100% of initial fees to treasury

Rejected. Trading fees should simultaneously fund operations and build a
permanent two-sided liquidity floor. The accepted initial allocation is 25%
auto-compounding liquidity and 75% treasury revenue.

## Non-goals

- Deploying the complete Statics Diamond in the Genesis release.
- Ongoing STATICS emissions or discretionary minting.
- Selling Genesis NFTs directly for ETH or WETH.
- Deploying a separate bonding curve, graduation mechanism, or market migration.
- Requiring treasury WETH or third-party liquidity to open the market.
- Guaranteeing a fixed WETH raise, sold supply, terminal price, or sale time.
- Treating Genesis backing, launch principal, or compounded liquidity as
  treasury revenue.
- Giving treasury or governance a Genesis-backing or permanent-liquidity
  withdrawal path.
- Promising an ETH, WETH, or fiat-denominated NFT floor.
- Using the canonical pool's spot price as a manipulation-resistant protocol
  oracle.
- Copying Bankr's fee rates, anti-snipe decay, creator vesting, or token supply.
- Finalizing initial hook fee rates or controller addresses in this ADR.
- Finalizing PositionNFT reward-weight implementation in the standalone release.

## Consequences

- Treasury begins with founder exposure in both forms: 555 fully backed Genesis
  NFTs and 500 paired units of liquid STATICS.
- Every public conversion of STATICS into Genesis backing reduces liquid supply
  by exactly `P` and increases circulating NFT supply by one.
- Every redemption reverses that transition exactly.
- Only 10% of public inventory is available below $10 million FDV, limiting
  cheap early capture while allowing observable price discovery.
- 45% of public inventory is distributed between $10 million and $1 billion,
  giving the market meaningful depth before large-cap valuations.
- 30% of public inventory is distributed between $1 billion and $10 billion,
  making that the largest band rather than treating it as an extraordinary
  tail.
- The final 15% makes complete inventory exhaustion economically remote without
  requiring a $10 billion valuation for ordinary public distribution.
- Every trade builds permanent liquidity while creating claimable treasury
  revenue in the assets actually charged.
- Operating revenue is observable hook-fee revenue rather than an accounting
  label applied to founder allocation, backing, or market reserves.
- The full Statics protocol can launch later without replacing the Genesis
  collection, token, vault, hook, or canonical STATICS/WETH market.

## Follow-up decisions

The implementation specification and deployment manifest must settle:

- whether deployment ratifies the accepted reference tick table unchanged or
  uniformly re-derives it from a newly approved WETH/USD reference;
- the token-order-correct opening `sqrtPriceX96`, ranges, and unique salts;
- initial input/output hook fee rates within the 200-basis-point ceiling;
- whether an anti-snipe mechanism is unnecessary or should be specified
  separately;
- whether third-party liquidity is permissionless, restricted, or disabled for
  the canonical pool;
- launch controller, treasury, and later control-acceptance addresses;
- exact V4 rounding-dust treatment;
- metadata behavior before and after later activation integration; and
- the narrow future interface through which the Diamond coordinates Genesis
  tier, link, and reward-weight transitions.

## References

- [Current Statics swap-fee hook](../../src/liquidity/StaticsSwapFeeHook.sol)
- [Statics Genesis-tokenomics PR #27](https://github.com/EqualFiLabs/statics/pull/27)
- [Doppler Multicurve paper](https://www.doppler.lol/multicurve.pdf)
- [Doppler `Multicurve.sol`](https://github.com/whetstoneresearch/doppler/blob/main/src/libraries/Multicurve.sol)
- [Doppler `NoOpMigrator.sol`](https://github.com/whetstoneresearch/doppler/blob/main/src/migrators/NoOpMigrator.sol)
- [Doppler SDK multicurve examples](https://github.com/whetstoneresearch/doppler-sdk)
- [Bankr token-launch documentation](https://docs.bankr.bot/token-launching/overview/)
- [Bankr fee structure](https://docs.bankr.bot/token-launching/fee-splitting/)
- [Observed Bankr/Doppler Base launch transaction](https://base.blockscout.com/tx/0x283159aae571ce4f403ea04fc25c2f3d80004ae256157a6d502245719dc0ded3)
- [Crotto fixed-backing NFT vault](https://github.com/EqualFiLabs/crotto/blob/master/src/diamond/facets/NFTVaultFacet.sol)
- [Crotto canonical V4 fee hook](https://github.com/EqualFiLabs/crotto/blob/master/src/liquidity/CrottoSwapFeeHook.sol)
- [Livo constant-product bonding curve](https://github.com/LivoLaunchpad/livo-contracts/blob/main/src/bondingCurves/ConstantProductBondingCurve.sol)
- [Uniswap v4 core repository](https://github.com/Uniswap/v4-core)
