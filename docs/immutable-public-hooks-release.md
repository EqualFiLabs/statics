# Immutable public hook release

This release replaces Phase 1 facet implementations and installs the complete
restricted-basket Phase 2 selector set. Dollar and Morpho selectors remain absent.
It introduces no launchpad, campaign, procurement, bootstrap zap, or auction API.
Phase 2 installs the shared distributor registry with no initial approvals.
Morpho uses explicit distributor approval in its later configuration batch;
this release does not initialize or activate Morpho.
The production Diamond, PoolManager, legacy PoolKeys and position bindings remain
in place. A zero common pool creation fee continues to mean owner-only creation.

The implementation decision record is
[immutable-public-pool-hooks.md](adr/immutable-public-pool-hooks.md).

## Local qualification

```sh
forge test --match-path 'test/liquidity/ModularPublicHooks.t.sol' -vv
forge test --match-path 'test/liquidity/PreparedBasketCreation.t.sol' -vv
forge test --match-path 'test/range/RestrictedRangeGauge.t.sol' -vv
forge test --match-path 'test/invariant/RestrictedSettlementInvariant.t.sol' -vv
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s scripts/public-hooks -p 'test_*.py' -v
```

The opt-in fork test reads the canonical private RPC environment and never
broadcasts. All deployments, staking, pool actions and the cut execute in the
local Foundry EVM. Its fixture pins chain 4663 at block 88,780,151, 32 facet
runtime hashes and 226 selectors. The pool inventory labels originated at block
88,740,831; actual pool views and liabilities are read again at the fork block.
No CreateX bytecode is etched in the fork test.

```sh
set -a
. /home/hooftly/.openclaw/workspace/.rpc
set +a
STATICS_PUBLIC_HOOK_FORK=true forge test --match-path test/deployment/ImmutablePublicHookUpgradeFork.t.sol -vv
```

The ordinary test command skips the opt-in fork. A skip is not evidence of a
passing fork. Local tests/review do not replace the repository's CI, static
analysis, remote formal gates, independent security review, or live qualification.

## Freeze before any deployment

Commit the entire reviewed candidate, then run:

```sh
set -a
. /home/hooftly/.openclaw/workspace/.rpc
set +a
python3 scripts/public-hooks/release.py .tooling/public-hook-release-REVIEWED_COMMIT
```

The destination must not exist. The tool builds with isolated output, cache and
build-info directories; it does not clean or overwrite existing deployment
artifacts. It records the exact commit, Foundry/dependency revisions, full Standard
JSON input, compiler metadata, constructor ABI, immutable-reference locations,
creation/runtime hashes, selector method identifiers and content digests. The
manifest's `releaseId` is its canonical SHA-256 content identity. Every checked
runtime fits EIP-170, deployment initcode fits EIP-3860 including constructor
arguments, and the token factory embeds the exact IPFS-bearing restricted-token
creation code.

The same command runs all four pinned Forge fork tests and the mandatory Cast/Anvil Phase 2 and later Morpho rehearsals. It captures the simulated
deployments, exact constructor arguments and initcode hashes, runtime bytes and
immutable substitutions, the actual token-factory code store, all 51 facet
destinations and 352 selectors, and the simulated Safe batch. It compares this evidence with
the independently reproduced artifacts before writing a release manifest. A
failed test, source/metadata mismatch, missing deployment, or selector mismatch
fails the gate. `dry-run.json`, `simulated-contracts.json`, and `dry-run.log` retain
the evidence beside the frozen inputs. There is no live broadcast or explorer
submission in this command.

The fork reuses only this release's isolated artifacts and cache. It cannot load
stale copies of the rehearsal from other workspace compiler profiles.

The Cast/Anvil run starts at the original pre-upgrade Diamond fixture and uses
real Safe owner approvals and `execTransaction` to execute the guard and cut.
It proves that a late failed call rolls the whole cut and financial state back;
then checks a stale guard, the actual cut, and 51 facets / 352 selectors. The
same persistent fork opens a legacy stake and LP leg before the cut, creates two
General pools against the General hook and two prepared restricted baskets against the Basket hook,
plus an independent two-basket market, and exercises
real liquidity, swaps, claims, collateral, distributor transfers, allowance
checks, budget replay, managed LP exit, rewards, basket retirement and unwind.
The second basket proves distributor approval applies to tokens created after
that approval and that revocation applies to both tokens.

The same run creates a maximum-size 16-asset basket and completes token preparation,
single-transaction finalization, minting, a canonical swap, retirement, redemption, POL
closure and all 16 unwinds. A second maximum basket uses two prepared eight-pool
batches, each submitted with a 16,777,216 gas limit. Preparation, token deployment,
atomic finalization, both batches, mint, redemption, first POL-close and unwind
receipts must retain at least 1,000 basis points of effective transaction gas
headroom. The observed chain transaction cap and target/local block limits bound
all requests; oversized local transaction ceilings are rejected. The gate
recomputes that headroom and binds every measurement to the mandatory transaction
evidence. The real-PoolManager invariant suite separately randomizes restricted
token swaps, liquidity, policy, fee settlement and distributor changes while
checking zero residual settlement budgets, claim solvency, immutable bindings,
and approved-spender rejection.

