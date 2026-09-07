# Launch-liquidity hook verification

This ledger covers the standalone `StaticsLaunchLiquidityHook` and the ordinary
Uniswap v4 PositionManager positions used with its registered pools. It does not
claim that external token contracts, PoolManager, PositionManager, price choice,
tick-range choice, or an offchain liquidity strategy are formally verified.

## Reproduction

Run the focused executable suites locally:

```sh
forge test --match-path test/liquidity/StaticsLaunchLiquidityHookAdversarial.t.sol -vv
FOUNDRY_PROFILE=security forge test --match-path test/liquidity/LaunchLiquidityInvariant.t.sol -vv
FOUNDRY_PROFILE=security forge test --match-path test/liquidity/LaunchLiquidityPositionInvariant.t.sol -vv
forge test --match-path test/liquidity/LaunchLiquidityPositionManager.t.sol -vv
forge test --match-path test/deployment/DeployStaticsLaunchLiquidity.t.sol -vv
```

Run the symbolic hook properties with Halmos 0.3.3:

```sh
scripts/run-formal.sh launch-liquidity
```

On a configured Certora host with `solc8.33` and `CERTORAKEY` available:

```sh
scripts/run-certora.sh launch-liquidity
```

The scheduled security workflow runs the fuzz and invariant suites at 10,000
fuzz cases, 1,024 invariant runs, 100 calls per run, and fail-on-revert enabled.

## Property ledger

| Property | Evidence |
| --- | --- |
| Exact-input specified fees are `ceil(grossInput * feeBps / 10,000)`; exact-output specified fees are `ceil(netOutput * feeBps / (10,000 - feeBps))` | Halmos over symbolic `uint120` amounts and valid fee rates; full-width Foundry fuzz |
| Exact-input unspecified fees are a fraction of raw pool output; exact-output unspecified fees are grossed up from core input so each configured rate is consistently a fraction of the trader's gross leg | Halmos representative exact-input path over symbolic `uint64` amounts; full-width Foundry fuzz covers both directions, exactness modes, and signed deltas |
| Every successful fee route mints PoolManager ERC-6909 claims to the current receiver without invoking either currency contract or requiring pre-existing counterasset reserves | Halmos claim-balance assertions, hostile-token adversarial tests, and the first-converting-swap PositionManager regression |
| A swap must completely fill its specified amount after the before-swap fee adjustment; incomplete price-limit or liquidity fills revert atomically and retain no claims | Halmos rejection-before-unspecified-claim property, mock atomic-rollback regression, and real PoolManager partial-fill regression |
| Per-pool fee changes remain bounded and isolated; receiver rotation preserves every pool registration | Halmos with two PoolKeys; Certora invariant/rule; two-pool stateful invariant |
| Only PoolManager may enter callbacks; only the owner may register pools, change fees, or rotate the receiver; ownership cannot be renounced | Halmos, Certora, adversarial unit tests, and fail-on-revert stateful invariant |
| Initialization succeeds only through the bound PositionManager at the registered price; swaps remain disabled until the registered launch operator or owner permanently activates the pool | Halmos, Certora, adversarial unit tests, and real PoolManager lifecycle tests |
| PoolManager, PositionManager, the hook, known system sinks, and zero cannot become unsafe launch-position recipients; initial liquidity fits the signed PositionManager delta | Deployment validation tests |
| Stable deployment artifacts contain no expiring PositionManager transaction; a separate preparation script emits fresh initialize-and-mint, mint-only fallback, and activation calldata | Deployment and artifact regression tests |
| A claim owner can authorize the stateless redeemer to burn claims and send underlying currency to any nonzero recipient without leaving helper custody | Real PoolManager redemption regression |
| The hook never owns PositionManager NFTs or pool assets | Real PoolManager/PositionManager stateful invariant and adversarial custody assertions |
| Multiple ordinary positions can coexist, increase, decrease, collect, transfer, fully exit, and burn without changing fee routing or disabling a pool that retains liquidity | Real PoolManager/PositionManager lifecycle tests and two-position stateful invariant |
| Liquidity owned by an unrelated LP remains unchanged under managed-position action sequences | Real PositionManager stateful invariant with a sentinel external position |

## Proof boundaries

- The Halmos harness bypasses hook-address flag validation so symbolic deployment
  does not depend on CREATE address mining. Production deployment and unit tests
  validate the actual permission bits.
- The before-swap Halmos theorem covers every boolean direction/exactness branch.
  The post-swap theorem uses one representative positive-delta branch because
  symbolic signed packed-delta branching is not CI-tractable; the adjacent
  full-width fuzz test covers all symmetric branches and both signs.
- Fee settlement mints PoolManager claims and therefore does not call token
  transfer code. Hostile ERC-20 behaviors are exercised to confirm they cannot
  reenter fee configuration or alter claim accounting during a swap callback.
- Position lifecycle evidence executes the pinned real Uniswap v4 contracts. It
  verifies integration behavior but is not a formal proof of those dependencies.
- The hook, Halmos test, Certora harness, and deployment script are compiled with
  solc 0.8.33 for launch verification; ordinary project tests retain their
  source-selected compiler versions.
- None of these checks proves that a chosen price or concentrated range is
  economically appropriate or that an offchain manager will act profitably.
