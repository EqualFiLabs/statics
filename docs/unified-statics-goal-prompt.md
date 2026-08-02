# Unified Statics `/goal` Prompt

Paste the following into an interactive Codex session opened at the Statics
repository root. The goal objective is intentionally concise and points to the
implementation tracker for the complete instructions and completion criteria.

```text
/goal Complete the unified Statics protocol implementation described in docs/unified-statics-implementation-plan.md and governed by docs/adr/position-fee-index-and-bounded-looping.md. Work through every unchecked slice in order, update the tracker with status, commit, and verification evidence after each slice, and continue until every completion criterion is satisfied.

Keep this repository as the canonical source. Use ../market-ui/ether-dollar only as a read-only reference pinned to commit 017064ec8188c7f3d120fb9588f88d01925e45f1; import its tracked source locally and never symlink to it or create a build/runtime dependency on it. Preserve unrelated dirty and untracked files in both repositories.

Implement one user-facing StaticsDiamond with PositionNFT ERC-721 facets, shared position authorization, shared physical-token reservations, and a common OpenZeppelin reentrancy guard. Keep StaticsDollarCoreDiamond as the separate Dollar collateral, issuance, health, insurance, and recovery backend. Preserve isolated namespaced Dollar, basket, reward, debt, and solvency books. Do not add a token registry, ERC-4626 basket semantics, cross-product collateralization, shared reward denominators, V1 compatibility branches, or arbitrary execution surfaces.

Rebrand Ether Dollar as Statics Dollar. Preserve the live Dollar behavior while moving its periphery onto shared positions. Implement permissionless isolated static baskets, tiered static mint/redemption fees, indexed multi-asset position rewards, permit-enabled BasketTokens, flash loans, exit-only decommissioning, and position-owned proportional lending capped at 95% LTV. Use measured token balance deltas and module-local plus global reservation accounting. Replace the blanket periphery recombination fee exemption with an explicit pairing/managed path; ordinary direct and gateway recombination must have identical economics.

Follow AGENTS.md and ETHSKILLS.md. Use OpenZeppelin implementations instead of custom token or reentrancy primitives. Add real-flow tests for every value-moving lifecycle, focused tests for each slice, and combined fuzz/invariant coverage. Never use forge clean or forced build commands. Commit each slice narrowly with the Conventional Commit message recorded in the tracker. Do not include unrelated files in any commit.

The goal is complete only when all tracker slices contain commit and test evidence, the complete Foundry suite and security-profile invariants pass, deployment and selector manifests verify the unified architecture, no path depends on the old repository, active code and docs consistently use Statics Dollar terminology, and no required implementation work remains. Do not perform a public deployment or external value-moving action without separate explicit authorization. If a deferred product decision blocks one slice, record the blocker and continue every independent slice that can be completed safely.
```

Goal mode keeps the objective attached to the active chat. Continue in the same
chat to steer the work or request status. Use `/goal pause`, `/goal resume`,
`/goal edit`, or `/goal clear` when needed.
