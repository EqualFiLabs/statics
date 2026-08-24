# ADR: Doppler Genesis launch with permanent activation and staged rewards

- Status: Accepted direction; amended by
  `genesis-reserve-backed-vault.md`
- Date: 2026-08-18
- Scope: Doppler Multicurve launch of STATICS/WETH, fully minted Genesis
  inventory, permanent activation state, permanent Doppler fee ingress,
  standalone Genesis rewards, transfer-reset activation, and later handoff to
  the full Statics reward system
- Supersedes: `standalone-genesis-launch-and-paired-supply.md`
- Amended by: `genesis-reserve-backed-vault.md`, which replaces the fixed
  180,018-STATICS claim with 180,000 STATICS plus a post-epoch 1/5,555 native
  ETH reserve share, routes the native acquisition fee and a configurable share
  of harvested WETH into that permanent reserve, and forwards activation
  payments to the treasury instead of burning STATICS. The 180,018-STATICS and
  withdrawable-fee economics described below are retained as historical context.
- Preserves: the fixed Genesis maximum supply, Genesis Vault custody and
  backing model, fixed redemption claim, marketplace compatibility, native
  acquisition fee, and separation from the later Statics Diamond except where
  this ADR expressly changes them

## Context

Statics needs to launch STATICS and Genesis before the complete Statics Diamond
is ready. The standalone release must provide a real STATICS/WETH market,
mechanically backed Genesis NFTs, immediate utility for Genesis activation, and
an explicit path into the later PositionNFT reward system.

The previous architecture built and operated a custom STATICS/WETH Uniswap v4
hook. Doppler already supplies a purpose-built v4 Multicurve launch market,
standard LP-fee beneficiary accounting, token deployment, governance handoff,
and a no-migration path. Reimplementing those launch-market responsibilities
in Statics would add code and integration risk without adding basket-specific
behavior.

Statics will therefore use Doppler for the protocol-token market. The Statics
v4 hook remains part of the full protocol for BasketToken markets, where
Statics-specific fee routing, locked liquidity, protocol-owned liquidity, and
basket rewards are core protocol behavior.

The launch also brings Genesis activation and fee rewards forward. Permanent
identity and activation state must outlive the temporary launch reward system,
while historical launch claims must remain available without migration.

## Decision summary

The standalone release has the following economic topology:

```text
1,000,000,000 fixed STATICS
        |
        +-- 200,000,000 -> treasury
        |
        +-- 800,000,000 -> Doppler Multicurve inventory


Doppler STATICS/WETH market
        |
        +-- 5% of launch-position fees -> Doppler/Airlock owner
        +-- 95% of launch-position fees -> StaticsFeeReceiver
                  |
                  v
        GenesisLaunchDistributor
                  |
                  +-- registered Genesis NFT rewards
                  +-- Statics treasury


StaticsGenesis <-> GenesisActivationRegistry
        |
        v
StaticsGenesisVault
```

The long-lived standalone contracts are:

1. `StaticsGenesis`;
2. `StaticsGenesisVault`;
3. `GenesisActivationRegistry`; and
4. `StaticsFeeReceiver`.

The launch-era `GenesisLaunchDistributor` is replaceable. It becomes claim-only
when the full Statics reward system accepts future fee ingress and activation
callbacks.

## Fixed STATICS supply and allocation

STATICS uses Doppler's standard fixed-supply token implementation. The initial
and maximum supply is:

```text
1,000,000,000 STATICS
```

There is no discretionary mint authority after creation.

The genesis allocation is:

| Destination | Share | STATICS |
| --- | ---: | ---: |
| Treasury | 20% | 200,000,000 |
| Doppler public inventory | 80% | 800,000,000 |
| **Total** | **100%** | **1,000,000,000** |

The treasury allocation and protocol Genesis reserve are vested under the later
accepted `protocol-treasury-genesis-reserve-and-launch-vesting.md` ADR. Its
99,900,000-STATICS backing commitment, 100,100,000-STATICS vesting principal,
555-Genesis reserve, and immutable 60-day schedule supersede the direct
treasury-transfer and all-vault-custody details below.

The Doppler Airlock creation path uses the launch governance factory and the
immutable treasury vesting contract as its remainder recipient. Multicurve
rounding dust is sent to the Genesis Vault as non-liability surplus. The no-op
governance factory is unsuitable because it routes excess supply to a dead
address.

