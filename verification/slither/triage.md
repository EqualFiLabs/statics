# Slither triage

The reviewed native ETH Phase One CI artifact covered 252 production Solidity files
and explicitly excludes 17 test, formal-fixture, and vendor files as finding
subjects. It normalizes to 863 stable findings: 51 high, 420 medium, 235 low,
and 157 informational. Every stable fingerprint has an explicit classification
and rationale in `baseline.json`; detector families are summarized below but
are not blanket suppressions for future findings.

All 863 findings in that snapshot were reviewed as intentional behavior or false
positives. The detector-family tables below describe that snapshot; the exact
current decisions are in `baseline.json`.

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

## Four launch pools extension

The launch-pool deployment script expands the current scope to 255 production
files. The reviewed artifact contains 896 normalized findings: 52 high, 421
medium, 258 low, and 165 informational. All 896 have individual decisions
(702 intentional, 194 false positive). Eleven prior fingerprints moved with
source lines; 25 findings are new to the launch-pool script and handoff checks.
The launch verifies the returned pool ID and installed hook directly. The
remaining new medium findings are partial PoolManager slot reads: only the
initialized price is needed, while pool identity and configured fees are
checked separately. The new loop reports concern four fixed launch pools or
read-only handoff checks, and the timestamp reports concern the one-day
creation deadline.

The four-pool fee revision relocates 18 reviewed fingerprints through source
mapping changes. Each is matched to its prior detector, subject, and rationale;
the current artifact adds no new finding and resolves none.

Removing the PoolId gate from handoff preparation removes ten findings tied to
that verification path. Five unchanged findings in the same script receive new
source-span fingerprints; their prior classifications and rationales still
apply. The resulting CI artifact has 886 normalized findings and no unreviewed
finding.

Pinning the Phase 1 mainnet guardian to the Genesis governance Safe moves four
reviewed deployment-script fingerprints because their source spans shift. The
detectors, subjects, classifications, rationales, and 886-finding total are
unchanged.

## Immutable public hooks and restricted baskets

