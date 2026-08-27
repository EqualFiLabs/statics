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

## Standalone Genesis release

`script/DeployStaticsGenesis.s.sol:DeployStaticsGenesis` is the canonical
launcher for the pre-Diamond Genesis release. It calls official Doppler modules
selected by chain ID and reads:

| Variable | Meaning |
| --- | --- |
| `PRIVATE_KEY` | Broadcaster key; load locally and never commit it |
| `STATICS_GENESIS_LAUNCH_ARTIFACT` | Confidential ignored Prepare output; use `artifacts/genesis-launch/production.json` and never publish it before Launch confirms |
| `STATICS_GENESIS_GOVERNANCE` | Pending two-step owner of the receiver, activation registry, vault, collection, and launch distributor, and immutable admin that may rotate the treasury vesting withdrawal recipient |
| `STATICS_GENESIS_TREASURY` | Immutable Doppler-native STATICS vesting beneficiary and initial recipient of vested Genesis, Genesis activation payments, royalties, and recovered bootstrap surplus |
| `WETH_ADDRESS` | Verified WETH paired with STATICS; on Robinhood mainnet it must match the manifest-pinned canonical proxy, implementation, proxy admin, and ownership-controller code |
| `STATICS_DOPPLER_INTEGRATOR` | Optional Doppler integrator; zero uses the Airlock owner |
| `STATICS_DOPPLER_SALT` | Reviewed deterministic token salt; use a cryptographically random 32-byte value and keep the raw salt confidential until the launch transaction reaches the sequencer |
| `STATICS_DOPPLER_FEE` | Static Uniswap v4 LP fee in millionths |
| `STATICS_GENESIS_REWARD_SHARE_BPS` | Receiver revenue share indexed to registered Genesis NFTs |
| `STATICS_GENESIS_RESERVE_SHARE_BPS` | Share (0..10,000) of harvested WETH routed into the permanent Genesis native ETH reserve; the remainder is attributed to the active distributor |
| `STATICS_GENESIS_CREDIT_ORIGINATION_FEE` | Ratified flat native fee required to open Genesis secured credit; no protocol default is assumed |
| `STATICS_GENESIS_CREDIT_EXTENSION_FEE` | Ratified flat native fee quoted when extending Genesis secured credit; no protocol default is assumed |
| `STATICS_GENESIS_RECOVERY_CALLER_SHARE_BPS` | Ratified caller share of the fixed 9,000-STATICS recovery residual; must be greater than 0 and less than 10,000 |
| `STATICS_GENESIS_EPOCH_END` | Reviewed absolute Unix timestamp for immutable `genesisEpochEnd`; it must be future at deployment and is included in the launch hash |
| `STATICS_TOKEN_URI` | Canonical Doppler ERC-20 metadata URI fixed by the launcher |
| `STATICS_GENESIS_CONTRACT_URI` | Optional local-fork override; production uses the launcher's fully onchain ERC-7572 collection JSON data URI |

The phased deployment:

1. **Prepare** deploys only the permanent fee receiver and immutable treasury
   vesting contract, verifies every launch dependency, predicts the deterministic
   STATICS address and PoolId, commits the exact `Airlock.create()` calldata, and
   records the next broadcaster nonce in the confidential artifact.
2. **Launch** submits one zero-value call to the canonical Airlock. That call
   creates exactly 1,000,000,000 STATICS, locks 100,100,000 STATICS inside the
   Doppler token under one zero-cliff 60-day schedule for the configured treasury,
   passes exactly 800,000,000 STATICS to the six-curve Multicurve initializer,
   and sends the exact 99,900,000 remainder to the bootstrap contract. The
   market is live as soon as this one transaction confirms.
3. **Finalize** binds the market to the receiver; mints Genesis IDs 1..5,000 to
   the vault and IDs 5,001..5,555 to treasury vesting; commits exactly
   99,900,000 STATICS as backing for the protocol's 555 Genesis; starts the
   separate 60-day Genesis NFT vest; binds the reserve vault,
   activation registry, and launch distributor; and proposes the configured
   governance address as the two-step owner of all five administered contracts.
   The same governance address is the vesting contract's immutable recipient
   admin. Any additional bootstrap-contract STATICS balance remains recoverable
   surplus and never increases Vault backing.

