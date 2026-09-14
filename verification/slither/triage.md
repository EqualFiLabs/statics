# Slither triage

The reviewed repository-wide CI artifact covers 185 production Solidity files
and explicitly excludes 17 test, formal-fixture, and vendor files as finding
subjects. It normalizes to 622 stable findings: 44 high, 316 medium, 206 low,
and 56 informational. Every stable fingerprint has an explicit classification
and rationale in `baseline.json`; detector families are summarized below but
are not blanket suppressions for future findings.

All 622 current findings are reviewed as intentional behavior or false
positives.

## High

| Detector | Count | Classification | Review conclusion |
| --- | ---: | --- | --- |
| `arbitrary-send-erc20` | 5 | FALSE POSITIVE | Internal exact-transfer helpers receive authenticated or protocol-controlled payers and validate the relevant debit and receipt deltas. |
| `arbitrary-send-eth` | 3 | 1 FALSE POSITIVE, 2 INTENTIONAL | Genesis donations use an immutable validated Vault; governed treasury and recipient payouts deliberately send native value after state accounting. |
| `reentrancy-balance` | 28 | FALSE POSITIVE | Reported balance reads and transfers are inside guarded actions, PoolManager unlock callbacks, or exact-delta helpers whose callers establish the authority and accounting boundary. |
| `reentrancy-eth` | 3 | FALSE POSITIVE | WETH unwrap, Vault donation, and Genesis distributor paths use the applicable reentrancy guard and revert atomically on failed settlement. |
| `unprotected-upgrade` | 1 | FALSE POSITIVE | `StaticsProtocolInit` is a Diamond delegatecall initializer; a direct call cannot mutate Diamond storage. |
| `weak-prng` | 4 | FALSE POSITIVE | Modulo selects deterministic bounded ring-buffer buckets and is not used as randomness. |

## Medium

| Detector | Count | Classification | Review conclusion |
| --- | ---: | --- | --- |
| `divide-before-multiply` | 3 | INTENTIONAL | The affected paths intentionally round at an accounting-bucket or staged fee boundary. |
| `incorrect-equality` | 28 | FALSE POSITIVE | Exact equality enforces zero state, fixed configuration, caps, sentinels, or conservation checks. |
| `reentrancy-no-eth` | 31 | INTENTIONAL | Guarded protocol entrypoints and PoolManager callbacks intentionally update accounting around external settlement; liabilities or custody are cleared before transfers where required. |
| `uninitialized-local` | 46 | FALSE POSITIVE | The values are intentional Solidity-zero accumulators, optional branch results, or bitmaps. |
| `unused-return` | 208 | INTENTIONAL | Calls are side-effect transitions, capability probes, partial tuple reads, callback boundaries, or Forge JSON serialization; security-sensitive asset movement is checked independently. |

## Low

| Detector | Count | Classification | Review conclusion |
| --- | ---: | --- | --- |
| `calls-loop` | 46 | INTENTIONAL | Loops are bounded by protocol configuration or caller-supplied batch size and preserve atomic batch semantics. |
| `missing-zero-check` | 12 | FALSE POSITIVE | The target is validated by the shared installer, binding check, caller, or downstream contract requirement. |
| `reentrancy-benign` | 19 | INTENTIONAL | The reported ordering occurs within guarded or atomic callback flows and does not expose a value-bearing intermediate state. |
| `reentrancy-events` | 70 | INTENTIONAL | Events follow successful external settlement so logs describe the committed result; a revert removes the complete transaction and its logs. |
| `return-bomb` | 1 | FALSE POSITIVE | The low-level capability probe uses a fixed 30,000-gas static call and bounded decoding. |
| `shadowing-local` | 9 | FALSE POSITIVE | Locals intentionally mirror domain terms without changing storage or dispatch resolution. |
| `timestamp` | 49 | INTENTIONAL | Timestamps implement explicit deadlines, vesting, maturity, grace periods, and epoch boundaries rather than randomness. |

## Informational

| Detector | Count | Classification | Review conclusion |
| --- | ---: | --- | --- |
| `assembly` | 21 | INTENTIONAL | Assembly implements established Diamond storage/dispatch, calldata, proxy, or exact revert-forwarding patterns. |
| `cyclomatic-complexity` | 1 | INTENTIONAL | Genesis protocol binding validates a one-time integration boundary in one atomic transition. |
| `low-level-calls` | 14 | INTENTIONAL | Calls are checked dispatch, capability, token-compatibility, or revert-forwarding boundaries. |
| `missing-inheritance` | 4 | FALSE POSITIVE | Structural suggestions cross interface or legacy-compatibility boundaries and do not indicate missing implementations. |
| `naming-convention` | 3 | INTENTIONAL | Names preserve established external interfaces or mathematical notation. |
| `solc-version` | 1 | INTENTIONAL | The repository pins the reviewed compiler through Foundry configuration and source pragmas. |
| `too-many-digits` | 6 | INTENTIONAL | Exact hashes, hook permission masks, and protocol constants must remain literal. |
| `unimplemented-functions` | 2 | FALSE POSITIVE | Implementations are provided by the concrete contract or inherited boundary used at runtime. |
| `unindexed-event-address` | 4 | INTENTIONAL | Established compatibility event signatures retain their topic layout and include full addresses in data. |

Future CI compares normalized findings to the exact reviewed fingerprints and
fails on unreviewed occurrences or growth in a reviewed occurrence group. A
detector appearing in this table still requires a new per-fingerprint decision.