## Genesis inventory and fixed claim

The entire Genesis collection exists from deployment:

```text
maximum and minted supply: 5,555 Genesis NFTs
initial owner:             StaticsGenesisVault
initial circulating NFTs: 0
```

There is no lazy mint path and no treasury NFT allocation.

Every circulating Genesis NFT represents a fixed claim of:

```text
P = 180,018 STATICS
```

Full backing capacity is:

```text
5,555 * 180,018 = 999,999,990 STATICS
```

The fixed token supply is therefore ten STATICS greater than full Genesis
backing capacity. This residual is explicit:

```text
RESIDUAL_STATICS = 10 STATICS
```

Before activation burns or donations, conservation is:

```text
vault backing
    = circulating Genesis NFTs * 180,018

vault backing + liquid STATICS outside the backing ledger
    = 1,000,000,000 STATICS

liquid STATICS outside the backing ledger
    = (5,555 - circulating Genesis NFTs) * 180,018 + 10
```

The ten-token residual never creates an additional NFT claim.

## Genesis Vault

The vault is a simplified internal Anvil-style inventory market, not an ETH
sale and not an AMM.

To acquire a vault-owned Genesis NFT, a user supplies exactly `P` STATICS plus
the configured flat native acquisition fee:

```text
180,018 STATICS + native acquisition fee
        |
        v
StaticsGenesisVault
        |
        v
selected Genesis NFT
```

The native fee is affordable, owner-configurable within an immutable cap, and
credited to the recipient active when the purchase occurs. It is pull-based so
a reverting treasury cannot block acquisition. The initial fee remains a
deployment parameter; the prior 0.003 native-token value is the working
default, with a permanent 0.01 native-token cap.

Redemption returns a Genesis NFT to vault inventory and releases exactly `P`
STATICS. Redemption charges no native fee.

The core solvency invariant is:

```text
actual STATICS custody >= logical backing
logical backing = circulating Genesis NFTs * P
```

Direct NFT transfers to the vault are permitted. They create backing surplus
rather than a withdrawal right for the sender. Surplus may not be treated as
treasury revenue or withdrawn through an administrative escape hatch.

Vault backing may never fund activation, rewards, liquidity, lending, fees, or
treasury operations.

## Genesis marketplace behavior

`StaticsGenesis` remains a standard ERC-721 collection compatible with
ordinary Seaport approvals, listings, offers, and transfers when unlocked.

It provides:

- ERC-173-compatible ownership through OpenZeppelin `Ownable2Step`;
- ERC-2981 royalty discovery with bounded owner configuration;
- ERC-7572 `contractURI()` and `ContractURIUpdated()`;
- ERC-4906 metadata update signals;
- ERC-5192 lock signaling while linked to a PositionNFT; and
- ERC-721C current and legacy interface discovery, with a zero validator
  meaning unrestricted transfers at launch.

The owner may deliberately configure a nonzero transfer validator later. A
validator-originated transfer must still satisfy normal ERC-721 authorization.
Ownership renunciation is disabled so collection administration cannot become
irrecoverably stranded.

All Genesis metadata and SVG rendering remain deterministic and onchain.

## Doppler Multicurve launch

STATICS/WETH launches directly through Doppler Multicurve. There is no custom
Statics protocol-token hook, separate bonding-curve contract, graduation,
second pool, or liquidity migration.

The launch uses:

- Doppler Airlock;
- `DopplerERC20V1` through its whitelisted token factory;
- the stock Doppler Multicurve hook initializer;
- the launch governance factory, configured with the Statics treasury;
- the no-op migrator so the market remains in its original pool; and
- no atomic developer buy.

Deployment must prove that every configured standard Doppler module has code,
that the Airlock creates the intended static-fee pool, and that the pool records
exactly the mandatory 5% Doppler/Airlock-owner beneficiary share and 95%
`StaticsFeeReceiver` beneficiary share. The integration proof must execute on
both Robinhood and Base Sepolia rather than inferring compatibility from code
presence alone. It must perform an actual swap and prove that the standard
initializer releases the receiver share into Genesis and treasury accounting.