STATICS vest linearly from the Launch timestamp in Doppler's token contract and
anyone may call `releaseFor(treasury, 0, 0)`; released tokens always go to the
immutable treasury beneficiary. Genesis vest linearly from the Finalize timestamp,
and anyone may call `releaseGenesis(maxCount)`; released NFTs go to the configured
withdrawal recipient. Genesis release is ascending by token ID,
requires a nonzero `maxCount`, and processes at most 50 NFTs per transaction.
Governance may rotate the Genesis/surplus withdrawal recipient but cannot change
either vesting schedule, principal, token range, or release assets early. After
bootstrap, governance may sweep any STATICS accidentally retained by or donated
to the bootstrap contract, always to the current withdrawal recipient. A recipient
contract must implement ERC-721 receipt before Genesis can be released to it.

Vault purchases always require exactly 180,000 STATICS plus the current native
acquisition fee. During the immutable Genesis Epoch the reserve buy-in is waived;
after the epoch, purchases additionally require a native reserve buy-in of
`ceil(reserveETH / 5,554)`.
Redemption returns exactly 180,000 STATICS and, after the epoch, an additional
native reserve payout of `floor(reserveETH / 5,555)`. The buy-in and fee
permanently enter the reserve, which has no withdrawal path. Activation forwards
its exact STATICS cost to the treasury, never burns STATICS, and can never debit
vault backing.

Genesis token metadata and SVG artwork are generated fully onchain by
`StaticsGenesisRenderer`. The separate ERC-7572 `contractURI()` is also fixed
to an onchain JSON data URI for collection-level marketplace metadata. It names
the collection `STATICS Operators`, uses symbol `STATOPS`, links to
`https://staticsprotocol.com`, and describes the 5,555 deterministic Genesis
identities and their protocol rights. Per-token JSON and SVG metadata remain
self-contained onchain with no token-specific website dependency. The canonical
collection metadata is committed by `launchConfigHash`.

Before simulation or broadcast, execute the official-module integration proof:

```bash
ROBINHOOD_MAINNET="$ROBINHOOD_MAINNET" \
REQUIRE_DOPPLER_FORK_PROOF=true \
  forge test \
  --match-path test/genesis/fork/DopplerGenesisLaunchFork.t.sol \
  -vv
```

The executed pinned-Robinhood path validates module code and the predicted
CREATE2 STATICS address before Launch. It calls the official Airlock, checks the
predicted token and PoolId, and executes a real v4 swap while the receiver and
vesting contracts are still unfinalized. Only then does it Finalize and prove
the native treasury vesting schedule and exact allocation, the mandatory 5%
Doppler/Airlock-owner share, the exact 95%
Statics receiver share, Genesis and treasury custody, fee harvest, secured
credit, recovery, vesting, and governance wiring.

The production `runPrepare()` and `runLaunch()` paths are deliberately locked
on Robinhood while `APPROVED_ROBINHOOD_LAUNCH_CONFIG_HASH` is zero. Ratifying
the production curves, static fee, Genesis reward share, reserve parameters,
and credit configuration requires a reviewed follow-up commit that pins their
exact hash. The commitment also binds every Genesis launch contract's creation
code, the Statics Operators metadata, the exact Doppler beneficiary, canonical
Robinhood WETH proxy and authority chain, every Doppler module and runtime code
hash, the token-factory implementation, the predicted STATICS address and
PoolId, and the exact `Airlock.create()` calldata.

Prepare checks and commits this state before its two receiver CREATE
transactions. When Forge executes `runLaunch()`, it rechecks the complete
artifact, dependency state, broadcaster nonce, deterministic addresses,
pristine receiver state, and exact calldata immediately before the typed
zero-value Airlock CALL. The direct-sequencer ceremony uses that entrypoint only
for trusted simulation: the separately signed raw transaction contains the
Airlock call, not the script preflight. Sign immediately after the same-state
simulation. If the nonce, dependency state, prepared contracts, or launch timing
changes before submission, discard the signed transaction and repeat simulation
and signing. Finalize accepts only that already-live token and pool, rechecks
every Airlock asset-data field and allocation, and requires the prepared receiver
and vesting state to remain pristine before broadcasting post-launch wiring.
WETH remains governed upstream after deployment, so later role or upgrade
changes remain an explicit continuing dependency.

Finalize is intentionally retry-hostile. A partial Finalize consumes at least
one broadcaster nonce; rerunning `runFinalize()` then fails before another
transaction. Reconcile every receipt, included nonce, and deployed address, then
review a separate recovery action. Never add address discovery, conditional
skips, or an automatic retry to the production ceremony. The lower-level
`deploy()` function remains available only for unit, fork, and guarded local
Anvil flows. Treasury vesting must hold at least the fixed 200-million-STATICS
protocol allocation; surplus stays outside Vault backing and fixed-principal
vesting accounting.