Each mandatory case is tied to its caller, full calldata, receipt, block, and
call trace. Rejection cases require the exact EVM error and matching financial
snapshots. The gate rejects a skipped case, a failed child counted as success,
a child rolled back only by its parent counted as a rejection, duplicate call
evidence, missing view status or missing receipt status. The Phase 2 run must
finish before release freezing succeeds. The original 23 Phase 1 scenarios stay
available through `scripts/phase-one-rehearsal/run-all.sh`; their source-signature
coverage report is now replaced by observed call and trace evidence.

Later Morpho activation is exercised after a Phase 2 snapshot, then the fork
returns to that snapshot before basket retirement. This separate local
experiment adds the Morpho selectors and explicit distributor approval, deploys
the pinned upstream Morpho implementation, and tests tracked collateral,
liquidation, direct top-up, restored health, surplus withdrawal and rewards.
It then changes the market from `Active` to `ExitOnly`, proves new collateral and
new borrowing are blocked, and proves repayment, recall, liquidation, loss
synchronization, and seized-collateral redemption remain available.
It uses WETH as a local loan asset and a controllable test oracle; it does not
qualify production Morpho market parameters or authorize activation. A Phase 2
release leaves these selectors absent and the distributor registry empty until
configured explicitly.

Run the Cast/Anvil rehearsal alone with
`scripts/phase-two-rehearsal/run-all.sh`; it writes ignored, timestamped
artifacts under `artifacts/phase-two-rehearsal`. The release gate validates
both summaries and every required case again, and checks the candidate roots
against the independently reproduced frozen bytecode. The compiler uses IPFS
metadata, and historical artifacts are preserved.

The five new deployment roots pin Solidity 0.8.33, Cancun, optimizer 200 and IPFS
metadata, without IR. The isolated release build explicitly uses IPFS for all
release artifacts, matching the typed dry run's importer profile. The repository's
historical default profile and old artifacts remain intact.
The typed deployment tests also compare the STOP-prefixed restricted-token
code-store payload against its creation hash. Select artifacts by metadata and
compilation target; a historical flat `out/<name>.sol` file can be stale when
Foundry emits a newer profile under a nested path.

The report's addresses and constructor bindings belong to the local simulation.
Its mock assets and impersonated Safe owner exercise the upgrade and value flows;
they are not production deployment predictions or an executable production Safe
payload. Actual deployment addresses depend on the authorized deployer and its
nonces. Rehearse that exact transaction sequence and pool configuration before
execution, using these frozen artifacts. Attach its addresses, bindings and
eventual explorer receipts to the release; the live deployment field remains
`TO_FILL_AFTER_DEPLOYMENT` until execution.

## Prepare the upgrade

1. Deploy the reviewed Phase 1/2 facet implementations, mined General and Basket hooks,
   `StaticsBasketTokenFactory`, a new restricted-aware `StaticsLiquidityManager`,
   the release initializer and the snapshot guard, only after explicit deployment
   authorization. Both hooks bind the existing Diamond and PoolManager and keep their own fee settings. They can
   deploy before the new Diamond selectors exist. Validate live code against the frozen
   artifacts and constructor arguments, verify the token factory's code store, and
   require the explorer to report a full source match for each standalone hook before
   approving the cut.
2. The replacement manager must bind the same Diamond, PoolManager, PositionManager
   and Permit2 as the existing manager. Existing user/POL legs keep their stored
   manager; new positions use the replacement. Leaving the old manager selected
   would break restricted-token settlement.
3. Read `StaticsPublicHookUpgradeGuard.snapshot(diamond)` from the actual live
   owner/selector topology. Review every current destination/code hash, fees,
   liquidity bindings, all legacy pools, policy settings, custody and liabilities.
   Refresh these reads immediately before payload preparation.
4. Call `PrepareStaticsPublicHookUpgrade.build(configuration, parts)` or
   `buildSafeJson(configuration, parts)`. The latter produces a Safe Transaction
   Builder import containing the guard assertion followed by the exact cut.
   The builder rejects missing old selectors, empty facets, an unreviewed zero
   snapshot, and incorrect guard/initializer runtimes. **The provided facet and
   manager addresses still require comparison with the frozen release artifacts.**
5. Review the resulting Add/Replace selectors and initializer input locally. The
   initializer advances Phase 1 to Phase 2 once, installs the two standalone hooks and token-factory bindings,
   selects the replacement manager and requires the common creation gate to stay
   zero. No selector removals or Dollar/Morpho initialization are performed.
