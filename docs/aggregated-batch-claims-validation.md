# Aggregated batch reward payout validation

The additive call settles authorized claims individually and pays each positive
token total once. Existing individual and batch selectors retain measured taxed-token
payouts. Aggregated mode requires exact sender debit and recipient receipt; it never
retries through the legacy API.

## Local execution

Focused reward checks pass 70 tests using disposable Foundry EVM state. The
fixtures use real approvals, transfers, staking, PoolManager/PositionManager
liquidity, allocations, reserve funding and community bribes. They compare
aggregated, legacy batch and individual results, wallet balances, reward books,
reserve commitments, liabilities and custody backing.

Coverage includes multiple NFTs/pools and shared assets across reward categories;
owner/approved callers and transferred NFTs; retained rewards and exited LP stubs;
zero entries and global `NoRewards`; independent stale minimums; both input limits;
bounded schedule catch-up; late token reverts and excess sender debits; taxed
receipt rollback with successful legacy taxed payouts; callback rejection;
consecutive calls and caught-revert recovery. A narrow route harness reproduces
missing, incorrect and excess acknowledgements. A storage probe observes a pending
batch reservation during a real token callback, before its later exact payout.
Synthetic probes test compatibility/accounting boundaries, not replacement funding
or reward lifecycles.

The populated upgrade test executes the actual four facet runtimes compiled from
parent revision `de38102e13998468242db7efd31d58a243df4361`, funds/stakes/provides
liquidity, then executes the timelocked atomic replacement and claims its existing
rewards. The parent BatchRewardsFacet runtime matches its recorded hash
`0x22a64a82b3504f7618d770ad1f46b1b8b2e40fdc9799f5a6b5c109e88f697757`.
The ordinary CustodyFacet runtime remains byte-for-byte identical to the parent;
it requires no fifth replacement. Its existing view reads persistent accounts;
the temporary batch reservation is internal transient state.

Deployment/selector checks pass 73 tests across fresh Phase 1, cumulative
installation, staged progression through later phases, populated upgrades,
interface registration, collisions and incompatible preparation inputs. The
separate CoreDeployment check passes seven tests. Final focused upgrade checks
are rerun after preparation changes. The Solidity interface/calldata/result
fixtures match the SDK, whose suite passes 121 tests and its TypeScript build.

The pinned runtime fixture is regenerated without changing branches or deploying:

```sh
python3 scripts/generate-batch-parent-fixture.py --solc /path/to/solc-0.8.33
```

Regeneration needs the pinned parent Git object and its unchanged initialized
contract submodules. Provenance and dependency revisions are recorded in
`test/fixtures/phase-one-batch-parent.json`.

## Gas and transfer counts

Measurements use Foundry nightly `bdd1162b2c24814d2424ffad4f8c587827f1a6ab`,
Solidity 0.8.33, Cancun, optimizer 200, no IR for Statics contracts and no metadata
hash. Existing third-party scoped IR exceptions remain unchanged. Values are
`gasleft()` differences around the fixture calls from equivalent restored state.
They exclude transaction intrinsic gas, include helper/return handling, and use
fixture-warmed state. The mixed aggregate case also includes ABI comparison.
These are reproducible execution comparisons, not production gas estimates.

| Fixture | Legacy gas | Aggregated gas | Payout transfers |
|---|---:|---:|---:|
| One LP entry, one token | 363,731 | 378,365 | 1 → 1 |
| Four pools, 16 entries, four repeated tokens | 3,402,416 | 3,342,920 | 16 → 4 |
| 16 pools, 64 entries, four repeated tokens | 12,975,498 | 12,523,717 | 64 → 4 |
| Reproduced 64-entry/13-token pattern | 13,281,530 | 12,980,573 | 64 → 13 |
| 16 pools, 64 distinct tokens | 15,015,556 | 15,569,640 | 64 → 64 |
| Mixed staking/gauge/LP-bribe/allocator claims | 3,227,178 | 3,149,642 | 10 → 4 |
| 64 entries, four tokens, 50-week lazy settlement | 9,073,730 | 8,617,755 | 64 → 4 |

The 64-entry/13-token fixture asserts exactly 13 outbound ERC-20 Transfer logs,
64 unchanged per-entry results and identical wallet totals. Repeated-token cases
improve measured gas; aggregation adds overhead when transfers cannot be combined.
Each complete batch still needs simulation and gas estimation, regardless of the
fixed input limits.

The existing ordinary batch fixtures increase by approximately 0.2–0.4% over the
parent's recorded measurements because legacy dispatch now checks the transient
context and reward helpers select their ordinary path. The custody transfer bodies
are unchanged. This is bounded context-check overhead, not additional settlement.

| Release facet | Runtime bytes | EIP-170 headroom |
|---|---:|---:|
| BatchRewardsFacet | 6,757 | 17,819 |
| GlobalRewardsFacet | 23,016 | 1,560 |
| RangeGaugeLivenessFacet | 21,660 | 2,916 |
| GaugeIncentiveFacet | 24,496 | 80 |

All four runtimes have size regression assertions. Allocator facet headroom is
small; future changes must keep the release compiler profile and recheck size.
Coverage instrumentation excludes these size assertions as documented in AGENTS.md.

## Reproduction and boundaries

```sh
forge test --match-path 'test/rewards/{*BatchRewards*,AggregatedBatchValidation}.t.sol' --threads 2 -vv
forge test --match-path 'test/deployment/{*Phase*,*RewardsUpgrade,SelectorManifest,DeployStatics}.t.sol' --threads 2 -vv
forge test --match-path test/dollar/unit/CoreDeployment.t.sol --threads 2 -vv
```

Changed Solidity files pass scoped formatting and Git whitespace checks.
Repository-wide formatting also reports eight pre-existing unmodified files;
they are outside this cleanup and the configured CI format gate checks changed
files. Independent local agent reviews found and remediated the original allocator
facet size overflow, then found no further core or SDK issues. These reviews are
not independent third-party audits.

The existing repository CI gates supply complete suites, static analysis and
established formal checks. This change adds no formal proof. No new remote-fork
acceptance or production deployment was executed locally, and the populated UI
fork, app, databases and reward balances were preserved. Required CI outcomes are
reported separately for each published PR head.
