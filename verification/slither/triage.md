# Slither triage

Slither emitted 168 in-scope occurrences: 13 high, 54 medium, 58 low, and 43
informational. Repeated compile-unit instances reduce to 147 stable findings in
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
| `reentrancy-no-eth` | 14 | INTENTIONAL | Guarded callbacks deliberately settle old-owner/old-weight state before transfer, recovery, or handoff effects. |
| `uninitialized-local` | 8 | FALSE POSITIVE | The values are intentional Solidity-zero accumulators, optional branch results, or bitmaps. |
| `unused-return` | 16 | INTENTIONAL | Calls are capability probes or side-effect transitions; security-sensitive asset deltas are independently checked. |

## Low and informational

The 58 low findings comprise one capped vesting call loop, two already-validated
zero-address reports, 13 benign reentrancy reports, 20 event-order reports, and
22 intentional timestamp reports. The 43 informational findings comprise eight
reviewed Diamond storage/dispatch assembly blocks, two bounded orchestration
complexity reports, five checked low-level calls, seven structural inheritance
suggestions, one naming report, one compiler-pragma report, one event topic
budget report, and 18 deployment/configuration state reports.

These findings are retained rather than suppressed. The important callback
orders—Genesis owner transition, activation reset, recovery unlink, FeeReceiver
handoff, and old-weight reward settlement—are inputs to the composed formal and
real-flow tests in this PR.
