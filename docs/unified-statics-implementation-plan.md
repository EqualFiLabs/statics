# Unified Statics Protocol Implementation Plan

> **Historical baseline, amended in live code (2026-07-25).** This tracker
> records the unification work. The live protocol uses global Statics-token
> staking with per-position reward-asset selections and a separate per-basket
> index for the canonical hook's BasketToken-staker allocation. Deposited
> BasketTokens remain eligible while locked for borrowing. Basket genesis is
> now owner-only when the creation fee is zero and exact-fee permissionless
> when positive; managed Dollar recovery holders are owner-approved and
> revocable. See
> `Statics-Design.md` and `docs/integration.md` for current behavior.

- Status: Historical implementation tracker; current economics documented elsewhere
- Last updated: 2026-07-19
- Canonical repository: `EqualFiLabs/statics`
- Statics baseline: `ffc8755b995a71796b4ab1728fd6ed6ac190982c`
- Statics Dollar source baseline: `017064ec8188c7f3d120fb9588f88d01925e45f1`
- Governing decision: [Unified Statics ADR](adr/position-fee-index-and-bounded-looping.md)

## Objective

Build Statics as one protocol containing Statics Dollar and Statics Baskets.
The protocol has one user-facing `StaticsDiamond`, one PositionNFT ERC-721
interface, one authorization model, and one shared physical-token reservation
layer. Statics Dollar and Statics Baskets retain isolated economic books,
collateral, liabilities, rewards, debt, and solvency rules.

The completed system must preserve:

- volatile Statics Dollar issuance, health, insurance, series-transition,
  recovery, staking, reward, opt-in, and pairing behavior;
- direct pegged-collateral mint and redemption without Risk Shares or series;
- governed genesis of isolated static baskets, opening to exact-fee public
  creation only when the configured fee is positive;
- static basket mint and redemption backing without ERC-4626 conversion rates;
- flat or threshold-tiered mint and redemption fees;
- PositionNFT-indexed multi-asset basket rewards;
- proportional self-backed basket lending capped at 95% LTV;
- recursive mint, deposit, borrow, and remint loops with a finite bound;
- basket-level exit-only decommissioning; and
- a typed, single-address user integration surface.

## Boundaries

- Keep this repository as the canonical combined source tree.
- Treat `../market-ui/ether-dollar` as a read-only source and behavioral
  reference pinned to the baseline above.
- Import tracked source into this repository. Do not symlink, dynamically
  import from, or require the old repository at build or runtime.
- Do not modify or delete the old Ether Dollar checkout as part of this work.
- Do not add a token registry or token-admission governance.
- Do not add cross-collateralization between Statics Dollar and basket loans.
- Do not pool Statics Dollar and basket reward denominators.
- Do not add ERC-4626 semantics to BasketTokens.
- Do not add V1 migration, compatibility shims, or legacy branches unless the
  user separately requests them.
- Preserve unrelated dirty and untracked files, including the current root
  design documents and historical audit outputs in the reference repository.
- Do not deploy publicly or perform value-moving external actions without
  separate explicit authorization.

## Target architecture

```text
StaticsDiamond
├── shared PositionNFT ERC-721 interface and position lifecycle
├── shared physical-token reservation and reentrancy accounting
├── Statics Dollar periphery
│   ├── series staking and migration
│   ├── passive and opt-in rewards
│   ├── pairing-vault liquidity
│   └── pegged-profile gateway and protocol revenue
└── Statics Baskets
    ├── governed genesis and permissionless minting and redemption
    ├── multi-asset fee indexes
    ├── proportional self-backed lending
    └── flash loans

StaticsDollarCoreDiamond
└── Dollar collateral, issuance, pegged wrappers, health, insurance, and
    volatile-series recovery
```

Suggested source layout:

```text
src/
├── diamond/                 shared EIP-2535 kernel and initialization
├── position/                ERC-721 facet and shared position lifecycle
├── custody/                 global reservations and transfer accounting
├── dollar/
│   ├── core/                Statics Dollar Core Diamond and facets
│   ├── facets/              staking, rewards, opt-in, and pairing
│   └── gateway/             typed Core convenience operations
├── basket/
│   ├── facets/              create, mint, redeem, and flash loans
│   ├── rewards/             multi-asset fee indexes
│   └── lending/             position-owned loans and recovery
└── tokens/                  Dollar, risk shares, and BasketTokens
```

## Accepted implementation rules

### Diamond and governance

- Use one EIP-2535 implementation for the user-facing Diamond and Dollar Core.
- Reuse the mature Dollar Diamond routing, deployment, selector, and upgrade
  tests where they match accepted Statics governance.
- Review inherited facet-policy restrictions explicitly; do not silently treat
  every historical restriction as an accepted product requirement.
- Keep the user-facing Diamond and Dollar Core storage separate while using the
  same protocol governance authority.
- Maintain a generated or programmatic selector manifest and reject selector
  collisions before deployment.

### PositionNFT

- Implement ERC-721 through an OpenZeppelin upgradeable implementation routed
  as Diamond facets. Do not write a custom ERC-721 implementation.
- Initialize the collection through the genesis initialization path.
- The `StaticsDiamond` is both the protocol action address and PositionNFT
  contract address. Do not deploy a separate PositionNFT contract.
- Track shared `activeLegCount`, per-leg activation, and initialization state.
- Prevent position destruction while any Dollar or basket value, reward,
  collateral, debt, or recovery state remains.
- Permit one position to contain multiple Dollar series and multiple baskets.
- Position transfer moves every attached asset and obligation without settling
  or rewriting module ownership records.

### Storage isolation

- Use explicit namespaced storage for shared positions, shared custody, Dollar
  periphery, baskets, fee indexes, and lending.
- Keep Dollar series books separate from basket books.
- Key every basket balance, fee reserve, remainder, reward index, checkpoint,
  loan principal, and recovery amount by basket and token where applicable.
- Keep Statics Dollar Core collateral physically and logically outside the
  shared Diamond.

### Custody and reentrancy

- Use `SafeERC20` for ERC-20 operations.
- Measure actual token balance deltas and credit or debit the affected module
  from observed transfers. Do not require a registry or assume nominal transfer
  amounts always equal actual amounts.
- Maintain both `globalReservedByToken[token]` and detailed module-local
  reservations.
- Do not infer module liquidity from the Diamond's raw token balance.
- Use one OpenZeppelin `ReentrancyGuard` storage slot across every value-moving
  facet in the shared Diamond. Remove module-local custom guards.
- Apply checks, accounting effects, and reservation updates before external
  value transfers wherever the flow permits.

### Statics Dollar

- Rebrand the product and Solidity identifiers from Ether Dollar to Statics
  Dollar while preserving behavior.
- Keep the Dollar and risk tokens permanently controlled by
  `StaticsDollarCoreDiamond`.
- Bind Core to `StaticsDiamond` as its fee receiver, periphery, managed recovery
  holder, and typed user gateway.
- Move Dollar position ownership checks to the shared PositionNFT interface.
- Route retained Dollar reward, insurance, and protocol-revenue balances
  through shared token reservations.
