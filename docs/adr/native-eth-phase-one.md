# Native ETH in Phase 1 public pools

Status: accepted for the initial Phase 1 deployment.

Public pools admit `Currency.wrap(address(0))` as currency0 and an ERC-20 as
currency1. They retain the complete public pool, PositionManager NFT, managed LP,
range-gauge, allocation, direct reward, and managed POL lifecycles. Static v4 LP
fees remain valid from 0 through 999,999 pips. Permissioned venues and basket
constituent admission retain their existing policies.

## Pool assets and rewards

ETH remains native for pool principal, managed LP principal, user LP fees, POL
inventory, POL positions, deposits, withdrawals, refunds, and rebalances. Custody
uses address(0) in the existing reservation mappings and backs it with the
Diamond's physical ETH balance. Each PoolId has its own POL reservation.

At the reward boundary ETH has the WETH accounting identity before eligibility,
indexing, or any existing reward math. A single WETH opt-in earns both WETH and
ETH hook revenue. Swaps retain native PoolManager claims; they do not wrap ETH.
Lazy settlement redeems an exact native receipt and deposits precisely that
amount into the already configured WETH contract before funding the existing
ERC-20 book. WETH-source claims fund that same book first, followed by native
claims for the remaining amount. Creator, basket-staker, Treasury, and
maintenance-tip proceeds follow the same boundary.

POL hook allocations stay native claims and settle into native POL reservations.
POL LP fees retain the existing Treasury classification: verify both currency
receipts, then wrap the native fee receipt. Harvest precedes principal mutation.
Operator POL position actions temporarily block swaps in that PoolId during token
callbacks, so new LP fees cannot accrue between harvest and principal accounting.
The transaction-local block does not affect other pools or ordinary swaps after
the action finishes.
Final general-pool decommission explicitly classifies the remaining POL inventory
as Treasury revenue, wrapping only that released native reservation. This does
not authorize wrapping principal while it remains POL inventory.

Pool creation, POL activation, and PositionNFT creation fees continue their
existing exact native payment and Treasury forwarding policies.

## Native settlement and custody

Native LP input entrypoints are payable and require exactly the native amount0
maximum. ERC-20 pools require zero msg.value. Rebalances reconcile only the
additional native input; exited native principal is reused separately. The
manager forwards the authorized native budget in PositionManager
`modifyLiquidities{value: ...}` and sweeps the unused budget back. Failed native
refunds and outputs revert the complete operation.

The Diamond receive path admits configured WETH and one transiently authorized
settlement sender. The PoolManager is authorized only while native hook claims
are being redeemed. The originating liquidity manager is authorized only while
it returns native POL or rebalance proceeds. The manager admits native ETH only
from its PoolManager or PositionManager during a native periphery operation.
Native sends remain inside the existing shared reentrancy guards.

PositionManager SWEEP returns its whole ETH balance. An existing periphery
surplus is excluded from operation movement and retained as unallocated manager
ETH, with `PositionManagerNativeSurplusRetained` evidence. It cannot increase a
user refund or a POL reservation. Forced ETH remains unallocated in both custody
and manager accounting.

## Configuration and compatibility

The public hook binds the existing canonical WETH address immutably. Deployment
and configuration verify that the PositionManager and hook agree on WETH.
There is no WETH setter, new reward book, storage migration, or native pool mode.
No Diamond selectors or interface IDs change. `provideLiquidity`,
`increaseLiquidity`, and `rebalanceLiquidity` become payable, as do the manager's
three input methods. The hook constructor gains its immutable WETH argument and
getter. Range topology and ERC-20 gauge reward admission remain unchanged.

```text
native v4 currency
        │
        ├── LP / POL path → remains ETH
        │
        └── reward path   → wraps to WETH → existing reward accounting
```
