# ADR: Four-phase Statics selector deployment

- Status: Accepted
- Date: 2026-09-16
- Updated: 2026-09-24
- Scope: production Diamond composition, audit boundaries, and release sequencing

## Decision

Statics will deploy one `StaticsDiamond` incrementally. All four launch phases are implemented and
kept deployable in the repository now. A phase is defined by the selectors installed in that
Diamond, not by a separate protocol deployment, a future placeholder, or a compatibility shim.
Later phases retain the same Diamond address and use timelocked `diamondCut(Add)` operations with
phase-specific one-time initialization.

`StaticsProtocolPlan` is the single selector-to-phase source for both paths:

- `DeployStaticsPhaseOne` installs the initial cut;
- `DeployStaticsPhases` deploys and prepares the Phase 2, 3, and 4 deltas; and
- the fresh full-stack launcher concatenates those same four cuts instead of maintaining a second
  handwritten full manifest.

The complete plan contains 360 selectors. CI deploys Phase 1, advances the same Diamond through all
four timelocked batches, and compares every final selector and implementation runtime hash with a
fresh full deployment. A selector addition or reassignment must therefore update the canonical
phase plan; the staged and fresh paths cannot silently diverge.

The standalone Genesis launch is already deployed and remains outside this sequence. No phased
launcher redeploys, reconfigures, upgrades, or transfers ownership of a Genesis contract. Phase 2
only installs the Diamond-side integration surface and its initializer. Binding that surface uses
the existing split-governance handoff against the deployed Genesis contracts. On Robinhood
mainnet, the Phase 1 launcher requires the exact STATICS token, WETH, treasury, and token runtime
hashes recorded by the Genesis deployment manifest. It also verifies the canonical WETH proxy,
implementation, ProxyAdmin, ProxyAdmin owner, owner implementation, and admin backlink against the
Robinhood manifest, so it cannot create a Diamond that the later handoff cannot bind.

## Phase 1: arbitrary hooked pairs and STATICS staking

Phase 1 installs 26 facets and 182 selectors for:

- the Diamond cut, loupe, ownership, and timelocked governance kernel;
- general Uniswap v4 pools between arbitrary compatible ERC-20s using the reusable
  `StaticsSwapFeeHook`;
- governed bilateral hook fees, creator revenue, treasury accounting, global STATICS-staker
  rewards, automatic matched POL formation, and explicit native-POL fee harvesting;
- PositionNFT creation, ownership, transfer, closure, and the global STATICS staking and reward
  opt-in lifecycle;
- public-pool PositionNFT range gauges with reserved protocol STATICS slot 0, four independent
  directly funded reward slots, swap-synchronized range accounting, claims, explicit forfeiture,
  and principal-first exit;
- creator-selected per-slot splits of future direct funding between active-range LPs and all valid
  PoolId allocators, with funder-side share protection, epoch snapshots, claims, and treasury expiry;
- a permissionlessly funded protocol STATICS reserve, next-epoch raw-stake PoolId allocations,
  all-pool weekly pro-rata protocol budgets, lazy PoolId activation, and unused slot-0 recycling,
  as specified in the [weekly gauge incentives ADR](./weekly-protocol-gauge-incentives.md);
- a Diamond-bound `StaticsLiquidityManager` that holds managed Uniswap v4 position NFTs and whose
  Diamond, PoolManager, PositionManager, and Permit2 bindings are immutable;
- the custody views and treasury configuration needed by those installed paths; and
- global and PoolId-local swap stops plus staking and liquidity ingress pauses;
- a separate permissioned v4 hook, creator-selected venue controllers, trusted swap and liquidity
  periphery, non-transferable approved-LP positions, and PoolId-local SLA economics;
- creator-authorized, timelocked controller replacement that installs a compatible halted
  controller without consulting the old provider or changing the PoolId;
