# AGENTS.md

## Project Identity and Boundaries

This repository is **Statics**, a standalone multi-asset basket, fee, flash-loan,
and self-backed lending protocol.

- Use **Statics** in contracts, interfaces, events, documentation, deployment
  artifacts, SDKs, and commit messages.
- EqualIndex in `../EdenFi` is behavioral reference material only. Do not use
  EqualIndex as the new protocol name.
- Do not modify EqualFi or EdenFi as part of Statics work unless the user
  explicitly expands the scope.
- Preserve the single-address integration model: protocol actions and custody
  live behind the upgradeable `StaticsDiamond`; each basket still has its own
  ERC-20 token address for transfers and external liquidity.
- Statics is purpose-built for multi-asset baskets. Do not force its core
  minting or redemption model into ERC-4626.

## Naming Constraint

Do not use `Task`, `Task (n)`, `Task 1`, or similar task-number language in
file names, function names, test names, or commit messages.

## Solidity Guidance

Refer to `ETHSKILLS.md` before writing or changing Solidity. Select and load the
relevant skill described there, then apply it to the change.

## Compiling and Testing

- Do not run `forge build --force`, `forge build --contracts`, or `forge clean`.
- Prefer focused verification with
  `forge test --match-path path/to/test/File.t.sol`.
- All code changes must include tests proving the behavior.

### Compiler Profiles

- The default profile compiles without IR (`via_ir` is intentionally absent).
  Do not reintroduce global IR; add codegen-resilient patterns instead.
- Scoped IR exceptions exist only for third-party contracts that fail legacy
  codegen (PositionManager, nested permit2) — see `compilation_restrictions`
  in `foundry.toml`. Each entry must keep its justification comment.
- Coverage runs disable the optimizer, so bytecode-size assertions cannot hold
  under instrumentation. Exclude them explicitly:

  ```sh
  forge coverage --report lcov --no-match-test \
    "testCanonicalLauncherCreatesOnlyDeployableContracts|test_PositionFacetRetainsEip170Headroom"
  ```

### Test Fidelity Guardrails

Keep the test pyramid balanced:

- Use unit harness tests for narrow branches, storage checks, and otherwise
  unreachable state-machine edges.
- Use live integration or launch-level tests for every value-moving lifecycle.
- Use invariant and fuzz suites to broaden state-machine coverage, not to
  replace live-flow proofs.
- Prefer real approvals, transfers, mints, redemptions, borrows, repayments,
  extensions, recoveries, flash loans, governance calls, and treasury claims.

If a synthetic shortcut is necessary, keep it narrow and document the concrete
reason in the test. Appropriate reasons include:

- storage or library smoke coverage
- unreachable failure branches requiring deliberately corrupted accounting
- state transitions that are impractical to reach economically during setup

Synthetic harness coverage does not count as end-to-end confidence. Every
value-moving behavior must also have at least one real-flow or launch-level
regression.

## Commit Discipline

- Commit implementation in narrow, reviewable slices.
- Stage only files belonging to the current slice; preserve unrelated dirty or
  untracked work.
- Use Conventional Commits with a title of at most 72 characters.
- Do not mention tasks, task numbers, or marking tasks complete.
- Use present-tense bullet points in the body explaining what changed and why.

Format commit messages as:

```text
feat(scope): short summary

- Key change detail
- Another change
- Rationale or context
```

When handing work back in chat, include the proposed or used commit message in
a fenced text block using the same format.

## Compiler-Resilience Rule for Test Harnesses

When editing or adding external/public helper functions in large test harnesses,
especially harnesses inheriting many facets, prefer:

- `uint256` for external/public numeric parameters
- explicit bounds checks before narrowing
- internal casts to `uint16`, `uint8`, or other narrow types at assignment
  boundaries

Example:

```solidity
function setLtv(uint256 ltvBps) external {
    if (ltvBps > type(uint16).max) revert();
    cfg.ltvBps = uint16(ltvBps);
}
```

Apply this proactively when broad harnesses or narrow ABI parameters cause
stack-depth or Yul compiler failures. Do not change production ABI widths when
compatibility matters; decompose the function or reduce local stack pressure
instead.