The [PR #139 CI artifact](https://github.com/EqualFiLabs/statics/actions/runs/38759691949)
at `1dbb08d9be2607069a45f4d4cbd139d50c79778c` covers 286 production files
and retains the existing 17 explicit exclusions. It contains 992 normalized
findings: 69 high, 437 medium, 288 low, and 198 informational. Compared with the
previous baseline, 378 fingerprints are new and 272 are absent. These include
source-span changes and findings in the new hook, factory, settlement, and
deployment paths.

Each new fingerprint has an individual source-reviewed decision and rationale
in `baseline.json`. The review checks authenticated callers and shared locks
around token callbacks, exact balance deltas and fresh manager state reads,
zero-initialized accumulators, intentionally unused tuple fields and side-effect
returns, and bounded or caller-sized loops. Existing reviewed decisions remain
attached to matching fingerprints. No detector suppression or scope exclusion
is added. Exact-fingerprint, occurrence-growth, and unresolved-finding gates
remain unchanged.

This artifact reports an analyzer coverage limitation: Slither cannot generate
IR for seven unchanged `LibGlobalRewards` helpers (`_increasePending`,
`_rollMatured`, `_matureBucket`, `_duePendingStake`, `_duePendingWeight`,
`_needsCheckpoint`, and `_eligibleAt`). The per-finding decisions cover the
reported results; a passing baseline does not establish analyzer coverage of
those helpers. Source review, executable tests, and formal checks remain
separate evidence.


## Shared basket distributor permissions

The [distributor-enabled CI artifact](https://github.com/EqualFiLabs/statics/actions/runs/38790538662)
at `4be0a9e2fe965c25975a35cb2e374ba0d4f3eb9c` covers the same 286 production
files and 17 explicit exclusions. It contains 989 normalized findings: 69 high,
437 medium, 286 low, and 197 informational. All 35 new fingerprints map to
previously reviewed subjects after source-span and call-graph changes. Each
receives an individual decision in `baseline.json` after source review.

The four high findings retain authenticated callers, the shared reentrancy
guard, fresh post-call balance measurements, and exact receipt checks. The
three medium findings intentionally discard a state-synchronization result
or exact-assets Morpho supply return values that do not feed custody
accounting. Restricted protocol-transfer authorization targets only registered
factory-created basket tokens and writes an exact transient ticket without an
external callback; distributor lookup is read-only and introduces no payout
callback. Low event reports retain the relevant guarded or atomic settlement
boundaries. Deployment-script events deliberately follow checked timelock
scheduling rather than relying on a script reentrancy guard.

Three findings disappear with the removed token-specific Morpho binding:
its interface-parameter shadow, a market-registration event report, and the
registration complexity warning. Three unchanged low PositionNFT event
fingerprints have two duplicate compile-unit reports instead of one; the
source occurrence and caller authority are unchanged. Their individual
rationales describe fresh-ID allocation, initialization, ERC-721 callbacks,
and checked creation-fee forwarding.

No high or medium occurrence group grows. No detector suppression, scope
exclusion, or gate change is added. The seven `LibGlobalRewards` IR-generation
limitations recorded above remain present in this artifact.

## Standalone modular hooks candidate `a66768e`

Slither 0.11.6 analyzes the simplified source with the repository Slither
profile, Solidity 0.8.33, optimization 200, and no global IR. The fresh result
contains 1,033 stable fingerprints: 70 high, 466 medium, 291 low, and 206
informational. No detector family is suppressed, and the new, expanded, and
unresolved gates remain enabled.

The focused Solidity audit reported three supported findings: a pending-basket
liquidity authorization that trusted the PositionManager without authenticating
its active locker, flash access to pending restricted baskets, and a sender-fee
token path whose actual payer debit could exceed the mint maximum. Candidate
`a66768e` authenticates both the configured PositionManager and its Statics
liquidity-manager locker, requires active restricted baskets for flash paths,
and measures the payer balance around each custody pull. Regression tests cover
each case and the audit remediation review found no remaining supported issue in
those paths.

The payer-debit measurement adds one `reentrancy-balance` fingerprint. The
balance reads deliberately bracket the custody pull; all reachable mint paths
are protected by the Diamond-wide reentrancy guard, with the launch helper
restricted to Diamond-self calls inside guarded finalization. A failed debit
cap rolls back the transfer and reservation atomically.

The standalone-hook cleanup removes the irrelevant allocation profile from each
hook, deletes ordinary salt queues, and combines prepared-token reservation and
deployment. Thirty-six fingerprints move only because those deletions change
source spans; their detector, subject, classification, and rationale remain
unchanged. Two informational `unimplemented-functions` fingerprints change
because the hooks no longer inherit the broad legacy interface: each hook now
exposes only its supported allocation profile while retaining the common ABI
used by the Diamond. The baseline contains an individual decision for every
current fingerprint.

The audit also retained one design lead: basket full-range arithmetic uses the
configured fixed tick spacing. This behavior predates the candidate and the
review did not establish an exploit or loss. The reviewed POL-operator finding
remains an explicitly governed strategy risk because only the configured
operator or owner can initiate the operation; there is no unprivileged trigger.

Coverage limitation: Slither cannot generate complete IR for the seven existing
`LibGlobalRewards` maturity and checkpoint helpers recorded in `run.log`.
Focused runtime reward tests supplement this limitation; this run is not a
formal proof. Symbolic proofs remain assigned to CI or the dedicated formal
verification environment.

Raw result SHA-256: `c692ebc193832404b9af5b8e238f9d10c620947f1d06cbeb8102b6f71f524ade`.
Local raw and normalized outputs remain in ignored Slither-results storage.
Historical review sections above describe their own snapshots and are retained.