- a guardian-add/timelock-remove reward-restriction policy that preserves existing claims; and
- permissioned output-fee routing with no POL: rewardable pairs default to 80% creator, 10%
  treasury, and 10% STATICS stakers, while a pair with two restricted currencies routes 80% to the
  creator and 20% to treasury with no reward liability. Gross-output fees round up, matching the
  public hook so every positive output and positive configured fee produces a nonzero charge.

It omits every basket, self-secured-credit, flash-loan, Genesis-integration, Dollar, Morpho,
and borrow-to-liquidity selector. It does not advertise a protocol
interface unless that interface's complete selector set is installed.

The initial phase launcher deploys 34 contracts: 26 facet implementations, `StaticsPhaseOneInit`,
`StaticsDiamond`, `StaticsTimelock`, `StaticsPermanentLiquidityMath`, `StaticsSwapFeeHook`,
`StaticsPermissionedSwapFeeHook`, `StaticsLiquidityManager`, and
`DefaultVenueControllerFactory`. A separate exact-0.8.26
periphery script deploys `StaticsPermissionedRouter`, `StaticsPermissionedPositionManager`, and its
companion `PermissionedPositionClaims`. It reuses the chain's PoolManager, quoter, Permit2, WETH,
and deployed STATICS token. Uniswap v4 pools are PoolManager state, not separately deployed pool
contracts.

The separate seven-call Phase 1 configuration batch atomically binds both PoolManager/hook paths,
installs the public liquidity manager, trusts the exact-input permissioned router,
non-transferable position manager, and quoter, and sets the public native-POL fee harvester. Every
runtime hash and immutable binding, including the canonical PositionManager and Permit2 bindings,
the manager's four immutable bindings, the permissioned claims companion, and the permissioned
position manager's canonical WETH binding, is verified before installation. The general-pool creation fee
starts at zero, which under current semantics keeps
public creation owner-curated rather than enabling free public creation. Permissioned creation is
always owner/timelock executed and requires exact creator EIP-712 or ERC-1271 authorization.

## Phase 2: baskets, credit, flash composition, and Genesis integration

Phase 2 adds 93 selectors for a cumulative 275 selectors across 38 facets. It installs:

- basket creation, mint, redemption, views, rewards, collateral, quarantine, and decommissioning;
- self-secured borrowing, repayment, extension, recovery, and borrow-to-liquidity;
- basket and single-asset flash loans and their dedicated callbacks;
- canonical basket pools, basket launch liquidity, liquidity unwind, and basket fee allocation
  through the Phase 1 liquidity manager; and
- the Diamond-side Genesis Operator linkage, reward, transition, and recovery surface.

The phase deploys 12 new facet implementations, `StaticsPhaseTwoInit`, and
`StaticsGenesisIntegrationInit`: 14 contracts total. Remaining
basket-dependent selectors are added to seven Phase 1 facet addresses; those facets are not
redeployed merely to expose their deferred selectors. Basket ERC-20s are deployed later per basket,
not during phase activation.

The Phase 2 timelock batch atomically installs the selector delta and initializes the basket
creation fee and runtime-configured single-asset flash-loan fee. Genesis
binding remains a separate ordered handoff because the deployed Genesis system and the new Diamond
can have different governance authorities. Preparation revalidates the exact expanded Phase 1
facet runtimes, deployed hook runtime and immutable bindings, installed liquidity-manager runtime
and four immutable bindings, and the chain-manifest PoolManager, PositionManager, and Permit2
runtimes and bindings.

## Phase 3: Statics Dollar

Phase 3 adds 58 selectors for a cumulative 333 selectors across 43 facets. It adds Dollar custody,
Risk Share staking and incentives, fee routing, the pairing vault, the Dollar gateway, and series
migration.

The phase deploys:

- five Dollar periphery facet implementations and `StaticsPhaseThreeInit`;
- the eleven-facet `StaticsDollarCoreDiamond` implementation set and `CoreInit`;
- `StaticsDollarCoreDiamond`, `StaticsDollar`, and `StaticsDollarRiskShares`; and
- the production `ChainlinkUsdOracle` for the initial collateral profile.