- Replace the blanket `msg.sender == periphery` recombination fee exemption
  with an explicit pairing or managed recombination path.
- Make ordinary recombination economically identical through Core and the
  typed `StaticsDiamond` gateway.
- Make pegged profiles direct nominal wrappers with independent mint and
  redemption fees. Do not create a Risk Series or mint Risk Shares for them.
- Route pegged fees to isolated protocol revenue rather than Dollar reward or
  insurance denominators.
- Quarantine pegged redemption at volatile downside-transition start and
  reopen only after every book is healthy for 48 continuous hours.

### Statics Baskets

- Support one to sixteen constituents and use the creation fee as the public
  genesis switch: zero is owner-only and positive is exact-fee permissionless.
- Keep BasketTokens as separate permit-enabled ERC-20 contracts controlled by
  `StaticsDiamond`.
- Implement the accepted tiered static mint and redemption fee model directly;
  do not port the historical embedded fee-pot model as an intermediate design.
- Accrue holder fees to basket-and-token reward indexes owned by eligible
  PositionNFT basket legs.
- Accrue a mint fee before adding newly minted position principal.
- Remove redeeming position principal before distributing its exit fee.
- Keep external loose BasketTokens transferable but ineligible for indexed
  rewards until deposited.
- Preserve permissionless flash loans and basket exit-only lifecycle behavior.

### Position lending

- Retain loan tranches, but assign each loan to a `positionId` and `basketId`
  rather than an immutable borrower address.
- Store each tranche's proportional constituent principals and maturity.
- Allow multiple tranches so one position can perform recursive loops without
  resetting older loan maturities.
- Keep locked BasketToken collateral reward eligible.
- Cap every configured basket LTV at the immutable 9,500 basis-point maximum.
- Make repayment restore the exact affected basket principal and unlock only
  that tranche's collateral.
- Make expired recovery permissionless and settle rewards before removing
  recovered collateral from eligibility.
- Fund any recovery-caller bounty only from the affected basket's isolated
  recovery surplus.
- Charge extensions in every stored outstanding underlying principal using
  upward-rounded basis-point math; reserve measured receipts as isolated
  basket protocol revenue without changing BasketToken supply or backing.

## Work tracking

Legend:

- `[ ]` pending
- `[~]` in progress
- `[x]` complete
- `[!]` blocked

Update the status and evidence under each slice as work progresses. Every slice
must compile, pass its focused tests, receive a narrow diff review, and land as
its own Conventional Commit before the next slice begins.

### [x] Record architecture and source provenance

Proposed commit:

```text
docs(protocol): adopt unified Statics architecture
```

- Commit the ADR, this implementation tracker, and the goal prompt.
- Add a source-provenance note recording the exact imported Dollar commit.
- Do not include unrelated root design documents.

Verification:

- `git diff --check`
- Confirm the staged file list contains documentation only.

Evidence:

- Commit: `docs(protocol): adopt unified Statics architecture` (this commit)
- Tests: documentation-only; new-file whitespace checks pass

### [x] Import the Statics Dollar baseline

Proposed commit:

```text
chore(dollar): import pinned Dollar source
```

- Import tracked Dollar contracts, tests, deployment scripts, and required
  local dependencies from the pinned reference commit.
- Exclude `out`, `cache`, audit output, and untracked files; retain the two
  tracked selector-manifest fixtures used by the upgrade rehearsal.
- Preserve behavior and test organization before architectural changes.
- Resolve repository-local remappings and dependency versions.

Verification:

- Imported Dollar unit, integration, property, and deployment tests pass.
- No build path references `../market-ui/ether-dollar`.
- Imported files match the pinned source except for mechanical path changes.

Evidence:

- Commit: `chore(dollar): import pinned Dollar source` (this commit)
- Source parity: `git diff --no-index --stat` against the pinned `src`, `test`,
  and `script` trees reports only repository-local import-path substitutions.
- Unit: `forge test --match-path 'test/dollar/unit/*.t.sol' --summary`
  (104 passed, 0 failed)
- Integration: `forge test --match-path 'test/dollar/integration/*.t.sol'
  --summary` (7 passed, 0 failed)
- Security profile: `FOUNDRY_PROFILE=security forge test --match-path
  'test/dollar/properties/*.t.sol' --summary` (12 passed, 0 failed; invariant
  handlers execute 32,768 calls with 0 reverts)
- Fork compile/skip proof: `forge test --match-path
  test/dollar/fork/BaseOracleFork.t.sol --summary` (0 failed, 3 skipped because
  `BASE_RPC_URL` is intentionally absent)
- Independence: imported paths contain no symlinks and no reference-repository
  path; `forge-std` matches the pinned source revision
  `bf647bd6046f2f7da30d0c2bf435e5c76a780c1b`.

### [x] Rebrand Ether Dollar as Statics Dollar

Proposed commit:

```text
refactor(dollar): adopt Statics Dollar identity
```

- Rename product contracts, interfaces, events, deployment artifacts, and test
  descriptions to Statics Dollar terminology.
- Preserve behavior while names change.
- Use the subsequently selected `USDstx` senior-token, `ethLEV` risk-token,
  and `STATICS` staking-token symbols; keep only the position symbol deferred.

Verification:

- Dollar tests remain behaviorally green.
- Source and active documentation contain no unintended Ether Dollar product
  names.

Evidence:

- Commit: `refactor(dollar): adopt Statics Dollar identity` (this commit)
- Unit: `forge test --match-path 'test/dollar/unit/*.t.sol' --summary`
  (105 passed, 0 failed)
- Integration and manifests: `forge test --match-path
  'test/dollar/integration/*.t.sol' --summary` (7 passed, 0 failed; both
  selector manifests regenerated)
- Security profile: `FOUNDRY_PROFILE=security forge test --match-path
  'test/dollar/properties/*.t.sol' --summary` (12 passed, 0 failed)
- Naming: contracts, interfaces, selectors, deployment fields, environment
  keys, storage domains, and test descriptions use Statics Dollar terminology.
  Token metadata now uses the selected Statics launch symbols; only the
  PositionNFT symbol remains deferred by the ADR.
- Historical kernel policy tests passed for this slice. The later corrective
  `6494f27` commit deliberately removed bytecode scanning and opcode policy in
  favor of standard EIP-2535 owner-controlled cuts.

### [x] Establish the unified Diamond kernel

Proposed commit:

```text
refactor(diamond): unify Statics protocol kernel
```

- Select one shared EIP-2535 kernel and initialization path.
- Align Diamond ownership, timelock, guardian, and cut semantics with accepted
  Statics governance.
- Add selector-manifest and selector-collision coverage.
- Keep Dollar Core and the user-facing Diamond as separate deployments of the
  common kernel.

Verification:

- Genesis cuts initialize atomically.
- Delayed upgrade and guardian tests match the accepted governance model.
- No duplicate selector can enter a cut or deployment manifest.

Evidence:

- Initial unification: `c2f243e` moved both Diamonds onto
  `src/diamond/DiamondKernel.sol`; corrective commit `6494f27` then removed the
  inherited nonstandard restrictions found during the pre-audit complexity
  review.
