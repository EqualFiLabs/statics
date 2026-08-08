# ADR: Governed Uniswap v4 protocol pools

- Status: Accepted and implemented
- Date: 2026-08-06
- Scope: Statics pool registration, permanent liquidity, fee routing, LP rewards,
  governance, indexing, and upgrade compatibility

## Context

Before this decision, Statics created one canonical Uniswap v4 pool for every
basket constituent during atomic basket creation. Each pool uses the installed
`StaticsSwapFeeHook`, has zero native v4 LP fee, uses tick spacing 10, launches
with creator-funded full-range permanent liquidity, and is associated with one
`basketId` and one constituent asset.

The hook is already less basket-specific than the Diamond integration around
it. Only `StaticsDiamond` may register a hook pool. Registration accepts any
two non-native currencies with zero native LP fee, and the hook independently
tracks pool fee overrides, fee inventory, permanent liquidity, and
decommissioned state by `PoolId`.

The remaining protocol surfaces were basket-specific:

- pool creation is only reachable as an internal step of basket creation;
- Diamond pool identity is stored as `basketId + constituent`;
- swap-fee delivery requires a basket canonical-pool association;
- LP staking requires an active associated basket; and
- `StaticsLiquidityManager` validates positions through a
  `basketId + constituent` key.

Governance needs to be able to initialize a Statics-hook v4 pool between any
two compatible ERC-20 assets, supply its initial liquidity, and make it
participate in Statics permanent-liquidity, LP-reward, global-reward, and
treasury accounting without pretending that the pool belongs to a basket.

## Decision

Statics will recognize two classes of registered protocol pool:

1. **Basket canonical pool**: the existing BasketToken/constituent pool tied to
   one basket and one constituent.
2. **Governance pool**: a governance-created pool between two compatible
   ERC-20 assets with no basket association.

Governance pools use the same installed PoolManager, PositionManager, hook,
permanent-liquidity mechanics, full-range LP-reward accounting, and
PositionNFT authorization model as basket canonical pools. A governance pool
does not acquire basket backing, basket rewards, basket lending, collateral,
oracle, or asset-admission semantics merely because one of its currencies is a
BasketToken, Statics Dollar, or another protocol asset.

Pool creation and initial permanent-liquidity funding are atomic. The pool is
active and swappable when the governance execution succeeds. There is no
warmup, TWAP requirement, activation transaction, or oracle validation of the
governance-selected initial price.

## Objectives

- Allow the Diamond owner, expected to be the governance timelock, to create a
  Statics protocol pool between any two compatible ERC-20 assets.
- Let governance name a separate payer that has approved the Diamond, so the
  governance authority and liquidity funder do not need to be the same
  account.
- Initialize and permanently seed the pool in one all-or-nothing execution.
- Preserve the existing fixed Statics PoolKey policy: installed hook, zero
  native v4 LP fee, tick spacing 10, and full-range permanent liquidity.
- Route swaps through the existing bilateral hook-fee policy.
- Allow full-range external PositionManager NFTs for the pool to be staked
  under a Statics PositionNFT and earn the configured LP allocation.
- Preserve existing basket pool, borrowing, reward, and ExitOnly behavior.
- Deliver the feature through a Diamond upgrade without changing the
  StaticsDiamond, PoolManager, PositionManager, hook, or Eves integration
  addresses.
- Emit sufficient events for Ponder to enumerate and present pools without an
  unbounded onchain pool array.

## Non-goals

- Permissionless creation or registration of arbitrary pools.
- Arbitrary hooks, native v4 LP fees, tick spacings, concentrated initial
  ranges, or dynamic-fee PoolKeys.
- Native ETH pools. WETH is used when an ETH-denominated asset is required.
- Support for fee-on-transfer, rebasing, callback-mutating, or otherwise
  balance-incompatible tokens.
- Treating a registered pool, its spot price, or its liquidity as an oracle.
- Automatically admitting a currency as Dollar collateral, basket
  constituent, borrowable asset, reward selection, or any other risk-bearing
  protocol role.
