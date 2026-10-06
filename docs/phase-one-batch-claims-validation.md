# Phase 1 batch reward claim validation

Local tests use disposable Foundry EVM state, real PoolManager/PositionManager
liquidity, token approvals/transfers, hook swaps, global staking, allocations,
reserve funding and community bribes. They do not use the populated app fork.
The narrow dispatcher unit harness separately covers unavailable routes,
malformed input and the shared guard's otherwise unreachable entered state.

- Equivalent-state batch versus individual claims compare nested return values,
  global reward books, reserve state, LP/allocator stream liabilities, physical
  token balances, custody reservations and complete event contents/order.
- Two NFTs and two pools exercise all sources, owner and approved operators,
  transferred-NFT rejection and rollback after a late authorization/minimum
  failure. Distinct unchanged claim events are identified by log index.
- Exited LP stubs and retained allocator claims resolve through ordinary claims.
- Taxed token minimums use actual received amounts; late reverting transfers
  undo earlier payouts. Token callbacks cannot reenter a batch, an individual
  claim or another guarded custody action. Successful retries prove lock recovery.
- A 60-week schedule gap retains the existing bounded catch-up failure; two
  explicit 52-period checkpoints allow the subsequent claim.
- Fresh Phase 1, all staged later phases, cumulative deployment parity and a
  timelocked upgrade to an already funded/staked/LP-populated Diamond are tested.
- Solidity-generated calldata/results and the interface ABI are checked by the
  SDK suite; local validation and deterministic immutable splitting are covered.

## Gas and bytecode measurements

Foundry 1.8.2 nightly `bdd1162b2c24814d2424ffad4f8c587827f1a6ab`, Solidity
0.8.33, Cancun, optimizer 200 runs, no IR for Statics contracts, no metadata hash.
The third-party PositionManager/Permit2 scoped IR exceptions are unchanged.
Measurements are `gasleft()` differences in the local lifecycle fixtures; they
exclude transaction intrinsic gas and use fixture-warmed state. The mixed case
includes return decoding and test assertions; maximum cases include the helper
call. They are reproducible test evidence, not production transaction estimates.

| Case | Measured gas |
|---|---:|
| Mixed: 6 groups, 10 entries, two NFTs/pools, all reward sources | 3,340,021 |
| Maximum: 16 LP groups, 64 bribe entries | 6,988,379 |
| Maximum: 16 LP groups, 64 entries, protocol reserve + bribes, 50-week lazy settlement | 9,042,345 |
| LP claim after explicit 60-week catch-up | 516,646 |

`BatchRewardsFacet` runtime is 3,824 bytes, below EIP-170's 24,576-byte limit.
Runtime keccak256:
`0x22a64a82b3504f7618d770ad1f46b1b8b2e40fdc9799f5a6b5c109e88f697757`.
Coverage instrumentation must exclude the bytecode-size test as described in
`AGENTS.md`. The fixed input limits cannot guarantee gas availability for
arbitrary token behavior or gauge boundary density.

Run the focused checks with:

```sh
forge test --match-path 'test/rewards/BatchRewards*.t.sol' -vv
forge test --match-path 'test/deployment/{BatchRewardsUpgrade,SelectorManifest,DeployStaticsPhaseOne,DeployStaticsPhases,DeployStatics}.t.sol'
```

Repository CI remains the complete-suite, static-analysis and existing formal
gate. These local tests provide no new formal proof or production-deployment
validation.
