# Phase 1 Robinhood fork rehearsal

This runner uses the deployed Genesis launch and deploys only the Phase 1 Statics
stack against a pinned Robinhood Mainnet fork. The production Phase 1 launcher
validates the live STATICS, WETH, and treasury bindings from the Genesis manifest.
The runner impersonates the deployed governance Safe for local timelock scheduling.
Forge deployment scripts create the new Phase 1 contracts. Cast performs the
stateful lifecycle transactions, reads, time warps, revert checks, and gas
measurements.

The canonical private RPC file is loaded only by `start-fork.sh`. RPC values and
private endpoints are never written to the run artifacts.

## Complete run

```sh
scripts/phase-one-rehearsal/run-all.sh
```

The command leaves Anvil running in a detached tmux session for inspection. Stop
it with:

```sh
scripts/phase-one-rehearsal/stop-fork.sh
```

The configured provider prunes historical trie proofs, so each run captures the
provider's current executable block before Anvil starts and records the exact
block and hash in `state.env`. The resulting run remains pinned and reproducible
for the life of that Anvil process, while later runs use a fresh executable state.
Generated receipts, logs, selector inventories, selector coverage, gas
measurements, and the final summary live under
`artifacts/phase-one-rehearsal/<run-id>/` and are ignored by Git. Deployment
compilation uses run-scoped artifact and cache directories so runtime
verification cannot accidentally accept stale shared build output.

## Evidence layers

- `verify-deployment.sh` validates canonical Robinhood dependencies, immutable
  bindings, exact source runtime bytecode, all 31 installed facets, all 220
  Diamond selector routes, and the PositionNFT market and royalty defaults.
- `public-pool-creation.sh` exercises exact native creation fees, invalid
  payment and configuration paths, distinct PoolKeys, direct and relayed
  creator authorization, nonce invalidation and replay, reciprocal pricing, and
  stale defaults.
- `vanilla-v4-gas.sh` initializes a no-hook v4 pool, mints full-range liquidity,
  and records cold and steady exact-input swap gas.
- `public-market-tape.sh` creates a Statics public pool, provides two managed
  ranges, verifies exact-input and exact-output canonical MarketTape records,
  crosses a managed boundary, and grows and wraps the observation ring.
- `managed-lp-lifecycle.sh` proves native-fee collection, increase, partial
  decrease, rebalance, exit, and PositionNFT closure through the managed LP path.
- `external-posm-attachment.sh` mints a real external Uniswap v4 position,
  rejects unauthorized, wrong-pool, permissioned-pool, and duplicate attachment,
  then exercises rewards, mutations, fees, rebalance, and exit after attachment.
- `liquidity-manager-replacement.sh` rejects incompatible replacements, installs
  a compatible manager through governance, keeps legacy positions operational,
  opens new positions under the replacement, and lazily migrates a legacy POSM
  while preserving its reward entitlement and binding integrity.
- `position-market-transfer.sh` builds a live PositionNFT financial account,
  proves bounded public valuation views, transfers staking, allocation, range,
  and reward state, clears ERC-721 authority, and exercises timelocked ERC-2981
  signaling without charging raw transfers.
- `permissioned-lifecycle.sh` proves creator authorization, trader and LP
  admission, permissioned trading, creator and Treasury revenue, restricted-asset
  normalization, normalized staker claims, halt enforcement, forced unwind,
  backed owner credit, and claims.
- `permissioned-creator-handover.sh` preserves the controller, LP ownership,
  trading, and credit through creator transfer; invalidates historical signed
  terms and controller approvals; exercises successor-approved configuration;
  and preserves creator rights after decommission.
- `protocol-pol-lifecycle.sh` proves disabled-POL fallback, paid activation,
  two-asset PoolId custody, managed position operations, the empty-position
  lifecycle, native LP fee routing to Treasury, and incremental decommissioning.
