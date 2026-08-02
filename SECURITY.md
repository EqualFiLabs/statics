# Statics security model

Statics holds user assets and should not carry production value before
independent review, testnet operation, and verified contract publication. The
repository test suite and internal review are not an external audit. No public
deployment is recorded in this repository.

## Permissionless constituent risk

There is no asset registry. A basket creator can select arbitrary ERC-20
addresses, and users decide whether that basket and its constituents are worth
using. Paying the native creation fee is not a compatibility certification.

Internal accounting is isolated by module, basket ID, and asset. Direct token
donations are unallocated and cannot inflate a basket's recorded backing or
global reward reserve. Shared physical custody additionally records both
`globalReservedByToken[token]` and module-local reservations.

Every custody operation measures balance deltas:

- inbound transfers credit the actual increase in the Diamond's balance, then
  the calling flow checks the minimum economic amount it requires;
- outbound transfers authorize a maximum debit from one named reservation and
  revert if the Diamond spends more; and
- the receiver's observed increase is checked separately against the caller's
  minimum-output bound where one is supplied.

This accounts for ordinary fee-on-transfer behavior without allowing a
sender-extra-charge transfer to debit physical tokens reserved for another
book. It does not make every token safe. Negative rebases, arbitrary burns from
the Diamond, deceptive `balanceOf` results, blocklists, transfer pauses, or
hostile callbacks can halt or damage baskets using that token. Because multiple
baskets may hold one token at the same physical address, token behavior that
changes the Diamond's balance outside a checked transfer can create a
token-wide physical shortfall. Internal books do not socialize the loss or
promise an exit order; discovery systems and user interfaces should surface
constituent behavior and basket reputation.

The Diamond accepts native currency for payable basket creation and the typed
Statics Dollar ETH gateway. Its receive hook accepts ETH only from the
configured WETH contract during an unwrap. Native currency can still be
force-sent at the EVM level and is not used as an internal accounting source.

## Custody and execution

Statics Dollar Core collateral remains physically held by
`StaticsDollarCoreDiamond`, outside the shared Diamond. Dollar periphery books,
basket backing, basket debt, global fees, staking custody, and recovery surplus
use separate namespaced ledgers even when they reference the same token or
PositionNFT. For each token, the Diamond's global reservation is the sum of its
Dollar, fee, staking, and per-basket account reservations.

Ordinary ERC-20/ERC-1155 custody-mutating facets on `StaticsDiamond` use the
same OpenZeppelin `ReentrancyGuard` namespaced storage slot under delegatecall.
`FlashLoanFacet` instead uses OpenZeppelin's transient guard and acquires the
persistent slot only during disbursement and repayment. Its callback can
therefore use ordinary basket mint and redemption, while nested flash loans
remain blocked. This design requires Cancun/EIP-1153. The PositionNFT uses
OpenZeppelin's constructorless ERC-721 implementation for the same reason; it
does not introduce a UUPS, transparent, beacon, or ERC-1967 proxy. EIP-2535
Diamond cuts remain the sole implementation upgrade mechanism.

Deployment manifests record facet runtime hashes as offchain release evidence.
The Diamond does not enforce those hashes at dispatch or inspect facet bytecode;
standard owner-controlled EIP-2535 cuts are the upgrade boundary. Reviewers and
deployment tooling must verify every proposed facet and initializer.

Statics Dollar uses OpenZeppelin EIP-2612 permit. A permit expresses only an
ERC-20 allowance and can be submitted by anyone; it is not proof of intent for
a particular series, receiver, or minimum output. The permit recombination
entrypoints fix the owner to `msg.sender`, spender to `StaticsDiamond`, and
value to the Dollar amount consumed. They tolerate a pre-submitted permit but
still require the subsequent `transferFrom` to succeed. Exit availability is
checkpointed before permit execution, and any later failure rolls back the
permit with the rest of the transaction. Series risk shares remain governed by
separate ERC-1155 operator approval.

## Authority

- One `StaticsTimelock` owns both `StaticsDiamond` and
  `StaticsDollarCoreDiamond`. Its delay initializes to seven days and can change
  only through a scheduled timelock call to the timelock itself.
- The configured multisig is the timelock proposer and canceller. Execution is
  open after the current delay. The emergency guardian is not a timelock
  canceller and cannot veto its own governed rotation.
- The basket guardian can pause minting, borrowing, extension, and flash loans
  and quarantine an active basket. It cannot unpause actions, release a
  quarantine, decommission a basket, or pause redemption.
- Timelocked governance can upgrade either Diamond, manage basket-level global
  settings and pauses, release quarantine, and mark baskets `ExitOnly`.
- The Dollar profile guardian can perform only the emergency actions exposed by
  Dollar Core governance. Core configuration derives directly from the Core
  Diamond owner, which is the same timelock; there is no second protocol
  governor or internal proposal queue.
- Anyone may trigger global treasury fee distribution, but the recipient is
  fixed to the configured treasury. Dollar insurance and opt-in routing remain
  governed by their isolated Dollar books; eligible Dollar fees can also enter
  the global fee ledger.

Diamond ownership uses immediate ERC-173 transfer by the current owner. A
governance migration must execute through the timelock and verify both Diamond
owners, the guardian roles, and the treasury after execution.

## Economic and liveness assumptions

BasketToken ownership and basket collateral do not earn basket-specific fees.
Global rewards require staking the deployment-configured ERC-20 in a
PositionNFT. Position owners or approved operators must claim rewards through
transactions; nothing runs in the background. Global stake is always
withdrawable, but initial stake, reward-asset selections, and top-ups mature
through a per-asset hourly ring no earlier than 24 hours after scheduling. Fee
and position interactions roll due buckets. A newly deposited
basket-collateral leg cannot withdraw until the next block. Dollar passive Risk
Share reward eligibility uses its separate 24-hour gate.

Canonical pools use zero native LP fee and separate input/output hook fees.
Their permanent full-range liquidity is owned by the hook, not by a protocol
PositionManager NFT, and cannot be released until the pool is decommissioned.
Full-range user PositionManager NFTs may be voluntarily held by the Diamond to
earn a separate LP hook allocation. New and increased liquidity waits one block
for eligibility but has no withdrawal cooldown; exit settles claims before
returning the NFT. If an LP or global-staker hook allocation cannot be routed,
it redirects to permanent liquidity. Governance controls pool initialization and activation; checkpoint,
manager sync, manual compounding, and post-`ExitOnly` unwind are permissionless.

Basket loans have no price-oracle liquidation. Their debt is the proportional
constituent vector and their LTV cannot exceed 95%. Repayment is open in every
basket lifecycle state. Recovery becomes permissionless after maturity plus
one hour and currently pays no caller bounty, so keepers must have an external
reason to execute it.

`ExitOnly` preserves redemption, repayment, recovery, and treasury claims in
the installed facets. Timelocked Diamond upgradeability means governance can
still replace those rules.

Interface-changing cuts must keep selector routing and ERC-165 declarations in
sync. The deployment and governance tests verify exact live selector manifests;
recorded runtime hashes remain offchain release metadata rather than live
dispatch controls.
