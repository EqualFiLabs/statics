# Statics deployment guide

## Scope and authorization

`script/DeployStatics.s.sol:DeployStatics` is the canonical full-stack launcher.
It deploys Statics Dollar Core and the unified user Diamond together. The
lower-level scripts under `script/dollar/` exist for focused tests and local
development; they are not the canonical production entrypoint.

This repository records a public Robinhood Chain testnet integration beta in
`deployment.md` and `deployments/robinhood-testnet-46630-statics.json`; it is
not a production deployment. Running any new broadcast remains a state-changing
external action and requires explicit authorization for the network,
broadcaster, and expected costs.

## Required configuration

Copy `.env.example` and select every production parameter explicitly. The
canonical launcher reads:

| Variable | Meaning |
| --- | --- |
| `PRIVATE_KEY` | Broadcaster key; load locally and never commit it |
| `MULTISIG` | Sole initial timelock proposer |
| `GUARDIAN` | Basket guardian and initial Dollar profile guardian |
| `TREASURY` | Common basket and Statics Dollar protocol treasury |
| `STAKING_TOKEN` | Deployed `StaticsToken` address used as the immutable global staking denominator |
| `BASKET_CREATION_FEE_AMOUNT` | `0` closes public creation and permits owner-only zero-value genesis; a positive value opens exact-fee public creation |
| `POSITION_CREATION_FEE_AMOUNT` | Exact native fee for every new Position NFT; `0` makes creation free and does not disable it; initial target is `1000000000000000` wei (`0.001 ETH`) |
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
| `STATICS_GENESIS_BASKET_CONFIG` | Reviewed JSON manifest for the owner-funded first basket |
| `STATICS_GENESIS_TIMELOCK_SALT` | Unique salt binding the approvals and atomic basket launch |

`RPC_URL` is consumed by the Forge command rather than Solidity. Do not infer
feed addresses, WETH addresses, risk parameters, fee amounts, or metadata from
this repository. Verify chain-specific contracts and make the economic choices
before broadcasting.

## Position NFT compatibility boundary

Fresh deployments install the payable Position surface, initialize
`POSITION_CREATION_FEE_AMOUNT`, and register the Modular Position NFT interface
atomically. Introducing that surface into a legacy deployment changes Position
selectors and requires packed structural state that legacy Positions do not
contain.

Do not apply the fresh-launch Position facets directly to a legacy Diamond.
Structural Position changes require a separately specified selector cut,
storage-compatibility proof, and, where necessary, per-Position migration. This
boundary does not prohibit ordinary in-place facet upgrades that preserve
storage and provide their own selector, interface, and deployment validation.

Position fees are forwarded immediately and entirely to the canonical
treasury. The Diamond does not accrue a native fee balance and there is no
separate treasury claim. Existing Positions in the fresh deployment remain
reusable without paying again.

Deploy `src/tokens/StaticsToken.sol:StaticsToken` before the protocol with
`script/DeployStaticsToken.s.sol:DeployStaticsToken`. Set
`STATICS_TOKEN_RECIPIENT` and `STATICS_TOKEN_INITIAL_SUPPLY`, then use the
resulting address as `STAKING_TOKEN`. This deployment token is for testnet: it
uses the `STATICS` symbol, supports ERC-2612 permit, makes the initial recipient
its OpenZeppelin owner, and lets that owner mint without a configured cap.
Transfer ownership if a different testnet operator should control emissions.
Do not use this uncapped owner-mintable implementation as the finalized
mainnet staking token.

The current Robinhood testnet deployment configuration has no verified
canonical addresses for the two Chainlink AggregatorV3 dependencies required
by the production-path Dollar launcher. Deploy the owner-operated testnet
fixtures before the protocol with
`script/DeployTestnetOracleFixtures.s.sol:DeployTestnetOracleFixtures`. The
script deploys three deliberately separate contracts:

- an eight-decimal ETH/USD aggregator for `ETH_USD_FEED`;
- a zero/up, one/down sequencer aggregator for `SEQUENCER_UPTIME_FEED`; and
- an 18-decimal normalized, sequencer-aware USDG oracle for
  `STATICS_DOLLAR_USDC_ORACLE`.