- Attaching generic pools to basket borrowing or basket-staker rewards.
- Automatically operating, rebalancing, activating, or decommissioning pools.
- Replacing Uniswap v4 routing, PositionManager NFTs, or the existing Statics
  hook with a custom AMM or LP token.
- Onchain search, sorting, or unbounded enumeration of every registered pool.

## Terminology

- **Protocol pool**: a PoolKey recognized by the Diamond as either basket
  canonical or governance-created and registered with the Statics hook.
- **Basket canonical pool**: a protocol pool associated with one basket and one
  constituent through the existing canonical-pool storage.
- **Governance pool**: a protocol pool stored in the governance-pool registry
  with no basket association.
- **Permanent liquidity**: hook-owned full-range liquidity that cannot be
  removed while the pool is active and can only be released after
  decommissioning.
- **User LP position**: a Uniswap v4 PositionManager NFT. It remains external
  unless its owner explicitly stakes it under a Statics PositionNFT.
- **Active pool**: a registered and initialized protocol pool that the hook has
  not decommissioned.
- **Decommissioned pool**: a pool for which the hook rejects new swaps and new
  permanent-liquidity compounding and whose permanent liquidity has been
  released through the appropriate lifecycle path.

## Pool classes and capabilities

| Capability | Basket canonical pool | Governance pool |
| --- | --- | --- |
| Statics hook registration and bilateral fees | Yes | Yes |
| Hook-owned full-range permanent liquidity | Yes | Yes |
| Fee-funded permanent-liquidity compounding | Yes | Yes |
| Full-range staked LP rewards | Yes | Yes |
| Per-pool fee configuration | Yes | Yes |
| Global Statics-staker rewards | Eligible selected stake required | Eligible selected stake required |
| Treasury accrual | Yes | Yes |
| Basket-staker rewards | Associated basket only | No; allocation redirects to permanent liquidity |
| Basket lending and borrow-to-liquidity | Yes | No |
| Basket ExitOnly unwind and BasketToken burn | Yes | No |
| Governance decommission and treasury recovery | No | Yes |

The pool class is explicit state. Sentinel values such as `basketId == 0`
cannot identify a governance pool because basket zero is valid.

## Protocol pool resolution

The upgrade will preserve the existing canonical pool storage and add an
isolated governance-pool storage namespace. A normalized resolver presents
both sources as protocol pools:

```solidity
enum ProtocolPoolKind {
    None,
    BasketCanonical,
    Governance
}

struct GovernancePool {
    PoolKey key;
    bool registered;
}

struct ProtocolPoolView {
    PoolId poolId;
    PoolKey key;
    ProtocolPoolKind kind;
    bool decommissioned;
    uint256 basketId;
    address basketAsset;
    uint128 permanentLiquidity;
}
```

Resolution follows these rules:

1. If the existing `poolAssociations[poolId]` entry is associated, the pool is
   `BasketCanonical` and its PoolKey comes from the existing canonical mapping.
2. Otherwise, if the governance-pool registry contains the PoolId, the pool is
   `Governance` and its PoolKey comes from that registry.
3. Otherwise, the PoolId is not a Statics protocol pool.

A PoolId may belong to exactly one class. Both basket pool creation and
governance pool creation must reject a PoolId already claimed by either class.
This virtual registry avoids copying or migrating existing canonical-pool
storage and gives every new consumer one normalized lookup surface.

## Fixed PoolKey policy

Governance chooses the two tokens and initial price. Statics determines the
PoolKey:

```solidity
PoolKey({
    currency0: Currency.wrap(min(tokenA, tokenB)),
    currency1: Currency.wrap(max(tokenA, tokenB)),
    fee: 0,
    tickSpacing: 10,
    hooks: IHooks(installedStaticsHook)
})
```

The tokens must be distinct, nonzero contract addresses. Native currency is
not supported. The PoolManager remains responsible for its ordinary PoolKey
and initialization validation.

Governance supplies `sqrtPriceBPerAX96`, defined as:

```text
sqrt(raw tokenB units / raw tokenA units) * 2^96
```

The Diamond converts this value into the sorted PoolKey orientation, including
inversion when token ordering requires it. Prices are expressed in raw token
units; tooling must account for token decimals when presenting human prices.
The converted v4 `sqrtPriceX96` must remain strictly inside the usable
full-range tick boundaries.