The production deployment manifest must record the exact chain, upstream
contract addresses, source versions, token order, salt, pool key, fee schedule,
governance addresses, Multicurve configuration, beneficiaries, and resulting
addresses.

### Four-curve implementation preset

Launch economics remain to be ratified. Implementation and integration tests
will use the current Doppler SDK Multicurve preset as a nonproduction fixture,
not as accepted production tokenomics.

The preset resolves the 800,000,000-STATICS market allocation into four curves:

| Fixture curve | Share | STATICS | Positions |
| --- | ---: | ---: | ---: |
| Low | 50% | 400,000,000 | 11 |
| Medium | 25% | 200,000,000 | 11 |
| High | 24% | 192,000,000 | 11 |
| Filler | 1% | 8,000,000 | 11 |
| **Total** | **100%** | **800,000,000** | **44** |

The fixture records the upstream SDK source revision and the fully resolved
configuration. Tests must not silently change if a future SDK release changes
its defaults.

The canonical Robinhood deployment entry point remains compile-time locked
while the approved configuration hash is zero. A follow-up economic-parameter
decision must pin the exact curves, static fee, and Genesis reward share before
that lock can be removed. The initializer may return at most 100 STATICS of
rounding residual; a larger return reverts rather than silently shrinking the
public market allocation.

The previous six-band FDV ladder is rejected. Its dollar ranges and inventory
shares are not accepted economics and must not remain in deployment code as
production defaults.

Production curve count, ticks, position counts, weights, WETH reference price,
and static pool fee require a separate launch-parameter ratification before
production deployment.

### External liquidity

The stock Doppler pool remains permissionless. External LPs may add liquidity
from launch.

The pool uses a standard static Uniswap v4 LP fee. External LP positions earn
fees attributable to their own liquidity under ordinary v4 accounting; they do
not participate in the beneficiary split of fees earned by Doppler's launch
positions. This release does not introduce a custom outside-LP reward gate or a
Statics wrapper around Doppler liquidity.

## Standard Doppler fee routing

The stock Doppler Multicurve initializer owns the launch liquidity positions
and accounts for the LP fees those positions earn. Its beneficiary shares are
configured exactly as:

```text
Doppler/Airlock owner:  5%
StaticsFeeReceiver:    95%
```

These percentages allocate fees earned by the Doppler launch positions; they
are not the pool's swap fee rate and do not seize fees earned by unrelated
external LP positions. There is no post-swap fee poster, dynamic fee decay, or
fee-funded auto-liquidity layer. The pool's static fee is a separately ratified
launch parameter.

The `StaticsFeeReceiver` is a beneficiary, not a fee-routing controller. The
temporary `GenesisLaunchDistributor` splits the receiver's collected assets
between registered Genesis rewards and treasury according to its governed
reward-share parameter.

## Permanent `StaticsFeeReceiver`

Doppler fee ingress terminates at a permanent minimal receiver rather than at a
replaceable reward implementation.

The receiver must:

1. authenticate the configured standard Doppler initializer and bound pool;
2. calculate harvested revenue using atomic balance deltas;
3. maintain cumulative harvested accounting per asset;
4. attribute harvested amounts to the distributor active at collection time;
5. preserve old distributor liabilities after rotation;
6. rotate distributors through propose/accept; and
7. expose pull-based distributor claims.

Raw balances are not revenue. Anyone may donate ERC-20 tokens, so only the
balance delta surrounding an authenticated fee collection increments the
protocol ledger.

The first distributor activation establishes a boundary for the launch system.
Every later acceptance harvests and attributes currently collectable fees to
the old distributor before installing the new distributor.

Only surplus above all recorded liabilities may be recovered. Recovery must
never reduce a distributor's claim.

## Permanent Genesis activation registry

Genesis activation begins during the standalone launch. Its canonical state
lives in `GenesisActivationRegistry`, not in the temporary launch distributor
or future Diamond.

The multiplier schedule is:

| Tier | Reward multiplier |
| --- | ---: |
| 0 | 1.00x |
| 1 | 1.10x |
| 2 | 1.15x |
| 3 | 1.20x |
| 4 | 1.25x |

Tier 0 has no boost. Activation progresses sequentially, but a holder may
activate multiple tiers in one transaction by paying the cumulative cost.

