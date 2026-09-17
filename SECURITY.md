# Statics security model

Statics holds user assets. The standalone Genesis release is deployed on
Robinhood Chain with source-verified contracts; the Phase 1 DEX-and-staking
Diamond and later selector phases remain subject to independent review before
production use. The repository test suite is not an external audit. The
repository also records a public Robinhood Chain testnet integration beta.

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
remain blocked. Per-token transient custody deficits represent only reserved
principal temporarily outside the Diamond; loaned unreserved balance remains
unavailable for new reservations. Repayment must restore raw physical backing
before the deficit clears and flash fees accrue. This design requires
Cancun/EIP-1153. The PositionNFT uses
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
separate ERC-1155 operator approval. Successful transition finalization
irreversibly freezes ordinary transfers for the predecessor's recoverable
series ID so a holder cannot reshuffle an expired full-balance recovery; Core
mint and burn operations, including direct Core recombination, remain available
for runoff and successor rollover. A series retired directly with its profile
remains transferable and ordinary-recombinable via Core (and the gateway for
profile 1) during runoff.

## Authority

- Phase 1 deploys one `StaticsTimelock` as owner of `StaticsDiamond`. Later
  phases retain that Diamond and add only their reviewed selector and
  initializer delta. The fresh full-stack reference uses the same ownership
  model for both `StaticsDiamond` and `StaticsDollarCoreDiamond`. The delay
  initializes to 24 hours on production chains and can change only through a
  scheduled timelock call to the timelock itself.
- The configured multisig is the timelock proposer and, under OpenZeppelin's
  proposer-role initialization, a canceller. Execution is open after the
  current delay. The emergency guardian is also an explicit timelock canceller,
  allowing it to veto a pending operation without gaining proposal or execution
  authority.
- In Phase 1 the guardian can pause liquidity, treasury distribution, and
  global staking ingress and can stop all Statics-hook swaps or quarantine one
  registered protocol pool. It cannot unpause actions, restore swaps, release a
  pool quarantine, or change configuration. Additional pause and lifecycle
  paths become reachable only when their later-phase selectors are installed.
- The governance Safe and guardian may be the same address, but doing so removes
  independence between the proposal and emergency-veto roles. A compromise or
  availability failure then affects both authorities.
- Timelocked governance can upgrade either Diamond, manage basket-level global
  settings and pauses, restore swaps, release quarantine, and mark baskets
  `ExitOnly`.
- The Dollar profile guardian can perform only the emergency actions exposed by
  Dollar Core governance. Core configuration derives directly from the Core
  Diamond owner, which is the same timelock; there is no second protocol
  governor or internal proposal queue.
- Dollar redemption fees are capped at 1,000 basis points independently from
  mint fees, and redemption rejects raw-unit rounding that would produce zero
  collateral output.
- Dollar Core binds to the freeze-capable `STATICS_DOLLAR_RISK_V1` token kind.
  Deploy the Risk Shares token, Core, and `StaticsDiamond` as one coordinated
  stack. Per-series transfer freezes preserve Core minting and burning so users
  can always roll predecessor claims into the active successor series.
- Insurance top-ups accept non-retired profiles. Pegged top-ups become
  immediately redeemable profile collateral; volatile top-ups remain
  profile-level transition reserve through `ReduceOnly`. Unassigned volatile
  reserve is not current solvency backing and cannot authorize issuance.
  Retirement first flushes pending periphery insurance, then assigns reserve to
  a live current series only when it is the profile's sole senior generation;
  otherwise it routes the non-claimant reserve globally without blocking
  retirement. Fixed historical recovery books never gain later reserve.
- Anyone may trigger global treasury fee distribution, but the recipient is
  fixed to the configured treasury. Dollar insurance and opt-in routing remain
  governed by their isolated Dollar books; eligible Dollar fees can also enter
  the global fee ledger.
- A standalone launch hook additionally permits the Safe holding its owner's
  existing timelock proposer role to register a new pool immediately. Initial
  pool terms are therefore established before trading begins without waiting
  for the delay. Later hook-fee and fee-receiver changes remain owner-only and
  must execute through the timelock.

Diamond ownership uses immediate ERC-173 transfer by the current owner. A
governance migration must execute through the timelock and verify Diamond
owners, guardian roles, and treasury configuration after execution. The
already deployed standalone Genesis contracts and their existing authorities
are outside the phased Diamond launch. No Phase 1 deployment or configuration
ceremony calls them, transfers their ownership, or changes their bindings.

## Staged production surface