Set `TESTNET_ORACLE_OWNER`, `TESTNET_ETH_USD_INITIAL_PRICE`,
`TESTNET_SEQUENCER_INITIAL_UPTIME`, `TESTNET_USDG_INITIAL_PRICE_WAD`, and
`TESTNET_USDG_ORACLE_MAX_STALENESS`, and
`TESTNET_USDG_SEQUENCER_GRACE_PERIOD`. The USDG oracle binds the deployed
sequencer fixture and advertises this grace period to Core. The owner must
publish fresh ETH/USD and USDG prices before their configured staleness windows
expire. Repeated sequencer heartbeats preserve the time at which the current
status began; changing between up and down restarts that timestamp and therefore
the configured recovery grace period.

These contracts are centralized public-testnet controls. They exist to exercise
the production oracle adapter and impairment paths when canonical testnet feeds
are unavailable. Never place their addresses in a mainnet deployment
configuration.

Robinhood Chain v4 dependencies are pinned separately for mainnet and testnet:

- `deployments/robinhood-chain-4663.json`
- `deployments/robinhood-chain-testnet-46630.json`

The launcher selects the manifest from `block.chainid` and rejects unsupported
chains. This separation is required because the testnet PositionManager,
Permit2, and Universal Router runtime hashes differ from mainnet even though
their addresses are the same. Production liquidity configuration must use the
selected manifest's PoolManager, PositionManager, Permit2, hook calibration,
and recorded code hashes; Solidity contracts do not embed those addresses.
The SDK's existing generated Robinhood binding remains mainnet-specific.
The testnet manifest also records the independently verified WETH address and
runtime code hash. Set `WETH_ADDRESS` to that manifest value for the Robinhood
testnet rehearsal; the launcher still requires the environment value so a
mainnet deployment cannot silently inherit a testnet token address.

The target network must implement Cancun transient storage (EIP-1153).
`FlashLoanFacet` uses OpenZeppelin's transient reentrancy guard so callbacks can
compose with ordinary persistently guarded basket minting and redemption while
nested flash loans remain blocked. A production preflight must reject a target
that lacks EIP-1153. The pinned Robinhood compatibility suite reads
`ROBINHOOD_MAINNET`.

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

1. Deploy `StaticsTimelock` with a two-minute delay on Robinhood testnet or local
   development and a seven-day delay on Robinhood mainnet, the multisig as
   proposer and canceller, open execution, and no bootstrap admin.
2. Deploy the Chainlink-backed Dollar oracle adapter.
3. Deploy the eleven Dollar Core facets and Core initializer.
4. Predict the Core address, deploy the permit-enabled `StaticsDollar` ERC-20 and
   `StaticsDollarRiskShares` ERC-1155 with that permanent authority, then deploy
   and initialize `StaticsDollarCoreDiamond`.
5. Deploy the twenty-one unified protocol facets and initialize
   `StaticsDiamond`, including the PositionNFT ERC-721, baskets, reservations,
   global rewards, Dollar periphery, typed gateway, canonical liquidity, and
   optional borrow-to-liquidity action. Initialization permanently records the
   configured staking-token address.
6. Finalize Core bootstrap by binding `StaticsDiamond` as Core periphery,
   PositionNFT, fee receiver, owner-approved managed recovery holder, and
   gateway. The Core owner may later add or revoke managed recovery holders.
7. Validate the manifest's PoolManager, PositionManager, and Permit2 code hashes
   and PositionManager immutable bindings.
8. Mine and deploy the bilateral-fee hook at the required `0x10cc`
   permission bitmap through Foundry's deterministic CREATE2 deployer at
   `0x4e59b44847b379578588920cA78FbF26c0B4956C`, then deploy the manager with
   immutable Diamond, PositionManager, PoolManager, and Permit2 bindings.
   `afterInitialize` is registration-only: it prevents third parties from
   pre-initializing a predictable canonical PoolKey, and does not maintain an
   oracle or create a post-launch activation step.

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
forge test --match-path test/deployment/RobinhoodDeploymentConfig.t.sol -vv
forge test --match-path test/deployment/DeployStaticsToken.t.sol -vv
forge test --match-path test/deployment/LaunchGenesisBasket.t.sol -vv
```

The Robinhood testnet dependency proof is read-only and pinned to the block in
the testnet manifest:

```bash
ROBINHOOD_TESTNET_RPC_URL="$ROBINHOOD_TESTNET_RPC_URL" \
  forge test \
  --match-path test/liquidity/fork/RobinhoodTestnetV4DeploymentFork.t.sol \
  -vv
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

For Robinhood testnet, first deploy and verify the owner-mintable staking token:

```bash
forge script script/DeployStaticsToken.s.sol:DeployStaticsToken \
  --rpc-url "$ROBINHOOD_TESTNET_RPC_URL" \
  --chain-id 46630 \
  --broadcast \
  --verify \
  --verifier blockscout \
  --verifier-url "$ROBINHOOD_TESTNET_VERIFIER_URL" \
  -vv
```

