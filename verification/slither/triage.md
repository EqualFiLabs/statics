# Slither triage

Slither emitted 255 in-scope occurrences: 13 high, 107 medium, 68 low, and 67
informational. Repeated compile-unit instances reduce to 218 stable findings in
the reviewed baseline. There are no `CONFIRMED` or `INVESTIGATE` findings.
The machine-readable classification and rationale for each detector family live
in `decisions.json`; `baseline.json` applies those decisions to each stable
finding fingerprint.

## High

| Detector | Count | Classification | Review conclusion |
| --- | ---: | --- | --- |
| `arbitrary-send-erc20` | 2 | FALSE POSITIVE | Internal exact-transfer helpers receive authenticated or protocol-controlled payers and verify balance deltas. |
| `arbitrary-send-eth` | 1 | FALSE POSITIVE | The destination is the immutable, one-time validated Genesis Vault donation endpoint. |
| `reentrancy-balance` | 4 | FALSE POSITIVE | Exact-delta checks sit behind guarded entrypoints and immutable/governance-activated dependencies. |
| `reentrancy-eth` | 3 | FALSE POSITIVE | WETH unwrap, Vault donation, share change, and distributor acceptance are protected by `nonReentrant`. |
| `unprotected-upgrade` | 1 | FALSE POSITIVE | `StaticsProtocolInit` is a Diamond delegatecall initializer; direct calls cannot mutate Diamond storage. |
| `weak-prng` | 2 | FALSE POSITIVE | Modulo selects deterministic reward ring-buffer buckets and is not randomness. |

## Medium

| Detector | Count | Classification | Review conclusion |
| --- | ---: | --- | --- |
| `incorrect-equality` | 26 | FALSE POSITIVE | Exact equality is used for zero-state, fixed-cap, configuration, and accounting validation. |
| `reentrancy-no-eth` | 16 | INTENTIONAL | Guarded callbacks deliberately settle old state, while claim paths clear liabilities and custody before exact token transfers. |
| `uninitialized-local` | 8 | FALSE POSITIVE | The values are intentional Solidity-zero accumulators, optional branch results, or bitmaps. |
| `unused-return` | 57 | INTENTIONAL | Calls are capability probes, side-effect transitions, Forge JSON serialization, or callbacks with intentionally empty return data; security-sensitive asset deltas are independently checked. |

## Launch-liquidity pass

The added launch-liquidity scope contains 54 stable findings: 42 medium, five
low, and seven informational. None is a confirmed defect.

- The 42 medium `unused-return` findings are 32 intermediate deployment-artifact
  serialization calls, nine intermediate fresh-calldata serialization calls,
  and the claim redeemer's PoolManager unlock result. Forge serialization builds
  one JSON object through side effects and only the final return is written. The
  redeemer callback deliberately returns empty bytes; success or revert and the
  PoolManager claim/underlying deltas are the relevant results.
- The two zero-check reports miss `_enforceValidReceiver`, which rejects zero,
  the hook, PoolManager, and PositionManager for both construction and rotation.
- The two event-order reports follow calls to the immutable PoolManager. Claim
  minting invokes no currency contract, the redeemer retains no state or assets,
  and callback failure reverts the entire transition.
- The preparation timestamp is an explicit transaction deadline. The remaining
  informational reports cover pinned compiler/remapping units, the fixed hook
  permission mask, inherited Forge script state, and a false missing-override
  report even though `getHookPermissions()` is implemented directly.

## Low and informational

The 68 low findings comprise two reviewed call loops, four already-validated
zero-address reports, 14 benign reentrancy reports, 24 event-order reports, and
24 intentional timestamp reports. The 30 informational findings comprise nine
reviewed Diamond storage/dispatch assembly blocks, one bounded orchestration
complexity report, six checked low-level calls, two structural inheritance
suggestions, one naming report, three compiler/remapping reports, two exact
hash-or-mask literals, one false missing-override report, one event topic budget
report, and four deployment/configuration state reports.

These findings are retained rather than suppressed. The important callback
orders—Genesis owner transition, activation reset, recovery unlink, FeeReceiver
handoff, and old-weight reward settlement—are inputs to the composed formal and
real-flow tests in this PR.