The Phase 1 launcher installs 18 facets and 122 selectors for the Diamond
kernel, public general Statics-hook pools, a separate permissioned venue path,
protocol revenue and public POL, PositionNFT, reward restrictions, and global
STATICS staking/reward opt-ins. Permissioned pools use their own hook,
creator-bound controller, trusted exact-input router, and non-transferable LP
positions. They create no Statics POL. It does not install or advertise basket,
credit, flash-loan, Genesis-integration, Dollar, Morpho, `StaticsLiquidityManager`,
BorrowLiquidity, ERC-1155 receiver, or series-migration interfaces.

The general-pool creation fee is fixed to zero at Phase 1 deployment. Under the
protocol's existing creation semantics, zero retains owner-only curation; it
does not open free permissionless creation. The launch does not add TVL,
position-notional, volume, or pool-count caps. Curated creation, timelocked
administration, guardian stops, monitoring, and asset disclosure are the
accepted initial controls. They reduce exposure but do not create a
protocol-level endorsement of curated assets.

The reward-restriction map is a technical delivery policy, not an asset
allowlist or legal classification. The guardian may add a restriction
immediately; only the timelock may remove one. Existing earned claims and exit
paths remain available. For permissioned pools, creator and treasury revenue
remain in the original output currency. If both currencies are restricted, the
pool-specific allocation is overridden with an 80% creator / 20% treasury
split and no reward liability.

Phase 2 adds baskets, self-secured credit, flash composition, and advanced
liquidity; Phase 3 adds Statics Dollar; Phase 4 adds Morpho. All four selector
deltas and one-time initializers exist now and derive from one canonical plan.
CI proves staged-to-fresh selector and runtime parity for both Diamonds, and
later-phase preparation rejects drifted earlier facet bytecode. Every live
transition still requires its own review and timelocked execution.

## Economic and liveness assumptions

Holding a BasketToken in a wallet does not earn basket-specific fees. Deposited
BasketTokens, including collateral locked for a basket loan, enter the isolated
basket reward denominator. Global rewards separately require staking the
deployment-configured ERC-20 in a PositionNFT. Position owners or approved
operators must claim rewards through transactions; nothing runs in the
background. A guardian staking pause blocks new global stake and reward-asset
opt-ins. It does not block unstaking, reward-asset opt-outs, reward claims, or
Position closure. Undeployed global stake has no cooldown, but stake
supplied to Morpho must first be recalled. Initial stake, reward-asset
selections, and top-ups mature through a per-asset hourly ring no earlier than
24 hours after scheduling. Basket collateral uses the same delayed hourly
eligibility model, but unlocked and undeployed shares have no separate
withdrawal-time gate. Fee and position interactions roll due buckets. Dollar passive Risk Share reward
eligibility does not exist: supplied Risk Shares are immediately consumable by
the pairing vault and earn only through actual consumption.

Permanent protocol pools use a creator-selected static native LP fee from 0
through 999,999 pips, plus separate governed input/output hook fees. Dynamic
fees and the 100% static-fee boundary are rejected.
Their permanent full-range liquidity is owned by the hook, not by a protocol
PositionManager NFT, and cannot be released until the pool is decommissioned.
User PositionManager NFTs stay in user custody and earn native v4 fees through
standard pool accounting. Native fees earned by hook-owned permanent liquidity
route only to treasury and never become compoundable POL inventory. Basket
creation initializes and seeds its canonical pools atomically. General-pool
creation registers and initializes the pool but does not require a liquidity
seed: it is owner-only while the creation fee is zero and permissionless with
exact payment while the fee is nonzero. The bilateral default initializes to
25 BPS per leg. Governance may change the global default and set or clear
registered PoolId overrides; creators cannot administer hook fees or allocation
profiles. Governance also controls the creation gate and irreversible
general-pool decommissioning.
Permanent-liquidity compounding and eligible post-decommission unwind are
permissionless.

Basket loans have no price-oracle liquidation. Their debt is the proportional
constituent vector and their LTV cannot exceed 95%. Repayment is open in every
basket lifecycle state. Recovery becomes permissionless after maturity plus
one hour. The recovery caller receives 20% of configured penalty backing, while
the remaining 80% enters the protocol fee route; principal is not paid to the
caller.

`ExitOnly` preserves redemption, repayment, recovery, and treasury claims in
the installed facets. Timelocked Diamond upgradeability means governance can
still replace those rules.

Shared Diamond kernel code built from this source recomputes the standard
IERC-165, IDiamondCut, IDiamondLoupe, and IERC-173 declarations from final
selector routing after every successful cut, including after its initializer.
The invalid `0xffffffff` interface ID always remains false. Protocol-specific
interface declarations remain governed metadata, while the generic metadata
setter rejects the four selector-derived standard IDs. Deployment and
governance tests verify selector counts and routing self-consistency; an
independently maintained release manifest remains necessary for exact
expected-set review.
Recorded runtime hashes remain offchain release metadata rather than live
dispatch controls.
