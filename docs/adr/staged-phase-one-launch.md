# ADR: Staged Statics selector deployment

- Status: Accepted
- Date: 2026-09-16
- Scope: production Diamond composition, audit boundaries, and release sequencing

## Decision

Statics will deploy one `StaticsDiamond` incrementally. Each launch phase is defined by the selectors
actually installed in that Diamond, not by a separate protocol deployment or a compatibility shim.
Later phases retain the same Diamond address and use timelocked `diamondCut(Add)` operations with
phase-specific initialization.

The standalone Genesis launch is already deployed and is outside this sequence. No phased-launch
script redeploys, reconfigures, or transfers ownership of any Genesis contract. A later Diamond-side
Genesis integration must bind to the deployed contracts as they exist and receive its own review.

### Phase 1: arbitrary hooked pairs and STATICS staking

Phase 1 installs 14 facets and 106 selectors for:

- the Diamond cut, loupe, ownership, and timelocked governance kernel;
- general Uniswap v4 pools between arbitrary compatible ERC-20s using the reusable
  `StaticsSwapFeeHook`;
- governed bilateral hook fees, creator revenue, treasury accounting, global STATICS-staker
  rewards, automatic matched POL formation, and explicit native-POL fee harvesting;
- PositionNFT creation, ownership, transfer, closure, and the global STATICS staking and reward
  opt-in lifecycle;
- the custody views and treasury configuration needed by those installed paths; and
- global and PoolId-local swap stops plus staking and liquidity ingress pauses.

It deliberately omits every basket, self-secured-credit, flash-loan, Genesis-integration, Dollar,
Morpho, basket-liquidity-manager, and borrow-to-liquidity selector. It also does not advertise a
protocol interface unless that interface's complete selector set is installed.

The launcher uses the dedicated `StaticsPhaseOneInit` constructor-time initializer so basket,
flash-loan, Dollar, and Morpho storage is not initialized merely because later source exists in the
repository. Future phase initializers must use a new one-time initialization version or an
equivalent namespaced guard; they cannot replay Phase 1 initialization. The launcher also deploys
the final reusable swap hook and its permanent-liquidity math contract against the chain's existing
v4 `PoolManager`. Phase 1 does not deploy or install
`StaticsLiquidityManager`; ordinary LPs can use the existing Uniswap v4 periphery. The separate
`ConfigureStaticsPhaseOneLiquidity` ceremony schedules exactly two calls through the owner
timelock: bind the PoolManager/hook pair and set the native-POL fee harvester. Before producing or
executing that batch, the ceremony requires the exact 14-facet/106-selector Phase 1 manifest.

The general-pool creation fee initializes to zero. Under existing protocol semantics, zero keeps
creation owner-only; it does not enable free public creation. Governance can curate the initial pool
set and later open permissionless creation by setting a nonzero exact fee.

### Phase 2: baskets and self-secured credit

Phase 2 will add the reviewed selector and initializer delta for static baskets, basket mint and
redemption, basket rewards and collateral, self-secured credit, basket canonical liquidity,
flash-loan and flash-arbitrage composition, and advanced borrow-to-liquidity flows. Diamond-side
Genesis Operator linkage, rewards, and recovery may be added here only against the already deployed
Genesis contracts; the standalone Genesis system itself remains unchanged.

The Phase 2 cut and initializer are intentionally not bundled into the Phase 1 release. They require
a separate audit of the added facets, shared-library interactions, storage initialization, and
Phase-1-to-Phase-2 transition.

### Phase 3: Statics Dollar

Phase 3 will deploy the separate Statics Dollar Core and its token contracts, then add the Dollar
gateway, Risk Share liquidity, fee routing, and series-migration selectors to `StaticsDiamond`.
The Core remains its own custody and solvency boundary while using the existing PositionNFT address.

### Phase 4: Morpho

Phase 4 will add the Morpho administration, action, settlement, recovery, and view selectors after
the Dollar and oracle dependencies are production-qualified. It requires a separate external-market,
oracle, liquidation, and account-recovery review.

## Selector and initialization rules

Every phase transition must:

1. begin from the exact deployed loupe manifest and runtime hashes;
2. add or replace only the selectors approved for that phase;
3. execute a phase-specific, one-time initializer atomically with the cut when new storage requires
   initialization;
4. advertise ERC-165 protocol interfaces only after their complete selector surface exists;
5. prove that all callback dependencies of the newly reachable paths are already installed; and
6. record the resulting selector-to-facet map and runtime hashes in the deployment manifest.

The full-stack `DeployStatics.s.sol` launcher remains a fresh-deployment reference and regression
target. It is not the upgrade procedure for a live phased Diamond.

## Audit boundary

Phase 1's deployed audit surface is the 106 reachable selectors, their facet code paths and shared
libraries, the Diamond kernel and initialization, `StaticsTimelock`, `StaticsSwapFeeHook`,
`StaticsPermanentLiquidityMath`, and the Phase 1 deployment/configuration ceremonies. Uninstalled
facet selectors cannot be dispatched through the Diamond and are not presented as live Phase 1
features.

That is a real audit reduction, but not a claim that file count alone defines risk. Review still has
to cover shared storage layouts, external v4 assumptions, upgrade authority, and any internal
library code reachable from an installed selector. Each later audit covers both its new delta and
the interactions it creates with the cumulative installed surface.

The launch does not add TVL, per-pool volume, position-notional, or pool-count caps. Those limits
would materially restrict permissionless composability and revenue while providing only a partial
substitute for review. The accepted controls are owner-curated initial creation, timelocked changes,
guardian stops, explicit runtime manifests, public monitoring, and phase-specific audits.

## Authority and emergency controls

`StaticsTimelock` owns the Diamond. The governance Safe is the proposer, execution is open only after
the delay, and the guardian is an additional canceller. The guardian can reduce exposure by pausing
new staking or liquidity actions and by stopping all protocol-pool swaps or quarantining one
registered PoolId. Only the timelock can restore those paths, change configuration, or cut facets.

Unstaking, reward claims, reward opt-out, and Position closure remain available during a staking
ingress pause. The governance Safe and guardian may be the same address, but separate authorities
provide stronger veto independence.

These controls reduce incident blast radius; they do not replace an external audit. No transaction
or production deployment is authorized by this ADR or its implementation.
