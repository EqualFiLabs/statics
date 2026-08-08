# Statics

Onchain multi-asset protocol targeting Robinhood Chain, implemented as two coordinated EIP-2535 Diamonds. Statics combines fixed-bundle basket tokens, a senior/junior Statics Dollar system, a shared PositionNFT, global multi-asset rewards, proportional self-backed lending, constituent flash loans, and canonical Uniswap v4 liquidity with bilateral hook fees and permanent protocol-owned liquidity.

For a plain-language introduction, see the [value proposition](./docs/value-proposition.md)
and [worked examples](./docs/examples.md). The repository also publishes an
[LLM-oriented protocol index](./llms.txt). For protocol invariants, accounting,
and lifecycle details, see [`Statics-Design.md`](./Statics-Design.md), the
[architecture guide](./docs/architecture.md), and the
[integration guide](./docs/integration.md). See the
[deployment guide](./docs/deployment.md) for procedures, the
[current deployment record](./deployment.md) for a human-readable summary, and
the [Robinhood testnet manifest](./deployments/robinhood-testnet-46630-statics.json)
for the canonical machine-readable integration-beta state.

---

## Table of Contents

- [Highlights](#highlights)
- [Architecture at a Glance](#architecture-at-a-glance)
- [Repository Layout](#repository-layout)
- [Prerequisites](#prerequisites)
- [Setup](#setup)
- [Build](#build)
- [Test](#test)
- [Deploy](#deploy)
- [Core Concepts](#core-concepts)
- [Common Flows](#common-flows)
- [Configuration Reference](#configuration-reference)
- [Conventions & Contributing](#conventions--contributing)
- [License](#license)

---

## Highlights

| Capability | Summary |
|---|---|
| **Unified integration address** | `StaticsDiamond` is the ordinary user action surface, PositionNFT ERC-721, and custody address for basket and Dollar periphery assets. |
| **Static baskets** | Each permit-enabled `StaticsBasketToken` represents a creator-defined vector of up to 16 assets with fixed bundle amounts and action-size fee tiers. |
| **Statics Dollar** | `StaticsDollarCoreDiamond` manages volatile and pegged collateral profiles, senior issuance, Risk Shares, solvency, transitions, insurance, and recovery. |
| **Shared PositionNFT** | One transferable ERC-721 position can own Dollar legs, basket collateral, loans, selected global rewards, and staked canonical-liquidity positions. |
| **Global rewards** | Positions stake the configured Statics token and select up to 64 reward assets; new selections cannot capture historical fees. |
| **Self-backed lending** | Basket collateral releases its proportional constituent vector at a basket-defined LTV, with independent loan tranches, extension, repayment, and permissionless expiry recovery. |
| **Flash composition** | Basket constituents can be borrowed atomically through a typed callback while nested flash loans remain blocked. |
| **Canonical v4 liquidity** | Protocol-created BasketToken/constituent pools use zero native LP fee and a Statics hook that charges bilateral input/output fees. |
| **Permanent liquidity** | The hook converts matched POL allocations into hook-owned full-range liquidity with no ordinary withdrawal path. |
| **Governed lifecycle** | A shared timelock owns both Diamonds; guardians can restrict exposure while repayment, recovery, and exit paths remain available. |

---

## Architecture at a Glance

```text
                    ┌────────────────────────────────────┐
   ETH / WETH ─────▶│ StaticsDollarCoreDiamond           │
 pegged collateral ▶│ collateral + issuance + solvency   │
                    │ insurance + transition + recovery  │
                    └───────────────┬────────────────────┘
                                    │
                         Statics Dollar + Risk Shares
                                    │
                                    ▼
┌────────────────────────────────────────────────────────────────────┐
│ StaticsDiamond (EIP-2535)                                         │
│ user gateway + PositionNFT ERC-721 + shared custody               │
│                                                                    │
│  ├─ Basket creation / mint / redemption / lifecycle               │
│  ├─ Basket collateral / lending / repayment / recovery            │
│  ├─ Global Statics staking + selected multi-asset rewards          │
│  ├─ Dollar gateway + pairing-risk liquidity                        │
│  ├─ Constituent flash loans                                        │
│  └─ Canonical-pool configuration + liquidity-position rewards      │
└──────────────────────────────┬─────────────────────────────────────┘
                               │
                  one pool per basket constituent
                               │
                               ▼
                 Uniswap v4 PoolManager + PositionManager
                               │
                 StaticsSwapFeeHook + LiquidityManager
                 bilateral fees + permanent full-range POL
```

`StaticsDiamond` is the normal integration address, but the Dollar Core remains a separate custody and solvency boundary. Both Diamonds are owned by the same `StaticsTimelock`. Each basket has its own transferable ERC-20 token; module accounting and physical-token reservations remain isolated inside the Diamond.

---

## Repository Layout

```text
statics/
├── src/
│   ├── diamond/                     # Statics Diamond kernel and initialization
│   ├── facets/                      # Basket, rewards, lending, flash, and liquidity facets
│   ├── position/                    # Shared PositionNFT storage and ERC-721 facet
│   ├── dollar/
│   │   ├── core/                    # Dollar Core facets, accounting, solvency, recovery
│   │   ├── periphery/               # Shared-Diamond Dollar gateway and staking facets
│   │   ├── interfaces/              # Dollar integration interfaces and types
│   │   └── testnet/                 # Explicit public-testnet oracle fixtures
│   ├── liquidity/                   # v4 hook, liquidity manager, and pool accounting
│   ├── periphery/                   # Typed flash-arbitrage receiver
│   ├── governance/                  # Statics timelock
│   ├── tokens/                      # Basket and Statics staking tokens
│   ├── testnet/                     # Public-testnet faucet
│   ├── interfaces/                  # User and integration interfaces
│   └── libraries/                   # Shared storage, custody, fee, and math libraries
├── script/                          # Deployment, upgrade, governance, and launch scripts
├── scripts/                         # Operational and focused security helpers
├── test/
│   ├── basket/                      # Basket lifecycle and custody flows
│   ├── dollar/                      # Unit, integration, property, and fork coverage
│   ├── liquidity/                   # v4, flash, POL, lending, and fork coverage
│   ├── rewards/                     # Global and basket reward behavior
│   ├── invariant/                   # Cross-module stateful invariants
│   └── deployment/                  # Launcher, manifest, and ceremony proofs
├── sdk/                             # TypeScript ABIs, decoders, builders, and chain bindings
├── deployments/                     # Pinned dependency and public testnet manifests
├── docs/                            # Architecture, integration, deployment, and ADRs
├── Statics-Design.md                # Full protocol design document
├── SECURITY.md                      # Authority, custody, and liveness assumptions
├── foundry.toml                     # Compiler, optimizer, fuzz, and invariant profiles
└── remappings.txt
```

---

## Prerequisites

- [Foundry](https://book.getfoundry.rs/getting-started/installation) (`forge`, `cast`, `anvil`)
- Node.js and npm for the TypeScript SDK
- Solidity `0.8.33` for Statics production sources
- Cancun-compatible EVM support; the v4 `PositionManager` dependency uses its pinned Solidity `0.8.26` compiler profile

---

## Setup

OpenZeppelin, Forge Standard Library, Uniswap v4, and the TypeScript SDK are pinned git submodules. Initialize the complete dependency tree after cloning:

```shell
git submodule update --init --recursive
npm ci --prefix sdk
```

The principal remappings are:

```text
@openzeppelin/contracts/=lib/openzeppelin-contracts/contracts/
@openzeppelin/contracts-upgradeable/=lib/openzeppelin-contracts-upgradeable/contracts/
@uniswap/v4-core/=lib/v4-periphery/lib/v4-core/
@uniswap/v4-periphery/=lib/v4-periphery/
forge-std/=lib/forge-std/src/
permit2/=lib/v4-periphery/lib/permit2/
```

Copy `.env.example` into an ignored environment file and populate only the values required for the intended local, fork, or deployment operation. Never commit broadcaster keys, mnemonics, RPC credentials, or populated environment files.

---

## Build

```shell
forge build
npm run build --prefix sdk
```

> Statics and its v4 dependencies are large. Do **not** run `forge build --force`, `forge build --contracts`, or `forge clean` during normal iteration. Prefer incremental compilation through path-scoped tests.

---

## Test

Run focused paths while iterating:

```shell
# Basket lifecycle and measured custody
forge test --match-path test/basket/BasketLifecycle.t.sol -vv

# Statics Dollar gateway behavior
forge test --match-path test/dollar/unit/StaticsDollarGateway.t.sol -vv

# Canonical hook fee accounting
forge test --match-path test/liquidity/StaticsSwapFeeHook.t.sol -vv

# Shared PositionNFT behavior
forge test --match-path test/position/PositionNFT.t.sol -vv

# SDK surface
npm test --prefix sdk
```

Test organization:

- `test/basket/`, `test/rewards/`, `test/position/` — focused module and real-flow coverage.
- `test/dollar/unit/` and `test/dollar/integration/` — Core/periphery state machines and launch-level flows.
- `test/liquidity/` — canonical pools, hook accounting, POL, lending composition, and flash behavior.
- `test/invariant/` and `test/dollar/properties/` — stateful invariants and fuzz properties.
- `test/deployment/` — complete launcher, selector, manifest, timelock, and genesis-ceremony proofs.
- `test/**/fork/` — environment-gated checks against pinned external chain state.

The default profile uses 1,000 fuzz runs and 256 invariant runs at depth 50. The `security` profile enables fail-on-revert invariants with 128 runs at depth 64.

### Fork evidence

Robinhood mainnet fork tests read `ROBINHOOD_MAINNET`. A missing RPC causes environment-gated tests to skip unless the matching `REQUIRE_*` flag is enabled.

Run the focused deployed-router proof with:

```shell
ROBINHOOD_MAINNET="$ROBINHOOD_MAINNET" \
  forge test \
  --match-path test/liquidity/fork/RobinhoodStaticsLiquidityFork.t.sol \
  -vv
```

This path exercises Robinhood's deployed Quoter, Universal Router, Permit2, and hooked canonical pools. Treat an executed pass separately from local-only coverage or an environment-gated skip.

### Testing guidance

- Use unit harnesses for narrow branches, storage checks, and otherwise-unreachable edges.
- Use real approvals, transfers, mints, redemptions, borrows, repayments, extensions, recoveries, flash loans, and governance calls for value-moving lifecycles.
- Use fuzz and invariant suites to broaden coverage, not replace real-flow proof.
- Keep synthetic state shortcuts narrow and document why the corresponding state is impractical to reach economically.
- Every code change must include behavior-focused regression coverage.

---

## Deploy

The canonical full-stack entry point is `script/DeployStatics.s.sol:DeployStatics`. It deploys `StaticsTimelock`, the Dollar Core, Dollar tokens, the unified `StaticsDiamond`, and the immutable canonical-liquidity hook and manager. Hook and manager installation is a separate timelocked ceremony.

The launcher validates governance addresses, Dollar risk parameters, oracle bounds, sequencer requirements, WETH, chain-specific v4 dependencies, runtime code hashes, hook permissions, and immutable bindings. Its fresh-deployment architecture is:

```text
StaticsDollarCoreDiamond: 11 facets, 95 selectors
StaticsDiamond:           23 facets, 209 selectors
Core.periphery == Core.positionNFT == StaticsDiamond
Core owner == Diamond owner == StaticsTimelock
```

### Local Anvil

`DeployLocalStaticsWithLiquidity` deploys local WETH and oracle fixtures, a pegged development profile, real local v4 dependencies, the Statics hook, and the liquidity manager:

```shell
anvil  # separate terminal

PRIVATE_KEY="$ANVIL_PRIVATE_KEY" forge script \
  script/dollar/DeployLocalStaticsWithLiquidity.s.sol:DeployLocalStaticsWithLiquidity \
  --sig 'runLocalWithLiquidity()' \
  --rpc-url http://127.0.0.1:8545 \
  --broadcast \
  -vv
```

Use an ephemeral Anvil key only. Local fixtures and addresses are not production deployment evidence.

### Robinhood Chain testnet

Robinhood testnet is chain `46630`. The repository records the current
integration beta in [`deployment.md`](./deployment.md), with canonical
machine-readable state in
[`deployments/robinhood-testnet-46630-statics.json`](./deployments/robinhood-testnet-46630-statics.json).

The release sequence is intentionally explicit:

1. Deploy and verify the owner-mintable testnet Statics staking token.
2. Deploy and verify the testnet ETH/USD, sequencer-uptime, and USDG oracle fixtures.
3. Set the confirmed staking-token and oracle addresses in the ignored release environment.
4. Simulate, inspect, then broadcast and verify the canonical Statics launcher.
5. Schedule and execute the timelocked canonical-liquidity installation.
6. Configure the pegged Mock USDG profile.
7. Schedule and execute the owner-funded genesis basket launch.
8. Verify both Diamond manifests, ownership, selector routing, immutable bindings, pool state, fee configuration, and deployment runtime hashes.

Focused deployment proofs:

```shell
forge test --match-path test/deployment/DeployStatics.t.sol -vv
forge test --match-path test/deployment/RobinhoodDeploymentConfig.t.sol -vv
forge test --match-path test/deployment/DeployStaticsToken.t.sol -vv
forge test --match-path test/deployment/LaunchGenesisBasket.t.sol -vv
```

The pinned read-only testnet dependency check is:

```shell
ROBINHOOD_TESTNET_RPC_URL="$ROBINHOOD_TESTNET_RPC_URL" \
  forge test \
  --match-path test/liquidity/fork/RobinhoodTestnetV4DeploymentFork.t.sol \
  -vv
```

After explicit authorization, the protocol deployment command is:

```shell
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

Do not treat a successful broadcast as complete release evidence. Verify every standalone contract and facet, preserve transaction receipts outside version control, and update the reviewed deployment manifest. See [`docs/deployment.md`](./docs/deployment.md) for the complete configuration, governance ceremonies, genesis basket, and post-deployment checklist.

---

## Core Concepts

### Static baskets

A BasketToken represents a fixed constituent vector. Minting deposits the configured bundle plus the selected flat fee; redemption burns BasketTokens and returns the same vector less the selected fee. Statics is deliberately not ERC-4626: historical fees do not change a basket conversion rate, and new minters do not purchase accrued yield.

Basket creators choose the immutable assets, bundle amounts, action-size fee tiers, flash fee, lending fees, LTV, recovery penalty, and loan duration. Assets remain permissionless and are not endorsed by inclusion.

### Shared PositionNFT

`StaticsDiamond` is the ERC-721 PositionNFT contract. A position owns all attached basket collateral, Dollar series legs, reward selections, loans, and custodied canonical-liquidity positions. ERC-721 transfer moves authority over the complete economic position. A position cannot close while any module leg remains active.

New PositionNFT creation charges the exact configured native fee; existing positions can be reused without paying again. Module entry points attach the first leg atomically so receiver callbacks cannot leave an empty initializing position.

Every valid PositionNFT has deterministic, fully onchain Base64 JSON and SVG metadata. The visual seed is the stable `(chain ID, StaticsDiamond, position ID)` identity, so transfers and position activity do not change the avatar. The Diamond owner may replace or clear the collection-wide renderer; the renderer contains no balances, achievements, risk claims, or other live protocol state.

### Global rewards

Users stake the configured Statics ERC-20 in a PositionNFT and opt into selected reward assets. Each asset indexes rewards only across positions that selected it. Eligibility begins after the configured delay, so a new selection cannot capture historical fees. Unsupported or temporarily ineligible fee shares fall through to the governed accounting destination rather than remaining unbooked.

Canonical LP rewards are separate: users may stake eligible full-range PositionManager NFTs for active Statics pools, accrue next-block liquidity weight, claim rewards, and unstake the NFT without a cooldown.

### Lending and recovery

Basket lending locks deposited BasketTokens and releases the proportional constituent vector at the basket's configured LTV, capped by the immutable 95% protocol ceiling. Independent tranches preserve separate maturities. Repayment restores the exact stored principal; extension charges each outstanding constituent; permissionless recovery becomes available only after maturity and grace.

### Canonical liquidity and bilateral fees

Each basket has one canonical BasketToken/constituent Uniswap v4 pool per asset. The pool uses zero native LP fee. `StaticsSwapFeeHook` charges configured fees on both input and output, then allocates them across permanent POL, eligible canonical LP positions, deposited BasketTokens, global Statics stakers, and treasury.

Matched POL inventory is converted into hook-owned full-range liquidity. It has no normal withdrawal path and can unwind only after the basket enters `ExitOnly` and its canonical pool is decommissioned. Timelocked per-pool overrides may replace or clear the complete global fee configuration.

### Statics Dollar profiles

Volatile profiles accept collateral such as WETH and mint equal senior Statics Dollar plus series-scoped Risk Shares. The Core governs price bands, coverage, insurance, transitions, recovery, oracle revision, and debt ceilings. Recombining equal senior and junior claims returns proportional collateral.

Pegged profiles mint only Statics Dollar, create no Risk Shares, and charge independent collateral-denominated mint and redemption fees. Any fungible Statics Dollar can redeem against available proportional profile capacity, subject to global health and recovery gates.

### Lifecycle and measured custody

Baskets transition through `Active`, `Quarantined`, and `ExitOnly`. Quarantine blocks new exposure immediately while preserving repayment, recovery, and exit paths. `ExitOnly` disables new risk in the installed facets but remains a governed software state because the Diamond is upgradeable.

Every module maintains isolated logical reservations while `LibCustody` enforces global physical backing. Transfers use observed balance deltas and caller-provided bounds. Fee-on-transfer behavior can be measured, but rebases, external burns, deceptive balance implementations, blocklists, pauses, and token callbacks remain constituent risks.

---

## Common Flows

These examples are illustrative. Read the live interfaces and [`docs/integration.md`](./docs/integration.md) for complete structs, approvals, return values, and failure conditions.

**Create a PositionNFT and stake Statics**

```solidity
address[] memory rewardAssets = new address[](2);
rewardAssets[0] = usdg;
rewardAssets[1] = basketToken;

uint256 creationFee = positionFees.positionCreationFee();
IERC20(staticsToken).approve(staticsDiamond, 100e18);

uint256 positionId = globalRewards.createAndStake{value: creationFee}(
    100e18,
    msg.sender,
    rewardAssets
);
```

**Mint and redeem a static basket**

```solidity
uint256 shares = 10e18;
uint256[] memory maximumAmountsIn = basket.quoteMint(basketId, shares);

for (uint256 i; i < assets.length; ++i) {
    IERC20(assets[i]).approve(staticsDiamond, maximumAmountsIn[i]);
}

basket.mint(basketId, shares, msg.sender, maximumAmountsIn);

IERC20(basketToken).approve(staticsDiamond, shares);
uint256[] memory minimumAmountsOut = basket.quoteRedeem(basketId, shares);
basket.redeem(basketId, shares, msg.sender, minimumAmountsOut);
```

**Deposit basket collateral and borrow constituents**

```solidity
IERC20(basketToken).approve(staticsDiamond, collateralShares);
basketCollateral.depositBasketCollateral(positionId, basketId, collateralShares);

(uint256 loanId, uint256[] memory principals) = lending.borrow(
    positionId,
    basketId,
    collateralShares,
    msg.sender
);

// Approve the exact stored principal for each constituent before repayment.
lending.repay(loanId);
```

**Mint Statics Dollar from native ETH**

```solidity
(uint256 seriesId, uint256 dollarOut, uint256 riskSharesOut) = dollarGateway.depositETH{value: 1 ether}(
    msg.sender,
    msg.sender,
    minimumDollarOut,
    minimumRiskSharesOut
);
```

**Borrow a basket constituent vector atomically**

```solidity
(address[] memory assets, uint256[] memory amounts, uint256[] memory fees) =
    flashLender.quoteFlashLoan(basketId, shares);

flashLender.flashLoan(basketId, shares, address(receiver), routeData);
// receiver.onStaticsFlashLoan(...) must return
// keccak256("IStaticsFlashBorrower.onStaticsFlashLoan") and restore principal + fees.
```

---

## Configuration Reference

Deployment reads protocol parameters from environment variables. Selected keys from `.env.example`:

| Variable | Meaning |
|---|---|
| `PRIVATE_KEY` | Local broadcaster key; never commit a populated value |
| `MULTISIG` | Initial timelock proposer and governance authority |
| `GUARDIAN` | Basket and initial Dollar emergency guardian |
| `TREASURY` | Shared protocol treasury |
| `STAKING_TOKEN` | Statics ERC-20 used as the global reward denominator |
| `BASKET_CREATION_FEE_AMOUNT` | Exact native fee opening permissionless basket creation; zero permits owner-only genesis |
| `POSITION_CREATION_FEE_AMOUNT` | Exact native fee for each new PositionNFT; zero keeps creation free |
| `WETH_ADDRESS` | Verified WETH for the selected chain |
| `ETH_USD_FEED` | Verified Chainlink-compatible ETH/USD feed |
| `SEQUENCER_UPTIME_FEED` | Verified target-chain sequencer uptime feed |
| `SEQUENCER_GRACE_PERIOD` | Required recovery interval after sequencer restoration |
| `STATICS_DOLLAR_COLLATERAL_RATIO_BPS` | Initial volatile-profile collateral ratio |
| `STATICS_DOLLAR_PRICE_BAND_BPS` | Initial volatile-profile transition band |
| `STATICS_DOLLAR_DEBT_CEILING` | Initial volatile-profile issuance ceiling |
| `STATICS_DOLLAR_RISK_URI` | ERC-1155 metadata URI for Risk Share series |
| `STATICS_DIAMOND_ADDRESS` | Existing Diamond used by post-deployment ceremonies |
| `STATICS_SWAP_FEE_HOOK_ADDRESS` | Deployed canonical swap-fee hook |
| `STATICS_LIQUIDITY_MANAGER_ADDRESS` | Deployed v4 liquidity manager |
| `STATICS_LIQUIDITY_TIMELOCK_SALT` | Unique salt binding the liquidity-installation batch |
| `STATICS_GENESIS_BASKET_CONFIG` | Reviewed owner-funded genesis basket JSON |
| `STATICS_GENESIS_TIMELOCK_SALT` | Unique salt binding genesis approvals and launch |
| `ROBINHOOD_MAINNET` | Archive-capable Robinhood RPC for required mainnet fork proof |
| `ROBINHOOD_TESTNET_RPC_URL` | Robinhood testnet RPC for simulation and authorized broadcast |
| `ROBINHOOD_TESTNET_VERIFIER_URL` | Blockscout verification endpoint |

Chain-specific v4 addresses and runtime hashes live in `deployments/robinhood-chain-4663.json` and `deployments/robinhood-chain-testnet-46630.json`. Solidity deployment code selects the matching manifest by `block.chainid` and rejects unsupported networks.

Runtime protocol state is available through the Diamond loupe, basket, position, rewards, liquidity, and Dollar view interfaces. Treat deployed state and the reviewed release manifest as authoritative over historical planning documents.

---

## Conventions & Contributing

- **Project name**: use Statics in contracts, interfaces, events, documentation, deployments, SDKs, and commits.
- **Solidity guidance**: read `ETHSKILLS.md` before changing Solidity and apply the relevant security and testing guidance.
- **Build discipline**: avoid full clean rebuilds; use incremental compilation and `forge test --match-path …`.
- **Test fidelity**: prove value-moving behavior with real flows; use fuzz and invariant tests to broaden coverage.
- **Harness resilience**: prefer `uint256` external helper parameters with explicit bounds checks and internal narrowing casts in broad test harnesses.
- **SDK changes**: run `npm test --prefix sdk` and `npm run build --prefix sdk` when changing TypeScript bindings or builders.
- **Commits**: use Conventional Commits, present tense, a title no longer than 72 characters, and a bulleted explanatory body.

---

## License

Statics is licensed under the Business Source License 1.1 (`BUSL-1.1`). See [`LICENSE`](./LICENSE) for the authoritative licensor, Additional Use Grant, Change Date, and Change License terms. Third-party submodules remain governed by their own licenses.
