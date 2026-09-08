# Launch-liquidity hook verification

This ledger covers the standalone `StaticsLaunchLiquidityHook` and the ordinary
Uniswap v4 PositionManager positions used with its registered pools. It does not
claim that external token contracts, PoolManager, PositionManager, price choice,
tick-range choice, or an offchain liquidity strategy are formally verified.

## Reproduction

Run the focused executable suites locally. The adversarial profile expands the
campaigns to 10,000 fuzz cases and 1,024 invariant runs of 100 calls each:

```sh
FOUNDRY_PROFILE=adversarial forge test --match-path test/liquidity/StaticsLaunchLiquidityHookAdversarial.t.sol -vv
FOUNDRY_PROFILE=adversarial forge test --match-path test/liquidity/LaunchLiquidityRangeTraversal.t.sol -vv
FOUNDRY_PROFILE=adversarial forge test --match-path test/liquidity/LaunchLiquidityInvariant.t.sol -vv
FOUNDRY_PROFILE=adversarial forge test --match-path test/liquidity/LaunchLiquidityPositionInvariant.t.sol -vv
forge test --match-path test/liquidity/LaunchLiquidityPositionManager.t.sol -vv
forge test --match-path test/deployment/DeployStaticsLaunchLiquidity.t.sol -vv
forge test --match-path test/deployment/PrepareStaticsLiquidityOperations.t.sol -vv
```

With `ROBINHOOD_MAINNET` configured, reproduce the block-pinned Safe rehearsal:

```sh
REQUIRE_ROBINHOOD_FORK=true forge test \
  --match-path test/liquidity/fork/RobinhoodSafeManagedLaunchLiquidityFork.t.sol -vv
```

The rehearsal pins block `47,690,599` and verifies hash
`0x4ca3ce6b00d4603804be596b721c738caf54c2a08515f84a8ca020f33613837b`
before executing against that state. Without a configured RPC, this local-only
fork proof compiles and skips.

Run the symbolic hook properties with Halmos 0.3.3:

```sh
scripts/run-formal.sh launch-liquidity
```

On a configured Certora host with `solc8.33` and `CERTORAKEY` available:

```sh
scripts/run-certora.sh launch-liquidity
```

Latest exact-candidate Certora report:
https://prover.certora.com/output/8471858/09a9c4b18cc64543aac06459079d92f2

The scheduled security workflow runs the fuzz and invariant suites at 10,000
fuzz cases, 1,024 invariant runs, 100 calls per run, and fail-on-revert enabled.

## Property ledger