## Governance pool creation interface

The intended external surface is:

```solidity
struct CreateGovernancePoolParams {
    address tokenA;
    address tokenB;
    uint160 sqrtPriceBPerAX96;
    uint256 amountAMax;
    uint256 amountBMax;
    uint128 minLiquidity;
    address payer;
    uint256 deadline;
}

function quoteGovernancePool(CreateGovernancePoolParams calldata params)
    external
    view
    returns (
        PoolKey memory key,
        PoolId poolId,
        uint160 sqrtPriceX96,
        uint128 liquidity,
        uint256 amountA,
        uint256 amountB
    );

function createGovernancePool(CreateGovernancePoolParams calldata params)
    external
    returns (
        PoolId poolId,
        uint128 liquidity,
        uint256 amountA,
        uint256 amountB
    );
```

`createGovernancePool` is owner-only, nonreentrant, and subject to the existing
liquidity pause. In production, `msg.sender` is the governance timelock. The
`payer` may be the timelock, treasury, proposer, or another account that has
approved the Diamond for both assets.

`quoteGovernancePool` performs the deterministic token, price, PoolKey, and
liquidity calculations. It does not promise that the payer's future balance,
allowance, or deadline will remain valid through timelock execution.

`amountAMax` and `amountBMax` are hard debit ceilings, not desired exact
amounts. Statics calculates the greatest full-range liquidity supported by
both ceilings at the governance-selected initial price, computes the exact
required token amounts, and rejects zero-sided or zero-liquidity seeds.
`minLiquidity` protects the proposal against an unexpectedly small result.

## Atomic creation sequence

A successful governance execution performs the following transition in one
transaction:

1. Enforce Diamond ownership, the liquidity pause, deadline, payer, token,
   price, and amount constraints.
2. Construct the fixed PoolKey and calculate the PoolId, sorted initial price,
   full-range ticks, maximum supported liquidity, and required token amounts.
3. Reject an existing basket association, governance registration, or hook
   registration for the PoolId.
4. Pull the exact required amount of each token from `payer` using the shared
   custody transfer path and observed balance deltas. Funding therefore occurs
   before the new pool can be called through PoolManager.
5. Record the governance pool in Diamond storage.
6. Register the PoolKey with `StaticsSwapFeeHook`.
7. Initialize the PoolKey through Uniswap v4 PoolManager.
8. Grant transaction-scoped exact approvals to the hook.
9. Seed the calculated full-range permanent liquidity through the hook.
10. Verify observed payer debits, Diamond debits, hook allowances, PoolManager
    settlement, and resulting locked liquidity.
11. Clear any remaining temporary approvals and emit the creation event.

Any failure reverts registration, PoolManager initialization, token movement,
and permanent-liquidity accounting together. There is no initialized-but-
unseeded protocol-pool state.

Hook registration precedes PoolManager initialization because the hook's
`afterInitialize` callback rejects unregistered PoolIds. Only the Diamond can
register, so a third party cannot pre-initialize the predictable Statics
PoolKey between governance proposal and execution.

The pool is active immediately after the transaction. Governance is
responsible for the initial price and funding decision. Arbitrage, not a
protocol activation or TWAP ceremony, is expected to reconcile the live AMM
price with external markets.

The Diamond liquidity pause prevents new governance-pool creation and new
managed LP actions. It does not intercept ordinary swaps submitted directly to
PoolManager. The supported terminal mechanism for stopping swaps through the
Statics hook is pool decommissioning.

## Creation event

The Diamond emits one authoritative event after successful initialization and
seeding:

```solidity
event GovernancePoolCreated(
    PoolId indexed poolId,
    address indexed tokenA,
    address indexed tokenB,
    address payer,
    address currency0,
    address currency1,
    uint160 sqrtPriceX96,
    int24 tick,
    uint128 liquidity,
    uint256 amountA,
    uint256 amountB
);
```

The hook and PoolManager continue emitting their native registration,
initialization, settlement, and liquidity events. Indexers use the Diamond
event to classify the pool as governance-created.