The working burn costs are 10,000, 20,000, 30,000, and 40,000 STATICS for the
four transitions. Governance may change future costs within bounds of 1,000 to
100,000 STATICS per transition. Earned tiers are not repriced or revoked by a
cost change.

Activation pulls the exact liquid STATICS cost into the registry and burns it
through the Doppler token's holder burn function. Exact-transfer checks reject
fee-on-transfer behavior. Activation may never debit Genesis Vault backing.

The registry exposes a narrow consumer callback before any weight change:

```solidity
interface IGenesisActivationConsumer {
    function onGenesisTransition(
        uint256 genesisId,
        address previousOwner,
        address nextOwner,
        uint16 previousMultiplierBps,
        uint16 newMultiplierBps
    ) external;
}
```

The exact ABI may vary, but the semantic boundary is fixed: the active consumer
settles the old interval before the registry commits the new tier.

Consumer rotation is two-step. Changing consumers never migrates or copies
activation tiers.

## Activation reset and transfer locks

Every owner-changing Genesis transfer resets activation to Tier 0.

Before ownership changes, `StaticsGenesis` calls the activation registry. The
registry invokes the active consumer so pre-transfer rewards settle at the old
multiplier, resets the tier, and then permits the ERC-721 ownership update.
Failure in settlement or reset reverts the transfer; activation correctness is
not best-effort.

Minting and vault redemption burns do not exist in the full-mint model. A
self-transfer does not change ownership and does not reset activation.

A Genesis NFT linked to a PositionNFT is locked under ERC-5192 and cannot
transfer until explicitly unlinked. The later Statics integration owns the
link state, while the Genesis contract exposes the lock signal and enforces the
authorized link consumer.

## Launch-era Genesis rewards

`GenesisLaunchDistributor` distributes a configurable share of receiver revenue
to registered Genesis NFTs. Only STATICS and WETH are supported launch reward
assets.

Registration is explicit and O(1):

```text
registered = true
checkpoint = current reward index
weight = current activation multiplier
```

Registration never captures historical rewards. A vault-owned Genesis has zero
reward weight. When a registered NFT enters the vault, the distributor settles
the old owner and suspends the NFT. When it later leaves the vault, it resumes
at the current index and base multiplier.

Each reward asset uses a monotonic RAY index and carried division remainder:

```text
RAY = 1e27

scaled = attributed * RAY + previousRemainder
indexIncrease = scaled / totalWeight
newRemainder = scaled % totalWeight
```

Fees received while total weight is zero are credited to treasury rather than
becoming historically claimable.

No fee ingress or claim path iterates the 5,555-token collection. Weight changes
settle the previous interval before changing the denominator.

The Genesis reward share is bounded and governance-configurable for future
collections. Its production value is intentionally unset and must be supplied
in deployment configuration.

During the launch phase, pre-transfer accrued rewards crystallize into a
pull-based claim for the previous owner. A reverting reward token or recipient
cannot block NFT transfers because settlement writes liabilities and performs
no reward-token transfer.

The receiver maintains a monotonic per-distributor attribution total. If a
permissionless caller has harvested fees into the receiver but the launch
distributor has not pulled the tokens yet, an owner-changing transfer advances
the reward indexes from that attribution cursor before settling the old owner.
The later pull supplies custody without indexing the same revenue twice. Fees
that remain unharvested inside Doppler have not crossed the receiver attribution
boundary and enter the index only after a future harvest.

## Handoff to full Statics

The permanent fee receiver and activation registry remain in place when the
full protocol launches.

The transition is:

1. deploy and validate the full Statics distributor and Genesis integration;
2. have the full distributor accept the fee-receiver role, atomically
   harvesting all currently collectable launch fees to the old distributor;
3. finalize the launch distributor's reward indexes;
4. rotate the activation registry consumer to the full Statics integration;
5. put the launch distributor into claim-only mode; and
6. enable Genesis-to-PositionNFT linking.

No batch over all registered Genesis NFTs is required.

Already crystallized owner claims remain owned by those addresses. After the
final index is fixed and launch transfer callbacks are disabled, any remaining
uncrystallized launch rewards follow the Genesis NFT. The NFT's current owner
may settle and claim them. This is the accepted handoff ownership rule.