### Production salt and submission ceremony

The pinned Doppler token factory deploys a deterministic clone keyed by
`STATICS_DOPPLER_SALT`, and `Airlock.create()` is permissionless. A party that
learns the raw salt before the intended creation reaches Robinhood's sequencer
can consume that deterministic token address first with different initialization
data. This is a launch denial of service: it forces a new salt and a newly
reviewed launch hash.

Use this exact boundary:

1. Generate the salt from a cryptographically secure random source. Do not use
   a phrase, timestamp, repository value, or hash of predictable text.
2. Set a restrictive process umask and keep the artifact under the ignored
   directory. Do not publish, back up, paste into logs, or copy the artifact
   before sequencing; it contains the raw salt and complete launch calldata.
3. Run Prepare through the normal public RPC. Its two transactions contain no
   salt and cannot create the market:

   ```bash
   umask 077
   mkdir -p artifacts/genesis-launch
   export STATICS_GENESIS_LAUNCH_ARTIFACT=artifacts/genesis-launch/production.json

   forge script script/DeployStaticsGenesis.s.sol:DeployStaticsGenesis \
     --sig "runPrepare()" \
     --rpc-url "$RPC_URL" \
     --broadcast \
     -vv
   ```

4. Confirm both Prepare receipts, the prepared receiver and vesting addresses,
   and the artifact hash. The artifact's `expectedLaunchNonce` must equal the
   broadcaster's current nonce. Any intervening transaction invalidates the
   ceremony.
5. Simulate the exact committed Launch against a trusted local fork or trusted
   launch RPC. Never send salt-bearing Launch calldata to an untrusted
   simulation provider, and never use `--broadcast` for this production check:

   ```bash
   forge script script/DeployStaticsGenesis.s.sol:DeployStaticsGenesis \
     --sig "runLaunch()" \
     --rpc-url "$TRUSTED_SIMULATION_RPC" \
     -vv
   ```

6. Read `airlock`, `deployer`, `expectedLaunchNonce`, `createCalldata`, and
   `createCalldataHash` locally from the artifact. Select gas and EIP-1559 fee
   values from the trusted simulation and current fee state immediately before
   signing; these envelope fields are intentionally outside the artifact
   commitment. Sign the exact zero-value Airlock call locally:

   ```bash
   AIRLOCK=$(jq -r .airlock "$STATICS_GENESIS_LAUNCH_ARTIFACT")
   DEPLOYER=$(jq -r .deployer "$STATICS_GENESIS_LAUNCH_ARTIFACT")
   EXPECTED_LAUNCH_NONCE=$(jq -r .expectedLaunchNonce "$STATICS_GENESIS_LAUNCH_ARTIFACT")
   CALLDATA=$(jq -r .createCalldata "$STATICS_GENESIS_LAUNCH_ARTIFACT")

   GAS_LIMIT=$(cast estimate "$AIRLOCK" "$CALLDATA" \
     --from "$DEPLOYER" --rpc-url "$TRUSTED_SIMULATION_RPC")
   RAW_TX=$(cast mktx "$AIRLOCK" "$CALLDATA" \
     --chain 4663 --nonce "$EXPECTED_LAUNCH_NONCE" --gas-limit "$GAS_LIMIT" \
     --gas-price "$MAX_FEE_PER_GAS" --priority-gas-price "$MAX_PRIORITY_FEE_PER_GAS" \
     --keystore "$KEYSTORE" --password-file "$PASSWORD_FILE")
   cast decode-transaction "$RAW_TX" --json
   ```

   Before submission, independently compare the decoded chain ID, recovered
   signer, nonce, Airlock target, zero value, and input hash against the
   artifact. Record the decoded signed transaction locally under the same
   restrictive handling; do not paste it into chat or hosted tooling.
7. Submit only the signed Launch transaction directly to Robinhood's sequencer:

   ```bash
   cast rpc --rpc-url https://sequencer.mainnet.chain.robinhood.com \
     eth_sendRawTransaction "$RAW_TX"
   ```

   `cast publish "$RAW_TX" --rpc-url
   https://sequencer.mainnet.chain.robinhood.com` is equivalent, but the literal
   `eth_sendRawTransaction` call above is the canonical ceremony. Confirm the
   returned transaction hash and expected STATICS address through the normal
   public RPC before proceeding.
