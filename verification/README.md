# STATICS Genesis verification

This directory records machine-checked properties for the standalone STATICS
Genesis launch and its permanent Diamond integration. It distinguishes protocol
mechanics from dependency and market assumptions. None of these proofs attests
an ETH/USD price, future valuation, trading volume, arbitrage behavior, or future
reserve value.

## Reproducing the mandatory proofs

The mandatory Halmos, Slither, and full-suite gates run in GitHub Actions. For
a pull request, use the repository's CI checks as the release evidence:

```sh
gh pr checks --watch
```

The workflow runs `scripts/run-formal.sh all` (plus Slither and the full Foundry suite) on clean runners and
uploads symbolic results as CI artifacts. Local development should use focused Foundry tests and,
when required, the hosted Certora run; rerunning the full Halmos or Slither jobs locally is not
required release evidence.

## Property ledger

| Property | Target | Engine | Result |
| --- | --- | --- | --- |
| STATICS backing covers circulating Genesis after acquisition, redemption, and direct return | `StaticsGenesisVault` | Halmos | Pass |
| Token custody and native custody cover accounted backing and reserve | `StaticsGenesisVault` | Halmos | Pass |
| Active-epoch buy-in and redemption payout are zero; acquisition charges and reserves exactly the governed native fee | `StaticsGenesisVault` | Halmos against production source | Pass |
| Post-epoch buy-in is ceil(reserve / 5,554) and redemption is floor(reserve / 5,555) | `StaticsGenesisVault` | Certora plus Foundry fuzz | Pass |
| Forced ETH is not classified as reserve; governance configuration cannot withdraw reserve | `StaticsGenesisVault` | Halmos | Pass |
| Credit opening, partial repayment, and target-principal extension conserve backing and outstanding principal; extension changes only the selected delta, maturity, and fee accounting | `StaticsGenesisVault` | Halmos transition model plus real-contract Foundry fuzz/invariant | Pass |
| Credit recovery conserves `unusedCredit + callerIncentive + genesisDistribution = 180,000 - principal`, removes the defaulting weight before indexing, and leaves the Vault solvent | `StaticsGenesisVault`, Genesis reward consumer | Halmos transition model plus real composed Foundry regression | Pass |
| Every valid governed credit-service fee split stores exact complementary shares; each flat origination or extension fee is allocated exactly between reserve and treasury | `StaticsGenesisVault` | Certora configuration rule plus Halmos arithmetic model plus real-contract Foundry | Pass |
| Harvested WETH equals reserve plus distributor allocation; STATICS is fully attributed | `StaticsFeeReceiver` | Halmos | Pass |
| Donations are excluded from harvested revenue and liabilities remain covered | `StaticsFeeReceiver` | Halmos | Pass |
| Distributor changes crystallize arbitrary pending fees to the old distributor | `StaticsFeeReceiver` | Halmos | Pass |
| Share changes crystallize pending fees under the old share | `StaticsFeeReceiver` | Halmos plus Foundry fuzz | Pass; zero and approved 50% symbolic boundaries plus general regression |
| Distributor claimable balances never exceed cumulative attribution | `StaticsFeeReceiver` | Certora invariant | Pass |
| Claimed, claimable, treasury, indexed, and remainder accounting cannot create rewards | `GenesisLaunchDistributor` | Halmos | Pass |
| A dual-asset batch claim consumes each Genesis reward once even when its ID is duplicated, pays both exact amounts, and leaves no pending reward | `GenesisLaunchDistributor` | Certora bounded transition plus Halmos and Foundry invariant/regression | Pass |
| Reward assets remain nonzero and distinct, the governed Genesis share remains bounded, and crystallized rewards equal claimable plus claimed | `GenesisLaunchDistributor` | Certora invariants | Pass |
| Secured-credit recovery cannot alter numeraire accounting; surplus recovery cannot alter accounted reward quantities | `GenesisLaunchDistributor` | Certora rules | Pass |
| Transfer checkpoints assign pre-transfer rewards to the old owner and reset activation | `GenesisLaunchDistributor` | Halmos plus Foundry regression | Pass |
| Activation settles the old weight and transfers the exact cumulative tier cost | `GenesisLaunchDistributor`, `GenesisActivationRegistry` | Halmos plus Foundry invariant/fuzz | Pass |
| Late permanent-Diamond registration starts at current STATICS and numeraire indexes and cannot capture historical rewards | `LibGenesisRewards` | Halmos against production library plus real-contract Foundry | Pass |
| Permanent Genesis allocations and recovery indexing conserve allocations and exclude the recovered zero-weight Genesis | `LibGenesisRewards` | Halmos arithmetic model plus production-source representatives and composed Foundry | Pass |
| Genesis/Position links form a bijection without moving either NFT; unlink and recovery clear only the Genesis relationship/leg while preserving Position ownership, raw stake, and unrelated legs | `GenesisNFTFacet`, `LibPosition`, `LibGlobalRewards` | Halmos against production facet plus composed Foundry | Pass |
| Effective reward weights are derived from raw stake, stepwise multiplier changes equal a direct transition, pending-bucket maturity conserves stake/weight, and lazy 1.00x migration is idempotent | `LibGlobalRewards` | Halmos transition model plus production-source Foundry/invariant suites | Pass |
| Genesis supply is fixed at 5,555 with one-time bindings and no callable burn path | `StaticsGenesis` | Halmos | Pass |
| Launch creates one exact 100.1M zero-cliff 60-day Doppler-native allocation for treasury, sends exactly 800M to the initializer and 99.9M to bootstrap, and leaves Airlock empty | pinned `DopplerERC20V1`, `DeployStaticsGenesis` | Official-module fork plus Foundry | CI gate |
| Bootstrap transfers exactly 99.9M backing, tolerates and retains unsolicited surplus, clears bootstrap authority, and cannot repeat | `StaticsTreasuryVesting` | Halmos plus Foundry | CI gate |
| The 555 Genesis vest linearly by integer floor over 60 days and cap at their immutable principal | `StaticsTreasuryVesting` | Halmos plus Certora plus Foundry | CI gate |
| Permissionless native STATICS release pays only the immutable treasury; Genesis release transfers sequential IDs with the immutable 50-NFT cap | pinned `DopplerERC20V1`, `StaticsTreasuryVesting` | Official-module fork plus Halmos and Foundry | CI gate |
| After bootstrap only `recipientAdmin` may recover the complete bootstrap-contract STATICS balance to the current withdrawal recipient without altering Genesis vesting or Vault accounting | `StaticsTreasuryVesting` | Halmos plus Certora state proof plus Foundry value-flow regression | CI gate |
| Exact pinned Multicurve produces six curves, 56 nonzero positions, a 120M tail, and residual at most 100 STATICS for both token orders | pinned Doppler `Multicurve` | Halmos plus Foundry | Pass |
| Launch hash binds economics, exact authorities, Statics creation bytecode, full proxy and ownership-controller dependencies, runtime hashes, geometry, metadata, salt, and epoch | `DeployStaticsGenesis` | Foundry | Pass |
| Zero approved Robinhood hash blocks production execution | `DeployStaticsGenesis` | Foundry | Pass |