Deploy and verify the testnet oracle fixtures:

```bash
forge script \
  script/DeployTestnetOracleFixtures.s.sol:DeployTestnetOracleFixtures \
  --rpc-url "$ROBINHOOD_TESTNET_RPC_URL" \
  --chain-id 46630 \
  --broadcast \
  --verify \
  --verifier blockscout \
  --verifier-url "$ROBINHOOD_TESTNET_VERIFIER_URL" \
  -vv
```

Set `STAKING_TOKEN`, `ETH_USD_FEED`, and `SEQUENCER_UPTIME_FEED` to the
confirmed outputs and retain the USDG oracle address for the later pegged
profile ceremony. Then simulate the full launcher without `--broadcast`. After
explicit authorization for the protocol broadcast, publish its sources in the
same operation:

```bash
forge script script/DeployStatics.s.sol:DeployStatics \
  --rpc-url "$ROBINHOOD_TESTNET_RPC_URL" \
  --chain-id 46630 \
  --broadcast \
  --verify \
  --verifier blockscout \
  --verifier-url "$ROBINHOOD_TESTNET_VERIFIER_URL" \
  --retries 20 \
  --delay 5 \
  -vv
```

Robinhood Explorer uses Blockscout's verification API. An API key is not
required by the current testnet endpoint. A successful Forge broadcast is not
by itself verification evidence: open every created address under
`$ROBINHOOD_TESTNET_EXPLORER_URL`, confirm that it is marked verified, and
preserve the Forge broadcast artifact and explorer links in the release
record. Diamond facets and constructor-only dependencies must each be verified;
verifying only the two Diamond addresses is insufficient.

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
this governance ceremony. After both integrations are installed, every basket
creation must provide one semantic constituent-per-BasketToken square-root
price, one paired-asset budget, and one complete input cap per constituent.
The same transaction creates the BasketToken, initializes and manager-registers
all pools, mints their fully backed BasketTokens, and seeds permanent full-range
liquidity. Every launched pool is immediately swappable and available to typed
liquidity paths.

Per-pool fee configuration changes are separate timelocked governance actions.
Schedule the typed `setCanonicalPoolFeeConfiguration` or
`clearCanonicalPoolFeeConfiguration` call against `StaticsDiamond`, record its
basket, constituent, derived PoolId, effective input/output rates, and fee
split, and do not treat pool age, liquidity, or volume as an
automatic graduation rule.

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
- every canonical pool key, PoolId, and hook fee split.

Also record hook `pendingPermanentLiquidity` and `lockedLiquidity` snapshots
for every canonical pool. Permanent liquidity is hook-owned and has no protocol
PositionManager token ID. Externally held and voluntarily Diamond-custodied v4
NFTs are identified through PositionManager, manager, and liquidity-reward
events.

The chain manifest records the bilateral hook fees, revenue split, and safety
calibration. `BasketLaunched`, pool initialization, manager registration,
and permanent-liquidity events provide the basket-specific
PoolKeys, PoolIds, seed amounts, and aggregate launch supply for release
evidence. A user v4 position remains external until `LiquidityPositionStaked`
attaches it to a PositionNFT; activation, increases, claims, and exit have their
own indexed events.

## Owner-funded genesis basket

When `BASKET_CREATION_FEE_AMOUNT` is zero, public basket creation is closed and
the timelock is the only valid creator. Use
`script/LaunchGenesisBasket.s.sol:LaunchGenesisBasket` after the hook and
liquidity manager installation has executed. The script does not introduce a
new deployed helper or authority. It prepares one typed timelock batch
containing a bounded approval for each constituent followed by the ordinary
`createBasket` call.

Copy `script/config/genesis-basket.example.json`, replace every example address
and economic parameter, and review the resulting file as a deployment
artifact. All token amounts are raw token units. Each
`sqrtPriceAssetPerBasketX96` is the semantic constituent-per-BasketToken launch
price; the protocol converts it to the PoolKey's currency order. The parallel
asset, bundle, pool, and maximum arrays must have the same order and length.
Fee-tier minimum and fee arrays must also have matching lengths.

`launchDeadline` is an absolute Unix timestamp because the schedule and
execution commands must reconstruct identical calldata and therefore the same
timelock operation hash. Set it far enough beyond the current timelock delay to
allow the execution transaction to confirm. Do not edit the manifest between
schedule and execution. `expectedBasketId` binds the script's preflight and
post-execution validation to the reviewed basket slot; it is `0` for a fresh
deployment.

