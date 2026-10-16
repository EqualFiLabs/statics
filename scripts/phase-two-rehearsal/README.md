# Phase 2 Cast/Anvil rehearsal

Run `scripts/phase-two-rehearsal/run-all.sh` from the repository checkout. The
runner loads the canonical private RPC configuration, forks the exact historical
pre-upgrade block pinned by `test/fixtures/immutable-hooks-phase-one.json`, and
writes timestamped artifacts under `artifacts/phase-two-rehearsal`. It sends
transactions only to a loopback Anvil process. It does not reuse or overwrite
Phase 1 artifacts.

The run first funds ordinary local actors with real Genesis STATICS and WETH,
deploys Phase 2 candidates with the release compiler profile, and checks their
runtime and the restricted-token code store. It then executes the reviewed Safe upgrade payload,
creates General pools on the General hook and restricted baskets on the Basket hook, tests the shared
distributor registry and settlement boundaries, and checks legacy and new
accounting. A separate later-activation branch exercises pinned upstream Morpho
and is reverted before Phase 2 retirement.

The pinned run creates a maximum 16-asset basket through the atomic path, then
prepares a second maximum basket and seeds it in two eight-pool transactions.
Each staged Safe transaction is submitted with a 16,777,216 gas limit. The last
batch activates the basket. A separate staged lifecycle exercises unauthorized
continuation, pending mint rejection, changed limits, completion and replay.
The atomic lifecycle also mints, swaps, retires, redeems, closes every POL position
and unwinds all constituents.

`chain-gas-policy.json` records the target's pinned ArbGasInfo maximum transaction
gas observation before Anvil starts. No sender may request more than that cap or
the applicable block limit. `gas-evidence.jsonl` binds measurements to mined
transactions, receipts and blocks; at least 1,000 basis points of headroom are
required against the minimum of the observed transaction cap, target/local block
limits and actual submitted gas limit. `STATICS_REHEARSAL_TRANSACTION_GAS` may
lower the sender ceiling; it cannot raise it above the observed target cap.

The later Morpho branch transitions the configured market from `Active` to
`ExitOnly`. It requires new collateral deployment and borrowing to revert, while
repayment, recall, liquidation, loss synchronization, and liquidator redemption
continue against the pinned upstream implementation.

`summary.json` and `later-morpho/summary.json` are written only after every
mandatory case passes. `case-evidence.jsonl` ties each named case to its receipt,
transaction, trace, and block; `case-requirements.json` records exact expected
calldata and error data. Failed runs retain their artifacts for diagnosis. Run
`python3 -m unittest discover -s test/rehearsal -v` for the offline corruption
tests. The pre-deployment `scripts/public-hooks/release.py` gate repeats this
rehearsal on a clean committed candidate and compares deployed roots to its
frozen compiler artifacts.

Run the real-PoolManager stateful settlement hammer separately:

```sh
forge test --match-path test/invariant/RestrictedSettlementInvariant.t.sol -vv
```

It randomizes swaps, liquidity changes, fee policy, fee settlement, distributor
changes, direct transfers, and allowance-based transfer attempts between two
restricted tokens. Its invariants require transient settlement budgets to return
to zero, PoolManager claims to equal every hook liability, immutable pool binding
to remain intact, and an approved spender without an approved endpoint to remain
unable to move tokens.

## Current-head production preflight

After the production candidates exist and before the Safe executes the upgrade,
run `scripts/phase-two-rehearsal/run-production-preflight.sh`. This is deliberately
separate from the historical pinned gate. It captures the then-current production
block and forks that exact hash, validates every candidate deployment transaction
and runtime against a frozen release, executes the exact two-call Safe JSON, then
executes the reviewed production General-pool and basket smoke payloads. All writes
remain on loopback Anvil.

Both standalone hooks must already have a full explorer source match for the frozen
solc 0.8.33 build and exact constructor arguments. A partial match, missing status,
different compiler, constructor arguments, or runtime blocks Safe approval. Record
that explorer evidence with the candidate review; the fork preflight independently
rechecks the deployment transaction, constructor bytes and runtime.

The runner requires four explicit paths:

```sh
STATICS_PHASE_TWO_RELEASE_DIR=/absolute/path/to/frozen-release \
STATICS_PHASE_TWO_PRODUCTION_CANDIDATE=/absolute/path/to/candidate.json \
STATICS_PHASE_TWO_SAFE_JSON=/absolute/path/to/safe.json \
STATICS_PHASE_TWO_SMOKE_JSON=/absolute/path/to/smoke.json \
scripts/phase-two-rehearsal/run-production-preflight.sh
```

The candidate uses format `statics-phase-two-production-candidate-v3`. It binds
the frozen `sourceCommit` and `releaseId`, chain `4663`, Diamond, owner, canonical
PoolManager/PositionManager/Permit2 bindings, the canonical SHA-256 digest of the
Safe JSON, the canonical SHA-256 digest of the smoke JSON, and a `contracts` object.
Its `policy` object freezes the legacy hook and WETH addresses, default input and
output fees, and the complete basket and General fee allocations read before the
cut. The preflight requires the legacy hook to expose those exact values, then
requires the Diamond to expose the same copied policy immediately after the cut
and again after the smoke lifecycle.
Every contract referenced by the cut must be
listed with its frozen artifact name, deployed address, exact constructor bytes,
and direct creation transaction hash. The fixed role keys are `generalHook`,
`basketHook`, `basketTokenFactory`, `manager`, `guard`, and `initializer`; facet
keys may use their artifact names.

The following fragment shows the required shape; populate every value from the
reviewed current-head reads:

```json
"policy": {
  "legacyHook": "0x...",
  "weth": "0x...",
  "defaultFeeRate": [100, 100],
  "basketFeeAllocation": [1500, 3000, 3000, 2000],
  "generalFeeAllocation": [4000, 3500, 2000]
}
```

The smoke file uses format `statics-phase-two-production-smoke-v3` and binds the
same commit and release ID. `safeBatches` contains exact `to`, `value`, and `data`
items executed atomically by the real Safe on the fork. `transactions` contains
exact impersonated `from`, `to`, `value`, `data`, expected status, and optional
revert bytes. `views` contains exact `eth_call` calldata and expected returned
bytes. Its `entities` object binds the exact General and basket pool IDs, both
standalone hook addresses, preparation ID, basket ID, and restricted basket token. These identities derive
the mandatory call and view checks; the input cannot declare substitute targets
or selectors. The required successful lifecycle cases are `general-create`,
`general-swap`, `basket-prepare`, `basket-stage`, `basket-finalize`, `basket-mint`,
and `basket-swap`. The five Diamond lifecycle cases must contain the exact
`createPool`, `prepareBasketCreation`, `deployPreparedBasketContracts`,
`createBasketPrepared`, and `mint` selectors at the Diamond. Required post-action
views are `general-pool-state`, `general-swap-state`, `basket-state`,
`basket-supply`, and `basket-swap-state`; their targets and calldata are derived
from the frozen entities and their returned bytes must match the reviewed values.
Both swaps must emit a nonzero, opposite-sign `Swap` delta from the canonical
PoolManager for the exact expected pool ID. The preflight also decodes the Diamond
pool registry, configured-hook registration and immutable bindings, restricted token identity, Active basket
state, and positive minted supply. Creation, preparation, contract staging,
finalization, mint, and swap receipts must emit the exact factory, Diamond, and
PoolManager events that thread those identities through the lifecycle in order;
each mandatory case contains exactly one outer call.
The preflight refuses placeholders, omitted cases, changed Safe
or smoke bytes, expected failures in a mandatory lifecycle action, an outdated
guard snapshot, unqualified cut facets, runtime drift, wrong factory code stores,
changed bindings, topology changes during smoke execution, or anything other than
the frozen 51-facet/354-selector deployment-address routing after the cut. It also recomputes
the release and artifact digests, binds the exact initializer arguments, and checks
the Phase 2 deployment phase, zero basket and General creation fees, five-basis-point
single-asset flash fee, every retained Phase 1 and activated Phase 2 ERC-165
interface, and the continued absence of Phase 3 and Morpho interfaces.

```json
"entities": {
  "generalPoolId": "0x...",
  "preparationId": "0x...",
  "basketPoolId": "0x...",
  "generalHook": "0x...",
  "basketHook": "0x...",
  "basketId": 1,
  "basketToken": "0x..."
}
```

This runner becomes usable only after exact production deployment transactions,
Safe JSON, and smoke calldata have been reviewed. Its presence alone is not
current-head evidence; only a passing `summary.json` tied to the captured block
hash and input digests is evidence.