That is 22 contracts. The core remains a separate custody and solvency boundary. Its explicit
bootstrap authority is the Statics timelock for this staged path, so the Phase 3 timelock batch can
atomically install and initialize the periphery before finalizing the core-to-Diamond binding.

## Phase 4: Morpho

Phase 4 adds 27 selectors for the final 360 selectors across 48 facets. It installs the remaining
Position portfolio view plus Morpho administration, actions, settlement, recovery, and views.

The phase deploys five Morpho facet implementations and `StaticsPhaseFourInit`: six contracts.
`StaticsMorphoAccount` contracts remain deterministic, per-Position deployments created only when
a Position first uses Morpho. Morpho markets are state in the existing Morpho deployment, not new
Statics contracts.

After the selector batch, the existing Morpho ceremony initializes the external Morpho/USDstx
binding, creates or verifies the approved markets, and registers them through the timelock. Oracle,
liquidation, market, and account-recovery assumptions remain a distinct Phase 4 audit boundary.

Before preparing the Phase 4 cut, the launcher also revalidates the complete 95-selector Dollar
Core manifest, all eleven Core facet runtimes, shared timelock ownership, completed bootstrap, and
Core/periphery/token bindings.

## Transition and drift rules

Every transition must:

1. start from the exact cumulative selector set for the preceding phase and the exact
   `StaticsTimelock` runtime;
2. require every earlier facet's current compiled runtime and reuse the already deployed shared
   facet addresses;
3. add only the selectors assigned to the next phase by `StaticsProtocolPlan`;
4. execute the phase-specific initializer atomically with the cut;
5. reject skipped phases and initializer replay through namespaced phase state;
6. advertise ERC-165 protocol interfaces only after every selector in that interface is present;
7. prove all callback dependencies of newly reachable paths are installed; and
8. record facet, initializer, dependency, selector, calldata, and runtime hashes in the deployment
   artifact used for review and execution.

The full-stack launcher remains a fresh-deployment regression and local-development option. It is
not the upgrade procedure for a live phased Diamond, but it consumes the exact same canonical
phase cuts. Future source changes that alter an already deployed phase require an explicit reviewed
replacement cut; later activation scripts fail closed on an unexpected earlier runtime.

## Audit boundary

Phase 1's deployed audit surface remains its 182 reachable selectors, facet paths and shared
libraries, Diamond kernel and initializer, timelock, both hooks, permissioned periphery and claims,
venue controller, public range-gauge accounting and custody, the liquidity manager,
permanent-liquidity math, and deployment ceremonies. Each later audit covers its
selector and contract delta plus every new interaction with the cumulative installed surface.
Preparing all phases now prevents tooling drift; it does not collapse the four audit scopes into one
launch decision.

The launch does not add TVL, per-pool volume, position-notional, or pool-count caps. Accepted
controls are curated initial creation, timelocked changes, guardian stops, exact runtime manifests,
public monitoring, and phase-specific audits.

Public range-gauge synchronization has boundary-linear gas cost. A wide swap across a densely
populated managed span may need to be split into smaller price movements to remain below transaction
or block gas limits. Phase 1 deliberately does not impose a fixed distinct-boundary cap because an
early caller could consume the cap and deny later gauge participation. Boundary density and assigned
reward-slot count are therefore explicit pool availability and monitoring inputs.

## Authority and emergency controls

`StaticsTimelock` owns `StaticsDiamond`. The governance Safe is the proposer, execution is open only
after the delay, and the guardian is an additional canceller. The guardian can pause new staking or
liquidity actions and stop all protocol-pool swaps or quarantine one PoolId. Only the timelock can
restore paths, change configuration, or cut facets.

Unstaking, reward claims, reward opt-out, and Position closure remain available during a staking
ingress pause. The governance Safe and guardian may be the same address, but separate authorities
provide stronger veto independence.

No transaction or production deployment is authorized by this ADR or its implementation.
