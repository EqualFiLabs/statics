# ETHSKILLS

Use the local Ethereum skills before changing Solidity. Start with `ship`, then
load only the skills relevant to the current slice.

## Required routing

- Architecture and state machines: `ship`, `concepts`
- ERC-20 and Permit behavior: `standards`
- Basket, flash-loan, and lending composition: `building-blocks`
- External addresses or deployments: `addresses`
- Value-moving Solidity: `security`
- Unit, fuzz, integration, and invariant coverage: `testing`
- Finished-contract review: `audit`, followed by `qa`

Load the canonical public skill entrypoints from
`https://ethskills.com/<name>/SKILL.md`.

## Statics rules

- Say **onchain**, not "on-chain".
- Never guess or hardcode deployment addresses; use deployment configuration
  and verify live addresses before production use.
- Use OpenZeppelin ERC-20, Permit, SafeERC20, math, and timelock primitives.
- Statics is a custom multi-asset protocol, not ERC-4626.
- Use exact balance deltas for inbound assets and reject incompatible token
  behavior.
- Every maintenance transition must name its caller and liveness assumption.
- Every value-moving lifecycle needs real-flow coverage plus fuzz or invariant
  coverage where arithmetic or state ordering matters.
