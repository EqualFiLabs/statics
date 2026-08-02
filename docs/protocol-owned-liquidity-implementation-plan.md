# Protocol-Owned Basket Liquidity Implementation Plan

> **Historical and superseded (2026-07-22).** This completed tracker documents
> an earlier implementation that used primary-fee POL reserves, protocol
> PositionManager NFTs, epochs, and LP-fee collection. Those mechanics are not
> the live protocol. Current canonical liquidity uses bilateral hook fees and
> hook-owned permanent full-range liquidity as documented in
> `Statics-Design.md` and `docs/integration.md`. The launch allocation is now
> 40% POL, 10% canonical LPs, 20% deposited BasketTokens, 20% global Statics
> stakers, and 10% treasury. `borrowAndStakeLiquidity` is the current optional
> atomic path for PositionNFT-owned full-range LP positions.

- Status: Historical; superseded by the bilateral hook-fee architecture
- Last updated: 2026-07-20
- Canonical repository: `EqualFiLabs/statics`
- Implementation baseline: `2c8833251bb0307ec66e17b362184e4e2a06acd8`
- Target network: Robinhood Chain mainnet, chain ID `4663`
- Governing decision:
  [Protocol-Owned Basket Liquidity ADR](adr/protocol-owned-basket-liquidity.md)
- Related decision:
  [Position Fee Index and Bounded Looping ADR](adr/position-fee-index-and-bounded-looping.md)

## Objective

Implement the accepted protocol-owned-liquidity design as a clean extension of
Statics Baskets. The finished system must:

- classify eligible mint, redemption, and flash-loan fees into holder, POL,
  and terminal protocol-revenue books when the fee enters Statics;
- create one canonical hooked Uniswap v4 BasketToken/constituent pool for each
  basket constituent;
- collect a static, caller-independent protocol fee from every canonical-pool
  swap, including swaps against entirely third-party liquidity;
- convert isolated liquidity reserves into exactly backed BasketTokens and
  matched constituent inventory once per 24-hour epoch;
- hold and compound protocol-owned v4 positions, sending 90% of Statics-owned
  LP fees back to POL and 10% to terminal basket protocol revenue;
- unwind POL safely when a basket becomes exit-only;
- preserve ordinary basket borrowing to an arbitrary receiver; and
- add an optional atomic borrow, ordinary-fee mint, and user-owned v4 liquidity
  path without placing the user's v4 NFT inside the Statics PositionNFT.

The implementation remains permissionless at the basket lifecycle and
maintenance layers. Basket genesis follows the current zero-fee owner-only or
positive-fee public policy. It does not add a constituent registry or make
governance responsible for approving basket assets.

## Target network and verified v4 deployment

The first production target is **Robinhood Chain mainnet**, chain ID `4663`.
Robinhood's [network configuration](https://docs.robinhood.com/chain/connecting/)
documents it as an EVM-compatible Arbitrum L2 using ETH for gas. The official
public RPC is `https://rpc.mainnet.chain.robinhood.com`, but it is rate-limited;
deterministic fork and release runs should use an archive-capable provider
through `ROBINHOOD_RPC_URL`.

The Robinhood Chain integration uses the following deployed contracts. These
addresses were supplied from Robinhood's contract documentation and checked
read-only on chain ID `4663` at block `14,498,238` on 2026-07-20. Every address
had non-empty runtime code.

| Contract | Robinhood Chain address | Runtime code hash at verification block | Statics use |
| --- | --- | --- | --- |
| PoolManager | `0x8366a39CC670B4001A1121B8F6A443A643e40951` | `0xbd3881180b547f5fe817545743cfb4343e96b1bc6640dcd70c106b0066e95626` | Required settlement singleton |
| PositionDescriptor | `0x9639443158E8C5efa35Bd45287bf2EFfd3D8dC06` | `0x09d3b199609b46e8921e47c5d0d98ae083e70d2d3b63a6099dc7e947b2f58b20` | Position metadata dependency |
| PositionManager | `0x58daec3116aae6D93017bAAea7749052E8a04fA7` | `0xc873e135dc9aaec88489cfbad146b4cb49d6a32e0d80326377784b7ba17670b2` | Required protocol and user v4 positions |
| Quoter | `0x8Dc178eFB8111BB0973Dd9d722ebeFF267c98F94` | `0xd707b1da8cb165e5ea35a3b4450d971eb562ec171e23492aa117036b78a868f6` | SDK and integration quotes only |
| StateView | `0xF3334192D15450CdD385c8B70e03f9A6bD9E673b` | `0x7d9c591e0956fd89d98feb4ffcfe8bf1f7a62bd485edd979fa21d104b49878a6` | Pool state and fork assertions |
| ReservesLens | `0x0000001b173C3bbF3984D417d8614E3eed34865B` | `0x157a3174cbad65b8ff57b8fbf94253b58be07398593d7d677e4fd6051e16ca91` | Optional observability; not core authority |
| Universal Router | `0x8876789976dEcBfCbBbe364623C63652db8C0904` | `0x2ce6aaaf9f4151f5e1cbf774668772f17f532ae11b15e9284fd0a072a8b0fbde` | Route-parity tests; not a Statics dependency |
| Permit2 | `0x000000000022D473030F116dDEE9F6B43aC78BA3` | `0x5208783f52488f7d3493e5e38311ab707c1d75457fe472a19b0b4d57d66a7fca` | PositionManager payment authorization |

The same read-only verification established:

- `PositionManager.poolManager()` equals the configured PoolManager;
- `PositionManager.permit2()` equals the configured Permit2, also published in
  Robinhood's [protocol-contract table](https://docs.robinhood.com/chain/protocol-contracts/);