- Current kernel policy: standard owner-controlled EIP-2535 add, replace,
  remove, and optional delegatecall initialization; atomic rollback on failed
  initialization; selector-collision rejection; and one-step ERC-173 ownership.
- The kernel does not scan facet bytecode, pin runtime hashes during dispatch,
  whitelist initializer targets or selectors, or maintain replay state.
  Runtime hashes remain optional offchain release evidence only.
- Governance: one OpenZeppelin `StaticsTimelock` owns both Diamonds. Direct cuts
  by non-owners fail, the proposer multisig may cancel scheduled operations,
  and the timelock may change its own delay only through a scheduled self-call.
  The emergency guardian has no timelock cancellation authority.
- The superseded baseline manifests exposed 18 facets and 137 selectors on
  `StaticsDiamond` and 11 facets and 93 selectors on Core before an intentional
  terminal cut removes two upgrade selectors.

### [x] Move PositionNFT into StaticsDiamond

Proposed commit:

```text
feat(position): expose shared position NFT facets
```

- Add the OpenZeppelin upgradeable ERC-721 dependency and PositionNFT facet.
- Add shared position IDs, active-leg accounting, initialization state, and
  owner-or-approved helpers.
- Register ERC-721 and metadata interface support through the Diamond.
- Remove the external PositionNFT deployment.
- Prevent safe-mint callbacks from closing a position before its initial module
  leg is attached.

Verification:

- ERC-721 transfer, approval, safe-transfer, mint, and burn behavior passes.
- A position can hold multiple independently keyed module legs.
- A position cannot burn while any active leg or initialization remains.

Evidence:

- Commit: `feat(position): expose shared position NFT facets` (this commit)
- Dependency: OpenZeppelin Contracts Upgradeable `v5.6.1` is pinned at
  `7bf4727aacdbfaa0f36cbd664654d0c9e1dc52bf`; it supplies constructor-free,
  ERC-7201-namespaced ERC-721 logic and does not add a second proxy.
- Position lifecycle: `forge test --match-path
  test/position/PositionNFT.t.sol --summary` (5 passed, 0 failed; standard
  transfers and approvals, multi-module legs, self-call-only module minting,
  safe-mint initialization, and burn blocking).
- Root deployment manifest: `forge test --match-path
  test/deployment/DeployStatics.t.sol --summary` (2 passed, 0 failed; 10 facets
  and 71 selectors route exactly).
- Root governance: `forge test --match-path
  test/governance/DiamondGovernance.t.sol --summary` (13 passed, 0 failed).
- Dollar unit: `forge test --match-path 'test/dollar/unit/*.t.sol' --summary`
  (102 passed, 0 failed; the real transferred-position lifecycle proves shared
  leg counts of one at creation, two after migration, and zero before burn).
- Dollar integration and manifests: `forge test --match-path
  'test/dollar/integration/*.t.sol' --summary` (7 passed, 0 failed; Core
  manifests regenerate at 123 selectors before and 119 after terminal
  finalization).
- Security profile: `FOUNDRY_PROFILE=security forge test --match-path
  'test/dollar/properties/*.t.sol' --summary` (12 passed, 0 failed; invariant
  handlers execute 32,768 calls with 0 reverts).
- Fork compile/skip proof: `forge test --match-path
  test/dollar/fork/BaseOracleFork.t.sol --summary` (0 failed, 3 skipped because
  `BASE_RPC_URL` is intentionally absent).
- Architecture: the external Dollar `PositionNFT` contract and deployment are
  deleted. The unified `StaticsDiamond` is the PositionNFT, and Core's
  `positionNFT()` view derives that same address from its single periphery
  binding rather than storing or configuring a second pointer.

### [x] Centralize custody and the execution lock

Proposed commit:

```text
refactor(custody): centralize protocol reservations
```

- Add global and module-local token reservation accounting.
- Replace custom periphery reentrancy state with the common OpenZeppelin guard.
- Route every shared-Diamond token ingress and egress through measured balance
  deltas and reservation updates.
- Add adversarial callback and same-token, cross-module test cases.

Verification:

- `globalReservedByToken` equals the sum of local reservations.
- One module cannot spend another module's attribution.
- Cross-facet reentrancy into any guarded value path fails atomically.
- Transfer-tax behavior is accounted from observed balance deltas.

Evidence:

- Commit: `refactor(custody): centralize protocol reservations` (this commit)
- Custody model: `LibCustody` stores one namespaced
  `globalReservedByToken[token]` total and per-basket or Dollar account
  reservations. The read-only `IStaticsCustody` surface is installed on both
  current Diamond launch paths; there is no public reservation mutator.
- Transfer accounting: ingress credits observed Diamond balance growth;
  reserved and transient egresses authorize a maximum Diamond debit, measure
  sender and receiver deltas, and prove physical balances still cover every
  remaining global reservation. Direct token donations remain unallocated
  surplus.
- Adversarial basket flows: `forge test --match-path
  'test/basket/*.t.sol' --summary` (20 passed, 0 failed; observed inbound and
  recipient-tax deltas, two same-token basket accounts, sender-extra debit
  rollback, unallocated surplus, and cross-facet callback rejection).
- Basket liquidity: `forge test --match-path
  test/liquidity/LendingAndFlash.t.sol --summary` (12 passed, 0 failed; lending
  escrow and constituent movements use the shared reservation account).
- Basket accounting invariants: `forge test --match-path
  test/invariant/AccountingInvariant.t.sol --summary` (3 passed, 0 failed;
  38,400 handler calls with zero reverts prove physical balance, detailed book,
  account reservation, and global reservation equality).
- Execution lock: all basket and Dollar periphery value facets inherit OpenZeppelin
  `ReentrancyGuard` and therefore delegatecall through its single fixed
  ERC-7201 slot. The custom Dollar periphery status word and modifiers are
  removed. Real BasketAdmin-to-Basket and Dollar Staking-to-Rewards callbacks
  both fail with `ReentrancyGuardReentrantCall` while their outer flows succeed.
- Dollar unit: `forge test --match-path 'test/dollar/unit/*.t.sol' --summary`
  (104 passed, 0 failed; reward donation, claim, pending insurance, pairing,
  transition, and recovery flows retain their economics).
- Dollar integration and manifests: `forge test --match-path
  'test/dollar/integration/*.t.sol' --summary` (7 passed, 0 failed; Core
  manifests remain exact at 123 selectors before and 119 after terminal
  finalization).
- Security profile: `FOUNDRY_PROFILE=security forge test --match-path
  'test/dollar/properties/*.t.sol' --summary` (13 passed, 0 failed; Dollar
  account reservations equal reward plus insurance books throughout the
  stateful periphery invariants).
- Deployment manifests: the basket-only development launcher routes 11 facets
  and 76 selectors; the unified Dollar bootstrap now supersedes the
  transitional Dollar-only launcher in the following slice.
- Complete suite: `forge test --summary` (180 passed, 0 failed, 3 fork tests
  skipped because `BASE_RPC_URL` is intentionally absent).

### [x] Bind Statics Dollar periphery to shared positions

Proposed commit:

```text
refactor(dollar): bind Dollar positions to Statics
```

