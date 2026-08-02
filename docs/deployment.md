# Statics deployment guide

## Scope and authorization

`script/DeployStatics.s.sol:DeployStatics` is the canonical full-stack launcher.
It deploys Statics Dollar Core and the unified user Diamond together. The
lower-level scripts under `script/dollar/` exist for focused tests and local
development; they are not the canonical production entrypoint.

This repository records no public Statics deployment. Running a broadcast is a
state-changing external action and requires explicit authorization for the
network, broadcaster, and expected costs.

## Required configuration

Copy `.env.example` and select every production parameter explicitly. The
canonical launcher reads:

| Variable | Meaning |
| --- | --- |
| `PRIVATE_KEY` | Broadcaster key; load locally and never commit it |
| `MULTISIG` | Sole initial timelock proposer |
| `GUARDIAN` | Basket guardian and initial Dollar profile guardian |
| `TREASURY` | Common basket and Statics Dollar protocol treasury |
| `BASKET_CREATION_FEE_AMOUNT` | Exact native amount required for basket creation |
| `WETH_ADDRESS` | Verified canonical WETH for the target chain |
| `ETH_USD_FEED` | Verified Chainlink-compatible ETH/USD feed |
| `SEQUENCER_UPTIME_FEED` | Verified target-chain sequencer uptime feed |
| `STATICS_DOLLAR_ORACLE_MAX_STALENESS` | Maximum accepted ETH/USD observation age |
| `STATICS_DOLLAR_ORACLE_MIN_PRICE_WAD` | Lower accepted oracle answer bound |
| `STATICS_DOLLAR_ORACLE_MAX_PRICE_WAD` | Upper accepted oracle answer bound |
| `SEQUENCER_GRACE_PERIOD` | Required recovery time after sequencer restoration |
| `STATICS_DOLLAR_COLLATERAL_RATIO_BPS` | Initial series collateral ratio; greater than 10,000 and at most 30,000 |
| `STATICS_DOLLAR_PRICE_BAND_BPS` | Initial transition band; greater than 10,000, at most 30,000, and no greater than the collateral ratio |
| `STATICS_DOLLAR_DEBT_CEILING` | Initial WETH-profile Statics Dollar ceiling |
| `STATICS_DOLLAR_RISK_URI` | ERC-1155 metadata URI for Dollar risk series |
| `STATICS_DIAMOND_ADDRESS` | Deployed Diamond for the liquidity installation ceremony |
| `STATICS_SWAP_FEE_HOOK_ADDRESS` | Hook emitted by the launcher |
| `STATICS_LIQUIDITY_MANAGER_ADDRESS` | Manager emitted by the launcher |
| `STATICS_LIQUIDITY_TIMELOCK_SALT` | Unique salt binding the installation batch |

`RPC_URL` is consumed by the Forge command rather than Solidity. Do not infer
feed addresses, WETH addresses, risk parameters, fee amounts, or metadata from
this repository. Verify chain-specific contracts and make the economic choices
before broadcasting.

Robinhood Chain v4 dependencies are pinned in
`deployments/robinhood-chain-4663.json`. The SDK generates its address binding
from that file. Production liquidity configuration must use the same
PoolManager, PositionManager, Permit2, hook calibration, and recorded code
hashes; Solidity contracts do not embed chain-specific addresses.

The production validator rejects zero governance addresses, missing risk or
oracle parameters, non-contract dependencies, an invalid oracle range, and the
repository's marked local WETH fixture.

Pegged profiles are optional post-launch governance actions. The
`ConfigurePeggedProfile` ceremony reads the collateral token and oracle,
`STATICS_DOLLAR_USDC_PEG_MIN_PRICE_WAD`,
`STATICS_DOLLAR_USDC_PEG_MAX_PRICE_WAD`, independent
`STATICS_DOLLAR_USDC_MINT_FEE_BPS` and
`STATICS_DOLLAR_USDC_REDEMPTION_FEE_BPS`, and the profile debt ceiling. Its
single timelock batch creates and activates a direct wrapper without allocating
a series ID or Risk Shares.

## Deployment order

The launcher performs one creation broadcast in this order:

1. Deploy `StaticsTimelock` with an initial seven-day delay, the multisig as
   proposer and canceller, open execution, and no bootstrap admin.
2. Deploy the Chainlink-backed Dollar oracle adapter.
3. Deploy the eleven Dollar Core facets and Core initializer.
4. Predict the Core address, deploy the permit-enabled `StaticsDollar` ERC-20 and
   `StaticsDollarRiskShares` ERC-1155 with that permanent authority, then deploy
   and initialize `StaticsDollarCoreDiamond`.
5. Deploy the twenty unified protocol facets and initialize
   `StaticsDiamond`, including the PositionNFT ERC-721, baskets, reservations,
   Dollar periphery, typed gateway, canonical liquidity, and optional
   borrow-to-liquidity action.
6. Finalize Core bootstrap by binding `StaticsDiamond` as Core periphery,
   PositionNFT, fee receiver, managed recovery holder, and gateway.
7. Validate the manifest's PoolManager, PositionManager, and Permit2 code hashes
   and PositionManager immutable bindings.
8. Mine and deploy the immutable one-basis-point hook at the required `0x1044`
   permission bitmap through Foundry's deterministic CREATE2 deployer at
   `0x4e59b44847b379578588920cA78FbF26c0B4956C`, then deploy the manager with
   immutable Diamond, PositionManager, PoolManager, and Permit2 bindings.

