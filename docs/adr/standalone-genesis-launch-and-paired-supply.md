# ADR: Standalone Genesis launch and paired STATICS supply

- Status: Accepted direction; implementation pending
- Date: 2026-08-15
- Scope: standalone STATICS launch, Genesis NFT issuance and backing,
  single-sided Uniswap v4 distribution, hook fee revenue, and later Statics
  Diamond integration
- Supersedes: the unmerged Genesis-tokenomics direction on
  `feat/genesis-tokenomics`

## Context

Statics needs a launchable Genesis product before the complete Statics Diamond
is ready. The release must establish the STATICS token, the 5,555-token Genesis
collection, a fully backed fixed-price conversion between the two, and a
canonical Uniswap v4 market that can survive the later launch of the full
protocol. The launch market and the long-lived canonical market are the same
pool.

The launch must not require EqualFi Labs to sell a discretionary treasury token
allocation to fund development. Users acquire STATICS from a market. EqualFi
Labs earns operating revenue from explicit trading fees. Genesis redemption
backing and market liquidity are not operating revenue.

Genesis NFTs and STATICS are not independent allocations. They are two
convertible forms of the same fixed genesis supply. A circulating Genesis NFT
is a claim on a fixed amount of STATICS held by the Genesis Vault. An unminted
or vault-owned Genesis slot leaves its corresponding STATICS in liquid token
form.

The full Statics Diamond, PositionNFTs, baskets, Statics Dollar, lending, and
global reward indexes are outside the deployment boundary of this release.

## Decision

Statics will launch a standalone contract set consisting of:

1. `StaticsToken`;
2. `StaticsGenesis`;
3. `StaticsGenesisVault`;
4. `StaticsV4Hook`; and
5. an authorized one-time pool and launch-position initialization path.

None of these contracts will require the Statics Diamond to exist. The full
protocol must later adopt the deployed token, Genesis collection, hook, and
STATICS/WETH pool rather than replace them.

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

There is no arithmetic remainder and no additional token allocation outside
these 5,555 paired units. `StaticsToken` has no post-deployment mint authority.
Future burns may reduce `totalSupply`, but nothing may increase it above the
genesis supply.

## Genesis allocations

The launch divides the paired units as follows:

| Economic allocation | Genesis state | STATICS state |
| --- | ---: | ---: |
| Treasury NFT founder allocation | 555 NFTs held by treasury | 99,905,550 held as Genesis Vault backing |
| Treasury token founder allocation | 500 NFTs held as vault inventory | 90,005,000 liquid STATICS held by treasury |
| Public allocation | 4,500 NFTs reserved for lazy mint | 810,045,000 STATICS distributed through the launch market |
| **Total** | **5,555 NFTs** | **999,955,550 STATICS** |

At genesis, the collection therefore has:

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

The vault's logical backing ledger must be initialized to exactly that amount.
The 500 vault-owned NFTs are inventory, not circulating redemption liabilities,
and therefore do not increase required backing while they remain in the vault.

The treasury's 90,005,000 STATICS is a genesis founder allocation equivalent to
500 paired units in liquid-token form. It is not hook revenue, sale proceeds,
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

The 4,500 public NFTs will be lazy-minted before the vault recycles its 500
genesis inventory NFTs. Once all 5,555 token IDs have been minted, a later
purchase may select a vault-owned inventory NFT, deposit `P`, and receive that
NFT. Normal issuance and inventory-sale flows preserve exact backing equality.

No Genesis NFT is sold directly for ETH or WETH.

## Fixed redemption and mechanical floor

The current owner of a circulating Genesis NFT may return it to the Genesis
Vault and receive exactly `P` STATICS to a valid receiver.

Redemption performs one atomic transition:

1. the NFT enters vault inventory;
2. circulating supply decreases by one;
3. logical backing decreases by exactly `P`; and
4. exactly `P` STATICS leaves the vault.

Redemption must remain available even if new issuance is paused. Treasury,
governance, controllers, and future protocol modules may not withdraw, borrow,
burn, stake, lend, route, or otherwise use Genesis backing.

The fixed claim gives every Genesis NFT a mechanical base value of `P` STATICS.
Its practical external-market floor is the realizable market value of `P`
STATICS less gas, marketplace costs, and execution slippage. It is not a fixed
ETH, WETH, or fiat-denominated floor.

Later tier, boost, trait, or protocol utility may support a premium over this
base claim but must not increase or decrease the redemption amount.

## Activation burns

Future Genesis activation may burn liquid STATICS, but it may never consume
Genesis Vault backing. Activation therefore reduces `totalSupply` without
reducing existing redemption liabilities.

Burns preserve the `P`-STATICS floor for every circulating NFT because its
backing is already isolated. They reduce future token-form conversion capacity:
after sufficient burns, some unminted or vault-owned Genesis slots may be unable
to circulate simultaneously unless another NFT is first redeemed.

