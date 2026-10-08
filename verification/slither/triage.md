# Slither triage

The reviewed repository-wide CI artifact covers 252 production Solidity files
and explicitly excludes 17 test, formal-fixture, and vendor files as finding
subjects. It normalizes to 863 stable findings: 51 high, 420 medium, 235 low,
and 157 informational. Every stable fingerprint has an explicit classification
and rationale in `baseline.json`; detector families are summarized below but
are not blanket suppressions for future findings.

All 863 current findings are reviewed as intentional behavior or false
positives.

The reviewed native ETH Phase One artifact produced the current source scope
and fingerprint baseline. It records 193 false positives and 670 intentional
findings. No detector family is suppressed.

## High

| Detector | Count | Classification | Review conclusion |
| --- | ---: | --- | --- |
| `arbitrary-send-erc20` | 5 | FALSE POSITIVE | Internal exact-transfer helpers receive authenticated or protocol-controlled payers or owners and validate the relevant debit, receipt, and ownership deltas. |
| `arbitrary-send-eth` | 3 | 1 FALSE POSITIVE, 2 INTENTIONAL | Genesis donations use an immutable validated Vault; governed treasury and recipient payouts deliberately send native value after state accounting. |
| `msg-value-in-nonpayable` | 1 | FALSE POSITIVE | The internal exact-value helper is reached through payable native-liquidity entrypoints; Slither loses payable reachability across the facet and library call graph. |
| `reentrancy-balance` | 35 | FALSE POSITIVE | Reported balance reads and transfers are inside guarded actions, PoolManager unlock callbacks, or exact-delta helpers whose callers establish the authority and accounting boundary. |
| `reentrancy-eth` | 3 | FALSE POSITIVE | WETH unwrap, Vault donation, and Genesis distributor paths use the applicable reentrancy guard and revert atomically on failed settlement. |
| `unprotected-upgrade` | 2 | FALSE POSITIVE | Statics initializers are Diamond delegatecall boundaries; a direct call cannot mutate Diamond storage. |
| `weak-prng` | 2 | FALSE POSITIVE | Modulo selects deterministic bounded ring-buffer buckets and is not used as randomness. |

## Medium

| Detector | Count | Classification | Review conclusion |
| --- | ---: | --- | --- |
| `divide-before-multiply` | 3 | INTENTIONAL | The affected paths intentionally round at an accounting-bucket or staged fee boundary. |
| `incorrect-equality` | 42 | FALSE POSITIVE | Exact equality enforces zero state, fixed configuration, period boundaries, caps, sentinels, transfer compatibility, or conservation checks. |
| `reentrancy-no-eth` | 16 | INTENTIONAL | Guarded protocol entrypoints and PoolManager callbacks intentionally update accounting around external settlement; liabilities or custody are cleared before transfers where required. |
| `uninitialized-local` | 62 | FALSE POSITIVE | The values are intentional Solidity-zero accumulators, binary-search bounds, optional branch results, memory contexts, or bitmaps. |
| `unused-return` | 297 | INTENTIONAL | Calls are side-effect transitions, capability probes, partial tuple reads, callback boundaries, or Forge JSON serialization; security-sensitive asset movement is checked independently. |

## Low

| Detector | Count | Classification | Review conclusion |
| --- | ---: | --- | --- |
| `calls-loop` | 51 | INTENTIONAL | Loops are bounded by protocol configuration or caller-supplied batch size and preserve atomic batch semantics. |
| `missing-zero-check` | 8 | FALSE POSITIVE | The target is validated by the shared installer, constructor provenance, binding check, caller, or downstream contract requirement. |
| `reentrancy-benign` | 25 | 8 FALSE POSITIVE, 17 INTENTIONAL | The reported ordering occurs within guarded or atomic callback flows and does not expose a value-bearing intermediate state. |
| `reentrancy-events` | 70 | 5 FALSE POSITIVE, 65 INTENTIONAL | Events follow successful external or authenticated self-call settlement so logs describe the committed result; a revert removes the complete transaction and its logs. |
| `return-bomb` | 1 | FALSE POSITIVE | The low-level capability probe uses a fixed 30,000-gas static call and bounded decoding. |
| `shadowing-local` | 10 | FALSE POSITIVE | Locals intentionally mirror domain terms without changing storage or dispatch resolution. |
| `timestamp` | 70 | 1 FALSE POSITIVE, 69 INTENTIONAL | Timestamps implement explicit deadlines, vesting, maturity, claim windows, and continuous reward-period boundaries rather than randomness. |

## Informational

| Detector | Count | Classification | Review conclusion |
| --- | ---: | --- | --- |
| `assembly` | 50 | INTENTIONAL | Assembly implements established Diamond storage/dispatch, calldata, transient settlement state, proxy, or exact revert-forwarding patterns. |
| `cyclomatic-complexity` | 3 | INTENTIONAL | Deployment, Genesis binding, bounded gauge allocation validation, and atomic native settlement preserve coherent transitions. |
| `dead-code` | 3 | INTENTIONAL | Internal phase-cut helpers remain explicit reusable composition boundaries for derived deployment tooling. |
| `low-level-calls` | 17 | INTENTIONAL | Calls are checked dispatch, capability, token-compatibility, native-fee forwarding, fallback-credit, or revert-forwarding boundaries. |
| `missing-inheritance` | 6 | FALSE POSITIVE | Structural suggestions cross interface or legacy-compatibility boundaries and do not indicate missing implementations. |
| `naming-convention` | 8 | INTENTIONAL | Names preserve established external interfaces, including PositionManager's canonical `WETH9()` selector, or mathematical notation. |
| `solc-version` | 2 | INTENTIONAL | The repository pins the reviewed compilers through Foundry configuration and source pragmas. |
| `too-many-digits` | 63 | INTENTIONAL | Exact hashes, hook permission masks, deployment identifiers, and protocol constants must remain literal. |
| `unimplemented-functions` | 1 | FALSE POSITIVE | Implementations are provided by the concrete contract or inherited boundary used at runtime. |
| `unindexed-event-address` | 4 | INTENTIONAL | Established compatibility event signatures retain their topic layout and include full addresses in data. |

Future CI compares normalized findings to the exact reviewed fingerprints and
fails on unreviewed occurrences or growth in a reviewed occurrence group. A
detector appearing in this table still requires a new per-fingerprint decision.


## Native ETH Phase One extension

The native ETH implementation changes 166 exact fingerprints relative to the
previous artifact. Review maps 139 of them one-for-one to the same detector,
source path, and normalized finding after line movement. The remaining 27 have
fresh per-fingerprint decisions covering exact `msg.value` enforcement,
authenticated transient native receipt, guarded PositionManager settlement,
lazy WETH materialization, and canonical `WETH9()` interface spelling.

Three private helpers that Slither proved unreachable were removed rather than
accepted as legacy dead code. No scope exclusion, detector-family suppression,
or unchecked finding was added.