8. Run Finalize through the normal RPC:

   ```bash
   forge script script/DeployStaticsGenesis.s.sol:DeployStaticsGenesis \
     --sig "runFinalize()" \
     --rpc-url "$RPC_URL" \
     --broadcast \
     -vv
   ```

Airlock creates the live pool in the single Launch transaction; there is no
later graduation or custom Statics initialization. Record the token,
PoolKey/PoolId, all Doppler modules and source revisions, fee receiver, treasury
vesting, activation registry, collection, vault, distributor, metadata
contracts, fee schedule, and six curves in the public deployment manifest.
Only after Launch is confirmed and the final public manifest is recorded may
the confidential artifact be moved to an approved secure archive or deleted.
Before declaring deployment complete, verify vesting admin, recipient, start
and end timestamps, principal custody, and Genesis ID endpoints.

Configured governance must submit one batch containing `acceptOwnership()` to
the fee receiver, activation registry, vault, Genesis collection, and launch
distributor. Verify `owner() == governance` and
`pendingOwner() == address(0)` on all five contracts; until then the broadcaster
remains active owner. The six-curve fixture and fee values are not approved
production economics.

## Full Statics Operators handoff

Full Statics deployment and the standalone Genesis launch remain separate.
Fresh `StaticsDiamond` deployments install `GenesisNFTFacet` but leave its
external bindings uninitialized, so registration and linking stay unavailable.
For an existing pre-feature Diamond, first deploy the replacement facets with
`PrepareStaticsGenesisUpgrade`; set `STATICS_GENESIS_INSTALL_UPGRADE=true` so
the same initialization cut replaces the reward, Position, and custody facets
and adds the Genesis facet without iterating existing Positions.

Deploy the stateless initializer with:

```bash
forge script script/ConfigureStaticsGenesis.s.sol:ConfigureStaticsGenesis \
  --sig "runDeployInitializer()" \
  --rpc-url "$RPC_URL" \
  --broadcast -vv
```

`ConfigureStaticsGenesis` validates the canonical Genesis, vault, activation
registry, fee receiver, treasury, STATICS, WETH, launch distributor, and reward
share before preparing any handoff. If all administered Genesis contracts are
owned by the Statics timelock, `runSchedule()` and `runExecute()` perform one
ordered batch. If Genesis governance remains a separate Safe or controller,
use `runScheduleInitialization()` and `runExecuteInitialization()` for the
Diamond-owned cut. The remaining six typed calls must alternate between the
two authorities in this order:

1. Genesis governance executes `buildGenesisDistributorProposal()`;
2. Statics governance executes `buildStaticsDistributorAcceptance()`;
3. Genesis governance executes `buildGenesisConsumerProposal()` to finalize
   launch rewards and propose the Diamond as activation consumer;
4. Statics governance executes `buildStaticsConsumerAcceptance()`; and
5. Genesis governance executes `buildGenesisProtocolBinding()`.

The Diamond role-acceptance wrappers are owner-only. Consumer acceptance also
requires the Diamond to already be the active fee distributor and any existing
launch consumer to be finalized, so neither an arbitrary caller nor an
out-of-order Safe batch can advance the handoff.

The ordered transition initializes the Diamond, proposes and accepts it as fee
distributor, migrates any pending recovery value, finalizes the launch
distributor, proposes and accepts the Diamond as activation consumer, and binds
`StaticsGenesis.protocol()`. Historical launch claims remain in the finalized
launch distributor. New full-protocol registration and Position linkage are
enabled only when `genesisIntegrationReady()` is true.

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
| `POOL_CREATION_FEE_AMOUNT` | Independent exact native fee for each permissionless general pool; `0` disables permissionless creation (owner-only, and not free public creation), while a positive value requires exact payment from every caller and is forwarded to treasury |
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
| `STATICS_GENESIS_INTEGRATION_INIT_ADDRESS` | Deployed one-time Diamond initializer used by the Genesis handoff |
| `STATICS_GENESIS_HANDOFF_TIMELOCK_SALT` | Unique salt binding the Genesis integration initialization or unified handoff |
| `STATICS_GENESIS_FEE_RECEIVER_ADDRESS` | Permanent standalone fee receiver being handed to the Diamond distributor |
| `STATICS_GENESIS_ACTIVATION_REGISTRY_ADDRESS` | Permanent activation registry whose consumer rotates to the Diamond |
| `STATICS_GENESIS_NFT_ADDRESS` | Canonical Genesis collection bound to the Diamond |
| `STATICS_GENESIS_VAULT_ADDRESS` | Canonical secured-credit and recovery vault |
| `STATICS_GENESIS_DISTRIBUTOR_ADDRESS` | Temporary launch distributor finalized by the handoff |
| `STATICS_GENESIS_INSTALL_UPGRADE` | `true` only for an existing Diamond that needs the prepared replacement facets; fresh deployments use `false` |
| `STATICS_GLOBAL_REWARDS_FACET_ADDRESS` | Prepared replacement facet for an existing-Diamond handoff |
| `STATICS_POSITION_NFT_FACET_ADDRESS` | Prepared replacement facet for an existing-Diamond handoff |
| `STATICS_CUSTODY_FACET_ADDRESS` | Prepared replacement facet for an existing-Diamond handoff |
| `STATICS_GENESIS_NFT_FACET_ADDRESS` | Prepared Genesis facet for an existing-Diamond handoff |

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