Full Statics reads the permanent activation registry when applying a linked
Genesis multiplier to a PositionNFT. Activation is not copied, migrated, or
repaid.

## Administration and liveness

Long-lived administrative authority uses two-step ownership transfer and may
not be renounced. Production ownership belongs to the launch multisig or a
timelock, not a deployer EOA.

User actions provide the ordinary maintenance callers:

- anyone may trigger authenticated Doppler fee harvest;
- registration, activation, transfer, acquisition, redemption, and claims
  checkpoint the state they touch;
- distributor and activation-consumer handoffs are explicit governance
  ceremonies; and
- historical pull claims remain available without an operator.

The architecture does not promise that governance ceremonies happen
automatically. If governance disappears before a handoff, the launch system
continues operating with its current distributor and consumer.

## Security invariants

Implementation and testing must prove at minimum:

1. STATICS supply is exactly 1 billion and cannot increase.
2. Exactly 200 million STATICS reaches treasury and 800 million reaches the
   Doppler initializer inventory in the launch flow.
3. All 5,555 Genesis NFTs are minted to the vault and no mint path remains.
4. Vault custody is always at least logical Genesis backing.
5. Logical backing equals circulating Genesis supply multiplied by 180,018.
6. The ten-token residual never becomes an additional redemption claim.
7. Acquisitions collect exact STATICS backing before NFT transfer.
8. Redemptions return custody before releasing exact backing.
9. Native acquisition fees are pull-based and cannot block acquisition.
10. Donations cannot reduce solvency or masquerade as Doppler revenue.
11. Vault backing cannot fund activation, fees, liquidity, rewards, or recovery.
12. Doppler's configured inventory totals exactly 800 million STATICS.
13. The four-curve fixture resolves exactly to 50%/25%/24%/1% and 44 positions.
14. The Robinhood broadcast path cannot run while the production launch hash
    remains unratified, and Multicurve residual may not exceed 100 STATICS.
15. External LP adds remain possible under stock Doppler behavior.
16. Standard Doppler beneficiary accounting applies exactly 5% to its
    Airlock owner and 95% to `StaticsFeeReceiver` for launch-position fees.
17. Receiver accounting uses authenticated collection deltas rather than raw
    balances.
18. Distributor rotation cannot reassign previously attributed revenue.
19. Activation burns exact liquid STATICS and cannot consume vault backing.
20. Activation never retroactively changes a completed reward interval.
21. Every owner-changing Genesis transfer resets activation to Tier 0.
22. Self-transfers do not reset activation.
23. A linked Genesis cannot transfer and reports ERC-5192 locked state.
24. Registration and reward accrual are O(1) in Genesis collection size.
25. Registration cannot capture historical rewards.
26. Vault-held NFTs have zero launch reward weight.
27. Pre-transfer launch rewards crystallize to the previous owner while the
    launch consumer is active.
28. Historical owner claims survive receiver and consumer rotation.
29. At handoff, uncrystallized launch rewards follow the NFT without a global
    batch.
30. Full Statics reads activation from the registry without reactivation.
31. The launch distributor cannot receive new protocol revenue after handoff.

## Consequences

### Positive

Doppler supplies the protocol-token market instead of Statics maintaining a
parallel launch hook. The token, market, and creator fee path use deployed,
shared launch infrastructure.

Every Genesis NFT exists from deployment and obeys ordinary collection
semantics. The vault provides a simple fixed STATICS conversion and mechanical
floor without mint races or multiple NFT classes.

Permanent fee ingress and activation state survive reward-system replacement.
Historical rewards do not require snapshots, Merkle migrations, or privileged
balance imports.

### Negative

Doppler's Airlock, token factory, governance factory, standard Multicurve
initializer, and no-op migrator become external dependencies of the
STATICS/WETH market and fee path. Their exact deployed versions and
configuration are part of the protocol trust boundary.

The standalone release has several coordinating contracts and explicit
governance ceremonies. Incorrect receiver or consumer rotation can interrupt
future fee accrual even though historical claims remain isolated.

The 200 million treasury tokens are not vested by this implementation. A
production launch requires a separately ratified vesting decision.

The four-curve fixture is not production economics. A production deployment is
blocked until curve and fee parameters are formally selected and reproduced in
the deployment manifest.

## Rejected alternatives

