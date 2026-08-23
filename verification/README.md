# STATICS Genesis launch verification

This directory records machine-checked properties for the standalone STATICS
Genesis launch. It distinguishes protocol mechanics from dependency and market
assumptions. None of these proofs attests an ETH/USD price, future valuation,
trading volume, arbitrage behavior, or future reserve value.

## Reproducing the mandatory proofs

The mandatory local gate uses Halmos 0.3.3, Foundry, Solidity 0.8.33, Cancun
code generation, and an eight-iteration loop bound:

```sh
python3.12 -m venv .halmos-venv
.halmos-venv/bin/pip install halmos==0.3.3
HALMOS_BIN="$PWD/.halmos-venv/bin/halmos" scripts/run-formal.sh all
```

The proof runner writes one JSON result per target to `formal-results/`. The
ordinary Foundry suites remain part of the gate because the post-epoch division
regressions and value-moving launch lifecycles are intentionally executable
tests beside the symbolic checks.

## Property ledger

| Property | Target | Engine | Result |
| --- | --- | --- | --- |
| STATICS backing covers circulating Genesis after acquisition, redemption, and direct return | `StaticsGenesisVault` | Halmos | Pass |
| Token custody and native custody cover accounted backing and reserve | `StaticsGenesisVault` | Halmos | Pass |
| Active-epoch purchase and redemption native amounts are zero | `StaticsGenesisVault` | Halmos | Pass |
| Post-epoch buy-in is ceil(reserve / 5,554) and redemption is floor(reserve / 5,555) | `StaticsGenesisVault` | Certora plus Foundry fuzz | Pass |
| Forced ETH is not classified as reserve; governance configuration cannot withdraw reserve | `StaticsGenesisVault` | Halmos | Pass |
| Harvested WETH equals reserve plus distributor allocation; STATICS is fully attributed | `StaticsFeeReceiver` | Halmos | Pass |
| Donations are excluded from harvested revenue and liabilities remain covered | `StaticsFeeReceiver` | Halmos | Pass |
| Distributor changes crystallize arbitrary pending fees to the old distributor | `StaticsFeeReceiver` | Halmos | Pass |
| Share changes crystallize pending fees under the old share | `StaticsFeeReceiver` | Halmos plus Foundry fuzz | Pass; zero and approved 50% symbolic boundaries plus general regression |
| Claimed, claimable, treasury, indexed, and remainder accounting cannot create rewards | `GenesisLaunchDistributor` | Halmos | Pass |
| Transfer checkpoints assign pre-transfer rewards to the old owner and reset activation | `GenesisLaunchDistributor` | Halmos plus Foundry regression | Pass |
| Activation settles the old weight and transfers the exact cumulative tier cost | `GenesisLaunchDistributor`, `GenesisActivationRegistry` | Halmos plus Foundry invariant/fuzz | Pass |
| Genesis supply is fixed at 5,555 with one-time bindings and no callable burn path | `StaticsGenesis` | Halmos | Pass |
| Escrow release sends exactly 200M STATICS to treasury, drains residual, and cannot repeat | `StaticsLaunchAllocationEscrow` | Halmos | Pass |
| Exact pinned Multicurve produces six curves, 56 nonzero positions, a 120M tail, and residual at most 100 STATICS for both token orders | pinned Doppler `Multicurve` | Halmos plus Foundry | Pass |
| Launch hash binds economics, authorities, dependencies, runtime hashes, geometry, metadata, salt, and epoch | `DeployStaticsGenesis` | Foundry | Pass |
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
```

The configurations enable basic rule-sanity checks, disable optimistic loops,
and use eight loop iterations. The specs use ghost ledgers to independently
track harvested fees and distributor attribution. The following selected rules
were proved with Certora CLI 8.18 and Solidity 0.8.33:

| Configuration | Proved rules | Hosted report |
| --- | --- | --- |
| `GenesisVault.conf` | Full-width post-epoch ceil/floor formulas; governance preserves backing ledgers | [report](https://prover.certora.com/output/8471858/6fdea74367f24739bbd461a813b5b452) |
| `FeeReceiver.conf` | Surplus recovery preserves distributor liability | [report](https://prover.certora.com/output/8471858/44904946b709447eaf79c06336b9170d) |
| `GenesisDistributor.conf` | Surplus recovery preserves all accounted reward quantities | [report](https://prover.certora.com/output/8471858/91b769bd131b47ab9a8229f062bfb801) |

The aggregate ghost invariants remain in the specs as reviewable next-stage
properties, but the default configurations do not select them yet. Hosted runs
without a linked model of the fee source, tokens, Genesis collection, and
activation callbacks produce dependency-scene counterexamples, so those runs
are not claimed as passing proofs. Halmos proves the corresponding conservation
properties against the explicit minimal dependency models in
`test/formal/mocks/`, and Foundry invariant handlers exercise arbitrary action
sequences. Before treating any additional hosted run as a production proof, its
report must show every selected rule as proved; type-checking alone is not a
passing result.

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
- Post-epoch division is verified at full `uint256` width in CVL. The adjacent
  Foundry regression decomposes reserves into a `uint64` quotient and bounded
  remainder, covering reserves above 100,000 native ETH.
- The transfer, activation, claim, and two-Genesis transition proofs use
  non-round representative rewards to keep symbolic execution tractable. The
  global two-asset conservation proof remains symbolic over `uint96` reward
  amounts. Exact post-transfer ownership has a normal Foundry regression, and
  arbitrary reward sizes and action sequences are covered by the adjacent fuzz
  and invariant suites. These are explicit proof boundaries, not exclusions
  from protocol behavior.
- The approved 50% WETH reserve split is proved with a non-round representative
  harvest, while the zero-share identity remains symbolic over `uint96` WETH
  amounts. The adjacent Foundry fuzz regression covers arbitrary valid shares
  and harvest amounts.

## Fork and economic evidence boundaries

Robinhood fork tests validate the external assumptions against runtime-hash
pinned WETH, Uniswap, and Doppler deployments. They do not prove those external
contracts correct. The deterministic JavaScript economics simulator explains
inventory and price geometry, but USD values remain launch-time attestations and
economic interpretations rather than EVM or formal-verification facts.