This is an intentional deflationary consequence. The collection has a maximum
supply of 5,555, but activation burns may make simultaneous circulation of the
entire maximum economically impossible.

Transfer-related activation reset, PositionNFT linking, and reward-weight
transitions belong to the later full-protocol integration. Those mechanics may
not weaken or complicate the fixed redemption claim.

## One-sided Uniswap v4 launch market

The initial public market receives exactly:

```text
4,500 * 180,010 = 810,045,000 STATICS
```

The public inventory is deposited directly into the canonical market:

```text
STATICS / WETH
```

The pool is initialized at a configured opening price with a protocol-owned,
single-sided concentrated-liquidity position containing the complete
810,045,000-STATICS public allocation and no WETH. The position range and
liquidity define the launch price path through native Uniswap v4 concentrated-
liquidity math. Statics will not reimplement swap pricing through hook custom
accounting.

The pool supports WETH-to-STATICS purchases immediately. A purchase moves WETH
into the position and STATICS out to the buyer. STATICS-to-WETH sales become
possible only to the extent the position has accumulated WETH through prior
purchases or later explicit liquidity additions. Treasury, vault-redeemed, and
other externally sourced STATICS therefore trade under the same ordinary pool
rules without creating an unfunded WETH liability.

The launch requires no treasury WETH contribution and no third-party liquidity.
The initial STATICS inventory is market principal, not a token sale by treasury
and not operating revenue. WETH received by the position remains market
liquidity. Only explicitly charged hook fees become operating revenue.

There is no separate bonding-curve contract, reserve vault, graduation
threshold, graduation transaction, or migration to another market. The
canonical PoolId, hook, price history, and liquidity position exist from the
first trade and remain the market later adopted by the full Statics protocol.

The launch position is permanent protocol-owned liquidity. Neither treasury nor
the controller may remove it or claim its principal. Any future in-pool
repositioning, range extension, or exceptional decommission path requires a
separate explicit governance decision that preserves market-asset accounting;
it is not implicit authority of the launch controller.

The pool uses zero native Uniswap v4 LP fees and the standalone Statics hook.
Additional user or protocol liquidity may be supported under the hook's defined
pool policy, but the market must never depend on that additional liquidity to
open or continue accounting for the launch position.

As users acquire STATICS and deposit it into the Genesis Vault, the V4 position
naturally shifts from STATICS toward WETH. Genesis redemptions return STATICS to
liquid circulation. This market behavior is part of the paired design rather
than a backing shortfall.

The pool initialization path must atomically bind the expected PoolKey,
authorized initializer, hook, opening `sqrtPriceX96`, launch range, launch
liquidity, and exact STATICS inventory before public trading. A third party must
not be able to initialize the predictable canonical pool at another price or
modify the launch position.

## Standalone Statics v4 hook

The hook will not contain an immutable dependency on the Statics Diamond. It
will use a two-step transferable controller:

```text
launch controller: Statics launch multisig or treasury governance

later controller: Statics Diamond or Statics timelock
```

Controller transfer changes future configuration authority only. It does not
move accrued claims, change historical allocation, alter PoolIds, or release
permanent liquidity.

The hook will support an explicit per-pool configuration registry so the same
deployed hook can later serve STATICS/WETH, Basket/WETH, Basket/constituent, and
approved partner pools. Configuration will be bounded and will not iterate an
unbounded recipient list during swaps.

The initial STATICS/WETH fee allocation is:

```text
Treasury: 100%
POL:        0%
Rewards:    0%
Partner:    0%
```

This is allocation of the collected hook fee, not a 100% swap fee. Exact input
and output fee rates remain launch parameters subject to an immutable combined
fee ceiling.

Fee revenue will accrue as pull-based per-recipient, per-asset liabilities so a
reverting recipient cannot block swaps. Configuration changes affect future
fees only. Previously accrued credit remains owned by the recipient credited at
accrual time.

`partnerRecipient == address(0)` explicitly means partner allocation is
disabled and requires `partnerShareBps == 0`. The hook retains a bounded partner
channel for later partner markets without assigning partner revenue to the
initial Statics-owned pool.

## Economic boundaries

The release maintains three non-interchangeable economic buckets.

### Genesis backing

```text
circulating Genesis NFTs * P
```

This custody serves only valid redemption.

### Market liquidity

This includes the launch position's STATICS inventory, the WETH accumulated by
that position through swaps, and any later protocol-owned liquidity explicitly
added to the market. These assets create and maintain the market and are not
operating revenue.

### Trading-fee revenue

This consists only of V4 hook trading fees. It is the initial operating revenue
stream for continued Statics development.

No asset amount may be counted in more than one bucket.

## Later Statics Diamond integration

The full protocol will integrate with the launch contracts by:

- recognizing the existing fixed-supply STATICS token;
- recognizing the existing Genesis collection and vault claim;
- preserving the existing STATICS/WETH PoolId and liquidity;
- accepting hook control through the hook's two-step transfer path;
- configuring later fee allocations and rewards through bounded hook controls;
  and