`Mandatory` means `scripts/run-formal.sh all` must pass. The Certora specs under
`certora/` are the selective aggregate-accounting layer and are not repository
CI gates because they require a hosted prover credential.

## Certora

Install `certora-cli`, expose the Solidity 0.8.33 compiler as `solc8.33`, set
`CERTORAKEY`, and run:

```sh
scripts/run-certora.sh vault
scripts/run-certora.sh fees
scripts/run-certora.sh distributor
scripts/run-certora.sh vesting
```

The configurations enable basic rule-sanity checks, disable optimistic loops,
and use eight loop iterations. The specs use ghost ledgers where the complete
external accounting boundary is modeled. The following selected rules were
proved with Solidity 0.8.33:

| Configuration | Proved rules | Hosted report |
| --- | --- | --- |
| `GenesisVault.conf` | Full-width post-epoch ceil/floor formulas; governed credit-service shares are exact complements; governance preserves backing ledgers | [report](https://prover.certora.com/output/8471858/a29e24d8add743e5bd8ced10ac0d8d72) |
| `FeeReceiver.conf` | Distributor claimable balances remain within cumulative attribution; surplus recovery preserves distributor liability | [report](https://prover.certora.com/output/8471858/9a10ef5901cf47338d7d62728899930f) |
| `GenesisDistributor.conf` | Reward assets remain nonzero and distinct; the Genesis share remains bounded; crystallized rewards equal claimable plus claimed; batches of up to eight IDs preserve crystallized accounting; recovery is segregated from numeraire accounting; surplus recovery preserves accounted reward quantities | [report](https://prover.certora.com/output/8471858/e187b2a7454a4aebae384b18a05a0d63) |
| `TreasuryVesting.conf` | Exact capped Genesis vesting; recipient rotation and successful post-bootstrap surplus recovery preserve immutable state and released accounting; unauthorized or pre-bootstrap sweeps revert | Current hosted run required after native STATICS vesting implementation |

The transition invariants listed in the table are selected hosted proofs. The
distributor's aggregate attribution ghost remains staged because secured-credit
recovery is a second valid allocation source that does not pass through fee
receiver attribution. A crystallization-within-index invariant is also not
claimed: it is not inductive from Certora's arbitrary invariant states without
a stronger reachable-state model. Halmos proves the corresponding conservation
properties against explicit minimal dependency models, and Foundry invariant
handlers exercise arbitrary reachable action sequences. Before treating any
additional hosted run as a production proof, its report must show every selected
rule as proved; a completed job or successful type-check alone is not a passing
result.

## Explicit dependency assumptions

- ERC-20 `transfer` and `transferFrom` move exactly the requested amount or
  revert. Fee-on-transfer, rebasing, callback, and malicious tokens are outside
  the launch model.
- WETH withdrawal burns the requested WETH and returns exactly the same native
  amount.
- The fee source transfers exactly the collected fees reported by the pinned
  Doppler implementation. Direct donations are modeled separately.
- Genesis ownership, approvals, safe transfers, and activation callbacks obey
  the pinned contracts. The formal mocks contain no behavior beyond those
  interfaces.
- Keccak collision resistance, runtime-code-hash collision resistance, and EVM
  implementation correctness are cryptographic/platform assumptions.
- Symbolic tests prove the modeled local transitions. Existing Foundry invariant
  handlers provide executable arbitrary-sequence coverage; they complement but
  do not turn a local transition proof into a theorem about an unmodeled
  dependency.
- Halmos 0.3.3 cannot soundly reload the assembly-selected Diamond storage used
  by `LibGlobalRewards` during these symbolic transitions. The global-reward
  arithmetic suite therefore uses an explicitly labeled normal-layout model.
  Production storage and value-moving behavior are covered by the real
  `GlobalRewards`, Genesis Position integration, upgrade-rehearsal, and invariant
  suites. The full 64-asset and 25-bucket execution bounds remain executable
  Foundry evidence rather than a brute-force symbolic claim.
- The secured-credit symbolic checks isolate the lifecycle algebra because the
  complete deployed Genesis environment is not tractable as one Halmos state
  space. Each property is paired with a real-contract representative and the
  secured-credit fuzz/invariant suites; composed recovery ordering is exercised
  by the real Vault, Genesis collection, Diamond callback, reward, and Position
  implementations.
- Permanent Genesis registration executes the production `LibGenesisRewards`
  path symbolically. Allocation and recovery conservation use explicitly labeled
  arithmetic models paired with production-source representatives and composed
  integration tests.
- The Genesis/Position Halmos target executes the production facet for one
  representative linked pair plus one unrelated active Position leg. It proves
  the exact link, unlink, and recovery transitions for that state; the broader
  ownership, activation-tier, credit, and maximum-asset compositions remain
  real-contract Foundry evidence.
- Treasury vesting arithmetic is symbolic for every timestamp in the `uint24`
  domain, which covers the complete 60-day schedule and more than 130 days
  beyond its cap. Halmos executes representative bootstrap surplus, midpoint
  release, pre-release sweep rejection, and post-release state-preservation
  transitions. Foundry fuzz and real-flow regressions provide the arbitrary
  surplus and exact ERC-20 balance-delta evidence. The Genesis symbolic
  transition uses a four-NFT ordered batch and binds the immutable 50-NFT cap;
  the real-contract Foundry regression executes the full 50-transfer batch.
- Post-epoch division is verified at full `uint256` width in CVL. The adjacent
  Foundry regression decomposes reserves into a `uint64` quotient and bounded
  remainder, covering reserves above 100,000 native ETH.
- The distributor's unbounded batch method is excluded from Certora's global
  invariants because the configuration disables optimistic loop unwinding. A
  direct rule proves crystallized-accounting conservation for batches of up to
  eight IDs. Halmos and Foundry cover the production transition beyond that
  bounded Certora execution.
- The transfer, activation, single/batch claim, and two-Genesis transition
  proofs use non-round representative rewards to keep symbolic execution
  tractable. The global two-asset conservation proof remains symbolic over
  `uint96` reward amounts. Exact post-transfer ownership has a normal Foundry
  regression, and arbitrary reward sizes and action sequences are covered by
  the adjacent fuzz and invariant suites. These are explicit proof boundaries,
  not exclusions from protocol behavior.
- The approved 50% WETH reserve split is proved with a non-round representative
  harvest, while the zero-share identity remains symbolic over `uint96` WETH
  amounts. The adjacent Foundry fuzz regression covers arbitrary valid shares
  and harvest amounts.

## Fork and economic evidence boundaries

Robinhood fork tests validate the external assumptions against runtime-hash
pinned Uniswap and Doppler deployments and the pinned WETH proxy,
implementation, proxy-admin, and ownership-controller layers. The live flow executes pool purchase,
Genesis registration, a subsequent fee-producing purchase, harvesting, reward
claims, and the epoch boundary. It does not prove those external contracts
correct or eliminate their continuing governance risk. The deterministic
JavaScript economics simulator explains inventory and price geometry, but USD
values remain launch-time attestations and economic interpretations rather than
EVM or formal-verification facts.
