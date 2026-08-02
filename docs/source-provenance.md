# Statics Source Provenance

## Canonical repository

The combined Statics protocol is developed and built from the canonical
`EqualFiLabs/statics` repository:

```text
https://github.com/EqualFiLabs/statics
```

The unified implementation starts from Statics commit:

```text
ffc8755b995a71796b4ab1728fd6ed6ac190982c
```

## Statics Dollar reference

The initial Statics Dollar implementation is imported from the tracked files at:

```text
Repository: EqualFiLabs/ether-dollar (private historical source)
Commit: 017064ec8188c7f3d120fb9588f88d01925e45f1
Tree: 328b5610ea3090d2fae8ef1e5193626920d2f5c9
Commit date: 2026-07-16T11:44:52-06:00
Commit subject: chore(docs): Update EtUSD-Design.md
```

The reference checkout is read-only for the unified Statics work. Import only
files tracked by the pinned commit. Do not import its untracked audit output,
build output, caches, or other workspace residue.

## Independence requirement

Imported source becomes ordinary source in this repository. The combined
protocol must not use:

- filesystem symlinks to the reference checkout;
- Solidity imports that resolve through an adjacent Ether Dollar checkout;
- scripts that copy source from the reference during normal builds or tests;
- submodules or package dependencies pointing at the old repository; or
- runtime dependencies on the old deployment or repository.

Mechanical path and naming changes must be reviewable separately from behavior
changes. The imported baseline must first reproduce the pinned Dollar tests
before its periphery is moved into the unified `StaticsDiamond`.

## Uniswap v4 integration stack

Statics vendors the official Uniswap v4 sources as a pinned submodule. The
selected periphery revision is the final official revision that both contains
the compatible `BaseHook` implementation and uses the exact core and Permit2
revisions matched by Robinhood Chain's verified deployments.

```text
v4-periphery: 3779387e5d296f39df543d23524b050f89a62917
v4-core:      59d3ecf53afa9264a16bba0e38f4c5d2231f80bc
Permit2:      cc56ad0f3439c502c246fc5cfcc3db92bb8b7219
Solmate:      4b47a19038b798b4a33d9749d25e570443520647
```

The dependency repositories are licensed as follows:

- `v4-periphery`: MIT
- `v4-core`: Business Source License 1.1 for core source, with individually
  marked MIT-licensed interfaces, libraries, and test utilities
- `Permit2`: MIT
- `Solmate`: AGPL-3.0-only

Robinhood Chain's verified `PoolManager` source matches the pinned
`v4-core` revision. Its verified `PositionManager` executable source matches
the later periphery revision `3c31961fb909a2b68d90f0094016cfb8edc68b50`;
the only `PositionManager.sol` changes between that revision and the pinned
compatible revision are comments warning about deprecated action constants.
The local fixture therefore exercises the same executable implementation while
retaining the official hook base compatible with the deployed PoolManager.

For this pinned version, liquidity fees are collected through a zero-liquidity
`DECREASE_LIQUIDITY` action followed by `CLOSE_CURRENCY` actions. Hook-returned
swap deltas are represented by v4's packed signed `BeforeSwapDelta` and
`BalanceDelta` types and are settled inside the PoolManager unlock callback.
The immutable Statics hook uses the official `PoolManager.take` path during
that callback to hold direct currency balances, returns the matching requested
hook delta, and records only its measured physical receipt as liability. This
is the sole production representation; Statics does not also maintain v4
ERC-6909 claims for hook fees.

Robinhood's deployed Universal Router uses the standard `V4_SWAP` command
`0x10`, but its verified single-hop payload is newer than the pinned
PositionManager payload: it appends `minHopPriceX36` after
`amountOutMinimum`. The required fork suite encodes that explicit field and
proves the live Universal Router route rather than substituting a mock or
silently treating the two payloads as identical.

## Verification

Before importing, verify the reference with:

```text
git -C ../market-ui/ether-dollar rev-parse HEAD
git -C ../market-ui/ether-dollar rev-parse 'HEAD^{tree}'
```

After importing, verify that no active path depends on the old checkout:

```text
rg -n "\.\./market-ui/ether-dollar|EqualFiLabs/ether-dollar" \
    src test script foundry.toml remappings.txt
```

The provenance document itself may retain the historical repository URL and
path; production source, tests, scripts, and build configuration may not.