## Fee routing

Governance pools use the existing global hook configuration unless governance
sets a PoolId-specific override. Generic entrypoints expose the same fee
configuration by PoolId:

```solidity
function setProtocolPoolFeeConfiguration(PoolId poolId, SwapFeeConfiguration calldata configuration) external;
function clearProtocolPoolFeeConfiguration(PoolId poolId) external;
function protocolPoolFeeConfiguration(PoolId poolId) external view returns (PoolFeeConfigurationView memory);
```

These write functions are owner-only. Existing basket-specific fee functions
remain supported and delegate to the same PoolId configuration.

For each realized swap leg, the hook applies the configured bilateral fee and
allocates it as follows:

- The permanent-liquidity share remains in the hook's pool-local inventory.
- The LP share enters the pool's LP reward indexes only when the pool has
  eligible activated staked liquidity; otherwise it redirects to permanent
  liquidity.
- A governance pool can never accrue basket-staker rewards. Its configured
  basket share redirects to permanent liquidity before fee delivery.
- The global Statics-staker share enters the currency's global reward book only
  when that currency has eligible selected stake; otherwise it redirects to
  permanent liquidity.
- The treasury share enters the shared fee reservation and currency-specific
  treasury accounting.

The existing hook calls the selector currently named
`routeCanonicalSwapFees`. To preserve the deployed hook, the Diamond retains
that selector but generalizes its implementation to resolve any protocol pool.
The legacy name is an implementation compatibility detail and does not limit
the new semantics.

The route rejects a nonzero basket-staker amount for a governance pool as a
defense-in-depth assertion. Under the supported hook, the amount has already
been redirected to permanent liquidity.

Matched pool-local permanent-liquidity inventory compounds during ordinary
swap execution through the existing hook. No keeper or scheduled maintenance
call is introduced.

## User LP positions and PositionNFTs

Any user may mint a Uniswap v4 PositionManager NFT for an active protocol pool
through ordinary v4 tooling. An external LP NFT receives no Statics hook LP
allocation until it is explicitly staked under a Statics PositionNFT.

Governance-pool staking follows the existing custody rules:

- the caller controls the PositionNFT;
- the PositionNFT owner also owns the PositionManager NFT;
- the PositionManager NFT belongs to the exact active registered PoolKey;
- the position has nonzero full-range liquidity and no subscriber; and
- staking transfers the PositionManager NFT into Diamond custody.

The one-block activation rule, independent pool/currency indexes, claims,
immediate unstaking, and crystallized reward behavior remain unchanged. Basket
canonical staking additionally requires an active associated basket.
Governance-pool staking has no basket-status check because no basket exists.

A governance-pool LP position remains a PositionNFT leg for custody,
authorization, transfer, increase, reward, claim, and exit purposes. It does
not create a lending leg or make its currencies borrowable.

After governance-pool decommissioning:

- new staking, activation, increases, and fee accrual are prohibited;
- previously earned rewards remain claimable; and
- users may unstake and recover their PositionManager NFTs without governance
  assistance.

## Generic liquidity manager

The current immutable `StaticsLiquidityManager` validates a PoolKey through
`basketId + constituent`. A replacement manager will validate by PoolId against
the Diamond's normalized protocol-pool resolver.

The replacement request removes basket-only identifiers:

```solidity
struct PositionRequest {
    PoolKey poolKey;
    int24 tickLower;
    int24 tickUpper;
    uint256 liquidity;
    uint256 amount0Limit;
    uint256 amount1Limit;
    uint256 deadline;
}
```

The manager remains non-upgradeable and immutable-bound to the Diamond,
PositionManager, PoolManager, and Permit2. Only the Diamond may call it. Before
each PositionManager action it verifies that the supplied PoolKey hash matches
the active Diamond record for its PoolId.

The manager continues to:

- accept only typed mint or increase actions;
- impose exact per-currency maximums and deadlines;
- use transaction-scoped ERC-20 and Permit2 approvals;
- clear allowances after use;
- measure actual token movements;
- refund unused assets to the named receiver;
- verify the resulting PositionManager NFT owner; and
- retain no intended token balance between operations.