Before scheduling, transfer each configured constituent to the timelock. Its
balance must cover both:

- backing for the aggregate BasketTokens minted across every canonical pool;
- the constituent paired directly with those BasketTokens in its own pool.

`maxAmountsIn` caps the timelock's aggregate debit per constituent; it is not
an estimate supplied by the script. Use reviewed, tightly bounded values. The
batch is atomic: if an approval, backing transfer, pool initialization, manager
registration, or permanent-liquidity seed fails, every approval and the basket
creation revert together.

Set `STATICS_GENESIS_BASKET_CONFIG` to the reviewed manifest and select a fresh
`STATICS_GENESIS_TIMELOCK_SALT`. Simulate both calls against the target RPC
without `--broadcast`, inspect the complete approval and creation calldata,
then schedule and execute with separate authorization:

```bash
forge script script/LaunchGenesisBasket.s.sol:LaunchGenesisBasket \
  --sig 'runSchedule()' --rpc-url "$RPC_URL" --broadcast -vv

forge script script/LaunchGenesisBasket.s.sol:LaunchGenesisBasket \
  --sig 'runExecute()' --rpc-url "$RPC_URL" --broadcast -vv
```

The execution command verifies that exactly the expected basket was created by
the timelock, its token has nonzero supply and backing, every manager key is
registered, and every pool has nonzero hook-owned permanent liquidity. No
post-launch pool activation ceremony is required.

Do not publish an address manifest until every transaction is confirmed and the
post-deployment checks below pass.

## Post-deployment verification

The deployment tests establish the expected fresh-launch architecture:

```text
StaticsDollarCoreDiamond: 11 facets, 95 selectors
StaticsDiamond:           21 facets, 190 selectors
gateway == PositionNFT == StaticsDiamond
Core.periphery == Core.positionNFT == StaticsDiamond
Core owner == Diamond owner == StaticsTimelock
```

Against the deployed addresses, verify:

1. both `owner()` values equal the timelock;
2. `getMinDelay()` equals the authorized current delay (two minutes for the
   Robinhood testnet deployment and seven days for the intended production
   launch), the intended proposer/canceller and executor roles are present, and
   the emergency guardian has no timelock cancellation authority;
3. the Diamond's `guardian()`, `treasury()`, `creationFee()`, `stakingToken()`,
   `totalStaked()`, selected reward-asset books, and treasury accruals match the
   authorized launch configuration;
4. Core `periphery()`, `positionNFT()`, owner, token addresses, WETH profile,
   oracle, sequencer requirement, and debt ceiling match the manifest;
5. Statics Dollar exposes `permit`, `nonces`, and `DOMAIN_SEPARATOR`; its
   EIP-712 domain uses name `Statics Dollar`, version `1`, the deployment chain
   ID, and the deployed token address;
6. both loupe manifests contain the exact facet and selector totals above; any
   offchain runtime hashes recorded for release provenance match deployed code,
   but the Diamonds do not enforce those hashes during dispatch;
7. ERC-165 reports the expected custody, global rewards, Dollar gateway,
   ERC-721, Position metadata, receiver, basket-liquidity, and
   borrow-to-liquidity interfaces;
8. `positionRenderer()` equals the recorded renderer, both the renderer and its
   immutable `avatarSVG()` helper have deployed code, and a minted PositionNFT
   returns decodable Base64 JSON containing a self-contained Base64 SVG;
9. `liquidityIntegration` and `liquidityManager` match the reviewed batch;
   hook and manager immutable getters match the Diamond and Robinhood manifest,
   hook address bits equal `0x10cc`, and its input/output fee and revenue split
   equal the reviewed manifest;
10. every created basket has exactly one initialized canonical pool per
   constituent, and every pool reports a zero native LP fee, tick spacing 10,
   expected hook, recorded PoolId, corresponding manager key hash, and nonzero
   launch liquidity; its hook-owned pending and locked permanent liquidity
   agree with launch and hook events;
10. every pool allocation view matches the reviewed global default or its
    timelocked override, and clearing a rehearsal override restores the current
    global allocation without changing fee rates or existing POL; and
11. verified source publication uses this canonical repository and compiler
   configuration (`solc 0.8.33`, Cancun, optimizer 200, via IR, no bytecode
   metadata hash).

Do not use `forge clean`, `forge build --force`, or
`forge build --contracts` during verification. Run the complete default and
security-profile suites before approving production value.