- Move Dollar series ownership and authorization to shared position IDs.
- Register and unregister Dollar series legs with shared position accounting.
- Adapt staking, activation, rewards, opt-in, transition, migration, and closing
  flows without changing their economics.
- Bind Dollar Core to the unified Diamond and remove the external PositionNFT
  wiring requirement.

Verification:

- Existing Dollar position and transition tests remain green.
- Position transfer moves Dollar legs and rewards without rewriting them.
- Dollar position closing respects basket legs owned by the same position.

Evidence:

- Commit: `refactor(dollar): bind Dollar positions to Statics` (this commit)
- Unified deployment: the Dollar bootstrap installs the basket, governance,
  PositionNFT, custody, lending, flash-loan, Dollar staking, rewards, opt-in,
  fee-router, and pairing facets behind one `StaticsDiamond` (16 facets and
  128 selectors). The obsolete Dollar-only Diamond, initializer, and deployer
  path are removed.
- Core binding: `finalizeBootstrap(address staticsDiamond)` now accepts one
  user-facing address. Core stores one periphery pointer; its `positionNFT()`
  view is a derived alias, not separately wired state.
- Position ownership: every Dollar authorization reads the shared ERC-721
  owner or approval, while Dollar series legs use the shared active-leg count
  and namespaced Dollar leg keys.
- Real position flows: `forge test --match-path
  test/dollar/unit/PeripherySecurityRegression.t.sol --summary` (12 passed, 0
  failed). A transferred NFT preserves the complete Dollar leg and accrued
  rewards without a rewrite, the new owner claims them, and a closed Dollar
  leg leaves an independently keyed basket leg blocking position burn. A live
  pairing redemption also proves native ETH can enter only from configured WETH
  and does not remain stranded.
- Bootstrap and deployment: `forge test --match-path
  test/dollar/unit/CoreBootstrap.t.sol --summary` (6 passed, 0 failed) and
  `forge test --match-path test/dollar/unit/CoreDeployment.t.sol --summary` (7
  passed, 0 failed) prove the single address, the 16-facet/128-selector
  manifest, token authorities, and Core wiring.
- Dollar unit: `forge test --match-path 'test/dollar/unit/*.t.sol' --summary`
  (107 passed, 0 failed; staking, activation, opt-in, transition, migration,
  rewards, and closing economics remain green).
- Dollar integration: `forge test --match-path
  'test/dollar/integration/*.t.sol' --summary` (7 passed, 0 failed; Core
  manifests remain exact at 123 selectors before and 119 after terminal
  finalization).
- Security profile: `FOUNDRY_PROFILE=security forge test --match-path
  'test/dollar/properties/*.t.sol' --summary` (13 passed, 0 failed; 32,768
  stateful handler calls with zero reverts).
- Complete suite: `forge test --summary` (183 passed, 0 failed, 3 fork tests
  skipped because `BASE_RPC_URL` is intentionally absent).

### [x] Implement static baskets and tiered fees

Proposed commit:

```text
feat(basket): add static baskets and tiered fees
```

- Redesign basket storage for static backing, tier schedules, protocol revenue,
  and shared reservations.
- Preserve single-asset and multi-asset creation under the configured genesis
  policy.
- Implement static mint and redemption without historical fee-pot buy-in.
- Preserve exit-only redemption and flash-loan behavior.

Verification:

- One whole BasketToken always represents its configured static bundle.
- Large actions pay only the configured tier fee.
- Single-asset baskets mint and redeem correctly.
- One basket cannot alter another basket's backing, including when both use the
  same token.

Evidence:

- Commit: `feat(basket): add static baskets and tiered fees` (this commit)
- Static economics: mint and redemption backing use aggregate-supply rounding,
  so each constituent's `vault balance + outstanding principal` exactly equals
  the static bundle represented by BasketToken supply. Flat fees are selected
  from the greatest qualifying threshold and never require historical fee-pot
  buy-in.
- Real basket flows: `forge test --match-path
  test/basket/BasketLifecycle.t.sol --summary` (17 passed, 0 failed). Coverage
  includes a live low-tier and high-tier mint/redemption lifecycle, unchanged
  same-size quotes after prior fees accrue, a fractional single-asset basket,
  permit authorization, fee-on-transfer ingress, taxed egress, and two
  same-token baskets rejecting an account-crossing sender-extra debit.
- Decommissioning: `forge test --match-path
  test/basket/BasketDecommission.t.sol --summary` (5 passed, 0 failed;
  exit-only redemption and permissionless recovery remain available).
- Lending and flash regression: `forge test --match-path
  test/liquidity/LendingAndFlash.t.sol --summary` (12 passed, 0 failed;
  supply-based backing reclassification preserves borrow, repay, extension,
  recovery, low-decimal, and flash-loan flows).
- Basket invariants: `forge test --match-path
  test/invariant/AccountingInvariant.t.sol --summary` (3 passed, 0 failed;
  38,400 handler calls with zero reverts prove exact static backing, physical
  reservation equality, and escrow bounds).
- Unified regression: `forge test --summary` (185 passed, 0 failed, 3 fork
  tests skipped because `BASE_RPC_URL` is intentionally absent). Dollar
  selector manifests, deployment wiring, and the 128-selector unified Diamond
  remain exact.
- Security profile: `FOUNDRY_PROFILE=security forge test --match-path
  'test/dollar/properties/*.t.sol' --summary` (13 passed, 0 failed; 32,768
  stateful handler calls with zero reverts).

### [x] Add indexed basket rewards

Proposed commit:

```text
feat(rewards): index basket fees by position
```

- Add basket-and-token fee indexes, remainders, reserves, checkpoints, and
  claimable balances.
- Add basket deposits, withdrawals, claims, and direct mint-to-position flows.
- Apply the basket eligibility gate without changing the Dollar gate.
- Keep loose BasketTokens reward ineligible.

Verification:

- New principal cannot claim historical fees or its own mint fee.
- Redeeming principal does not receive its own exit fee.
- Every claim decreases only its basket-token reserve.
- Dollar principal cannot receive basket rewards and basket principal cannot
  receive Dollar rewards.

Evidence:

- Commit: recorded by the narrow `feat(rewards): index basket fees by position`
  slice.
- Focused basket flows: `forge test --match-path 'test/basket/*.t.sol'
  --summary` (30 passed, 0 failed), including seven indexed-reward real-flow
  tests and exit-only position redemption.
- Cross-product isolation: `forge test --match-path
  test/dollar/unit/PeripherySecurityRegression.t.sol --summary` (13 passed, 0
  failed), including a shared PositionNFT carrying independent Dollar and
  basket reward legs.
- Combined accounting invariants: `forge test --match-path
  test/invariant/AccountingInvariant.t.sol --summary` (4 passed, 0 failed;
  51,200 stateful handler calls with zero reverts).
- Deployment manifests: basket deployment exposes 12 facets and 86 selectors;
  unified deployment exposes 17 facets and 138 selectors.
- Complete suite: `forge test --summary` (195 passed, 0 failed, 3 skipped
  because `BASE_RPC_URL` is absent).
- Security profiles: inherited Dollar properties pass 13/13 and combined basket
  accounting passes 4/4, with 8,192 calls per invariant and zero handler
  reverts.