- adding PositionNFT linking, activation, staking-weight, baskets, lending,
  Statics Dollar, and reward-index behavior without migrating Genesis backing.

Genesis ownership will remain optional for full-protocol access. The redemption
claim is intrinsic to Genesis and independent of future PositionNFT utility.

## Immutability and configuration boundary

The following values or guarantees are immutable:

- STATICS genesis supply and absence of mint authority;
- Genesis maximum supply;
- `P`;
- the 555/500/4,500 genesis allocation counts;
- the STATICS token used for backing;
- prohibition on withdrawing Genesis backing;
- independence of redemption value from activation tier;
- PoolManager and WETH used by the canonical launch market;
- the combined hook-fee safety ceiling; and
- the permanent-liquidity policy of the launch STATICS/WETH pool.

The canonical PoolKey, opening price, launch range, launch liquidity, and
inventory amount must be fixed before public trading opens. Governance may
configure future per-pool hook fee rates, allocations, recipients, and approved
pool integrations only within immutable bounds.

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
9. PoolManager, position, and hook custody cover every recorded market asset and
   fee liability.
10. No WETH or STATICS amount is recorded in two economic buckets.
11. The launch position begins with exactly 810,045,000 STATICS and requires no
    WETH contribution.
12. The market cannot pay out more WETH principal than the position has
    accumulated through prior swaps or later explicit liquidity additions.
13. Price and inventory movement follow native V4 concentrated-liquidity math
    under all valid swap sequences and rounding boundaries.
14. The canonical pool is initialized once at the committed PoolId, opening
    price, and launch range.
15. Unauthorized pool initialization and liquidity modification revert.
16. Hook allocations sum to every fee collected on both swap legs.
17. Recipient changes cannot redirect historical fee claims.
18. Permanent STATICS/WETH launch liquidity never decreases.
19. Direct token or NFT donations can only overcollateralize custody and cannot
    create withdrawable revenue or unearned claims.
20. Activation burns cannot debit or reduce Genesis backing.

Stateful invariant tests must exercise arbitrary sequences of public issuance,
inventory purchase, NFT transfer, redemption, direct donation, exact-input
swaps, exact-output swaps, hook-fee claims, and later burn integration. Real V4
integration tests must prove launch from zero WETH, inventory distribution,
both swap directions after WETH enters the position, fee routing, and market-
asset conservation.

## Non-goals

- Deploying the complete Statics Diamond in the Genesis release.
- Ongoing STATICS emissions or discretionary minting.
- Selling Genesis NFTs directly for ETH or WETH.
- Deploying a separate bonding curve, auction, graduation mechanism, or market
  migration path.
- Requiring treasury WETH or third-party liquidity to open the market.
- Guaranteeing a fixed WETH raise, sold supply, terminal price, or time to sell
  through the launch range.
- Treating Genesis backing or V4 market liquidity as treasury revenue.
- Giving treasury or governance a Genesis-backing withdrawal path.
- Promising an ETH, WETH, or fiat-denominated NFT floor.
- Using the canonical pool's spot price as a manipulation-resistant protocol
  oracle.
- Finalizing the opening price, launch range, fee rates, tick spacing, or
  controller addresses in this ADR.
- Finalizing PositionNFT reward-weight implementation in the standalone release.

## Consequences

- Treasury begins with founder exposure in both forms: 555 fully backed Genesis
  NFTs and 500 paired units of liquid STATICS.
- Every public conversion of STATICS into Genesis backing reduces liquid supply
  by exactly `P` and increases circulating NFT supply by one.
- Every redemption reverses that transition exactly.
- Maximum NFT backing can approach the complete token supply; liquid market
  depth is therefore endogenous to Genesis issuance and redemption.
- V4 liquidity supplies token-form public inventory from the first trade and can
  shift toward WETH as Genesis demand absorbs STATICS.
- Future activation burns preserve existing NFT floors while reducing future
  conversion capacity and increasing scarcity.
- Operating revenue is observable market-fee revenue rather than an accounting
  label applied to founder allocation, backing, or reserves.
- The full Statics protocol can launch later without replacing the Genesis
  collection, token, vault, hook, or canonical STATICS/WETH market.

## Follow-up decisions

The implementation specification must settle:

- the opening human price and its token-order-correct `sqrtPriceX96` value;
- tick spacing, one-sided launch-range endpoints, and the exact liquidity value
  that deposits 810,045,000 STATICS;
- behavior when price reaches either end of the launch range, including whether
  any later range extension or repositioning can ever be authorized;
- initial V4 input/output hook fee rates and combined ceiling;
- whether third-party liquidity is permissionless, restricted, or disabled for
  the canonical launch pool;
- deployment controller, treasury, and later control-acceptance process;
- precise treatment of V4 rounding dust;
- metadata behavior before and after later activation integration; and
- the narrow future interface through which the Diamond coordinates Genesis
  tier, link, and reward-weight transitions.