Basket borrow-to-liquidity paths resolve the basket canonical PoolKey in the
Diamond before calling the same generic manager. Pool registration alone never
enables a governance pool for basket borrowing.

## Governed manager replacement

The Diamond adds an owner-only manager replacement operation rather than a
second one-shot installation path:

```solidity
function replaceLiquidityManager(address newManager) external;
```

Replacement verifies that the new manager is a contract and that its immutable
Diamond, PositionManager, PoolManager, and Permit2 bindings exactly match the
installed integration. It revokes the old manager's PositionManager operator
approval before approving the new manager and updating storage. It emits both
addresses:

```solidity
event LiquidityManagerReplaced(address indexed oldManager, address indexed newManager);
```

The current manager accepts calls only from the Diamond, but revocation is
still required to minimize obsolete authority. Existing staked
PositionManager NFTs remain owned by the Diamond and require no custody
migration.

## Governance-pool decommissioning

Governance pools have an explicit owner-only terminal transition:

```solidity
function decommissionGovernancePool(PoolId poolId)
    external
    returns (uint256 amount0, uint256 amount1);
```

The function is available even while liquidity actions are paused. It:

1. requires an active governance pool;
2. marks the pool decommissioned in the hook, causing later swaps to revert;
3. releases the hook's full-range permanent liquidity and unmatched pool-local
   fee inventory to the Diamond;
4. measures the exact received currency amounts;
5. reserves both amounts in the shared fee account;
6. accrues both amounts to currency-specific treasury accounting; and
7. emits the released amounts.

```solidity
event GovernancePoolDecommissioned(
    PoolId indexed poolId,
    address indexed currency0,
    address indexed currency1,
    uint256 amount0,
    uint256 amount1
);
```

Decommissioning is irreversible. A Uniswap v4 pool cannot be deleted, and the
same PoolKey cannot be initialized again. A future replacement market would
require an explicitly different supported PoolKey policy or hook deployment;
this ADR does not add a reactivation or replacement-pool mechanism.

Basket canonical pools retain their existing separate ExitOnly unwind. That
path burns released BasketTokens, reduces backing and reservations
proportionally, and routes released constituent value according to basket
accounting. Governance-pool decommissioning must never invoke BasketToken burn
or backing reduction.

## State transitions and callers

```text
Absent
  └── governance timelock: createGovernancePool with funded payer
        └── Active
              ├── swaps: any router/user; fees and matched POL compound in-hook
              ├── stake/increase/activate: authorized users or permissionless activation
              ├── claim/unstake: authorized PositionNFT controller
              └── governance timelock: decommissionGovernancePool
                    └── Decommissioned
                          ├── claim: authorized PositionNFT controller
                          └── unstake: authorized PositionNFT controller
```

Nothing depends on an automatic background action:

- Pool creation and decommissioning happen only after governance execution.
- Fee allocation and compounding are driven by swaps.
- LP activation is permissionless; a position that nobody activates simply
  remains ineligible and earns nothing.
- Claims and exits are called by the users entitled to the assets.

## Views and indexing

The Diamond exposes bounded point lookups:

```solidity
function protocolPool(PoolId poolId) external view returns (ProtocolPoolView memory);
function isProtocolPool(PoolId poolId) external view returns (bool);
```

Existing `canonicalPool(basketId, asset)` and basket-specific views remain
available. They return only basket canonical pools.

The Diamond does not store an append-only array solely for frontend discovery.
Ponder indexes:

- existing `CanonicalPoolInitialized` events as `BasketCanonical`;
- new `GovernancePoolCreated` events as `Governance`;
- per-pool fee configuration changes;
- hook permanent-liquidity and fee events;
- LP stake, activation, increase, settlement, claim, and exit events; and
- both basket and governance decommission events.

The Statics app reads the indexed pool list and confirms action-sensitive pool
state through Diamond and PoolManager views at the receipt block after every
transaction.

## Compatibility and upgrade approach

The intended release is an in-place Statics upgrade:

- keep the current StaticsDiamond address;
- keep the current PoolManager, PositionManager, Permit2, and
  `StaticsSwapFeeHook` addresses;
