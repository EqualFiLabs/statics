# Statics Dollar Risk Rewards and Eve Integration Plan

- Status: Complete
- Last updated: 2026-07-20
- Canonical protocol repository: `EqualFiLabs/statics`
- Eve integration repository: `EqualFiLabs/eves-market`
- Statics baseline: `2894f15980550b218084f0cbbda36a10f68e4b03`
- Eve baseline: `07b645660eb3788c6657f92db552d76a0e9071ea`
- Target network: Robinhood Chain mainnet, chain ID `4663`
- Governing decision:
  [Position Fee Index and Bounded Looping ADR](adr/position-fee-index-and-bounded-looping.md)

## Objective

Finish the clean-break Statics Dollar reward model and replace Eve's historical
Ether Dollar integration with the current Statics protocol. The completed work
must:

- release volatile-series opt-in reserves proportionally when pairing fills
  consume opt-in principal;
- preserve the initial effective volatile fee allocation of 21% passive
  rewards, 49% opt-in rewards, and 30% insurance;
- keep pegged-profile fees entirely in isolated protocol revenue;
- remove governance-set opt-in reward rates and all associated storage and ABI;
- make Eve consume the pinned Statics source rather than Ether Dollar;
- configure one derived Statics Dollar rail instead of duplicating mutable
  Statics policy in Eve;
- route Eve's former EtRisk fee share to Senior Capital without changing any
  market's total fee; and
- prove the combined Statics Dollar mint-and-buy lifecycle on a Robinhood Chain
  fork without broadcasting a public transaction.

## Accepted boundaries

- Statics remains the canonical source of Statics Dollar contracts and ABIs.
- Eve pins Statics as tracked source. It must not symlink to this checkout or
  depend on an adjacent repository at build or runtime.
- Statics Dollar Core remains the collateral and issuance backend.
  `StaticsDiamond` remains the shared gateway, PositionNFT, rewards, and
  pairing address.
- Eve stores only the Core, derived Statics Diamond, collateral token, and
  pegged profile ID needed to identify its rail. Statics remains authoritative
  for profile state, oracle policy, debt ceilings, fees, and redemption status.
- Eve's launch rail is a pegged profile and therefore has no Risk Shares.
- Volatile Statics Dollar profiles may still direct their configured fee share
  to passive and opt-in Risk Share positions.
- Eve does not bridge generic EtRisk rewards into Statics at launch.
- Existing Base deployment records are historical. Production planning and
  fork verification target a fresh Robinhood Chain deployment.
- This is a clean break. No storage migration, old selector, old token-kind
  alias, compatibility branch, or dual Ether Dollar/Statics Dollar path is
  retained.
- No public deployment or external value-moving action is authorized by this
  plan.

## Economic rules

### Statics volatile-series fees

The initial Statics configuration remains:

```text
series fee
├── 21% passive Risk Share position rewards
├── 49% opt-in Risk Share reserve
└── 30% volatile-profile insurance
```

The opt-in reserve has no administrative emission rate. For each reserve asset
and each pairing fill:

```text
release = floor(reserveBefore * fill / optInPrincipalBefore)
```

A fill that consumes all remaining principal releases all remaining reserve.
The released collateral and Statics Dollar are indexed across the exact stored
units and epoch consumed by the pairing operation.

The pairing redemption fee remains 50 basis points by default. Opt-in
positions receive 80% of that fee plus their complete junior residual;
insurance receives 20% of the fee.

### Statics pegged-profile fees

Pegged profiles remain direct wrappers without Risk Shares. Their mint and
redemption fees remain 100% isolated protocol revenue. External funding may
still donate to volatile reward books, but pegged fees do not automatically
subsidize them.

### Eve fees

Eve keeps its current total fee rates. The distribution share previously
named and routed as `etRiskFeeBps` becomes Senior Capital funding. Initial
distribution defaults are:

