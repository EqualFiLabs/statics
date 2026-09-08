# Launch-liquidity tooling

The standalone launch hook is deployed once and can register many PoolKeys. Its
liquidity remains in ordinary PositionManager NFTs owned by the configured
recipient. The scripts in this document prepare calldata and artifacts; they do
not broadcast transactions.

## Funding modes

`STATICS_LAUNCH_FUNDING_MODE` accepts exactly:

- `STATICS_ONLY`: the initialized price is outside the range on the side that
  makes the position entirely STATICS.
- `PAIRED_TOKEN_ONLY`: the initialized price is outside the range on the side
  that makes the position entirely the paired token.
- `TWO_SIDED`: the initialized price is strictly inside the range and both
  amount caps are nonzero.

The validators derive the correct side after sorting the token addresses into
currency0 and currency1. Full-range, narrow-range, balanced, and asymmetric
positions are range or amount choices rather than separate modes.

If `STATICS_LAUNCH_LIQUIDITY` is unset or zero, the deployment and pool-launch
scripts calculate the maximum liquidity supported by `amount0Max`,
`amount1Max`, the configured price, and the selected ticks. The non-limiting
token can remain as residual wallet inventory.

## Prepare another pool

Set `ROBINHOOD_MAINNET` through the operator's local secret-management workflow,
then set one pool's parameters and generate its artifact:

```shell
STATICS_LAUNCH_LIQUIDITY_ARTIFACT=artifacts/launch-liquidity/robinhood-4663.json \
STATICS_POOL_LAUNCH_ARTIFACT=artifacts/launch-liquidity/nvda-pool.json \
STATICS_LAUNCH_PAIRED_TOKEN="$PAIRED_TOKEN" \
STATICS_LAUNCH_POSITION_OWNER="$POSITION_OWNER" \
STATICS_LAUNCH_FUNDING_MODE=TWO_SIDED \
STATICS_LAUNCH_NATIVE_LP_FEE="$NATIVE_LP_FEE" \
STATICS_LAUNCH_TICK_SPACING="$TICK_SPACING" \
STATICS_LAUNCH_SQRT_PRICE_X96="$SQRT_PRICE_X96" \
STATICS_LAUNCH_TICK_LOWER="$TICK_LOWER" \
STATICS_LAUNCH_TICK_UPPER="$TICK_UPPER" \
STATICS_LAUNCH_AMOUNT0_MAX="$AMOUNT0_MAX" \
STATICS_LAUNCH_AMOUNT1_MAX="$AMOUNT1_MAX" \
STATICS_LAUNCH_INPUT_FEE_BPS="$INPUT_FEE_BPS" \
STATICS_LAUNCH_OUTPUT_FEE_BPS="$OUTPUT_FEE_BPS" \
STATICS_LAUNCH_POSITION_DEADLINE="$FRESH_UNIX_TIMESTAMP" \
forge script script/PrepareStaticsPoolLaunch.s.sol:PrepareStaticsPoolLaunch \
  --rpc-url "$ROBINHOOD_MAINNET"
```

The output records currency ordering, calculated or explicit liquidity, and
four calls:

1. `registerPoolCalldata`, executed immediately by an account holding the hook
   owner's current timelock proposer role.
2. `initializeAndMintCalldata`, executed against PositionManager after the
   required ERC-20 and Permit2 approvals.
3. `mintOnlyCalldata`, used only if exact-price initialization already
   succeeded but the atomic call did not.
4. `activatePoolCalldata`, executed by the configured launch operator or hook
   owner after the first position exists.

Use a distinct output artifact for every PoolKey.

## Add another position

Additional positions do not require hook calls. The mint preparation reads the
pool's current PoolManager price and uses it when calculating liquidity:

```shell
STATICS_POOL_LAUNCH_ARTIFACT=artifacts/launch-liquidity/nvda-pool.json \
STATICS_POSITION_MINT_ARTIFACT=artifacts/launch-liquidity/nvda-position-mint.json \
STATICS_POSITION_TICK_LOWER="$TICK_LOWER" \
STATICS_POSITION_TICK_UPPER="$TICK_UPPER" \
STATICS_POSITION_AMOUNT0_MAX="$AMOUNT0_MAX" \
STATICS_POSITION_AMOUNT1_MAX="$AMOUNT1_MAX" \
STATICS_POSITION_OWNER="$POSITION_OWNER" \
STATICS_POSITION_MINT_DEADLINE="$FRESH_UNIX_TIMESTAMP" \
forge script script/PrepareStaticsPositionMint.s.sol:PrepareStaticsPositionMint \
  --rpc-url "$ROBINHOOD_MAINNET"
```

Set `STATICS_POSITION_LIQUIDITY` only when an explicit liquidity delta is
desired. Otherwise the script calculates it from the live pool price and the
two amount caps. Running this process repeatedly creates independently managed
ranges in the same pool.

## Manage an existing position

Prepare standard PositionManager calls for a specific NFT:

```shell
STATICS_POOL_LAUNCH_ARTIFACT=artifacts/launch-liquidity/nvda-pool.json \
STATICS_POSITION_ACTIONS_ARTIFACT=artifacts/launch-liquidity/nvda-position-actions.json \
STATICS_POSITION_TOKEN_ID="$TOKEN_ID" \
STATICS_POSITION_LIQUIDITY_DELTA="$LIQUIDITY_DELTA" \
STATICS_POSITION_AMOUNT0_MAX="$AMOUNT0_MAX" \
STATICS_POSITION_AMOUNT1_MAX="$AMOUNT1_MAX" \
STATICS_POSITION_AMOUNT0_MIN="$AMOUNT0_MIN" \
STATICS_POSITION_AMOUNT1_MIN="$AMOUNT1_MIN" \
STATICS_POSITION_RECIPIENT="$RECIPIENT" \
STATICS_POSITION_ACTION_DEADLINE="$FRESH_UNIX_TIMESTAMP" \
forge script script/PrepareStaticsPositionActions.s.sol:PrepareStaticsPositionActions \
  --rpc-url "$ROBINHOOD_MAINNET"
```

The artifact includes calldata to increase liquidity, decrease the requested
amount, collect fees without removing principal, or remove all liquidity and
burn the NFT. Amount maximums and minimums are token-unit slippage bounds, not
USD values. Set fields unused by the intended action to zero. Fee collection
always uses zero principal and zero principal minimums. Removing or burning one
position does not deactivate the pool or affect other LP positions.