### [x] Add position-owned proportional lending

Proposed commit:

```text
feat(lending): add position-owned basket loans
```

- Move loan ownership from borrower addresses to PositionNFT IDs.
- Add proportional multi-asset principal, locked eligible shares, independent
  maturities, repayment, extension, and permissionless recovery.
- Support multiple loan tranches per position and basket.
- Enforce the immutable 95% maximum LTV.

Verification:

- Position transfer moves every attached loan obligation.
- Locked collateral continues earning basket rewards.
- Repayment and recovery touch only the affected basket and loan tranche.
- Recursive looping converges and cannot exceed the theoretical 20x deposited
  shares or 19x debt bound before fees and rounding.

Evidence:

- Commit: recorded by the narrow `feat(lending): add position-owned basket
  loans` slice.
- Lending and flash real flows: `forge test --match-path
  test/liquidity/LendingAndFlash.t.sol --summary` (19 passed, 0 failed),
  including PositionNFT transfer, multiple independent tranches, lower basket
  LTV, the immutable 95% ceiling, reward-eligible locked shares, isolated
  recovery surplus, and a 24-layer recursive loop below the 20x/19x bounds.
- Exit-only settlement: `forge test --match-path
  test/basket/BasketDecommission.t.sol --summary` (6 passed, 0 failed), proving
  repayment and permissionless recovery remain available during decommission.
- Combined accounting invariants: `forge test --match-path
  test/invariant/AccountingInvariant.t.sol --summary` (4 passed, 0 failed;
  51,200 stateful handler calls with zero reverts).
- Deployment manifests: basket deployment exposes 12 facets and 87 selectors;
  unified deployment exposes 17 facets and 139 selectors.
- Complete suite: `forge test --summary` (202 passed, 0 failed, 3 skipped
  because `BASE_RPC_URL` is absent).
- Security profiles: lending real flows pass 19/19, combined basket accounting
  passes 4/4 with 8,192 calls per invariant, and inherited Dollar properties
  pass 13/13.

### [x] Add typed Statics Dollar gateway operations

Proposed commit:

```text
feat(gateway): route Statics Dollar operations
```

- Add typed Dollar mint, recombination, stake, pairing, and transition
  convenience functions required for single-address integrations.
- Replace caller-based Core fee exemption with an explicit pairing or managed
  recombination selector.
- Keep Core directly callable.
- Avoid arbitrary execution or user-selected delegatecall surfaces.

Verification:

- Ordinary direct and gateway recombination have identical fee economics.
- Only the explicit pairing path receives pairing-vault fee treatment.
- Gateway operations leave no unaccounted residual balances or approvals.

Evidence:

- Commit: recorded by the narrow `feat(gateway): route Statics Dollar
  operations` slice.
- Typed gateway real flows: `forge test --match-path
  test/dollar/unit/StaticsDollarGateway.t.sol --summary` (13 passed, 0
  failed), including ETH and WETH minting, WETH and ETH recombination,
  impaired exits, slippage bounds, same-address staking, residual custody,
  and exact ordinary direct-versus-gateway economics.
- Explicit managed pairing: `forge test --match-path
  test/dollar/unit/PeripherySecurityRegression.t.sol --summary` (13 passed, 0
  failed), including a real pairing redemption whose exact distribution sums
  to the Core gross output while direct and gateway exits remain fee-paying.
- Core and deployment regressions: Core mint/recombination passes 6/6, Core
  lifecycle passes 4/4, bootstrap passes 6/6, and deployment passes 7/7.
- Deployment manifests: the Core exposes 11 facets and 93 selectors; the
  unified Diamond exposes 18 facets and 137 selectors. The deployment returns
  the Diamond itself as the gateway and deploys no separate router.
- Complete suite: `forge test --summary` (203 passed, 0 failed, 3 skipped
  because `BASE_RPC_URL` is absent).

### [x] Prove combined protocol invariants

Proposed commit:

```text
test(invariant): prove cross-module isolation
```

- Add stateful handlers spanning Dollar rewards, baskets, positions, loans,
  claims, recovery, transfers, and gateway operations.
- Exercise shared tokens across Dollar and multiple basket books.
- Exercise hostile callbacks and non-standard transfer deltas.
- Run focused invariants during development and the full security profile at
  the milestone boundary.

Required invariants:

```text
actual token balance >= global reserved amount
global reservation == sum of module reservations
Dollar actions cannot alter basket reservations
basket actions cannot alter Dollar reservations
one basket cannot consume another basket's accounting
direct and gateway Dollar recombination have equal economics
positions cannot close with any live leg, reward, or debt
recursive borrowing remains bounded at 95% LTV
```

Evidence:

- Commit: recorded by the narrow `test(invariant): prove cross-module
  isolation` slice.
- Unified invariant campaign: `forge test --match-path
  test/invariant/UnifiedProtocolInvariant.t.sol --summary` (5 passed, 0
  failed; 64,000 stateful calls with zero handler reverts).
- The handler shares WETH, a sender-extra-charge token, and a callback token
  across two isolated basket books while exercising Dollar minting, staking,
  rewards, direct and gateway recombination, insurance routing, basket minting,
  redemption, rewards, loans, repayment, recovery, and PositionNFT transfers.
- Proven properties cover physical balances, exact global-to-module reservation
  sums, Dollar/basket and basket/basket isolation, ordinary recombination
  parity, live-position attachment, hostile callback exclusion, and the 95%
  LTV recursive-debt bound.
- Full security profile: `FOUNDRY_PROFILE=security forge test --summary` (208
  passed, 0 failed, 3 skipped because `BASE_RPC_URL` is absent), including five
  unified invariants at 8,192 calls each with zero handler reverts.

### [x] Align the SDK with unified protocol interfaces

Proposed commit:

```text
feat(sdk): expose unified Statics operations
```

- Replace historical fee-pot quotes with aggregate-supply static backing and
  tier-selected flat fees.
- Encode governed or exact-fee public basket creation, PositionNFT reward flows,
  position-owned lending, recovery, and the typed Statics Dollar gateway.
- Keep constituent routing venue-neutral and independent of BasketToken
  liquidity.
- Do not retain legacy basket or borrower-address lending overloads.

Verification:

- `npm test --prefix sdk` (9 passed, 0 failed).
- `npm run build --prefix sdk` (TypeScript compilation passes).
- SDK selector assertions match the live Solidity identifiers for basket
  creation (`c4b42fb5`), position lending (`242011d5`), Dollar ETH deposit
  (`be1a35f6`), and ordinary WETH recombination (`a9824eaa`).
- Active SDK source contains no fee-pot buy-in fields or obsolete basket ABI.

Evidence:

- Commit: recorded by the narrow `feat(sdk): expose unified Statics
  operations` slice.
- Tests and build: the commands above pass from the canonical repository.

### [x] Finish deployment and integration documentation

Proposed commit:

```text
docs(deploy): describe unified Statics protocol
```

- Deploy and initialize the user-facing Diamond, PositionNFT facet, Dollar
  Core, Dollar tokens, and Dollar-to-Statics binding in the correct order.