| Property | Evidence |
| --- | --- |
| Exact-input specified fees are `ceil(grossInput * feeBps / 10,000)`; exact-output specified fees are `ceil(netOutput * feeBps / (10,000 - feeBps))` | Halmos over symbolic `uint120` amounts and valid fee rates; 10,000-case Foundry fuzz over amounts bounded to half of `int128.max` |
| Exact-input unspecified fees are a fraction of raw pool output; exact-output unspecified fees are grossed up from core input so each configured rate is consistently a fraction of the trader's gross leg | Four Halmos properties over symbolic `uint64` amounts covering both directions and exactness modes; 10,000-case Foundry fuzz over amounts bounded to half of `int128.max` and signed deltas |
| Every successful fee route mints PoolManager ERC-6909 claims to the current receiver without invoking either currency contract or requiring pre-existing counterasset reserves | Halmos claim-balance assertions, hostile-token adversarial tests, and the first-converting-swap PositionManager regression |
| A swap must completely fill its specified amount after the before-swap fee adjustment; incomplete price-limit or liquidity fills revert atomically and retain no claims | Halmos over both directions and exactness modes; mock atomic-rollback regression; real PoolManager exact-capacity search proving maximum succeeds while maximum plus one reverts with price, tick, active liquidity, fee growth, token balances, claims, and NFT liquidity unchanged |
| Per-pool fee changes remain bounded and isolated; receiver rotation preserves every pool registration | Halmos with two PoolKeys; Certora invariant/rule; two-pool stateful invariant |
| Only PoolManager may enter callbacks; only the owner or an account holding the owner's current timelock proposer role may register pools; only the owner may change fees or rotate the receiver; ownership cannot be renounced | Halmos over symbolic callers and proposer membership using the production hook; Certora for fee/receiver authorization and ownership; real TimelockController integration for initial and revoked proposers; fail-on-revert stateful invariant |
| Production deployment starts with a 24-hour delay; fee and receiver changes fail immediately and at 24 hours minus one second, then succeed at maturity through the open executor | Deployment regression against `StaticsTimelock` and a composed real PositionManager lifecycle under a 24-hour TimelockController |
| Initialization succeeds only through the bound PositionManager at the registered price; swaps remain disabled until the registered launch operator or owner permanently activates the pool | Halmos, Certora, adversarial unit tests, and real PoolManager lifecycle tests |
| PoolManager, PositionManager, the hook, known system sinks, and zero cannot become unsafe launch-position recipients; initial liquidity fits the signed PositionManager delta | Deployment validation tests |
| Stable deployment artifacts contain no expiring PositionManager transaction; a separate preparation script emits fresh initialize-and-mint, mint-only fallback, and activation calldata | Deployment and artifact regression tests |
| Pool-launch tooling accepts STATICS-only, paired-token-only, and two-sided funding, calculates liquidity from amount caps, and emits reusable registration, initialization, mint, and activation calls | Deployment validation and real PoolManager execution tests |
| Additional-position and existing-position tooling mints independent ranges and emits working increase, partial decrease, fee collection, and full exit-and-burn calls without affecting another position | Real PoolManager/PositionManager lifecycle test |
| A claim owner can authorize the stateless redeemer to burn claims and send underlying currency to any nonzero recipient without leaving helper custody | Real PoolManager redemption regression |
| Across receiver changes and partial redemptions, cumulative claims minted always equal outstanding claims plus redeemed underlying for each receiver and currency | 1,024-run stateful campaign with 102,400 actions and zero handler reverts |
| The hook never owns PositionManager NFTs or pool assets | Real PoolManager/PositionManager stateful invariant and adversarial custody assertions |
| Multiple ordinary positions can coexist, increase, decrease, collect, transfer, fully exit, burn, and remint without changing fee routing or disabling a pool that retains liquidity | Real PoolManager/PositionManager lifecycle tests and a four-range stateful invariant covering narrow, broad, and both one-sided shapes with exact-input and exact-output swaps |
| Liquidity owned by an unrelated LP remains unchanged under managed-position action sequences | Real PositionManager stateful invariant with a sentinel external position |
| Existing Robinhood governance and operations Safes can register, launch, own, manage, and redeem a hooked pool without exposing owner private keys | Block-pinned fork rehearsal using both 2-of-2 Safes, approved-hash signatures in sorted-owner order, Safe `execTransaction`, and deployed MultiSend |
| STATICS-only, paired-token-only, and two-sided launches all settle correctly through the deployed PositionManager and Permit2 | Three separate PoolKeys in the block-pinned fork rehearsal, followed by 256 swaps equally split across direction and exactness modes, at least $100,000 illustrative notional, and a Safe-managed liquidity change every 32 swaps |
| Deployed Robinhood Quoter and Universal Router remain compatible with the launch hook | Block-pinned quotes for all four swap modes on all three PoolKeys and a routed Safe-owned exact-input execution through the deployed Universal Router |

## Proof boundaries

- The Halmos harness bypasses hook-address flag validation so symbolic deployment
  does not depend on CREATE address mining. Production deployment and unit tests
  validate the actual permission bits.
- The symbolic proposer model supplies deterministic `hasRole` state around the
  production hook. The real OpenZeppelin role grant, self-administered revocation,
  scheduling, maturity, and open execution paths are exercised in integration
  tests rather than reimplemented in the symbolic model.
- The before-swap theorem covers symbolic direction and exactness. Four bounded
  post-swap theorems separately cover every direction and exactness branch so
  packed signed-delta branching remains tractable.
- Fee settlement mints PoolManager claims and therefore does not call token
  transfer code. Hostile ERC-20 behaviors are exercised to confirm they cannot
  reenter fee configuration or alter claim accounting during a swap callback.
- Position lifecycle evidence executes the pinned real Uniswap v4 contracts. It
  verifies integration behavior but is not a formal proof of those dependencies.
- Fork balances are supplied synthetically. Token approvals, Permit2 allowances,
  PositionManager settlement, Safe execution, swaps, fee claims, and redemption
  still execute against the pinned deployed contracts.
- The hook, Halmos test, Certora harness, and deployment script are compiled with
  solc 0.8.33 for launch verification; ordinary project tests retain their
  source-selected compiler versions.
- None of these checks proves that a chosen price or concentrated range is
  economically appropriate or that an offchain manager will act profitably.
- These checks materially strengthen machine-verifiable assurance but do not
  substitute for an independent review or prove the absence of all defects.