- `PositionManager.tokenDescriptor()` equals the configured descriptor;
- `PositionManager.WETH9()` equals Robinhood Chain's
  [canonical WETH](https://docs.robinhood.com/chain/contracts/),
  `0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73`;
- `Quoter.poolManager()` equals the configured PoolManager; and
- `StateView.poolManager()` and `PositionDescriptor.poolManager()` equal the
  configured PoolManager.

Create one checked-in Robinhood deployment manifest containing the chain ID,
addresses, runtime code hashes, source URLs, and a pinned fork block. Contracts
receive the addresses through constructors or installation calldata; production
Solidity must not duplicate chain-specific constants. Deployment scripts, fork
tests, and the SDK must all consume the same manifest or generated bindings.

Required environment variables:

```text
ROBINHOOD_RPC_URL=
ROBINHOOD_FORK_BLOCK=
REQUIRE_ROBINHOOD_FORK=false
```

Normal developer runs may skip the fork suite when no endpoint is configured.
Release completion may not: `REQUIRE_ROBINHOOD_FORK=true` must make a missing
RPC, unavailable archive block, chain-ID mismatch, code-hash mismatch, or
binding mismatch fail the suite.

## Delivery boundaries

### Required

- `StaticsDiamond` remains the only Statics address a user calls for basket,
  position, lending, treasury, canonical-pool, POL, and combined-path actions.
- Each BasketToken remains a separate permit-enabled ERC-20 address.
- `StaticsSwapFeeHook` is immutable and has only the hook permissions required
  to assess and account for the accepted swap fee and record price
  observations.
- `StaticsLiquidityManager` is a narrow, Diamond-authorized adapter and v4 NFT
  custodian. It is not a second user-facing protocol entrypoint.
- Every external token movement is measured at the contract that physically
  holds the token. Diamond, hook, and manager accounting must each be solvent
  independently.
- Every canonical pool uses the exact configured hook, LP fee, tick spacing,
  and BasketToken/constituent pair.
- Ordinary direct v4 users may create their own positions in canonical pools;
  the hook fee applies independently of LP ownership.
- All new Diamond value-moving functions use the existing shared OpenZeppelin
  reentrancy guard.

### Explicitly excluded

- No ERC-4626 basket semantics.
- No token registry, asset allowlist, or governance asset-admission process.
- No upgradeable hook proxy or upgradeable manager proxy.
- No generic router, multicall executor, arbitrary target, arbitrary calldata,
  or arbitrary approval surface.
- No protocol swaps to rebalance mismatched inventory.
- No caller, router, aggregator, or protocol-originated hook-fee exemption.
- No custody of user-owned v4 NFTs inside PositionNFT.
- No use of user LP positions as Statics collateral.
- No change to the existing 95% maximum basket-loan LTV, loan maturity,
  repayment, extension, or recovery economics.
- No Statics Dollar collateral or fee participation in basket POL.
- No router, aggregator, UniswapX, cross-DEX migration, or user exit helper in
  this delivery. Those require separate decisions after the canonical path is
  proven.

## Implementation rules

- Follow `AGENTS.md` and `ETHSKILLS.md` before every Solidity slice.
- Use exact source commits for Uniswap dependencies. Do not depend on a branch,
  a floating tag, or an adjacent checkout.
- Never guess or hardcode deployed v4 addresses. Chain configuration must name
  the address and verification evidence for `PoolManager`, `PositionManager`,
  Permit2, and any view helper.
- Keep v4 types at integration boundaries. Statics accounting libraries should
  use Statics-native IDs, tokens, and amounts.
- Do not add compatibility branches for the current two-way fee split. Replace
  it with the accepted three-way model in one clean migration.
- Avoid redundant state. If a value can be derived safely from a canonical pool
  key, Basket configuration, v4 position, or isolated accounting book, do not
  store another mutable copy.
- Do not move protocol accounting into the hook or manager merely because
  those contracts physically touch v4. The Diamond remains the source of truth
  for basket economic classification.
- Use unit harnesses for arithmetic and deliberately unreachable corruption
  branches. Every value-moving lifecycle must also pass through real local v4
  contracts.
- Update this tracker with the exact commit and verification output after each
  completed slice.

## Target architecture

```text
users and permissionless keepers
               |
               v
        StaticsDiamond
        |      |      |
        |      |      +-- basket, reward, lending, revenue, and POL books
        |      +--------- canonical-pool and observation policy
        +---------------- typed calls and measured asset handoff
               |
               v
    StaticsLiquidityManager ----------------------+
    | - Diamond-only typed operations             |
    | - isolated manager inventory                 |
    | - owns protocol v4 position NFTs             |
    | - sends user NFTs directly to lpRecipient    |
    +----------------------------------------------+
               |
               v
    Uniswap v4 PositionManager / PoolManager
               |
               v
       canonical v4 pools
               |
               v
      StaticsSwapFeeHook
      - immutable Diamond and PoolManager bindings
      - afterSwap fee accounting
      - per-pool fee liabilities
      - per-pool tick observations
      - Diamond-only measured fee withdrawal
```

The hook must be a separate contract because v4 calls the hook address encoded
in each pool key. The manager must be a separate contract because it owns the
protocol's external ERC-721 positions and contains v4 approvals away from
Diamond custody. This does not create three integration surfaces: users call
`StaticsDiamond`; v4 calls the hook; and the Diamond alone calls the manager.

### Contract responsibilities

| Component | Owns economic policy | Holds tokens | Holds v4 NFTs | Callable by |
| --- | --- | --- | --- | --- |
| `StaticsDiamond` | Yes | Basket backing, reserves, rewards, debt, and revenue | No | Users, keepers, governance |
| `StaticsSwapFeeHook` | No; immutable fee rule only | Unsettled per-pool hook fees | No | `PoolManager`; Diamond for withdrawal |
| `StaticsLiquidityManager` | No; typed execution only | Isolated POL idle inventory and transaction-scoped user inventory | Protocol positions only | Diamond |
| v4 `PositionManager` | External venue rules | Pool settlement | User positions and manager-owned protocol positions | Manager and ordinary v4 users |

### Proposed source layout

Names may be tightened during a slice, but responsibilities must not be merged
into an unbounded contract.

```text
src/
├── facets/
│   ├── BasketAdminFacet.sol          existing fee policy and revenue claims
│   ├── BasketFacet.sol               existing ordinary mint and redemption
│   ├── FlashLoanFacet.sol            existing eligible flash fees
│   ├── LendingFacet.sol              ordinary and optional combined borrow
│   └── BasketLiquidityFacet.sol      pools, settlement, POL, and views
├── hooks/
│   └── StaticsSwapFeeHook.sol
├── liquidity/
│   └── StaticsLiquidityManager.sol
├── interfaces/
│   ├── IStaticsBasketAdmin.sol
│   ├── IStaticsBasketLiquidity.sol
│   ├── IStaticsLiquidityManager.sol
│   └── IStaticsSwapFeeHook.sol
└── libraries/
    ├── LibBasket.sol                 global three-way allocation policy
    ├── LibBasketBacking.sol          shared backing reclassification math
    ├── LibBasketLiquidity.sol        isolated POL and canonical-pool books
    ├── LibBasketMint.sol             ordinary-fee mint accounting
    ├── LibBasketRewards.sol          holder index plus fee classification
    └── LibLendingActions.sol         shared loan origination accounting
```

Do not create a library simply to wrap one assignment or one external call.
`LibBasketBacking`, `LibBasketMint`, and `LibLendingActions` are justified only
when both an existing public path and a new POL or combined path use the exact
same state transition. If a proposed extraction has only one caller after the
slice is complete, keep the logic in its facet.

## State and accounting design

### Existing basket storage change

Replace the single global `holderFeeShareBps` with one protocol-wide allocation
record:

```solidity
struct BasketFeeAllocation {
    uint16 holderShareBps;
    uint16 liquidityShareBps;
    uint16 protocolShareBps;
}
```

The setter accepts all three values and requires their sum to equal 10,000.
There is no two-way legacy setter or fallback calculation. Fee allocation is
protocol-wide because that matches the current model and avoids per-basket
configuration state that does not improve isolation.

For an eligible fee `F`:

```text
holder   = floor(F * holderShareBps / 10,000)
liquidity = floor(F * liquidityShareBps / 10,000)
protocol = F - holder - liquidity
```

Assigning the remainder to terminal protocol revenue guarantees exact
conservation without another remainder book. If no BasketTokens are eligible
for holder rewards, the holder amount also becomes terminal protocol revenue;
it does not silently enlarge POL.

### New Diamond liquidity storage

Use one namespaced `LibBasketLiquidity` storage position. Keep only state that
cannot be derived cheaply and unambiguously:

```text
configuration
├── immutable integration identity recorded at installation
│   ├── hook
│   └── liquidity manager
└── protocol-wide pool and safety parameters

per basket and asset
├── liquidityReserve
├── canonical PoolKey association
├── canonical pool lifecycle
├── protocol position token ID
└── cumulative reserve/POL/revenue metrics needed by the SDK

per basket
├── nextCompoundAt
└── lifecycle flags derived from BasketStatus where possible
```

Do not copy constituent lists into liquidity storage. Read them from
`LibBasket.Basket`. Do not store a second PoolId if it is always the hash of the
stored PoolKey. Do not represent v4 deployed liquidity as Diamond custody.

### External custody ledgers

The shared Diamond reservation book covers tokens physically held by the
Diamond. The hook and manager need their own narrow physical ledgers because a
Diamond reservation cannot honestly reserve a balance held at another
address.

- Hook liabilities are keyed by canonical `PoolId` and currency.
- Manager POL inventory is keyed by basket and token.
- Transaction-scoped user inventory is never carried across transactions.
- A shared token used by two baskets or pools has separate local claims whose
  sum cannot exceed that contract's measured balance.
- Every outbound transfer measures sender debit, caps it at the authorized
  amount, and updates the exact local claim before returning.
- Every inbound transfer credits the measured receipt, not the nominal amount.

The combined solvency invariant is therefore location-aware:

```text
Diamond balance(token) >= Diamond global reservation(token)
Hook balance(token)    >= sum of unsettled hook liabilities(token)
Manager balance(token) >= sum of isolated POL inventory(token)
                          + no persistent user inventory
```

### Primary-fee flow

Eligible fees are already physically inside the basket custody account. Fee
classification changes books, not custody location:

```text
measured eligible fee
├── feeYieldReserve[basketId][asset]
├── liquidityReserve[basketId][asset]
└── protocolRevenue[basketId][asset]

sum of the three remains reserved to basketAccount(basketId)
```

Loan origination and extension fees, creation fees, recovery surplus, and hook
fees do not call the three-way allocator.

### Hook-fee flow

The hook computes its fee from the realized swap amounts returned by v4. It
charges output currency on exact-input swaps and input currency on exact-output
swaps, with the same rule for both token orderings and every caller.

Per-swap execution updates only hook-local per-pool liability. It must not call
the Diamond. A permissionless Diamond function later asks the hook to withdraw
the exact accrued currencies and measures the receipts:

- constituent received: reserve it to the basket custody account and credit
  terminal `protocolRevenue[basketId][asset]`;
- BasketToken received: burn it, reduce supply-aware `vaultBalances` for every
  constituent, and credit the released backing to terminal protocol revenue;
- unsupported or no-longer-associated pool: reject settlement without moving
  another pool's claim.

The hook holds direct currency balances received through `PoolManager.take`.
It returns the requested custom-accounting delta but records only the measured
receipt as its per-pool liability. Diamond-only withdrawal measures both the
hook debit and Diamond receipt. There is no ERC-6909 production mode and no
per-swap Diamond callback.

### POL construction flow

`compoundBasketLiquidity(basketId)` performs one bounded epoch:

1. Verify the basket is active, liquidity actions are not paused, the epoch is
   due, every canonical pool is active, and the price checks pass.
2. Collect the basket's protocol LP fees and classify the measured result 90/10.
3. Determine the maximum proportional reserve slice constrained by every
   constituent after conservative supply-aware rounding.
4. Reclassify the backing half from `liquidityReserve` to `vaultBalances` and
   mint exactly backed BasketTokens directly to the manager. This internal mint
   charges no user fee and has no external or general-purpose entrypoint.
5. Transfer the paired constituent half from Diamond custody to the manager
   using exact maximum debits and measured receipts.
6. Add liquidity to the one canonical pool per constituent with explicit
   liquidity and amount bounds. Never use a permissive "from deltas" command
   that lets the current pool price decide an unbounded position size.
7. Record protocol position token IDs and manager idle inventory. Unmatched
   BasketTokens and constituents carry forward; they are not swapped.
8. Advance `nextCompoundAt` only after a successful economically meaningful
   epoch. An empty or below-minimum call reverts without consuming the window.

If a prepared BasketToken is returned to the Diamond rather than retained as
isolated manager inventory, it must be burned and its backing reclassified
from `vaultBalances` back to `liquidityReserve` in the same transaction.

### Protocol LP-fee flow

The manager collects actual v4 position proceeds using the fee-collection
operation supported by the pinned PositionManager version. Each currency is
measured at the manager:

```text
measured protocol LP fee
├── 90% manager POL inventory
└── 10% transferred to StaticsDiamond
```

The 10% underlying path becomes terminal protocol revenue after measured
Diamond receipt. The 10% BasketToken path is burned and reclassifies its
represented backing into terminal protocol revenue. User-owned v4 positions
never pass through this split.

### Combined borrower flow

The final entrypoint remains conceptually:

```solidity
function borrowAndProvideLiquidity(
    uint256 positionId,
    uint256 basketId,
    uint256 collateralShares,
    LiquidityParams[] calldata pools,
    address lpRecipient
) external returns (uint256 loanId, uint256[] memory v4TokenIds);
```

The exact ABI is frozen only after the pinned v4 types and local manager flow
are implemented. The function must:

1. enforce ordinary PositionNFT authorization and the existing lending rules;
2. originate the same loan, fee, collateral lock, maturity, and constituent
   principals as `borrow`;
3. retain the proportional principals in Diamond custody instead of first
   transferring them to the user;
4. use part of those principals in the ordinary fee-paying basket mint path;
5. transfer the new BasketTokens and paired constituents to the manager under
   explicit per-token limits;
6. mint v4 position NFTs directly to `lpRecipient`;
7. return every unused BasketToken, constituent, and v4 refund to
   `lpRecipient`; and
8. leave no user balance, approval, entitlement, or position ID in POL books.

The function is one atomic convenience path, not a new loan product. A revert
in minting, pool validation, deadline, slippage, or v4 execution rolls back the
loan and every reclassification.

## Public surface and authorization

The exact selectors are finalized in their implementation slices. The intended
surface is intentionally small:

```text
governance through the existing timelock
├── setBasketFeeAllocation(holder, liquidity, protocol)
├── setLiquiditySafetyParameters(...)
└── pause/unpause liquidity funding

permissionless callers through StaticsDiamond
├── initializeCanonicalPool(basketId, asset, sqrtPriceX96)
├── activateCanonicalPool(basketId, asset)
├── checkpointCanonicalPool(basketId, asset)
├── settleCanonicalHookFees(basketId, asset)
├── compoundBasketLiquidity(basketId)
└── unwindBasketLiquidity(basketId, asset, limits)

position-authorized users through StaticsDiamond
└── borrowAndProvideLiquidity(...)

views through StaticsDiamond
├── basketFeeAllocation()
├── liquidityReserve(basketId, asset)
├── canonicalPool(basketId, asset)
├── basketLiquidityState(basketId)
├── protocolPosition(basketId, asset)
└── pending/cumulative hook and LP fee views
```

`StaticsLiquidityManager` exposes only Diamond-authorized typed position
creation, increase, fee collection, removal, and isolated inventory return. It
cannot call arbitrary targets or accept arbitrary calldata. Hook and manager
addresses are bound by the liquidity installation initializer rather than a
standing public rebind selector. A later DEX migration decision must add only
the typed authority it actually needs.

### Pause and lifecycle policy

Add `PAUSE_LIQUIDITY` as a guardian-pausable, governance-unpausable action. It
blocks new pool activation, reserve conversion, recompounding, and the combined
borrow-to-liquidity path. The combined path also requires ordinary mint and
borrow actions to be available.

It does not block:

- hook fee accrual caused by external v4 swaps;
- hook-fee settlement into terminal protocol revenue;
- protocol LP-fee collection without reinvestment;
- POL removal and inventory return; or
- ordinary basket redemption, repayment, recovery, or treasury claims.

| Transition | Caller | Liveness assumption |
| --- | --- | --- |
| Initialize canonical pool | Anyone | Basket creator, integrator, or first LP can pay gas |
| Record price checkpoints | Anyone | Protocol keeper maintains observations; all callers remain eligible |
| Activate canonical pool | Anyone after warm-up | A keeper or LP completes activation after objective checks pass |
| Settle hook fees | Anyone through Diamond | Compounding always attempts settlement; independent callers may settle earlier |
| Compound active basket | Anyone once per 24 hours | Protocol keeper calls by default; bounty decision below determines third-party incentive |
| Collect while paused/quarantined | Anyone | Protocol keeper or treasury protects idle value without adding exposure |
| Unwind exit-only POL | Anyone | Protocol keeper calls by default; operation is permissionless and risk reducing |
| Change configuration | Existing timelock | Normal Statics governance execution delay applies |

## Calibration and dependency gate

These inputs must be recorded before their first dependent production slice.
Test-only values may be used to build earlier primitives, but they must be
clearly named as fixtures and cannot leak into deployment defaults.

| Input | Accepted first implementation | Required by |
| --- | --- | --- |
| Primary fee allocation | Protocol-wide `4,500 / 4,500 / 1,000` bps | Three-way fee slice |
| Allocation mutability | Existing timelock changes all three atomically | Three-way fee slice |
| Hook fee scope | One immutable protocol-wide rate per hook deployment | Hook deployment |
| Hook fee rate | 1 bp, rounded up for nonzero charged amounts | Hook deployment manifest |
| Canonical LP fee/tick spacing | 5 bps (`500` millionths) and tick spacing 10 | Pool activation |
| Initial range | Full usable range for tick spacing 10 | Manager position mint |
| Observation model | One-minute cumulative-tick observations in a 64-slot ring | Pool activation |
| Warm-up/window/deviation | 1 hour / 30 minutes / 100 bps | Pool activation |
| Young-pool bound | 7 days; at most 10% of available slice per epoch | POL compounding |
| Minimum epoch size | `1e12` BasketToken shares and nonzero pool liquidity | POL compounding |
| Keeper bounty | Zero; named protocol keeper supplies expected liveness | POL compounding |
| Dependency commits | Exact v4-periphery SHA and its matching core/Permit2 SHAs | Any v4 Solidity |
| Production addresses | Robinhood Chain manifest above, reverified on the pinned fork | Fork compatibility slice |

The accepted zero-bounty first release removes a separate bounty reserve,
claim path, and griefing surface while usage is being measured. If permissionless
third-party liveness is required instead of protocol-keeper liveness, amend the
ADR with a precise bounty source and cap before implementing it.

## Work tracking

Legend:

- `[ ]` pending
- `[~]` in progress
- `[x]` complete
- `[!]` blocked

Every slice must receive a narrow diff review, focused verification, a separate
Conventional Commit, and evidence in this file before the next dependent slice
begins. Independent documentation may proceed while a calibration choice is
being decided, but dependency order may not be bypassed.

### [x] Ratify the first-release calibration

Dependencies: none.

Implementation:

- Resolve every row in the calibration gate or explicitly retain its stated
  recommendation.
- Record the accepted values and mutability in the governing ADR so deployment
  configuration cannot silently choose policy.
- Confirm that the hook rate is one protocol-wide immutable constructor value,
  primary allocation is one timelock-governed protocol-wide record, canonical
  LP and safety parameters are protocol-wide, and the first release has no
  keeper bounty unless the ADR is amended.
- Define test-fixture values separately from production inputs when an exact
  production rate remains chain-specific.
- Do not add Solidity or dependencies in this slice.

Focused verification:

```text
git diff --check
test -f docs/adr/protocol-owned-basket-liquidity.md
```

Acceptance evidence:

- No row required by a production contract or deployment is left ambiguous.
- The ADR, tracker, and deployment input vocabulary agree.
- Any intentionally chain-specific value has an explicit required input and no
  production fallback.

Proposed commit:

```text
docs(liquidity): fix the initial POL calibration

- Record the accepted fee, pool, safety, and liveness parameters
- Separate test fixtures from required production inputs
- Keep first-release configuration protocol-wide and narrow
```

Evidence:

- Commit: `3500051` (`docs(liquidity): fix the initial POL calibration`)
- Checks: `git diff --check`; ADR and tracker calibration vocabulary reviewed

### [x] Pin dependency provenance and build the local v4 fixture

Dependencies: first-release calibration.

Implementation:

- Pin `v4-periphery` by full commit SHA and use the matching `v4-core`, Permit2,
  and Solmate revisions expected by that checkout. Record all SHAs in source
  provenance.
- Install the pinned sources locally under `lib/`; add explicit remappings and
  retain repository independence.
- Build a reusable local-v4 fixture that deploys the real PoolManager,
  PositionManager, Permit2 dependencies, currencies, and a swap-capable test
  router. Mocks may stand in for external users, not for v4 settlement.
- Record which fee-collection command and hook-delta settlement representation
  are supported by the pinned version.
- Do not add Statics protocol behavior in this slice.

Focused verification:

```text
forge test --match-path test/liquidity/V4Fixture.t.sol
forge test --match-path test/deployment/RepositoryIndependence.t.sol
```

Acceptance evidence:

- Exact dependency SHAs and licenses are recorded.
- Local initialization, liquidity mint, exact-input swap, exact-output swap,
  fee collection, and position removal succeed against real v4 contracts.
- No source or runtime path reaches another workspace checkout.

Proposed commit:

```text
build(uniswap): pin the local v4 integration stack

- Pin compatible v4 sources by full commit SHA
- Add a real local PoolManager and PositionManager fixture
- Record settlement and fee-collection provenance
```

Evidence:

- Commit: `9fe4f36` (`build(uniswap): pin the local v4 integration stack`)
- Tests: `forge test --match-path test/liquidity/V4Fixture.t.sol -vv`
  (3 passed); `forge test --match-path
  test/deployment/RepositoryIndependence.t.sol -vv` (1 passed)

### [x] Verify the Robinhood Chain v4 deployment on a fork

Dependencies: pinned v4 fixture.

Implementation:

- Add the checked-in chain-4663 deployment manifest and generated address
  bindings used by tests, scripts, and the SDK.
- Record a reproducible `ROBINHOOD_FORK_BLOCK` at or after the verified block
  above and require an archive-capable `ROBINHOOD_RPC_URL` for that block.
- Add `ROBINHOOD_RPC_URL`, `ROBINHOOD_FORK_BLOCK`, and
  `REQUIRE_ROBINHOOD_FORK` to `.env.example` without committing credentials.
- Add a fork helper that accepts an already selected chain-4663 fork or creates
  the pinned fork from the environment. It may skip only when the required flag
  is false.
- Assert chain ID, deployed code, recorded code hashes, PositionManager
  bindings, Quoter binding, StateView binding, descriptor binding, and
  canonical WETH on the fork.
- Deploy only Statics test currencies and a typed test swapper into local fork
  state, then initialize a pool and exercise the live Robinhood PoolManager and
  PositionManager through position mint, increase, exact-input swap,
  exact-output swap, fee collection, and removal.
- Exercise the live Quoter and StateView against the fork-created pool. Use the
  live Universal Router for a route-parity smoke if its pinned command ABI is
  compatible; a router mismatch must be documented rather than hidden behind
  a mock.
- Do not broadcast, fund a public address, or mutate Robinhood Chain mainnet.

Focused verification:

```text
ROBINHOOD_RPC_URL="$ROBINHOOD_RPC_URL" \
ROBINHOOD_FORK_BLOCK="$ROBINHOOD_FORK_BLOCK" \
REQUIRE_ROBINHOOD_FORK=true \
forge test --match-path test/liquidity/fork/RobinhoodV4DeploymentFork.t.sol -vvv
```

Acceptance evidence:

- The required fork suite passes on chain ID `4663` at the recorded block and
  reports that block in its evidence.
- The locally pinned v4 interfaces and commands work against Robinhood's live
  deployed bytecode.
- Every configured address and immutable binding agrees with the checked-in
  manifest.
- The suite cannot report success by skipping when
  `REQUIRE_ROBINHOOD_FORK=true`.

Proposed commit:

```text
test(uniswap): verify Robinhood v4 deployment

- Pin the chain-4663 v4 deployment and runtime code hashes
- Exercise live PoolManager and PositionManager behavior on a fork
- Fail required fork runs on address, binding, or chain drift
```

Evidence:

- Commit: `891d53e` (`test(uniswap): verify Robinhood v4 deployment`)
- Fork: chain ID `4663`, block `14,498,238`, public archive-capable Tenderly
  gateway; no credential recorded
- Tests: `ROBINHOOD_RPC_URL=<archive-endpoint>
  ROBINHOOD_FORK_BLOCK=14498238 REQUIRE_ROBINHOOD_FORK=true forge test
  --match-path test/liquidity/fork/RobinhoodV4DeploymentFork.t.sol -vv
  --threads 1` (2 passed, 0 failed, 0 skipped)

### [x] Classify primary basket fees into three isolated books

Dependencies: calibration, local fixture, and Robinhood fork compatibility.

Implementation:

- Replace `holderFeeShareBps` with the atomic three-way protocol-wide
  allocation.
- Add `liquidityReserve[basketId][asset]` to namespaced liquidity storage.
- Change `LibBasketRewards.accrueFee` so mint, redemption, and flash fees are
  classified once at receipt.
- Preserve the existing holder index and no-eligible-holder behavior.
- Keep loan, extension, creation, recovery, and existing protocol revenue paths
  outside the allocator.
- Expose allocation, reserve, and cumulative classification views and events.
- Update initialization, admin selectors, deployment expectations, and SDK fee
  math in the same clean break.

Focused verification:

```text
forge test --match-path test/basket/BasketFeeAllocation.t.sol
forge test --match-path test/basket/BasketRewards.t.sol
forge test --match-path test/liquidity/LendingAndFlash.t.sol
npm test --prefix sdk
```

Acceptance evidence:

- Every eligible fee conserves exactly across the three destinations.
- Two baskets sharing a constituent have isolated liquidity reserves.
- No existing terminal revenue source is accidentally redirected.
- Diamond account reservations remain equal to the sum of basket books.

Proposed commit:

```text
feat(fees): add isolated basket liquidity reserves

- Split eligible basket fees across holder, liquidity, and revenue books
- Preserve terminal lending and recovery fee treatment
- Expose exact allocation and reserve accounting
```

Evidence:

- Commit: `645c82a` (`feat(fees): add isolated basket liquidity reserves`)
- Tests: `forge test --match-path test/basket/BasketFeeAllocation.t.sol`
  (4 passed), `forge test --match-path test/basket/BasketRewards.t.sol`
  (7 passed), `forge test --match-path test/liquidity/LendingAndFlash.t.sol`
  (25 passed), `npm test --prefix sdk` (13 passed),
  `forge test --match-path test/invariant/AccountingInvariant.t.sol`
  (4 invariant campaigns passed), and
  `forge test --match-path test/invariant/UnifiedProtocolInvariant.t.sol`
  (5 invariant campaigns passed)

### [x] Implement the immutable canonical swap-fee hook

Dependencies: pinned v4 fixture and Robinhood fork compatibility.

Implementation:

- Implement `StaticsSwapFeeHook` from the pinned official hook base.
- Mine and verify an address whose permission bitmap enables only the required
  `afterSwap` behavior, return-delta support, and any permission strictly needed
  for the accepted observation mechanism.
- Bind PoolManager, StaticsDiamond, and the protocol-wide static hook fee in
  immutable constructor state.
- Register canonical PoolIds only when called by the Diamond.
- Reject swaps for unregistered PoolIds so arbitrary pools cannot use the hook
  without an accounting association.
- Calculate exact-input and exact-output fees from realized amounts after
  partial execution and round dust according to one documented rule.
- Accrue liabilities per PoolId and currency without calling the Diamond during
  the swap.
- Implement Diamond-only measured withdrawal of one pool's accrued currencies.
- Add no owner, arbitrary rescue, caller exemption, dynamic fee, or upgrade
  surface.

Focused verification:

```text
forge test --match-path test/liquidity/StaticsSwapFeeHook.t.sol
forge test --match-path test/liquidity/HookAccountingInvariant.t.sol
```

Acceptance evidence:

- Exact-input, exact-output, both token orderings, partial execution, and dust
  cases match the documented fee formula.
- Direct, router, multi-hop, third-party LP, and protocol-originated swaps have
  identical fee economics.
- Two pools sharing a currency remain isolated and hook liabilities never
  exceed physical hook balances or claims.
- Hook address permissions are asserted from deployed bytecode/address bits.

Proposed commit:

```text
feat(hook): collect canonical basket swap revenue

- Charge one immutable caller-independent fee after realized swaps
- Isolate unsettled liabilities by pool and currency
- Restrict withdrawals and pool association to StaticsDiamond
```

Evidence:

- Commit: `c0594bf` (`feat(hook): collect canonical basket swap revenue`)
- Tests: `forge test --match-path test/liquidity/StaticsSwapFeeHook.t.sol`
  (8 passed) and
  `forge test --match-path test/liquidity/HookAccountingInvariant.t.sol`
  (2 invariant campaigns passed, 25,600 calls, 0 reverts)

### [x] Register, initialize, and observe canonical pools

Dependencies: immutable hook.

Implementation:

- Add canonical-pool state and views to `LibBasketLiquidity` and
  `BasketLiquidityFacet`.
- Derive the pair from the basket's BasketToken and one configured constituent;
  do not accept arbitrary currencies.
- Require the configured hook, protocol LP fee, and tick spacing. Normalize
  currency order and derive PoolId deterministically.
- Make initialization permissionless. The caller supplies the initial price,
  but initial price alone never authorizes POL.
- Add the minimal hook-maintained cumulative-tick observation ring required for
  a time-weighted reference, warm-up, and current/reference deviation check.
- Make observation checkpointing and activation permissionless.
- Reject duplicate assets, duplicate pool associations, mismatched hooks,
  invalid currency order, invalid tick spacing, and an already-associated pool.
- Add `PAUSE_LIQUIDITY` and the lifecycle rules described above.
- Add canonical pool discovery events and SDK readers. Do not add a swap router.

Focused verification:

```text
forge test --match-path test/liquidity/CanonicalPoolLifecycle.t.sol
forge test --match-path test/liquidity/CanonicalPoolOracle.t.sol
forge test --match-path test/governance/DiamondGovernance.t.sol
```

Acceptance evidence:

- One-, three-, and sixteen-asset baskets can associate exactly one pool per
  constituent.
- Activation cannot occur before warm-up or outside the accepted deviation.
- One-block spot manipulation cannot authorize POL against the reference.
- Quarantine and `PAUSE_LIQUIDITY` block new exposure while leaving settlement
  and unwind paths available.

Proposed commit:

```text
feat(liquidity): establish canonical basket pools

- Associate one hooked v4 pool with each basket constituent
- Require objective warm-up and price-deviation checks
- Add a guardian pause for new liquidity exposure
```

Evidence:

- Commit: `40bbfe5` (`feat(liquidity): establish canonical basket pools`)
- Tests: `forge test --match-path test/liquidity/CanonicalPoolLifecycle.t.sol`
  (6 passed),
  `forge test --match-path test/liquidity/CanonicalPoolOracle.t.sol`
  (4 passed), and
  `forge test --match-path test/governance/DiamondGovernance.t.sol`
  (15 passed)

### [x] Settle hook fees into terminal basket revenue

Dependencies: three-way books, hook, and canonical pools.

Implementation:

- Add the permissionless Diamond settlement entrypoint.
- Withdraw only the associated PoolId's currencies and measure both the hook's
  debit and Diamond's receipt.
- For constituent receipts, reserve the measured amount in the basket custody
  account and credit terminal protocol revenue.
- For BasketToken receipts, burn the measured amount and reuse one
  supply-aware backing-reclassification helper to decrease every constituent's
  `vaultBalances` and increase terminal protocol revenue.
- Make the same helper serve every protocol-owned BasketToken burn that has the
  same economics; do not duplicate backing loops.
- Emit enough information to index pending and cumulative hook revenue.
- Leave empty settlement callable without changing any epoch timer.

Focused verification:

```text
forge test --match-path test/liquidity/HookFeeSettlement.t.sol
forge test --match-path test/basket/BasketLifecycle.t.sol
```

Acceptance evidence:

- Underlying settlement becomes claimable only through the basket treasury.
- BasketToken settlement burns supply and releases the exact represented
  backing to revenue without weakening remaining token backing.
- Shared currencies, fee-on-transfer receipts, and sender-extra-debit attempts
  cannot consume another pool or basket's accounting.
- Settlement never changes holder rewards or liquidity reserves.

Proposed commit:

```text
feat(revenue): settle canonical swap fees

- Measure hook withdrawals through the shared basket custody layer
- Burn BasketToken fees into proportional terminal revenue
- Preserve pool and basket isolation during settlement
```

Evidence:

- Commit: `53e0d0b` (`feat(revenue): settle canonical swap fees`)
- Tests: `forge test --match-path test/liquidity/HookFeeSettlement.t.sol`
  (5 passed) and
  `forge test --match-path test/basket/BasketLifecycle.t.sol`
  (17 passed, including 1,000 fuzz runs)

### [x] Add the typed v4 liquidity manager

Dependencies: pinned v4 fixture and canonical pool types.

Implementation:

- Deploy an immutable manager bound to StaticsDiamond, PositionManager,
  PoolManager, and Permit2.
- Expose only Diamond-authorized typed methods for canonical position mint,
  increase, collection, removal, inventory return, and migration transfer.
- Use exact or per-call bounded approvals and clear residual allowances after
  execution. Diamond grants no v4 or Permit2 approval.
- Measure manager receipts, v4 consumption, refunds, and outbound debits.
- Isolate persistent POL inventory by basket and token; assert the sum of local
  books against manager balances.
- Implement a transaction-scoped user position path that takes explicit pool,
  range, amount, slippage, deadline, and recipient data and mints the v4 NFT
  directly to the recipient.
- Ensure user leftovers go directly to the requested refund recipient and are
  never written to POL inventory.
- Reject arbitrary PoolKeys, arbitrary recipients for protocol NFTs, generic
  command streams, and arbitrary external calls.

Focused verification:

```text
forge test --match-path test/liquidity/StaticsLiquidityManager.t.sol
forge test --match-path test/liquidity/UserPositionManagerFlow.t.sol
forge test --match-path test/liquidity/ManagerAccountingInvariant.t.sol
```

Acceptance evidence:

- Real protocol and user v4 positions can be minted, increased, collected, and
  removed through the exact pinned PositionManager interface.
- Protocol NFTs are manager-owned; user NFTs are recipient-owned at creation.
- Manager reentrancy and excessive-debit tokens revert atomically without
  affecting a second basket's inventory.
- Manager and Diamond end every user flow with no residual user approval or
  entitlement.

Proposed commit:

```text
feat(liquidity): add the typed v4 position manager

- Isolate protocol inventory and v4 NFT custody from Diamond balances
- Restrict execution to canonical typed position operations
- Mint user positions directly to their chosen recipient
```

Evidence:

- Commit: `3731f52` (`feat(liquidity): add the typed v4 position manager`)
- Tests: `forge test --match-path test/liquidity/StaticsLiquidityManager.t.sol`
  (7 passed),
  `forge test --match-path test/liquidity/UserPositionManagerFlow.t.sol`
  (3 passed), and
  `forge test --match-path test/liquidity/ManagerAccountingInvariant.t.sol`
  (3 invariant campaigns passed, 38,400 calls, 0 reverts)

### [x] Convert isolated fee reserves into protocol-owned liquidity

Dependencies: three-way books, active canonical pools, and manager.

Implementation:

- Implement conservative limiting-constituent math for the maximum matched
  reserve slice at current BasketToken supply.
- Reclassify the backing half, mint exactly backed BasketTokens directly to the
  manager, and transfer the paired constituent half with measured accounting.
- Keep the internal fee-free mint unreachable except from the bounded
  compounding state transition.
- Calculate explicit v4 liquidity from accepted pool prices and full-range
  ticks; do not divide BasketTokens equally across pools.
- Create the first protocol position per constituent and increase the same
  position in later epochs.
- Retain unmatched manager inventory by basket and token without swaps.
- Enforce the 24-hour interval, minimum useful amount, active lifecycle, pause,
  and price reference.
- Advance the epoch only after successful value movement.

Focused verification:

```text
forge test --match-path test/liquidity/BasketLiquidityCompounding.t.sol
forge test --match-path test/liquidity/LiquidityReserveMath.t.sol
```

Acceptance evidence:

- One-, three-, and sixteen-asset real flows create protocol-owned v4
  positions from classified fees.
- The limiting constituent, conservative rounding, idle carryover, duplicate
  epoch, and below-minimum cases behave exactly as specified.
- Minted protocol BasketTokens are fully backed and never become PositionNFT
  reward eligible.
- Two baskets sharing one underlying cannot use each other's reserve or manager
  inventory.

Proposed commit:

```text
feat(liquidity): compound basket fees into POL

- Mint exactly backed protocol BasketTokens from isolated fee reserves
- Pair each basket constituent in its canonical v4 pool
- Carry unmatched inventory without protocol swaps
```

Evidence:

- Commit: `bb42785` (`feat(liquidity): compound basket fees into POL`)
- Tests: `forge test --match-path test/liquidity/BasketLiquidityCompounding.t.sol`
  (7 passed),
  `forge test --match-path test/liquidity/LiquidityReserveMath.t.sol`
  (3 passed, including 1,000 fuzz runs),
  `forge test --match-path test/deployment/DeployStatics.t.sol` (2 passed),
  and `forge test --match-path test/basket/BasketLifecycle.t.sol`
  (17 passed, including 1,000 fuzz runs)

### [x] Collect and split protocol LP fees 90/10

Dependencies: protocol-owned positions.

Implementation:

- Collect fees without unintentionally changing principal using the operation
  verified against the pinned PositionManager.
- Measure both currencies and split each independently: 90% isolated manager
  POL inventory, 10% terminal revenue transfer.
- Recompound the 90% with available primary-fee inventory when the epoch is
  otherwise valid; carry unmatched amounts forward.
- Convert 10% underlying receipts to reserved terminal protocol revenue.
- Burn 10% BasketToken receipts and reclassify represented backing to terminal
  protocol revenue.
- Keep user-owned LP fees entirely outside this code path.
- Add pending and cumulative LP-fee metrics and conservation events.

Focused verification:

```text
forge test --match-path test/liquidity/ProtocolLpFeeCompounding.t.sol
forge test --match-path test/liquidity/ThirdPartyLiquidityRevenue.t.sol
```

Acceptance evidence:

- Measured fees split 90/10 in both currency orderings and under rounding dust.
- BasketToken revenue burns preserve exact backing for remaining supply.
- Third-party-only pools continue producing hook revenue but no protocol LP
  revenue until Statics owns a position.
- User positions collect 100% of their v4 LP entitlement while still paying
  the canonical hook fee on swaps.

Proposed commit:

```text
feat(liquidity): compound protocol LP fees

- Reinvest ninety percent of measured protocol position fees
- Route ten percent to isolated terminal basket revenue
- Keep third-party LP earnings outside protocol accounting
```

Evidence:

- Commit: `2570023` (`feat(liquidity): compound protocol LP fees`)
- Tests: `forge test --match-path test/liquidity/ProtocolLpFeeCompounding.t.sol`
  (3 passed),
  `forge test --match-path test/liquidity/ThirdPartyLiquidityRevenue.t.sol`
  (1 passed),
  `forge test --match-path test/liquidity/BasketLiquidityCompounding.t.sol`
  (7 passed), and `forge test --match-path test/deployment/DeployStatics.t.sol`
  (2 passed)

### [x] Unwind POL during quarantine and exit-only decommissioning

Dependencies: protocol-owned positions and LP-fee split.

Implementation:

- In quarantine or while liquidity is paused, allow collection and inventory
  return but prohibit reserve conversion and position increases.
- In exit-only, make position removal and inventory normalization
  permissionless and risk reducing.
- Collect fees before principal removal and apply the same measured 90/10 split
  only to actual LP fees, not returned principal.
- Credit returned underlying principal and idle underlying POL directly to
  terminal basket protocol revenue, with explicit classification events.
- Burn returned protocol-owned BasketTokens and reclassify their backing into
  terminal protocol revenue.
- Clear protocol position IDs only after the external NFT no longer represents
  liquidity and all manager inventory is accounted for.
- Preserve ordinary BasketToken redemption throughout exit-only.

Focused verification:

```text
forge test --match-path test/liquidity/BasketLiquidityDecommission.t.sol
forge test --match-path test/basket/BasketDecommission.t.sol
```

Acceptance evidence:

- Active, quarantined, paused, and exit-only states have the exact allowed
  transitions documented above.
- Full removal burns all protocol-owned BasketTokens, returns underlying, and
  leaves no orphaned manager book or NFT.
- One basket's decommissioning cannot alter a shared asset's other reservations
  or pool liabilities.

Proposed commit:

```text
feat(liquidity): unwind POL for basket decommissioning

- Stop new liquidity exposure during quarantine and exit-only
- Remove protocol positions through a permissionless risk-reducing path
- Burn returned BasketTokens into isolated terminal revenue
```

Evidence:

- Commit: `c473895` (`feat(liquidity): unwind POL for basket decommissioning`)
- Tests: `forge test --match-path test/liquidity/BasketLiquidityDecommission.t.sol`
  (4 passed), `forge test --match-path test/basket/BasketDecommission.t.sol`
  (6 passed), `forge test --match-path test/liquidity/StaticsLiquidityManager.t.sol`
  (8 passed), and `forge test --match-path test/deployment/DeployStatics.t.sol`
  (2 passed)
- Note: v4 full-range removal rounds each returned currency down by at most one
  base unit. Any such unit remains physically pool-custodied and exactly basket
  backed; manager inventory and the PositionManager NFT are fully cleared.

### [x] Share ordinary mint and loan-origination accounting

Dependencies: stable POL accounting and manager user-position path.

Implementation:

- Extract the smallest internal state transitions needed by both existing and
  combined paths.
- Make ordinary `borrow` and the future combined path call one loan quote and
  origination implementation for collateral locking, fee burn, principal,
  maturity, debt, and events.
- Make ordinary `mint` and the future combined path call one ordinary-fee mint
  implementation for fee selection, backing increase, fee allocation, token
  mint, and events.
- Separate accounting from the final asset destination so the ordinary path
  still pushes principal to any receiver while the combined path may retain it
  transactionally.
- Preserve external ABI widths and selectors in existing interfaces.
- Do not expose fee-free minting, receiver-less borrowing, or general internal
  execution as new external functions.

Focused verification:

```text
forge test --match-path test/basket/BasketLifecycle.t.sol
forge test --match-path test/liquidity/LendingAndFlash.t.sol
forge test --match-path test/liquidity/LendingMintParity.t.sol
```

Acceptance evidence:

- Existing real mint, borrow, repay, extend, recover, and recursive-loop tests
  retain exact economics and event data.
- Quote and execution parity holds over fuzzed supplies, fee tiers, LTVs, and
  one- through sixteen-asset baskets.
- No new public bypass exists for either shared internal action.

Proposed commit:

```text
refactor(basket): share mint and loan accounting

- Reuse one origination transition across ordinary and retained principal
- Reuse ordinary static-fee mint accounting without exposing bypasses
- Preserve existing borrow and mint economics
```

Evidence:

- Commit: `7ec0535` (`refactor(basket): share mint and loan accounting`)
- Tests: `forge test --match-path test/basket/BasketLifecycle.t.sol`
  (17 passed, including 1,000 fuzz runs),
  `forge test --match-path test/liquidity/LendingAndFlash.t.sol`
  (25 passed, including 2,000 fuzz runs), and
  `forge test --match-path test/liquidity/LendingMintParity.t.sol`
  (4 passed, including 1,000 fuzz runs plus one-, three-, and sixteen-asset
  real flows)

### [x] Add the optional borrow-to-liquidity action

Dependencies: shared accounting, manager user path, and canonical pools.

Implementation:

- Freeze a typed `LiquidityParams` ABI using the pinned v4 types only where
  necessary.
- Implement `borrowAndProvideLiquidity` on `StaticsDiamond` under the shared
  reentrancy guard.
- Require PositionNFT authorization, active basket status, available borrow,
  mint, and liquidity actions, canonical pool association, valid ranges,
  explicit amount caps, minimum liquidity, deadline, and nonzero recipient.
- Originate the normal loan and retain principal transactionally.
- Solve the balanced allocation after the ordinary static mint fee, perform the
  normal fee-paying mint, and send only bounded inventory to the manager.
- Mint every v4 NFT directly to `lpRecipient`, including when that address is
  different from the PositionNFT owner.
- Return all manager and PositionManager refunds to `lpRecipient`.
- Emit loan, mint, and user-liquidity events that can be reconciled without a
  separate hidden position book.
- Leave the original ordinary `borrow` path unchanged.

Focused verification:

```text
forge test --match-path test/liquidity/BorrowAndProvideLiquidity.t.sol
forge test --match-path test/liquidity/BorrowLiquidityParity.t.sol
forge test --match-path test/position/PositionNFT.t.sol
```

Acceptance evidence:

- One- and multi-asset real flows originate a loan, charge the exact normal
  mint fee, mint a user v4 NFT, and leave no residual user manager state.
- The combined path matches equivalent separate actions for loan principal,
  origination fee, maturity, backing, mint fee, and pool allocation.
- Invalid pool, duplicate pool, range, deadline, amount, and liquidity inputs
  roll back every loan and mint effect.
- PositionNFT transfer, repayment, extension, expiry, and recovery do not move
  or seize the independently owned v4 NFT.
- Original locked collateral remains reward eligible; BasketTokens in the user
  v4 position do not become PositionNFT eligible.

Proposed commit:

```text
feat(lending): add optional borrow-to-liquidity

- Retain borrowed principals for an atomic ordinary-fee basket mint
- Create canonical v4 positions directly for the chosen recipient
- Preserve ordinary borrowing and independent LP ownership
```

Evidence:

- Commit: `c7851b7` (`feat(lending): add optional borrow-to-liquidity`)
- Tests: `forge test --match-path test/liquidity/BorrowAndProvideLiquidity.t.sol`
  (5 passed), `forge test --match-path test/liquidity/BorrowLiquidityParity.t.sol`
  (2 passed), `forge test --match-path test/position/PositionNFT.t.sol`
  (5 passed), and `forge test --match-path test/deployment/DeployStatics.t.sol`
  (2 passed)

### [x] Expose liquidity data in the SDK and protocol documentation

Dependencies: public ABIs and events are stable.

Implementation:

- Add ABI fragments, typed readers, quotes, calldata builders, and event types
  for fee allocation, pool lifecycle, reserves, hook settlement, compounding,
  decommissioning, and the combined path.
- Expose effective canonical fee composition as separate LP and hook rates.
- Expose POL reserve, deployed position ID, manager idle inventory, pending and
  cumulative hook revenue, pending LP fees, cumulative recompounding,
  cumulative protocol LP revenue, next epoch, and lifecycle status.
- Document that user v4 NFTs are discovered from ordinary PositionManager
  events and are not protocol-owned positions.
- Update architecture, ABI/event, deployment, operational, and threat-model
  documentation to match live code. Do not document deferred routers or exit
  helpers as implemented.

Focused verification:

```text
npm test --prefix sdk
npm run build --prefix sdk
```

Acceptance evidence:

- SDK calculations match Solidity vectors for fee splits, epoch eligibility,
  hook fee rounding, and combined action inputs.
- Every new selector and event is represented once with current Statics naming.
- Documentation distinguishes hook revenue, protocol LP revenue, and user LP
  revenue.

Proposed commit:

```text
feat(sdk): expose canonical liquidity workflows

- Add typed pool, POL, hook-revenue, and combined-action helpers
- Mirror Solidity fee and allocation calculations
- Document user and protocol v4 position ownership
```

Evidence:

- Commit: `934aec2` (`feat(sdk): expose canonical liquidity workflows`)
- Tests: `npm test --prefix sdk` (19 passed) and
  `npm run build --prefix sdk` (TypeScript build passed)

### [x] Wire deployment, selector, and configuration manifests

Dependencies: all production selectors and external contracts are stable.

Implementation:

- Add every new Diamond selector to `StaticsSelectors`, interface detection,
  deployment cuts, collision checks, and generated manifests.
- Extend fresh local deployment tests with the hook, manager, and full
  canonical configuration.
- Add a separate production configuration script that emits the required
  timelock batch for an existing Diamond. Do not weaken timelock-from-genesis
  ownership or assume a temporary deployer owner.
- Deploy the Diamond before immutable contracts so hook and manager constructors
  bind the real Diamond address; then install/configure liquidity through the
  timelock path. Do not add predicted-address machinery merely to make it one
  transaction.
- Record PoolManager, PositionManager, Permit2, manager, hook address and
  permission bitmap, pool keys, PoolIds, fee parameters, safety parameters,
  and protocol position token IDs.
- Verify configured external addresses, code, and manager/hook immutable
  bindings before producing a broadcastable batch.
- Do not broadcast or perform public value-moving actions without separate
  explicit authorization.

Focused verification:

```text
forge test --match-path test/deployment/DeployStatics.t.sol
forge test --match-path test/deployment/ConfigureStaticsLiquidity.t.sol
forge test --match-path test/deployment/SelectorManifest.t.sol
```

Acceptance evidence:

- Fresh deployment and timelocked upgrade/configuration both reproduce the
  expected architecture.
- Selector counts, ERC-165 support, address bindings, hook bits, pool metadata,
  and token IDs agree across code, manifest, SDK, and docs.
- No public transaction was sent.

Proposed commit:

```text
feat(deploy): wire the Statics v4 liquidity stack

- Install liquidity selectors through the existing timelock model
- Verify immutable hook and manager bindings before configuration
- Emit complete canonical pool and protocol position manifests
```

Evidence:

- Commit: `b1b4727` (`feat(deploy): wire the Statics v4 liquidity stack`)
- Tests: `forge test --match-path test/deployment/DeployStatics.t.sol`
  (2 passed),
  `forge test --match-path test/deployment/ConfigureStaticsLiquidity.t.sol`
  (1 passed), and
  `forge test --match-path test/deployment/SelectorManifest.t.sol`
  (2 passed)

### [x] Prove combined accounting and complete security review

Dependencies: all implementation slices.

Implementation:

- Extend the existing accounting and unified protocol handlers with primary
  fee classification, hook settlement, POL epochs, LP fee collection,
  quarantine, exit-only unwind, and combined borrowing.
- Add handler actions for two baskets sharing a constituent and two pools
  sharing a currency.
- Track token balances at Diamond, hook, manager, PoolManager, treasury, users,
  and position owners.
- Prove backing, reservation, manager inventory, hook liability, POL isolation,
  LP-fee conservation, and user-allocation isolation invariants.
- Add reentrancy actors at hook, token, manager, and refund boundaries
  supported by the real interfaces. Verify the real PositionManager mint does
  not invoke an ERC-721 receiver callback, and reject inbound user NFT custody
  at the manager boundary.
- Add an end-to-end chain-4663 fork suite that deploys the completed Statics
  contracts into local fork state, binds them to Robinhood's deployed v4
  contracts, creates fork-local test baskets, and exercises canonical pool
  activation, hooked swaps, hook settlement, POL creation, LP fee compounding,
  user-owned liquidity, and exit-only unwind.
- Run the complete fork lifecycle against the pinned block with required mode
  enabled. The suite must not replace target contracts with local v4 mocks or
  report success through a skip.
- Run a focused security review using `audit`, then the independent pre-ship
  `qa` checklist. Resolve every confirmed finding before marking complete.
- Run the complete default and security-profile suites only after focused
  failures are resolved.

Required invariants:

```text
BasketToken supply is backed by vaultBalances at supply-aware requirements.
Diamond global reservations equal the sum of Diamond module reservations.
No POL reserve is holder claim, backing, debt principal, recovery, or revenue.
Hook balance or claims cover every per-pool hook liability.
Manager balances cover every per-basket POL inventory claim.
Persistent manager user inventory is always zero.
Protocol LP fees conserve exactly across 90% POL and 10% revenue.
Hook fees conserve exactly into terminal revenue after settlement.
One basket or pool cannot debit another isolated book sharing the same token.
Combined-path loan and mint accounting equals separate-path accounting.
User v4 NFTs are never recorded as protocol positions or PositionNFT legs.
Exit-only unwind cannot reduce backing owed to loose BasketTokens.
```

Verification:

```text
forge test --match-path test/invariant/LiquidityAccountingInvariant.t.sol
forge test --match-path test/invariant/UnifiedProtocolInvariant.t.sol
FOUNDRY_PROFILE=security forge test --match-path test/invariant/LiquidityAccountingInvariant.t.sol
ROBINHOOD_RPC_URL="$ROBINHOOD_RPC_URL" ROBINHOOD_FORK_BLOCK="$ROBINHOOD_FORK_BLOCK" \
REQUIRE_ROBINHOOD_FORK=true forge test \
--match-path test/liquidity/fork/RobinhoodStaticsLiquidityFork.t.sol -vvv
forge test --summary
FOUNDRY_PROFILE=security forge test --summary
npm test --prefix sdk
npm run build --prefix sdk
```

Acceptance evidence:

- All focused, complete, and security-profile suites pass with exact counts and
  invariant call totals recorded below.
- Both the deployment-compatibility and complete Statics liquidity fork suites
  pass against the recorded chain-4663 block with required mode enabled.
- Audit and QA findings are either fixed and regression tested or explicitly
  rejected with evidence; no confirmed issue remains open.
- Repository independence, naming, selector manifests, and dirty-worktree
  checks pass.

Proposed commit:

```text
test(liquidity): prove unified POL accounting

- Exercise hook, manager, Diamond, and v4 state in combined invariants
- Prove fee conservation and cross-basket custody isolation
- Record complete security and release verification evidence
```

Evidence:

- Implementation commit: `bc83e8e`
  (`test(liquidity): prove unified POL accounting`)
- Audit remediation commit: `59a8d6e`
  (`fix(liquidity): harden fee and deployment accounting`)
- Release-expectation commit: `00e7a96`
  (`test(deploy): align unified manifest expectations`)
- Default suite: `forge test --summary` passed 315 tests with zero failures.
  The generic run skipped three separately configured Base fork tests and the
  two Robinhood tests that require an RPC. Liquidity and unified invariants
  each passed 256 runs, 12,800 calls, and zero reverts per invariant.
- Security suite: `FOUNDRY_PROFILE=security forge test --summary` passed 315
  tests with zero failures. Liquidity and unified invariants each passed 128
  runs, 8,192 calls, and zero reverts per invariant.
- Required Robinhood fork: workspace-configured archive endpoint from the
  `ROBINHOOD_MAINNET` key in `../../.rpc` (credential not recorded), chain ID
  `4663`, block `14,498,238`, and `REQUIRE_ROBINHOOD_FORK=true`; both fork
  suites passed without skips (3 tests total).
- SDK: `npm test --prefix sdk` passed 19 tests and
  `npm run build --prefix sdk` passed.
- Deployment and independence: `forge test --match-path
  'test/deployment/*.t.sol'` passed 7 tests, including exact selector,
  configuration, full launch, CREATE2, and adjacent-repository checks.
- Audit: the focused checklist and static-analysis triage confirmed and fixed
  collection-frequency rounding leakage, cross-pool shared-currency hook
  insolvency, and production hook address prediction against the wrong
  CREATE2 deployer. Regression tests cover each correction. Reported generic
  `transferFrom`, initializer, native-value, and Diamond fallback candidates
  were rejected after caller, modifier, custody, and proxy-flow review.
- QA: the applicable protocol checks passed for Statics naming, SDK/build
  parity, exact manifests, repository independence, and dirty-worktree
  preservation. Frontend wallet, UI, and public contract-verification items
  are not applicable because this repository has no frontend and no public
  deployment was authorized or performed.

## Coverage matrix

| ADR requirement | Implemented by | Primary proof |
| --- | --- | --- |
| Three-way fee classification | Fee allocation slice | `BasketFeeAllocation.t.sol` |
| Per-basket/per-asset POL reserve | Fee allocation slice | `BasketFeeAllocation.t.sol` and invariants |
| Static fee on every canonical swap | Hook slice | `StaticsSwapFeeHook.t.sol` |
| No per-swap Diamond callback | Hook slice | Hook call-trace assertions |
| Canonical pool association | Pool lifecycle slice | `CanonicalPoolLifecycle.t.sol` |
| Price warm-up and deviation | Pool lifecycle slice | `CanonicalPoolOracle.t.sol` |
| Hook fees become 100% revenue | Hook settlement slice | `HookFeeSettlement.t.sol` |
| Exactly backed 50/50 POL construction | POL slice | `BasketLiquidityCompounding.t.sol` |
| One pool per constituent | Pool and POL slices | one/three/sixteen-asset real flows |
| Protocol LP fees split 90/10 | LP fee slice | `ProtocolLpFeeCompounding.t.sol` |
| No automatic mismatch swap | POL and LP fee slices | idle-inventory assertions |
| Once-per-24-hour permissionless epoch | POL slice | epoch timing real flows |
| Quarantine and exit-only handling | Decommissioning slice | `BasketLiquidityDecommission.t.sol` |
| Ordinary borrowing unchanged | Shared accounting slice | `LendingMintParity.t.sol` |
| Optional user-owned LP path | Combined action slice | `BorrowAndProvideLiquidity.t.sol` |
| User LP fees outside 90/10 | LP fee and combined slices | third-party/user fee collection flow |
| Shared-token isolation | Hook, manager, and invariants | location-aware solvency invariants |
| Robinhood v4 compatibility | Fork compatibility and final review slices | required chain-4663 fork suites |
| Deployment and indexability | SDK and deployment slices | manifest and SDK tests |

## Verification discipline

- Use `forge test --match-path ...` for the focused commands recorded per
  slice.
- Never run `forge clean`, `forge build --force`, or
  `forge build --contracts`.
- Use locally deployed real v4 contracts for deterministic unit and invariant
  flows. The Robinhood fork suite is an additional mandatory target-integration
  gate; neither test mode replaces the other.
- A normal developer run may report a Robinhood fork skip when no endpoint is
  configured. Completion evidence must set `REQUIRE_ROBINHOOD_FORK=true`, use
  the pinned block, and pass without a skip.
- Record the RPC provider category, fork block, chain ID, relevant runtime code
  hashes, and exact fork commands without recording an RPC credential.
- Keep fuzz runs at repository defaults during development and use the
  security profile for completion evidence.
- Review `git diff --check`, the staged diff, and `git status --short` before
  each commit.
- Stage only files belonging to the current slice. Preserve unrelated `.c`,
  `Statics-Design.md`, audit artifacts, and any later user work.
- After a slice lands, replace its pending evidence with the commit hash, exact
  test command, pass count, fuzz/invariant calls, and any justified skips.

## Completion criteria

This plan is complete only when:

- every slice is checked complete with a narrow commit and exact verification
  evidence;
- every unresolved calibration row is replaced by an accepted value and the
  deployment manifest reflects it;
- eligible primary fees conserve across holder, POL, and terminal revenue;
- the immutable hook charges every canonical swap identically and all hook
  liabilities are solvent by pool and currency;
- real local v4 flows prove initialization, swaps, protocol and user position
  creation, increases, fee collection, compounding, and removal;
- required Robinhood Chain fork suites pass on chain ID `4663` at the pinned
  block against the configured deployed v4 contracts, without a skip;
- protocol LP earnings conserve exactly across the fixed 90/10 split;
- one-, three-, and sixteen-asset baskets preserve exact backing and isolation;
- ordinary borrowing remains unchanged and the optional combined action is
  economically identical to its separate actions;
- quarantine, pause, and exit-only paths stop new exposure without trapping
  settlement, removal, redemption, repayment, or recovery;
- Diamond, hook, and manager location-aware solvency invariants pass under the
  security profile;
- SDK, events, documentation, selectors, deployment scripts, and manifests
  expose the same architecture and Statics terminology;
- no source, build, runtime, or deployment path depends on another repository;
- the completed audit and QA review has no unresolved confirmed finding;
- no unrelated dirty or untracked file has been committed; and
- no public deployment or external value-moving action has occurred without
  separate explicit authorization.

## Progress log

| Date | Slice | Status | Commit or evidence | Notes |
| --- | --- | --- | --- | --- |
| 2026-07-20 | Implementation tracker | Complete | `docs(liquidity): add POL implementation tracker` | ADR mapped to the live Statics architecture |
| 2026-07-20 | First-release calibration | Complete | `docs(liquidity): fix the initial POL calibration` | Protocol-wide first-release values accepted |
| 2026-07-20 | Dependency provenance and local v4 fixture | Complete | `build(uniswap): pin the local v4 integration stack` | Pinned deployed-compatible v4 lineage and real local lifecycle |
| 2026-07-20 | Robinhood v4 fork compatibility | Complete | `test(uniswap): verify Robinhood v4 deployment` | Required live v4 lifecycle passes at block 14,498,238 |
| 2026-07-20 | Three-way fee allocation | Complete | `feat(fees): add isolated basket liquidity reserves` | Exact 45/45/10 classification with isolated reserves |
| 2026-07-20 | Immutable swap-fee hook | Complete | `feat(hook): collect canonical basket swap revenue` | Caller-independent realized-output fee and isolated liabilities |
| 2026-07-20 | Canonical pool lifecycle | Complete | `feat(liquidity): establish canonical basket pools` | Fixed pool identity, bounded oracle, warm-up, and guardian pause |
| 2026-07-20 | Hook fee settlement | Complete | `feat(revenue): settle canonical swap fees` | Measured underlying receipts and supply-aware BasketToken burns become isolated revenue |
| 2026-07-20 | Typed liquidity manager | Complete | `feat(liquidity): add the typed v4 position manager` | Immutable bindings, typed v4 actions, isolated inventory, and direct user NFT ownership |
| 2026-07-20 | POL reserve compounding | Complete | `feat(liquidity): compound basket fees into POL` | Once-per-24-hour isolated reserve deployment |
| 2026-07-20 | Protocol LP fee compounding | Complete | `feat(liquidity): compound protocol LP fees` | Measured fixed 90/10 split |
| 2026-07-20 | POL decommissioning | Complete | `feat(liquidity): unwind POL for basket decommissioning` | Permissionless exit-only risk reduction |
| 2026-07-20 | Shared mint and lending accounting | Complete | `refactor(basket): share mint and loan accounting` | Ordinary-flow parity foundation |
| 2026-07-20 | Optional borrow-to-liquidity | Complete | `feat(lending): add optional borrow-to-liquidity` | User owns v4 NFTs directly |
| 2026-07-20 | SDK and protocol documentation | Complete | `feat(sdk): expose canonical liquidity workflows` | Stable ABI, math, events, and ownership documented |
| 2026-07-20 | Deployment and manifests | Complete | `feat(deploy): wire the Statics v4 liquidity stack` | Immutable deployments and timelocked installation; no broadcast |
| 2026-07-20 | Unified invariants and security review | Complete | `bc83e8e`, `59a8d6e`, `00e7a96` | Full default/security suites, required Robinhood forks, SDK, audit, and QA pass |

## Atomic basket-launch extension

The final launch gap is closed by making canonical market creation inseparable
from basket genesis. This extension supersedes every earlier tracker statement
that describes a separately initialized or manager-synced canonical pool.

The clean-break public creation call accepts the basket definition, one
semantic constituent-per-BasketToken square-root price and paired-asset amount
per constituent, and one complete constituent input cap. It atomically:

1. deploys the BasketToken;
2. registers and initializes every canonical pool;
3. registers every PoolKey with the installed manager;
4. mints the aggregate pool BasketTokens through ordinary backing and fee
   accounting;
5. pulls each creator-funded paired constituent amount; and
6. locks every full-range position through one hook unlock.

The owner uses the same call and provides the same assets when public creation
is closed. There is no separate administrative bootstrap, empty basket state,
standalone pool initializer, or standalone manager-sync action.

| Date | Slice | Status | Commit or evidence | Notes |
| --- | --- | --- | --- | --- |
| 2026-07-28 | Batch hook seeding | Complete | `7cd7758` | One Diamond-authorized unlock settles shared currencies once and preserves pending POL |
| 2026-07-28 | Atomic basket launch | Complete | `7473748` | Creation initializes, registers, backs, and permanently seeds every pool |
| 2026-07-28 | Launch stress coverage | Complete | `e34d02b` | Immediate swap, 16 pools, 1,000-run price fuzz, and complete rollback |
| 2026-07-28 | SDK clean break | Complete | `89be05e` | New creation calldata and events; obsolete initializer and sync builders removed |
| 2026-07-28 | Documentation | Complete | `bca11b9` | Design, integration, architecture, deployment, and ADR surfaces aligned |
| 2026-07-28 | Final audit and suite | Complete | `fad6286`, `0bb428c` | Launch limits, price bounds, selector visibility, genesis flow, and seeded baselines remediated |

Focused evidence:

- `forge test --match-path test/liquidity/AtomicBasketLaunch.t.sol` passes 6/6,
  including 1,000 fuzz runs, sender-extra debit rejection, and usable
  full-range price-bound rejection.
- `forge test --match-path 'test/liquidity/*.t.sol'` passes 144/144 with three
  expected environment-gated fork skips.
- `forge test --match-path 'test/invariant/*.t.sol'` passes all 12 invariants at
  256 runs and 12,800 calls per invariant.
- Both required Robinhood Chain fork suites pass without skips at pinned block
  `14,498,238` with `REQUIRE_ROBINHOOD_FORK=true`.
- `npm test --prefix sdk` passes 32/32 and `npm run build --prefix sdk` passes.
- `forge test --summary` and `FOUNDRY_PROFILE=security forge test --summary`
  each pass 432/432 with seven expected environment-gated skips. The security
  profile runs invariants with `fail_on_revert=true` for 128 runs and 8,192
  calls per invariant.
- `forge build --sizes` reports production runtime sizes of 22,726 bytes for
  `BasketFacet` and 20,928 bytes for `BasketLiquidityFacet`. Its nonzero exit is
  caused only by the intentionally monolithic `StaticsTestDeployer` test
  harness exceeding EIP-170.

The implementation review and Aderyn-assisted scan identified no unresolved
critical or high-severity launch finding. Remediation added an execution
deadline, measured the creator's complete aggregate constituent debit, bounded
prices to the usable tick-spacing-10 full range, removed Diamond-only launch
helpers from the public ERC-165 interface, and proved owner-only genesis
through the ordinary timelock-funded creator flow. Full-suite qualification
also updated stale zero-supply and zero-fee baselines to account for permanent
launch liquidity and the ordinary launch mint fee. This is implementation
review evidence, not a substitute for an independent external audit.