- Update active architecture, deployment, ABI, event, and integration docs.
- Document direct Core access and the preferred typed Diamond gateway.
- Record unresolved production parameters without inventing defaults.

Verification:

- Local deployment tests verify every address and immutable binding.
- Generated selector and deployment manifests match the live facets.
- Full Foundry suite passes without `forge clean` or forced rebuild commands.
- `git diff --check` passes and the final worktree contains no accidental files.

Evidence:

- Deployment implementation: commit `523cee8` (`feat(deploy): launch unified
  Statics protocol`).
- Documentation: recorded by the narrow `docs(deploy): describe unified
  Statics protocol` slice.
- Focused launch proof: `forge test --match-path
  test/deployment/DeployStatics.t.sol -vv` (2 passed, 0 failed). It verifies
  both timelock owners, every cross-binding, the 11-facet/93-selector Core,
  and the 18-facet/137-selector user Diamond.
- Complete default suite: `forge test --summary` (208 passed, 0 failed, 3
  skipped because `BASE_RPC_URL` is absent). Every default invariant handler
  reports zero reverts.
- SDK: commit `c5f3089` keeps the common calldata builders synchronized with
  the live interfaces; its 9 tests and TypeScript build pass.
- Generated artifacts: the Core pre- and post-finalization rehearsal manifests
  were regenerated by the green integration suite and contain the current
  runtime hashes and digests.
- Independence: `src`, `test`, `script`, and `sdk` contain no reference-repo
  path or symlink. Only dependency-managed executables under `sdk/node_modules`
  are symlinks.
- Documentation: active architecture, deployment, ABI/event, integration,
  security, environment, and SDK guidance now describe Statics and Statics
  Dollar, static tier fees, PositionNFT lending, and measured custody deltas.
- Worktree review: `git diff --check` passes; unrelated `.c`,
  `EvePredict-Design.md`, and `Statics-Design.md` remain untracked and excluded.

### [x] Simplify inherited upgrade and administration policy

Proposed commit:

```text
docs(protocol): record corrective architecture evidence
```

- Restore standard EIP-2535 cut, initialization, loupe, and ownership behavior.
- Use ordinary OpenZeppelin `ReentrancyGuard` on the separate Core execution
  boundary instead of a protocol-specific lock.
- Derive all Core administration from the shared timelock-owned Diamond
  authority and remove the parallel governor, proposal queues, execution
  windows, and capability locks.
- Remove irreversible fee, reward, and redemption configuration locks from the
  user Diamond.

Verification:

- Standard cuts and arbitrary delegatecall initializers remain atomic and
  owner-controlled.
- Cross-facet Core callbacks fail through OpenZeppelin's guard.
- Guardian authority can only reduce Dollar risk; restoration and all ordinary
  administration require the Core owner.
- Fee, reward, and redemption parameters can be changed repeatedly through the
  timelock.

Evidence:

- Kernel: `6494f27` (`refactor(diamond): restore standard cut semantics`).
  Diamond cut, governance, deployment, and Core upgrade-rehearsal tests pass.
- Core execution lock: `67c4781` (`refactor(core): adopt OpenZeppelin execution
  lock`). The full Dollar integration suite passes, including a live receiver
  callback that observes `ReentrancyGuardReentrantCall`.
- Unified authority: `d198fab` (`refactor(governance): use one protocol
  authority`). Focused governance/bootstrap/configuration tests pass 27/27;
  affected lifecycle, 1,000-run fuzz, and 256-run multi-profile invariant tests
  pass 32/32. Core manifests regenerate at 93 selectors before and 91 after
  terminal finalization.
- Periphery administration: `0bb3bf5` (`refactor(periphery): remove
  administrative locks`). Governance and deployment pass 16/16; periphery,
  gateway, and unified invariant suites pass 33/33 with zero handler reverts.
- Documentation and final verification are recorded by the narrow
  `docs(protocol): record corrective architecture evidence` slice.

### [x] Complete the security and release audit

Proposed commit:

```text
docs(protocol): record completion evidence
```

- Run the repository audit workflow against the complete unified architecture.
- Remediate every confirmed in-scope finding in separate narrow commits, with
  focused real-flow or invariant regression tests where code changes.
- Run the release QA workflow and requirement-by-requirement completion audit.
- Run the complete default and security-profile suites after all remediation.
- Prove selector manifests, repository independence, active terminology, clean
  staging, and the absence of unauthorized public deployment or value movement.

Verification:

- Audit and QA evidence are recorded with any findings and dispositions.
- `forge test --summary` passes.
- `FOUNDRY_PROFILE=security forge test --summary` passes.
- `npm test --prefix sdk` and `npm run build --prefix sdk` pass.
- Every completion criterion below has direct current-state evidence.

Evidence:

- Review record: internal review workpapers and raw analyzer output are not
  published with the source tree. The remediation commits and their focused
  regression coverage remain the durable implementation evidence.
- Recovery math: `5e198ba` fixes low-decimal bounty partitioning and pins the
  persisted final-claim counterexample. Core recovery passes 18/18, including
  1,001 runs of the affected fuzz property.
- Reward math: `802946a` removes the overflowing raw RAY product. Passive and
  opt-in boundary regressions pass 2/2 and periphery security remains 13/13.
- Diamond metadata: `8171cc2` restricts live ERC-165 metadata changes to the
  timelock owner while retaining atomic cut initialization. Governance passes
  15/15.
- Guardian scope: `c3d56ba` removes unrestricted timelock cancellation from the
  emergency guardian while preserving proposer-multisig cancellation and
  direct risk-reducing emergency powers. Governance, deployment, and pegged
  configuration pass 19/19.
- Historical release QA covered the pre-deployment revision only. It is not a
  current release assurance claim and its internal workpapers are intentionally
  excluded from publication.
- Complete default suite: `forge test` passes 209, fails 0, and skips the 3
  Base fork tests because `BASE_RPC_URL` is intentionally absent.
- Complete security profile: `FOUNDRY_PROFILE=security forge test` passes 209,
  fails 0, and skips the same 3 Base fork tests; invariant handlers report zero
  reverts.
- SDK: `npm test --prefix sdk` passes 9/9 and `npm run build --prefix sdk`
  completes successfully.
- Final artifacts: Core manifests contain 11 facets/93 selectors before
  terminal finalization and 10 facets/91 selectors after it; launch tests prove
  the user Diamond contains 18 facets/137 selectors.
- Commit: `docs(protocol): record completion evidence` (this commit).

## Clean-break fee and pegged-profile refactor

The following slices supersede the completed baseline where their behavior
conflicts. No slice retains old selectors, struct members, events, SDK methods,
or deployment assumptions for compatibility.

### [x] Record the clean-break architecture

Proposed commit:

```text
docs(architecture): define pegged wrappers and extension fees
```

- Amend the ADR with underlying-paid extension fees, direct pegged wrappers,
  independent wrapper fees, isolated protocol revenue, and quarantine rules.
- Record fresh-deployment semantics and the explicit absence of migration or
  compatibility paths.

Verification:

- `git diff --check`
- Confirm the staged file list contains the ADR and tracker only.

Evidence:

- Commit: `06d8e4a` (`docs(architecture): define pegged wrappers and extension
  fees`).
- Documentation whitespace and staged-file checks passed; only the ADR and
  tracker were committed.

### [x] Charge basket extensions in underlyings

Proposed commit:

```text
refactor(lending): charge extension fees in underlyings
```

- Quote fees from each stored outstanding principal with upward rounding.
- Pull caller-selected gross inputs, require measured receipts to satisfy each
  quote, and reserve the receipts as isolated basket protocol revenue.
- Remove BasketToken extension burns from contracts, manifests, SDKs, and
  tests.

Verification:

- Focused real-flow and fuzz tests cover ordinary tokens, taxed ingress,
  underpayment, overpayment, authorization, maturity, and isolation.
- Lending and combined reservation invariants pass.

Evidence:

- Commit: `refactor(lending): charge extension fees in underlyings` (this
  commit).
- Lending and flash real flows: `forge test --match-path
  test/liquidity/LendingAndFlash.t.sol --summary` (25 passed, 0 failed),
  including measured taxed ingress, overpayment, underpayment rollback,
  authorization, pause, expiry, shared-asset isolation, and 1,000-run extension
  rounding fuzz coverage.
- Exit-only regression: `forge test --match-path
  test/basket/BasketDecommission.t.sol --summary` (6 passed, 0 failed).
- Combined accounting invariants: `forge test --match-path
  test/invariant/AccountingInvariant.t.sol --summary` (4 passed, 0 failed;
  51,200 handler calls with zero reverts).
- Canonical launch: `forge test --match-path
  test/deployment/DeployStatics.t.sol --summary` (2 passed, 0 failed), proving
  the replacement lending selectors install behind the timelocked Diamond.
- SDK: `npm test --prefix sdk` passes 10/10 and `npm run build --prefix sdk`
  completes successfully.

### [x] Remove pegged Risk Share series

Proposed commit:

```text
refactor(dollar): remove pegged risk series
```

- Create pegged profiles without a series and mint only Statics Dollar.
- Replace pegged previews, events, storage fields, and public signatures with
  wrapper-specific forms.
- Keep every series, Risk Share, staking, pairing, and reward surface
  volatile-only.

Verification:

- Pegged profile creation leaves series counters, Risk Share supply, and
  position/reward books unchanged.
- Volatile series lifecycle tests remain green.

Evidence:

- Commit: `refactor(dollar): remove pegged risk series` (this commit).
- Governance and ceremony: `CoreProfileGovernance.t.sol` passes 6/6 and
  `PeggedProfileConfiguration.t.sol` passes 2/2, proving pegged creation does
  not probe token-specific issuer controls or consume a series ID.
- Real lifecycle: `CoreDiamondLifecycle.t.sol` passes 4/4, including pegged
  minting with no Risk Shares, no series book, isolated protocol revenue, and
  direct profile-reserve solvency.
- Volatile regression: `CoreMintRecombine.t.sol` passes 6/6 with 1,000 fuzz
  runs and `CoreSeriesRecovery.t.sol` passes 18/18 with 2,001 combined fuzz
  runs.
- Multi-profile invariants: `MultiProfileSecurityInvariants.t.sol` passes 3/3
  across 38,400 handler calls with zero reverts while conserving both volatile
  series liabilities and series-free pegged liabilities.

### [x] Add pegged redemption and quarantine

Proposed commit:

```text
feat(dollar): add pegged redemption quarantine
```

- Burn fungible Statics Dollar against profile-level pegged capacity and route
  independent mint/redemption fees to isolated protocol revenue.
- Latch pegged redemption at downside-transition start and clear it only after
  all transitions resolve and every book remains healthy for 48 hours.
- Expose permissionless status and checkpoint functions without an
  administrative bypass.

Verification:

- Real flows cover partial and final redemption, fee accounting, profile
  modes, old-series deficits, multiple transitions, cancellation, finalization,
  oracle failure, custody shortfall, timer reset, and recovery.
- Supply, senior-liability, solvency, and revenue-isolation invariants pass.

Evidence:

- Commit: `feat(dollar): add pegged redemption quarantine` (this commit).
- Pegged lifecycle: `PeggedRedemptionLifecycle.t.sol` passes 8/8, including
  1,000 fuzz runs over partial redemption, fungible Dollar exits, final backing
  sweeps, mode handling, fee revenue, cancellation, finalized downside runoff,
  simultaneous transitions, oracle failure, custody shortfall, and timer reset.
- Quarantine has no owner bypass: status and checkpoint functions are
  permissionless, while every downside start latches redemption and every
  current Core book must remain healthy for 48 continuous hours.
- Stateful multi-profile coverage includes pegged mint and redemption alongside
  volatile mint, recombination, oracle movement, insurance, and global health.
- Dollar regression suites: unit tests pass 108/108, integrations pass 15/15,
  and property suites pass 10/10 with 64,000 stateful handler calls and zero
  reverts.
- Deployment: `DeployStatics.t.sol` passes 2/2 with the 96-selector Core; both
  Core upgrade-rehearsal manifests regenerate and verify successfully.

### [x] Expose unified pegged gateway and artifacts

Proposed commit:

```text
feat(gateway): expose pegged wrapper operations
```

- Add typed StaticsDiamond pegged mint, redemption, preview, revenue, and
  treasury operations.
- Prove direct Core and gateway economics match and gateway custody returns to
  its prior unreserved state.
- Replace selector manifests, deployment wiring, and SDK bindings; do not ship
  legacy aliases.

Verification:

- Gateway integration, launch, selector-manifest, SDK test, and SDK build
  checks pass.

Evidence:

- Commit: `feat(gateway): expose pegged wrapper operations` (this commit).
- Gateway real flows: `StaticsDollarGateway.t.sol` passes 16/16, including
  typed pegged mint and redemption, direct-versus-gateway fee parity, deferred
  custody, residual approval and balance checks, and common-treasury revenue
  claims.
- Common treasury: the inherited Dollar-only reward-treasury storage and
  selectors are removed; Dollar retirement residue and pegged revenue use the
  existing protocol treasury exposed by `IStaticsBasketAdmin`.
- Deployment: `DeployStatics.t.sol` passes 2/2 and `CoreDeployment.t.sol`
  passes 7/7 with the 18-facet/143-selector StaticsDiamond and
  11-facet/96-selector Core.
- SDK: `npm test --prefix sdk` passes 11/11 and `npm run build --prefix sdk`
  completes successfully with wrapper and revenue calldata builders.
- Active architecture, deployment, integration, and root documentation reflect
  direct pegged wrappers, underlying-paid extensions, the common treasury, and
  current selector totals.

### [x] Verify the refactored protocol

Proposed commit:

```text
test(protocol): prove wrapper and extension invariants
```

- Broaden stateful coverage across baskets, loans, pegged wrappers, volatile
  recovery, shared custody, and treasury claims.
- Run the complete default and security-profile suites and record exact
  release evidence.

Verification:

- `forge test --summary`
- `FOUNDRY_PROFILE=security forge test --summary`
- `npm test --prefix sdk`
- `npm run build --prefix sdk`
- Repository-independence, terminology, selector, and dirty-worktree checks.