| Market path | Maker | Creator | Protocol | Senior Capital | Resolver |
| --- | ---: | ---: | ---: | ---: | ---: |
| Orderbook | 4,000 | 500 | 1,000 | 4,000 | 500 |
| Spot | 4,000 | 0 | 1,500 | 4,000 | 500 |
| Combo | 4,000 | 500 | 1,000 | 4,000 | 500 |
| Parimutuel | 0 | 500 | 5,000 | 4,000 | 500 |

All values are basis-point allocations of the already calculated Eve fee, not
additional trade fees. The generic EtRisk receiver, route, event, view, and
configuration surface are removed.

## Target integration

```text
Eve trader
    |
    v
Eve Diamond: mintAndBuyWithUSDC
    |
    +-- pulls approved pegged collateral
    +-- calls IStaticsDollarGateway on StaticsDiamond
    +-- receives newly minted Statics Dollar
    +-- executes the existing Eve market purchase
    |
    v
StaticsDiamond ------------------> StaticsDollarCoreDiamond
 gateway + shared positions         pegged collateral + issuance
```

Eve configures the rail with one clean-break administration call:

```solidity
setStaticsDollarRail(address core, uint256 profileId, address collateralToken)
```

Configuration derives `staticsDiamond` from `core.periphery()` and verifies:

- Core and token bindings agree;
- Core periphery and PositionNFT are the same Statics Diamond;
- the selected profile is pegged and uses the supplied collateral token; and
- the Statics Diamond gateway identifies the same Core.

The configuration does not cache mutable profile health, oracle, debt, or fee
state. Execution calls the four-argument Statics gateway mint and removes the
obsolete Risk Share receiver from Eve's buy parameters and event schema.

Eve's MLO validation uses the Statics Dollar token kind
`keccak256("STATICS_DOLLAR_TOKEN_V1")`, the Statics Dollar interfaces, and
`core.staticsDollar()` as its source of truth.

## Delivery slices

Each slice receives a focused diff review, verification evidence, and one
narrow Conventional Commit. Update the checkbox, commit, and evidence directly
under the slice after it lands.

### [x] Record the clean-break reward and integration decision

Commit:

```text
docs(dollar): define proportional exit rewards

- Specify pairing-triggered proportional reserve release
- Lock Statics and Eve fee destinations for the clean break
- Track the two-repository Robinhood integration work
```

Evidence:

- Commit: `5997172` (`docs(dollar): define proportional exit rewards`).
- Documentation diff passes `git diff --check`.

### [x] Release opt-in reserves on pairing fills

Commit:

```text
refactor(rewards): release opt-in reserves on fills

- Replace configurable reward rates with proportional reserve release
- Sweep remaining reserve dust when the final principal is consumed
- Remove obsolete reward-rate storage and selectors for fresh deployment
```

Required verification:

- focused compilation and existing pairing/reward regressions;
- selector manifest assertions; and
- storage namespace and interface review.

Evidence:

- Commit: `0361d73` (`refactor(rewards): release opt-in reserves on fills`).
- `StaticsDollarGateway.t.sol`: 16 passed, 0 failed.
- `DiamondGovernance.t.sol`: 15 passed, 0 failed.
- `PeripherySecurityRegression.t.sol`: 13 passed, 0 failed.
- Source search confirms the reward-rate setter, fields, event, and v3 storage
  namespace are absent from active contracts, interfaces, scripts, and tests.

### [x] Prove exit-incentive accounting

Commit:

```text
test(rewards): extend exit incentive invariants

- Cover partial and complete pairing fills with both reward assets
- Fuzz proportional reserve conservation and final-fill dust release
- Assert module and global reservations remain solvent
```

Required verification:

- real-flow pairing tests;
- arithmetic fuzz coverage; and
- combined stateful invariants.

Evidence:

- Commit: `87eab63` (`test(rewards): extend exit incentive invariants`).
- `PeripherySecurityRegression.t.sol`: 15 passed, 0 failed, including 1,000
  proportional-release fuzz runs and the real partial/final pairing lifecycle.
- `PeripheryPositionInvariants.t.sol`: 3 invariants passed across 256 runs and
  12,800 calls each, including live collateral and Statics Dollar donations,
  opt-in changes, fills, and custody coverage.

### [x] Replace Eve's Ether Dollar dependency

Commit in `eve-predict`:

```text
build(statics): pin canonical protocol source

- Add the canonical Statics repository as a tracked submodule
- Pin reward and integration interfaces to commit 87eab63
- Expose a dedicated Statics Foundry remapping for the clean break
```

Required verification:

- submodule status resolves to the exact local Statics implementation commit;
- no production source imports `@etusd`; and
- no symlink or adjacent runtime dependency exists.

Evidence:

- Eve commit: `85c22b3` (`build(statics): pin canonical protocol source`).
- Eve commit `917ae06` removes the obsolete `lib/etusd` gitlink and all
  production Ether Dollar imports while adopting the new rail.
- Statics commit `9943914` makes internal Solidity imports safe for downstream
  consumers without changing runtime behavior.
- Eve's tracked `lib/statics` gitlink resolves to exact Statics commit
  `994391462a4624167d49ccdd17f3a820f0108535` from the canonical repository.
- The pin is a real gitlink, not a symlink, and no build or runtime path refers
  to an adjacent checkout.
- Searches across active Eve source, scripts, and tests find no `@etusd`,
  `lib/etusd`, Ether Dollar, `EtUSD`, or `EtRisk` dependency.

### [x] Adopt the Statics Dollar rail in Eve

Commit in `eve-predict`:

```text
refactor(collateral): adopt Statics Dollar rail

- Derive the shared Statics Diamond from the configured Core
- Route mint-and-buy through the current pegged gateway
- Remove Risk Share assumptions and legacy token-kind checks
```

Required verification:

- configuration validation tests;
- mint-and-buy real-flow tests;
- MLO collateral validation regressions; and
- selector and deployment manifest review.

Evidence:

- Eve commit: `917ae06` (`refactor(collateral): adopt Statics Dollar rail`).
- `TradeRouter.t.sol`: 10 passed, 0 failed.
- `StaticsDollarMarketFlow.t.sol`: 3 passed, 0 failed.
- `MLOPredictionAdapter.t.sol`: 87 passed, 0 failed.
- `DeployScript.t.sol`: 6 passed, 0 failed.
- Configuration tests prove the Core, derived Statics Diamond, PositionNFT,
  gateway, pegged profile, and collateral-token bindings.
- Deployment and MLO tests use `STATICS_DOLLAR_TOKEN_V1` and current Statics
  interfaces and selectors.

### [x] Fund Senior Capital without EtRisk

Commit in `eve-predict`:

```text
refactor(fees): route risk share to Senior Capital

- Remove the obsolete Risk Share reward address and fee fields
- Fold the former allocation into a forty-percent Senior share
- Prove orderbook and parimutuel fees accrue to Senior depositors
```

Required verification:

- focused fee conservation tests for orderbook, spot, combo, and parimutuel;
- governance selector and view cleanup; and
- deployment default assertions.

Evidence:

- Eve commit: `b5b5860` (`refactor(fees): route risk share to Senior Capital`).
- `FeeRouter.t.sol`: 15 passed, 0 failed.
- `ParimutuelFacet.t.sol`: 67 passed, 0 failed.
- `ParimutuelFeeProperties.t.sol`: 2 passed, 0 failed.
- `GenericCLOB.t.sol`: 8 passed, 0 failed.
- `AdminConfig.t.sol`: 5 passed, 0 failed.
- Fee conservation assertions cover orderbook, spot, combo, and parimutuel
  defaults without increasing total market fees.
- Active ABI and storage searches find no generic Risk Share reward receiver,
  route, selector, view, or configuration field.