6. Both transactions must execute in one atomic Safe batch. Do not send the guard
   as a separate transaction: its purpose is to reject topology/ownership/code
   drift immediately before the cut. Source verification and Safe approval are
   separate from transaction execution.

The builder does not broadcast. It does not claim an independently audited or
production-approved upgrade. Safe addresses and transaction payloads are produced
from actual deployed candidates, never invented for a planning document.

## Rehearse the exact production inputs

After every production candidate has been deployed and the final Safe JSON and
pool/basket smoke payloads have been reviewed, run the current-head production
preflight described in `scripts/phase-two-rehearsal/README.md`. It forks the then
current production block, validates every direct creation transaction, constructor
encoding, runtime, immutable binding and token-factory code store against the frozen
release, recomputes the guard snapshot, and executes the exact two-call Safe batch.
It recomputes the release and artifact digests, requires the full cut to reproduce
the frozen selector-to-facet deployment-address inventory, and binds the initializer
to the reviewed General and Basket hooks, token factory, manager, zero basket fee and
five-basis-point flash fee.
The candidate also freezes the live legacy hook, WETH, default fee rate, and both
fee allocations. The preflight checks those values before the cut and checks their
exact copied Diamond values immediately after the cut and after all smoke actions.
It then requires a real General pool creation and swap plus prepared-token deployment,
finalization, mint and swap using the supplied production calldata. Post-cut state
must contain 51 facets and 352 selectors and point to the reviewed General and Basket hooks,
token factory and liquidity manager while retaining the same owner, zero General and basket creation
fees, Phase 2 state, flash fee, every Phase 1 and Phase 2 interface, and no Phase 3
or Morpho interface. Mandatory smoke actions must succeed. The smoke file freezes
the created pool, its configured hook, basket and token identities; the runner derives the required
calls and views from those identities, decodes the resulting protocol state, and
requires canonical PoolManager `Swap` events with nonzero value for both exact pool
IDs. Token-factory and Diamond events must thread the exact General pool,
preparation ID, staged token, finalized basket and pool, and nonzero mint
through the mandatory lifecycle order. Self-declared substitute targets or selectors
cannot qualify the lifecycle.

This current-head run does not replace the pinned historical qualification. The
pinned run makes the release reproducible; the current-head run detects production
state drift and mistakes in the exact deployment, Safe, and launch inputs. Do not
submit the Safe transaction unless both have passing evidence. Regenerate the Safe
and rerun the current-head preflight whenever the captured guard snapshot, candidate
deployment, or production smoke input changes.

## Prepare and qualify new identities

Deploy the mined General and Basket hook addresses once from their frozen creation
bytecode and exact constructor arguments. Fully verify both before the Diamond cut.
General pool creation uses the configured General hook directly; there is no
child hook prediction, salt, code store or deployment step. Basket preparation
reserves and deploys only the deterministic restricted-token identity and binds
the authenticated payer, creator, configuration and deadline.

General creation deploys and initializes an unfunded pool. Keep admission owner-only,
verify that address and its exact binding, then qualify liquidity, swaps, MarketTape,
gauges, POL, revenue and claims before production funding.

Prepared baskets support a separate boundary:

1. `prepareBasketToken` reserves the exact intent and deploys the token with zero supply and no pool
   initialization, constituent transfer or POL seeding. Restricted identity is
   registered immediately, preventing a staged token from entering the General
   path. Unfinalized basket identity is rejected by mint/market creation.
2. Verify the deployed token address and binding against this release.
3. `createBasketPrepared` finalizes that token, registers each PoolId on the Basket
   hook, initializes canonical pools and funds creator-backed launch liquidity.
   Execution rechecks admission,
   authority, configuration and deadline. An expired deployment may leave a gap
   in basket IDs; neither its identity nor salt is reused.

Changing a relevant fee/configuration invalidates the prepared intent. A valid
signature or prepared salt never bypasses a zero-fee owner-only gate. Only a
separately authorized positive common fee enables public creation later.

## Source verification confirmation

The pre-deployment gate must pass before deployment authorization. It recompiles
frozen full Standard JSON input with the pinned compiler and requires exact
creation bytecode, runtime template, immutable-reference locations and metadata.
It also verifies the IPFS-bearing token-factory child code and deployment size
limits. Failure produces no approved release manifest. Use only this frozen
artifact and exact constructor encoding for deployment; do not rebuild from a
mutable checkout during submission.

After deploying each standalone hook, submit its preserved Standard JSON input and
constructor arguments to the explorer. Confirm a full match for the exact compiler,
constructor arguments and runtime before authorizing the Diamond cut. A partial
match or missing status is a release failure requiring investigation of the
deployed artifact and input. This confirmation does not replace or defer the
pre-deployment checks.

References: [Foundry compiler configuration](https://getfoundry.sh/reference/config/solidity-compiler),
[Blockscout contract verification API](https://docs.blockscout.com/devs/apis/rpc/contract).