- add governance-pool storage and normalized pool views;
- update basket creation to reject collisions with governance pools;
- generalize LP staking and hook fee delivery to normalized protocol pools;
- deploy the generic immutable liquidity manager;
- replace the installed manager through the timelock-controlled setter; and
- update selectors, interfaces, SDK bindings, deployment verification, Ponder,
  and frontend configuration.

Existing canonical-pool records remain in their current storage namespace and
are resolved directly; no bulk storage migration is required. Existing hook
registrations, permanent liquidity, reward books, staked LP records, claims,
and BasketToken accounting remain in place.

Because the StaticsDiamond and PositionNFT address do not change, Eves Market
does not require a contract redeployment or integration-address update for this
feature. Deployment documentation changes only after the governed upgrade and
live verification execute.

## Security and trust boundaries

- Governance controls which pairs receive Statics protocol-pool status, the
  initial price, seed maxima, fee overrides, and terminal decommissioning.
- The payer controls whether governance can consume its assets through balance
  and allowance. Revocation or insufficient funding causes the entire delayed
  governance execution to revert.
- Pool registration is not token endorsement. UIs must distinguish registered
  market availability from protocol risk approval.
- Pool spot and TWAP values are never trusted for Dollar health, basket
  backing, lending, liquidation, or collateral valuation under this ADR.
- Exact balance-delta accounting rejects incompatible inbound and outbound
  token behavior rather than silently socializing a shortfall.
- Temporary hook, ERC-20, PositionManager, and Permit2 approvals must be zero
  after successful value-moving calls.
- Governance creation must not expose arbitrary PoolManager, PositionManager,
  hook-data, callback, or router execution.
- User PositionManager NFTs are never seized or burned during pool
  decommissioning.
- Shared custody reservations must cover LP claims, global rewards, and
  treasury liabilities independently of hook-held permanent liquidity.
- A governance pool involving a BasketToken or Statics Dollar does not gain
  access to their backing or Core custody.

## Required invariants

1. A PoolId belongs to at most one protocol-pool class.
2. Every protocol-pool record hashes to the exact PoolKey registered with the
   hook and initialized in PoolManager.
3. Every governance pool uses two distinct non-native ERC-20 addresses, the
   installed hook, zero native LP fee, and tick spacing 10.
4. Successful governance creation ends with nonzero full-range permanent
   liquidity and no initialized-but-unseeded state.
5. Observed payer debits never exceed the corresponding maxima.
6. Incompatible transfers revert the complete pool-creation transaction.
7. Hook-held balances cover all pool-local permanent-liquidity inventory.
8. Diamond fee reservations cover all LP, global reward, and treasury
   liabilities after routed fees.
9. Governance pools never accrue basket-staker rewards or enter basket lending.
10. LP reward currency identities exactly match the registered PoolKey.
11. Liquidity-manager actions cannot target an unregistered, mismatched, or
    decommissioned PoolKey.
12. Manager replacement leaves the old manager unapproved and the new manager
    approved, with no PositionManager NFT ownership change.
13. Governance-pool decommissioning cannot debit basket backing or user LP
    liquidity.
14. Existing basket canonical creation, fee routing, borrowing, rewards, and
    ExitOnly unwind remain behaviorally unchanged.

## Consequences

- Statics gains a governed liquidity layer for protocol-relevant ERC-20 pairs
  without broadening basket or Dollar risk admission.
- The shared hook and fee flywheel can support pools that are useful to Statics
  but do not naturally correspond to a basket constituent.
- Governance assumes explicit responsibility for initial pricing, seed assets,
  fee policy, and irreversible decommissioning.
- External LPs must opt into PositionNFT custody to receive Statics hook LP
  rewards; zero native v4 LP fee means an unstaked LP receives no native pool
  fee under this PoolKey policy.
- The generic manager removes basket-only identity from typed v4 liquidity
  execution while preserving narrow authority and exact accounting.
- Event indexing, rather than an unbounded onchain array, becomes the discovery
  source for governance pools.
- The current hook-facing fee route retains a legacy name to avoid a disruptive
  hook and PoolKey migration.
