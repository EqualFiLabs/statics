#!/usr/bin/env bash

set -Eeuo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

require_commands cast jq awk bc
load_current_run
require_local_chain
reset_to_base

LP_INDEX=8
TRADER_INDEX=9
LP=$(anvil_address "$LP_INDEX")
LP_KEY=$(anvil_private_key "$LP_INDEX")
POOL_MANAGER=$(jq -er '.contracts.poolManager.address' deployments/robinhood-chain-4663.json)
POSITION_MANAGER=$(jq -er '.contracts.positionManager.address' deployments/robinhood-chain-4663.json)

if [[ "${WETH_ADDRESS,,}" < "${STAKING_TOKEN,,}" ]]; then
    CURRENCY0=$WETH_ADDRESS
    CURRENCY1=$STAKING_TOKEN
else
    CURRENCY0=$STAKING_TOKEN
    CURRENCY1=$WETH_ADDRESS
fi

POOL_KEY="($CURRENCY0,$CURRENCY1,3000,60,0x0000000000000000000000000000000000000000)"
cast send "$POOL_MANAGER" \
    'initialize((address,address,uint24,int24,address),uint160)(int24)' \
    "$POOL_KEY" 79228162514264337593543950336 \
    --private-key "$LP_KEY" --rpc-url "$RPC_URL" --legacy --json >"$RUN_DIR/vanilla-initialize.json"

acquire_genesis_statics "$LP_INDEX" 2000000000000000000 vanilla-lp >/dev/null
wrap_weth "$LP_INDEX" 100000000000000000000 vanilla-lp
approve_permit2_spender "$LP_INDEX" "$CURRENCY0" "$POSITION_MANAGER" vanilla-position-currency0
approve_permit2_spender "$LP_INDEX" "$CURRENCY1" "$POSITION_MANAGER" vanilla-position-currency1

MINT_PARAM=$(cast abi-encode \
    'f((address,address,uint24,int24,address),int24,int24,uint256,uint128,uint128,address,bytes)' \
    "$POOL_KEY" -887220 887220 50000000000000000000 \
    60000000000000000000 60000000000000000000 "$LP" 0x)
SETTLE_PARAM=$(cast abi-encode 'f(address,address)' "$CURRENCY0" "$CURRENCY1")
PLAN=$(cast abi-encode 'f(bytes,bytes[])' 0x020d "[$MINT_PARAM,$SETTLE_PARAM]")
DEADLINE=$(( $(cast block latest --field timestamp --rpc-url "$RPC_URL") + 3600 ))
cast send "$POSITION_MANAGER" 'modifyLiquidities(bytes,uint256)' "$PLAN" "$DEADLINE" \
    --private-key "$LP_KEY" --rpc-url "$RPC_URL" --gas-limit 3000000 --legacy --json \
    >"$RUN_DIR/vanilla-mint-liquidity.json"

wrap_weth "$TRADER_INDEX" 10000000000000000000 vanilla-trader
v4_swap_exact_in "$TRADER_INDEX" "$CURRENCY0" "$CURRENCY1" 3000 60 \
    0x0000000000000000000000000000000000000000 true 100000000000000000 vanilla-cold
rpc_warp_by 60
v4_swap_exact_in "$TRADER_INDEX" "$CURRENCY0" "$CURRENCY1" 3000 60 \
    0x0000000000000000000000000000000000000000 true 100000000000000000 vanilla-steady

COLD_GAS=$(receipt_gas_used "$RUN_DIR/vanilla-cold-swap.json")
STEADY_GAS=$(receipt_gas_used "$RUN_DIR/vanilla-steady-swap.json")
jq -n \
    --argjson coldGas "$COLD_GAS" \
    --argjson steadyGas "$STEADY_GAS" \
    '{coldSwapGas:$coldGas,steadySwapGas:$steadyGas}' >"$RUN_DIR/vanilla-swap-gas.json"
record_result gas vanilla-cold pass "$COLD_GAS"
record_result gas vanilla-steady pass "$STEADY_GAS"
note "vanilla Uniswap v4 gas baseline passed"
