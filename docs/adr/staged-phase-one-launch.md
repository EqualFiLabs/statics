# ADR: Staged Statics protocol launch

- Status: Accepted
- Date: 2026-09-16
- Scope: production Diamond composition, emergency authority, Genesis ownership, and release sequencing

## Decision

Statics will launch the multi-asset protocol in two independently reviewed phases. The standalone
Genesis launch is already deployed; the Statics Diamond is not. Phase 1 therefore uses a fresh,
minimal Diamond composition instead of preserving selectors for features that have never been
deployed.

Phase 1 includes:

- basket creation, minting, redemption, lifecycle, rewards, and canonical liquidity;
- global STATICS staking and selected-asset rewards;
- PositionNFT accounts and self-secured basket credit;
- basket-vector and single-asset flash loans plus the flash-arbitrage receiver surface;
- general Statics-hook pools, protocol fee routing, and permanent liquidity;
- Genesis Operator linking, rewards, recovery, and the existing standalone Genesis contracts; and
- custody, governance, loupe, ownership, and Diamond upgrade infrastructure required by those flows.

Phase 2 adds the separate Statics Dollar Core, USDstx and Risk Shares, the Dollar gateway and risk
liquidity flows, Morpho integration, and advanced borrow-to-liquidity flows. The existing
`DeployStatics.s.sol` remains the canonical fresh-deployment reference for the full composition.
Extending a live Phase 1 Diamond will require a separately reviewed timelocked facet-addition and
initialization ceremony; that future Phase 2 operation is not part of this launch.

`DeployStaticsPhaseOne.s.sol` installs 25 facets and 204 selectors. It does not install or advertise
the BorrowLiquidity, Dollar, Morpho, ERC-1155 receiver, or series-migration interfaces. A PositionNFT
without a Morpho account can close without the Morpho view facet, so the excluded integration does
not become an accidental Phase 1 dependency.

## Curated launch without economic caps

Both basket creation and general-pool creation initialize with an exact native creation fee of zero.
Under the existing Statics semantics, zero does not mean free permissionless creation: it restricts
creation to the Diamond owner. Governance can curate the initial asset and pool surface through the
timelock.

The deployment does not add TVL, per-basket issuance, position-notional, flash-loan-notional,
borrow-notional, or pool-count caps. Those limits would constrain legitimate protocol revenue and
composability while providing only a partial substitute for review. The accepted mitigation is
curated creation, delayed upgrades and configuration, emergency stop authority, public monitoring,
and explicit asset-risk disclosure.

## Authority and emergency controls

The Phase 1 `StaticsTimelock` starts with its chain-specific delay, the governance Safe as proposer,
open execution after the delay, and the guardian as an explicit canceller. Open execution does not
bypass the delay or proposer authorization.

The guardian may only reduce exposure. It can:

- pause new mint, borrow, extension, flash, liquidity, treasury-distribution, and staking ingress;
- quarantine an active basket;
- stop all Statics-hook swaps or isolate one registered protocol pool; and
- cancel a pending timelock operation.

Only the timelock owner can restore paused actions, release basket or pool quarantine, decommission a
basket, change configuration, or upgrade the Diamond. Redemption, collateral withdrawal, unstaking,
Genesis unlinking, repayment, and recovery remain available while staking ingress is paused.

The governance Safe and guardian may be the same address. This is operationally simpler but removes
independent veto separation: compromise or unavailability affects both proposal and emergency roles.
Using distinct authorities remains preferable when the operational setup can support it.

## Genesis ownership migration

The five mutable Genesis contracts are currently owned by the launch governance Safe through
OpenZeppelin `Ownable2Step`:

- `StaticsFeeReceiver`;
- `GenesisActivationRegistry`;
- `StaticsGenesisVault`;
- `StaticsGenesis` (Operators NFT); and
- `GenesisLaunchDistributor`.

`ConfigureStaticsGenesisGovernance.s.sol` builds a read-only six-call Safe proposal. The first five
calls nominate the Phase 1 timelock as pending owner; the sixth schedules one timelocked batch in
which the timelock accepts all five ownership transfers. The tool requires exact runtime hashes,
current Safe ownership, empty pending-owner slots, the expected proposer role, a nonzero delay, open
execution, and unique targets. Acceptance is atomic after the delay.

`StaticsTreasuryVesting.recipientAdmin` is immutable and remains the launch governance Safe. This is
an intentional exception: the deployed contract has no ownership transfer or admin-rotation path,
and changing it would require replacing an already-live immutable custody commitment.

## Verification boundary

Focused Foundry tests prove the exact Phase 1 selector and interface manifest, configuration values,
timelock roles, excluded Phase 2 routes, Position closure without Morpho, liquidity dependency
bindings, emergency stop/restore authority, and the atomic Genesis migration ceremony.

The `phase-one` Halmos target separately checks stop authority, restoration asymmetry, pool isolation,
stake-versus-redeem pause separation, flash reservation capacity, exact flash repayment, and
underpayment rejection. Slither already classifies every owned production Solidity source under
`src/` and every production ceremony under `script/`; both new scripts are therefore in the mandatory
scope without adding an exclusion.

These controls reduce incident blast radius but do not replace an external audit. Phase 2 requires a
separate release decision and review of its larger oracle, solvency, liquidation, and external-market
surface.
