# Statics source provenance

## Canonical source boundary

The canonical Statics source is the `EqualFiLabs/statics` repository:

```text
https://github.com/EqualFiLabs/statics
```

Production source, tests, scripts, and build configuration are self-contained
within this repository and its pinned submodules. Normal builds do not depend on
adjacent checkouts, historical deployments, or untracked workspace files.

## Uniswap v4 integration stack

Statics vendors the official Uniswap v4 sources through pinned submodules. The
selected periphery revision contains the compatible `BaseHook` implementation
and uses the core and Permit2 revisions matched by Robinhood Chain's verified
deployments.

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

Robinhood Chain's verified `PoolManager` source matches the pinned `v4-core`
revision. Its verified `PositionManager` executable source matches periphery
revision `3c31961fb909a2b68d90f0094016cfb8edc68b50`; the only
`PositionManager.sol` changes between that revision and the pinned compatible
revision are comments warning about deprecated action constants. The local
fixture therefore exercises the same executable implementation while retaining
the official hook base compatible with the deployed PoolManager.

For this pinned version, liquidity fees are collected through a zero-liquidity
`DECREASE_LIQUIDITY` action followed by `CLOSE_CURRENCY` actions. Hook-returned
swap deltas use v4's packed signed `BeforeSwapDelta` and `BalanceDelta` types and
settle inside the PoolManager unlock callback. The immutable Statics hook uses
the official `PoolManager.take` path during that callback, holds direct currency
balances, returns the matching requested hook delta, and records only its
measured physical receipt as liability. Statics does not also maintain v4
ERC-6909 claims for hook fees.

Robinhood's deployed Universal Router uses the standard `V4_SWAP` command
`0x10`, but its verified single-hop payload appends `minHopPriceX36` after
`amountOutMinimum`. The required fork suite encodes that field and proves the
live Universal Router route instead of treating the router and pinned
PositionManager payloads as identical.

## Verification

After cloning, initialize and verify the complete pinned dependency tree:

```shell
git submodule update --init --recursive
git submodule status --recursive
```

Chain dependency manifests under `deployments/` bind the expected Robinhood
addresses, runtime hashes, and compatibility evidence. The current Statics
testnet deployment is recorded separately in `deployment.md` and
`deployments/robinhood-testnet-46630-statics.json`.