- `protocol-pol-rebalance.sh` seeds dual-sided and both single-sided bands,
  replaces portfolios at the eight-close/eight-open bound, replaces the manager,
  checks exact per-asset principal/refund accounting and fee separation, and
  mines malicious calls with unauthorized actors, expired deadlines, invalid
  leg counts, duplicate/foreign/unknown closes, insufficient PoolId custody,
  gross-debit violations, overflow, bad ranges and lifecycle stops. Late-open
  failures must roll back earlier closes and valid mints, including POSM IDs,
  ownership, gauge bindings, balances, custody and Treasury accounting.
- `direct-range-rewards.sh` funds direct LP reward slot 1, proves reserved-slot
  and duplicate-asset guards, and exercises claim, exit, forfeiture, and close
  liveness through real managed positions.
- `allocator-rewards.sh` proves a creator-funded slot can split continuously
  between the LP and allocator paths while protocol slot 0 remains isolated.
- `public-revenue-rewards.sh` proves swap-time global reward ownership, later
  staker isolation, delayed backing, creator and Treasury claims, and restriction
  fallback and recovery.
- `fee-configuration.sh` proves default and PoolId-local fee precedence, exact
  creator/staker/POL/Treasury allocation across bilateral swaps, POL override
  capping, and Treasury-funded maintenance tips.
- `creator-handover.sh` proves the public creator proposal state machine, fixed
  revenue recipients, settled-credit continuity, authority replacement, POL and
  gauge administration transfer, and PoolId-local claim backing.
- `staking-and-gauges.sh` proves stake and allocation cooldowns, allocation locks,
  reserve funding, slot-0 delivery, two-period catch-up, and a 105-period gap
  recovered through bounded 52, 52, and 1 period calls.
- `multi-pool-gauges.sh` proves persistent allocation across two PoolIds and
  pro-rata protocol reward delivery to both productive markets.
- `configuration-surface.sh` exercises the timelocked guardian, Treasury,
  PositionNFT fee, global reward limit, maintenance tip, POL activation fee,
  gauge duration/release/cooldown, and permissioned-periphery configuration.
- `governance-upgrade-surface.sh` executes a timelocked ephemeral facet add,
  invocation, and removal, then proves the live Diamond ownership handoff path.
- `governance-controls.sh` executes real swaps, staking, liquidity, POL, claims,
  and Treasury distribution across guardian pauses, pool quarantine, and the
  global public-swap pause, including exit liveness and timelock-delay proof.
- `composed-soak.sh` keeps one accumulated state across staking, allocations,
  direct and protocol incentives, POL, creator and PositionNFT transfers,
  restrictions, emergency controls, decommissioning, claims, and solvency
  reconciliation without resetting between transitions. Its terminal checks
  separately report custody backing and PoolId-local liability reconciliation.

The selector coverage manifest joins every installed selector to its exact
signature, facet name, direct-success and revert evidence, and explicit
classification. The runner fails when any externally callable state-changing
selector lacks a direct fork scenario or any installed view remains unqueried.
Deployment-only installation calls and authenticated hook callbacks remain
separately classified; route verification is never presented as behavioral
coverage. Foundry unit, fuzz, invariant, and formal suites remain separate
evidence.

The added rebalance selector requires observed transaction hashes for successful
and reverted calls in `selector-execution.jsonl`; textual signature matching
cannot satisfy that gate. Reverts are deliberately mined with explicit gas limits
and retained separately under `expected-reverts/`. Each requires status `0x0`,
the expected error in its trace, any required earlier successful calls, and equal
before/after financial state. The final summary reports these intentional reverts
separately from failed successful-path transactions. No formal verification is
added or invoked by this rehearsal.

After every scenario the runner scans all successful-path mined JSON receipts and rejects any
transaction whose status is not `0x1`. This is required because a mined revert
can still be serialized successfully by `cast send --json`.

## Gas interpretation

Each scenario reverts to the same post-deployment base snapshot. Gas files
separate first-use cold initialization from steady-state swaps. The vanilla and
Statics pools use the same fork, assets, PoolManager, native LP fee, tick spacing,
router family, direction, and exact-input amount. Managed-boundary gas is reported
separately because it includes an active-liquidity denominator transition.