### [x] Prove the Robinhood combined lifecycle

Commit in `eve-predict`:

```text
test(deploy): prove Robinhood Statics Dollar lifecycle

- Deploy both protocol stacks against a Robinhood Chain fork
- Configure Eve with the fresh Statics Dollar pegged rail
- Mint collateral-backed Dollar and execute a real Eve purchase
```

Required verification:

- chain ID `4663` and configured fork block are asserted;
- fresh local deployments use current selectors and bindings;
- the test proves collateral pull, Statics Dollar issuance, market purchase,
  and resulting accounting; and
- no transaction is broadcast.

Evidence:

- Eve commit: `881a1d8`
  (`test(deploy): prove Robinhood Statics Dollar lifecycle`).
- The required fork test passes: 1 passed, 0 failed, 0 skipped.
- The test pins Robinhood Chain ID `4663` at block `14,498,238`, verifies the
  configured PoolManager code hash, and deploys fresh Statics and Eve stacks.
- The live flow proves pegged collateral reaches Core, the mint fee reaches
  isolated Statics protocol revenue, Dollar supply and liabilities increase,
  and Eve delivers the purchased position with no router balance or allowance
  residue.
- The test uses `eth_call`-style local fork execution and broadcasts no public
  transaction.

### [x] Record release verification

Commit in the repository owning the affected documentation:

```text
docs(statics): record integration verification

- Record focused, full-suite, invariant, and fork evidence
- Mark Robinhood as the active launch target and Base as historical
- Document downstream ABI and provenance updates
```

Required verification:

- complete Statics Foundry suite;
- complete Eve Foundry suite;
- Statics and Eve invariant/security profiles;
- required Robinhood fork proof;
- deployment and selector manifests; and
- searches proving old dependency, terminology, selectors, and token kind are
  absent from active code.

Evidence:

- Eve commit `d01a6d5` documents Robinhood Chain and Statics Dollar as the
  active launch direction and labels predecessor collateral material as
  historical.
- Statics commit `c381387` verifies the current 168-selector periphery
  deployment after removal of reward-rate governance.
- Eve complete suite: 104 suites, 1,064 passed, 0 failed, 1 environment-gated
  fork test skipped; the required fork is executed separately above.
- Eve property and stateful-invariant slice: 41 suites, 156 passed, 0 failed,
  0 skipped. Eve has no separate Foundry security profile; these tests are also
  included in its complete suite.
- Statics default suite: 57 suites, 318 passed, 0 failed, 5 environment-gated
  fork tests skipped.
- Statics security profile: 57 suites, 318 passed, 0 failed, 5
  environment-gated fork tests skipped, including 256 fuzz runs and 128
  invariant runs at depth 64 with `fail_on_revert = true`.
- Final diff audit found no production-code security issue. Aggregate testing
  exposed stale Eve fixtures and compiler-pressure regressions, remediated in
  `7e78cb3`, `0b6093e`, and `017c5da`; the complete suite passes afterward.
- Active-code searches find no old dependency, terminology, reward-rate API,
  legacy token kind, or generic Risk Share fee route.
- `git diff --check` passes in both repositories.

## Completion criteria

This plan is complete only when:

- every slice above records an exact commit hash and current test evidence;
- no Statics reward reserve depends on a governance-set release rate;
- complete consumption of opt-in principal releases all associated reserves;
- partial consumption conserves the reserve and credits only consumed epochs;
- pegged profile fees remain isolated protocol revenue;
- Eve builds solely against the pinned Statics source;
- Eve has no generic EtRisk fee receiver or distribution route;
- Eve's former EtRisk share funds Senior Capital without increasing total fees;
- the active codebase consistently uses Statics Dollar terminology;
- Robinhood Chain fork tests prove the combined value-moving lifecycle;
- the complete suites and security-profile invariants pass; and
- no required implementation or audit-remediation work remains.