### Continue PR #29's custom STATICS/WETH hook

Rejected. It duplicates Doppler launch-market infrastructure and embeds the
superseded six-band economics.

### Lazy-mint public Genesis NFTs

Rejected. The collection should exist in full from deployment. Vault custody,
not nonexistence, represents inactive inventory.

### Mint Genesis NFTs to treasury

Rejected. Treasury receives 20% of STATICS. All Genesis NFTs begin with
identical vault inventory status and no redemption liability until acquired.

### Make the launch distributor the Doppler beneficiary

Rejected. Distributor implementations are replaceable, while Doppler fee
ingress should remain stable.

### Count raw receiver balances as revenue

Rejected. Arbitrary token donations would corrupt protocol accounting.

### Migrate activation or rewards into the Diamond

Rejected. Activation remains canonical in the permanent registry. Historical
launch claims remain canonical in the launch distributor.

### Preserve activation through transfer

Rejected. Activation is deliberately reset on every owner-changing transfer.

### Crystallize every NFT in a handoff batch

Rejected. It creates a collection-wide liveness boundary. The final index lets
uncrystallized claims follow each NFT and settle lazily.

### Add a post-swap fee poster or launch auto-liquidity split

Rejected. The stock Multicurve initializer already creates and retains the
launch liquidity while its standard beneficiary accounting routes 95% of the
fees earned by that liquidity to Statics. A dynamic fee poster, fee decay, and
a second 25% auto-liquidity allocation are not part of this architecture.

### Disable external Doppler liquidity

Rejected. Stock Doppler liquidity remains permissionless. External LPs use
ordinary v4 positions and earn the fees attributable to their own liquidity.

## Decisions required before production

The following values remain intentionally unresolved:

- production Multicurve ticks, position counts, and curve weights;
- the reference WETH/USD assumption used when modeling ticks;
- static Uniswap v4 LP fee;
- Genesis share of receiver revenue;
- any residual receiver revenue destination;
- final activation burn costs within the accepted bounds;
- native Genesis acquisition fee within its cap;
- royalty receiver and percentage;
- contract and token metadata URIs;
- production treasury, multisig, and timelock addresses; and
- treasury vesting architecture and schedule.

No production deployment should proceed until these parameters are ratified.

## References

- [Doppler contracts at pinned revision](https://github.com/whetstoneresearch/doppler/tree/86a5200456b148c156d2eb81a893747dd601c3ca)
- [Doppler SDK](https://github.com/whetstoneresearch/doppler-sdk)
- [Doppler Multicurve paper](https://www.doppler.lol/multicurve.pdf)
- [Doppler `DopplerERC20V1`](https://github.com/whetstoneresearch/doppler/blob/86a5200456b148c156d2eb81a893747dd601c3ca/src/tokens/DopplerERC20V1.sol)
- [Doppler `DopplerHookInitializer`](https://github.com/whetstoneresearch/doppler/blob/86a5200456b148c156d2eb81a893747dd601c3ca/src/initializers/DopplerHookInitializer.sol)
- [Doppler `FeesManager`](https://github.com/whetstoneresearch/doppler/blob/86a5200456b148c156d2eb81a893747dd601c3ca/src/base/FeesManager.sol)
- [Doppler `LaunchpadGovernanceFactory`](https://github.com/whetstoneresearch/doppler/blob/86a5200456b148c156d2eb81a893747dd601c3ca/src/governance/LaunchpadGovernanceFactory.sol)
- [Doppler `NoOpMigrator`](https://github.com/whetstoneresearch/doppler/blob/86a5200456b148c156d2eb81a893747dd601c3ca/src/migrators/NoOpMigrator.sol)
- [Doppler deployment registry](https://github.com/whetstoneresearch/doppler/blob/86a5200456b148c156d2eb81a893747dd601c3ca/Deployments.json)
- [OpenSea contract metadata standard](https://docs.opensea.io/docs/contract-level-metadata)
- [ERC-2981](https://eips.ethereum.org/EIPS/eip-2981)
- [ERC-4906](https://eips.ethereum.org/EIPS/eip-4906)
- [ERC-5192](https://eips.ethereum.org/EIPS/eip-5192)
- [ERC-7572](https://eips.ethereum.org/EIPS/eip-7572)