Use the `DopplerERC20V1` token created by the standalone Genesis release as
`STAKING_TOKEN`. The repository intentionally has no parallel production
STATICS token implementation or token-only launcher.

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
Both manifests record independently verified WETH addresses and runtime code
hashes. Set `WETH_ADDRESS` to the selected manifest value. The standalone
Genesis launcher actively enforces the Robinhood mainnet WETH address and
runtime hash because WETH unwrapping funds its permanent reserve; the full-stack
launcher still requires the environment value so a mainnet deployment cannot
silently inherit a testnet token address.

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
5. Deploy the twenty-four unified protocol facets and initialize
   `StaticsDiamond`, including the PositionNFT ERC-721, baskets, reservations,
   global rewards, Dollar periphery, typed gateway, canonical liquidity, and
   optional borrow-to-liquidity action. Initialization permanently records the
   configured staking-token address.
6. Finalize Core bootstrap by binding `StaticsDiamond` as Core periphery,
   PositionNFT, fee receiver, owner-approved managed recovery holder, and
   gateway. The Core owner may later add or revoke managed recovery holders.
7. Validate the manifest's PoolManager, PositionManager, and Permit2 code hashes
   and PositionManager immutable bindings.
8. Mine and deploy the bilateral-fee hook at the required `0x10ec`
   permission bitmap through Foundry's deterministic CREATE2 deployer at
   `0x4e59b44847b379578588920cA78FbF26c0B4956C`, then deploy the manager with
   immutable Diamond, PositionManager, PoolManager, and Permit2 bindings.
   `afterInitialize` is registration-only: it prevents third parties from
   pre-initializing a predictable canonical PoolKey, and does not maintain an
   oracle or create a post-launch activation step. `beforeDonate` rejects all
   native PoolManager donations to registered Statics pools.

The `beforeDonate` permission changes the hook address and every PoolKey. The
existing public testnet remains a historical deployment with its original
hook; do not treat these calibration changes as an in-place upgrade. Rehearse a
second fresh testnet deployment with the `0x10ec` hook before mainnet.

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
forge test --match-path test/deployment/DeployStaticsGenesis.t.sol -vv
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
StaticsDiamond:           30 facets, 254 selectors
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
   ERC-721 metadata, receiver, basket-liquidity, and
   borrow-to-liquidity interfaces;
8. a minted PositionNFT returns decodable Base64 JSON with the stable Statics
   logo and Position ID SVG, without mutable renderer configuration;
9. `liquidityIntegration` and `liquidityManager` match the reviewed batch;
   hook and manager immutable getters match the Diamond and Robinhood manifest,
   hook address bits equal `0x10ec`, and its input/output fee and revenue split
   equal the reviewed manifest;
10. every created basket has exactly one initialized canonical pool per
   constituent, and every pool reports a zero native LP fee, tick spacing 10,
   expected hook, recorded PoolId, corresponding manager key hash, and nonzero
   launch liquidity; its hook-owned pending and locked permanent liquidity
   agree with launch and hook events;
11. every pool allocation view matches the reviewed global default or its
    timelocked override, and clearing a rehearsal override restores the current
    global allocation without changing fee rates or existing POL; and
12. verified source publication uses this canonical repository and compiler
   configuration (`solc 0.8.33`, Cancun, optimizer 200, via IR, no bytecode
   metadata hash).

Do not use `forge clean`, `forge build --force`, or
`forge build --contracts` during verification. Run the complete default and
security-profile suites before approving production value.
