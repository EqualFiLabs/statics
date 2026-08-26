# Slither triage

Slither emitted 175 in-scope occurrences: 13 high, 56 medium, 62 low, and 44
informational. Repeated compile-unit instances reduce to 154 stable findings in
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
| `incorrect-equality` | 16 | FALSE POSITIVE | Exact equality is used for zero-state, fixed-cap, configuration, and accounting validation. |
| `reentrancy-no-eth` | 16 | INTENTIONAL | Guarded callbacks deliberately settle old state, while claim paths clear liabilities and custody before exact token transfers. |
| `uninitialized-local` | 8 | FALSE POSITIVE | The values are intentional Solidity-zero accumulators, optional branch results, or bitmaps. |
| `unused-return` | 16 | INTENTIONAL | Calls are capability probes or side-effect transitions; security-sensitive asset deltas are independently checked. |

## Low and informational

The 62 low findings comprise two reviewed call loops, two already-validated
zero-address reports, 14 benign reentrancy reports, 22 event-order reports, and
22 intentional timestamp reports. The 44 informational findings comprise eight
reviewed Diamond storage/dispatch assembly blocks, two bounded orchestration
complexity reports, five checked low-level calls, seven structural inheritance
suggestions, one naming report, one compiler-pragma report, one exact hash
literal, one event topic budget report, and 18 deployment/configuration state
reports.

These findings are retained rather than suppressed. The important callback
orders—Genesis owner transition, activation reset, recovery unlink, FeeReceiver
handoff, and old-weight reward settlement—are inputs to the composed formal and
real-flow tests in this PR.