Both Diamonds are owned by the same timelock from genesis. No later ownership
handoff or separate PositionNFT/router deployment is required. Because the
Diamond already belongs to the timelock, the launcher does not install the
hook or manager by pretending to be a temporary owner. Installation is a
separate two-call timelock batch.

The CREATE2 deployer is a deployment-time utility, not a Statics runtime
dependency or authority. A production preflight must confirm that this address
has the expected deterministic-deployer runtime code on the target chain. The
launcher mines the hook address against this deployer because Foundry routes
salted creation broadcasts through it; mining against the broadcaster EOA
would predict a different address and make deployment fail.

## Rehearsal and broadcast

Run the focused deployment proof before any rehearsal:

```bash
forge test --match-path test/deployment/DeployStatics.t.sol -vv
```

For a local full-stack rehearsal, call `DeployStatics.deployWithLiquidity` with
explicit `Config` and locally deployed real v4 contracts. It supplies
repository WETH and oracle fixtures, deploys the immutable hook and manager,
then exercises the same timelock installation ceremony. It must never be
treated as a production artifact. `DeployStatics.deploy` remains a narrower
Dollar/Diamond fixture for tests that do not need v4.

After explicit production authorization, simulate against the target RPC
without `--broadcast`, inspect the trace and gas, then run:

```bash
forge script script/DeployStatics.s.sol:DeployStatics \
  --rpc-url "$RPC_URL" \
  --broadcast \
  -vv
```

After the creation transactions confirm, compare every emitted address and
runtime hash to the manifest, populate the four liquidity ceremony variables,
and inspect the exact payloads returned by
`ConfigureStaticsLiquidity.buildBatch`. With separate authorization for the
governance transactions, schedule and later execute the installation:

```bash
forge script script/ConfigureStaticsLiquidity.s.sol:ConfigureStaticsLiquidity \
  --sig 'runSchedule()' --rpc-url "$RPC_URL" --broadcast -vv

forge script script/ConfigureStaticsLiquidity.s.sol:ConfigureStaticsLiquidity \
  --sig 'runExecute()' --rpc-url "$RPC_URL" --broadcast -vv
```

The schedule and execution use the current timelock delay. They fail if code,
immutable bindings, hook fee, permission bits, ownership, or already-installed
state differs from the reviewed batch. No canonical pool is initialized by
this governance ceremony: each permissionless basket creates its constituent
pools later through the typed Diamond lifecycle.

Preserve Foundry's `broadcast/DeployStatics.s.sol/<chain-id>/run-latest.json`
and transaction receipts as the deployment record. Record at minimum:

- `StaticsTimelock`;
- `StaticsDiamond` (also PositionNFT and Dollar gateway);
- `StaticsDollarCoreDiamond`;
- `StaticsDollar`;
- `StaticsDollarRiskShares`;
- WETH and oracle; and
- every installed facet address and, if desired for offchain verification, its
  observed runtime codehash;
- the immutable `StaticsSwapFeeHook` and `StaticsLiquidityManager`, including
  their Diamond, PoolManager, PositionManager, and Permit2 bindings; and
- every canonical pool key, PoolId, lifecycle parameter, and protocol
  PositionManager token ID.

The chain manifest records the fixed fee and safety calibration. Pool
initialization, activation, manager sync, POL funding, and protocol position
events provide the basket-specific PoolKeys, PoolIds, and token IDs for the
release manifest. User v4 token IDs come from ordinary PositionManager
`Transfer` events and must not be listed as protocol positions.

Do not publish an address manifest until every transaction is confirmed and the
post-deployment checks below pass.

## Post-deployment verification

The deployment tests establish the expected architecture:

```text
StaticsDollarCoreDiamond: 11 facets, 95 selectors
StaticsDiamond:           20 facets, 170 selectors
gateway == PositionNFT == StaticsDiamond
Core.periphery == Core.positionNFT == StaticsDiamond
Core owner == Diamond owner == StaticsTimelock
```

Against the deployed addresses, verify:

1. both `owner()` values equal the timelock;
2. `getMinDelay()` equals the authorized current delay (seven days at genesis),
   the intended proposer/canceller and executor roles are present, and the
   emergency guardian has no timelock cancellation authority;
3. the Diamond's `guardian()`, `treasury()`, `creationFee()`, and holder split
   match the authorized launch configuration;
4. Core `periphery()`, `positionNFT()`, owner, token addresses, WETH profile,
   oracle, sequencer requirement, and debt ceiling match the manifest;
5. Statics Dollar exposes `permit`, `nonces`, and `DOMAIN_SEPARATOR`; its
   EIP-712 domain uses name `Statics Dollar`, version `1`, the deployment chain
   ID, and the deployed token address;
6. both loupe manifests contain the exact facet and selector totals above; any
   offchain runtime hashes recorded for release provenance match deployed code,
   but the Diamonds do not enforce those hashes during dispatch;
7. ERC-165 reports the expected custody, basket reward, Dollar gateway,
   ERC-721, receiver, basket-liquidity, and borrow-to-liquidity interfaces;
8. `liquidityIntegration` and `liquidityManager` match the reviewed batch;
   hook and manager immutable getters match the Diamond and Robinhood manifest,
   hook address bits equal `0x1044`, and the hook fee equals one basis point;
9. every initialized canonical pool reports the fixed 500-pip fee, tick spacing
   10, expected hook, recorded PoolId, and corresponding manager key hash; and
10. verified source publication uses this canonical repository and compiler
   configuration (`solc 0.8.33`, Cancun, optimizer 200, via IR, no bytecode
   metadata hash).

Do not use `forge clean`, `forge build --force`, or
`forge build --contracts` during verification. Run the complete default and
security-profile suites before approving production value.