Evidence:

- Commit: `test(protocol): prove wrapper and extension invariants` (this
  commit).
- Combined stateful coverage seeds successful pegged gateway mint, direct and
  gateway redemption, common-treasury revenue claim, basket mint, 95%-bounded
  borrow/remint, and underlying-paid extension before fuzzing. The same
  sender-extra-charge token is simultaneously used by the pegged Dollar profile
  and two isolated baskets.
- Focused accounting: `AccountingInvariant.t.sol` passes 4/4 across 51,200
  handler calls with zero reverts, including repeated loan extensions.
- Focused unified protocol: `UnifiedProtocolInvariant.t.sol` passes 5/5 across
  64,000 handler calls with zero reverts, proving global reservations equal the
  sum of module reservations, each module reservation equals its isolated
  books, Dollar supply equals Core senior liabilities, direct and gateway
  wrapper economics match, position legs stay attached, and recursive basket
  debt remains bounded.
- Complete default suite: `forge test --summary` passes 226/226 with zero
  failures; three Base fork tests are skipped because no fork endpoint is
  configured.
- Security profile: `FOUNDRY_PROFILE=security forge test --summary` passes
  226/226 with zero failures; the unified invariant contributes 40,960 calls
  with zero reverts and the same three fork tests are skipped.
- SDK: `npm test --prefix sdk` passes 11/11 and `npm run build --prefix sdk`
  completes successfully.
- Release checks: source, test, script, SDK, Foundry, and remapping paths contain
  no dependency on the reference repository; the reference checkout remains at
  `017064ec8188c7f3d120fb9588f88d01925e45f1`; no tracked symlinks exist; active
  source and product documentation use Statics naming; and deployment tests
  verify the 11-facet/96-selector Core plus 18-facet/143-selector
  `StaticsDiamond` manifests.

## Remaining product decisions

The Statics Dollar senior token uses `USDstx`, Dollar Risk Shares use `ethLEV`,
and the global staking token uses `STATICS`. Only the PositionNFT's `etPOS`
symbol remains deferred. Changing display symbols does not alter the
implemented contract topology or accounting.

Mint and redemption fee tiers are permissionless per-basket choices rather than
protocol launch parameters. The first implementation resolves the other
previously deferred behavior as recorded in the governing ADR: a configurable
9,000-basis-point initial basket holder split, retained claimable rewards after
recovery, isolated recovery surplus, no basket-loan recovery bounty, and the
four typed ETH/WETH Dollar gateway operations.

## Verification discipline

- Follow `AGENTS.md` and consult `ETHSKILLS.md` before Solidity changes.
- Prefer focused `forge test --match-path ...` checks for each slice.
- Run the full suite only at integration boundaries and before completion.
- Do not run `forge clean`, `forge build --force`, or
  `forge build --contracts`.
- Add real-flow coverage for every value-moving lifecycle.
- Use fuzz and invariant tests to broaden real-flow tests, not replace them.
- Review the staged diff and staged file list before every commit.
- Stage and commit only the files belonging to the current slice.
- Update this tracker immediately after verification and include the evidence.

## Completion criteria

This plan is complete only when:

- every slice above is checked complete with commit and verification evidence;
- the combined deployment uses one `StaticsDiamond` user action and
  PositionNFT address plus a separate `StaticsDollarCoreDiamond` backend;
- the imported Statics Dollar behavior and new basket behavior are both fully
  covered and green;
- the cross-module invariants pass under the repository security profile;
- no source, build, test, or deployment path depends on the old repository;
- active source and documentation consistently use Statics and Statics Dollar;
- no required implementation work remains; and
- no public deployment or external value-moving action has been performed
  without separate authorization.

## Progress log

| Date | Slice | Status | Commit or evidence | Notes |
| --- | --- | --- | --- | --- |
| 2026-07-18 | Architecture and tracking | Complete | `748e065` | ADR, tracker, goal prompt, and pinned source provenance |
| 2026-07-18 | Dollar source import | Complete | `0fac7ea` | Pinned source imported without external dependency |
| 2026-07-18 | Statics Dollar identity | Complete | `d0589cf` | Active product and Solidity names rebranded |
| 2026-07-18 | Shared Diamond kernel | Complete | `c2f243e` | One EIP-2535 kernel and accepted governance model |
| 2026-07-18 | Shared PositionNFT | Complete | `9a43ffb` | ERC-721 facets installed at the user Diamond |
| 2026-07-18 | Shared custody | Complete | `e80afda` | Global reservations and common execution lock |
| 2026-07-18 | Dollar position binding | Complete | `a2a34e7` | Dollar periphery moved to shared positions |
| 2026-07-18 | Static baskets | Complete | `bf0b4af` | Permissionless fixed bundles and tiered fees |
| 2026-07-18 | Indexed basket rewards | Complete | `b82f137` | Position-owned multi-asset fee indexes |
| 2026-07-18 | Position lending | Complete | `2677dc0` | Proportional tranches capped at 95% LTV |
| 2026-07-18 | Dollar gateway | Complete | `b0a3310` | Typed common flows and explicit managed pairing |
| 2026-07-18 | Unified invariants | Complete | `c599734` | Cross-module isolation and bounded looping |
| 2026-07-18 | Canonical deployment | Complete | `523cee8` | Timelocked Core and unified Diamond launch |
| 2026-07-18 | Unified SDK | Complete | `c5f3089` | Static quotes and current unified calldata |
| 2026-07-18 | Deployment and integration docs | Complete | `docs(deploy): describe unified Statics protocol` | Current architecture, environment, ABI/event, and security guidance |
| 2026-07-19 | Standard Diamond semantics | Complete | `6494f27` | Removed bytecode policy, codehash dispatch, and initializer restrictions |
| 2026-07-19 | Core OpenZeppelin guard | Complete | `67c4781` | Replaced the custom Core execution lock |
| 2026-07-19 | Unified protocol authority | Complete | `d198fab` | Removed the second Core governor and internal delay machinery |
| 2026-07-19 | Governable periphery parameters | Complete | `0bb3bf5` | Removed irreversible configuration locks |
| 2026-07-19 | Security and release audit | Complete | `docs(protocol): record completion evidence` | All confirmed findings fixed; full suites and fresh QA pass |
| 2026-07-19 | Clean-break architecture | Complete | `06d8e4a` | Underlying extensions and direct pegged wrappers accepted |
| 2026-07-19 | Underlying extension fees | Complete | `ad463c9` | Measured constituent receipts become basket revenue |
| 2026-07-19 | Direct pegged wrappers | Complete | `81d0c2b` | Pegged profiles mint Dollar without Risk Series or Risk Shares |
| 2026-07-19 | Pegged redemption quarantine | Complete | `7c08bd5` | Fungible redemption uses isolated revenue and health recovery delay |
| 2026-07-19 | Unified pegged gateway | Complete | `b17c585` | Typed wrapper flows, common treasury, SDK, and current manifests |
| 2026-07-19 | Refactor verification | Complete | `test(protocol): prove wrapper and extension invariants` | Full default, security, SDK, independence, naming, and manifest checks |
