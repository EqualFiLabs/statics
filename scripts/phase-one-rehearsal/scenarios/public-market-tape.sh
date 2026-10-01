#!/usr/bin/env bash

set -Eeuo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

require_commands cast jq awk bc
load_current_run
require_local_chain
reset_to_base

LP_INDEX=6
TRADER_INDEX=7
LP=$(anvil_address "$LP_INDEX")
LP_KEY=$(anvil_private_key "$LP_INDEX")
TRADER=$(anvil_address "$TRADER_INDEX")
POSITION_FEE=1000000000000000
POOL_ID=$(create_public_pool "$STAKING_TOKEN" "$WETH_ADDRESS" "$LP" 2 public-market)

if [[ "${WETH_ADDRESS,,}" < "${STAKING_TOKEN,,}" ]]; then
    CURRENCY0=$WETH_ADDRESS
    CURRENCY1=$STAKING_TOKEN
else
    CURRENCY0=$STAKING_TOKEN
    CURRENCY1=$WETH_ADDRESS
fi

acquire_genesis_statics "$LP_INDEX" 2000000000000000000 public-lp >/dev/null
wrap_weth "$LP_INDEX" 100000000000000000000 public-lp
cast send "$CURRENCY0" 'approve(address,uint256)' "$STATICS_DIAMOND_ADDRESS" "$(cast max-uint)" \
    --private-key "$LP_KEY" --rpc-url "$RPC_URL" --legacy --json >"$RUN_DIR/public-lp-currency0-approve.json"
cast send "$CURRENCY1" 'approve(address,uint256)' "$STATICS_DIAMOND_ADDRESS" "$(cast max-uint)" \
    --private-key "$LP_KEY" --rpc-url "$RPC_URL" --legacy --json >"$RUN_DIR/public-lp-currency1-approve.json"

POSITION_ID=$(cast call "$STATICS_DIAMOND_ADDRESS" 'nextPositionId()(uint256)' --rpc-url "$RPC_URL" | awk '{print $1}')
cast send "$STATICS_DIAMOND_ADDRESS" 'createPosition(address)(uint256)' "$LP" \
    --value "$POSITION_FEE" \
    --private-key "$LP_KEY" --rpc-url "$RPC_URL" --legacy --json >"$RUN_DIR/public-lp-create-position.json"
DEADLINE=$(( $(cast block latest --field timestamp --rpc-url "$RPC_URL") + 3600 ))
cast send "$STATICS_DIAMOND_ADDRESS" \
    'provideLiquidity(uint256,(bytes32,int24,int24,uint128,uint256,uint256,uint256))((uint256,uint128,uint256,uint256,uint256,uint256))' \
    "$POSITION_ID" "($POOL_ID,-600,600,100000000000000000000,100000000000000000000,100000000000000000000,$DEADLINE)" \
    --private-key "$LP_KEY" --rpc-url "$RPC_URL" --legacy --json >"$RUN_DIR/public-lp-provide.json"

# Keep a wider managed range active after the inner boundary is crossed so the
# exact-input swap can complete while still exercising the denominator change.
WIDE_POSITION_ID=$(cast call "$STATICS_DIAMOND_ADDRESS" 'nextPositionId()(uint256)' --rpc-url "$RPC_URL" | awk '{print $1}')
cast send "$STATICS_DIAMOND_ADDRESS" 'createPosition(address)(uint256)' "$LP" \
    --value "$POSITION_FEE" \
    --private-key "$LP_KEY" --rpc-url "$RPC_URL" --legacy --json >"$RUN_DIR/public-wide-create-position.json"
cast send "$STATICS_DIAMOND_ADDRESS" \
    'provideLiquidity(uint256,(bytes32,int24,int24,uint128,uint256,uint256,uint256))((uint256,uint128,uint256,uint256,uint256,uint256))' \
    "$WIDE_POSITION_ID" "($POOL_ID,-1200,1200,100000000000000000000,90000000000000000000,90000000000000000000,$DEADLINE)" \
    --private-key "$LP_KEY" --rpc-url "$RPC_URL" --legacy --json >"$RUN_DIR/public-wide-provide.json"

GAUGE=$(cast call "$STATICS_DIAMOND_ADDRESS" \
    'gaugePool(bytes32)((bool,bool,uint40,int24,uint128,uint64,uint64))' "$POOL_ID" --rpc-url "$RPC_URL" --json)
ACTIVE_LIQUIDITY=$(jq -r '.[0][4]' <<<"$GAUGE")
assert_eq "$ACTIVE_LIQUIDITY" 200000000000000000000 "initial active gauge liquidity"
record_result range-gauge managed-liquidity pass "positions $POSITION_ID and $WIDE_POSITION_ID"

wrap_weth "$TRADER_INDEX" 20000000000000000000 public-trader
v4_swap_exact_in "$TRADER_INDEX" "$CURRENCY0" "$CURRENCY1" 3000 60 \
    "$STATICS_SWAP_FEE_HOOK_ADDRESS" true 100000000000000000 public-ordinary

MARKET_EVENT_TOPIC=$(cast keccak 'MarketSwapRecorded(bytes32,uint256,int256,uint256,int24,uint24,uint8)')
EVENT_COUNT=$(jq --arg topic "${MARKET_EVENT_TOPIC,,}" \
    '[.logs[] | select((.topics[0] | ascii_downcase) == $topic)] | length' \
    "$RUN_DIR/public-ordinary-swap.json")
assert_eq "$EVENT_COUNT" 1 "ordinary swap MarketTape event count"
STATE=$(cast call "$STATICS_DIAMOND_ADDRESS" \
    'canonicalMarketState(bytes32)((uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,int256,uint40,int24,uint24,uint8,uint8))' \
    "$POOL_ID" --rpc-url "$RPC_URL" --json)
EXTERNAL_COUNT=$(jq -r '.[0][6]' <<<"$STATE")
SEQUENCE=$(jq -r '.[0][8]' <<<"$STATE")
FLAGS=$(jq -r '.[0][13]' <<<"$STATE")
assert_eq "$EXTERNAL_COUNT" 1 "canonical external swap count"
assert_eq "$SEQUENCE" 1 "canonical sequence after first swap"
assert_eq "$FLAGS" 1 "zero-for-one exact-input flags"
record_result market-tape ordinary-swap pass "sequence $SEQUENCE"

ORDINARY_GAS=$(receipt_gas_used "$RUN_DIR/public-ordinary-swap.json")
rpc_warp_by 60
v4_swap_exact_in "$TRADER_INDEX" "$CURRENCY0" "$CURRENCY1" 3000 60 \
    "$STATICS_SWAP_FEE_HOOK_ADDRESS" true 100000000000000000 public-steady
STEADY_GAS=$(receipt_gas_used "$RUN_DIR/public-steady-swap.json")
STATE=$(cast call "$STATICS_DIAMOND_ADDRESS" \
    'canonicalMarketState(bytes32)((uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,int256,uint40,int24,uint24,uint8,uint8))' \
    "$POOL_ID" --rpc-url "$RPC_URL" --json)
assert_eq "$(jq -r '.[0][6]' <<<"$STATE")" 2 "canonical count after steady swap"
assert_eq "$(jq -r '.[0][8]' <<<"$STATE")" 2 "canonical sequence after steady swap"
rpc_warp_by 60
v4_swap_exact_in "$TRADER_INDEX" "$CURRENCY0" "$CURRENCY1" 3000 60 \
    "$STATICS_SWAP_FEE_HOOK_ADDRESS" true 7000000000000000000 public-boundary-crossing
BOUNDARY_GAS=$(receipt_gas_used "$RUN_DIR/public-boundary-crossing-swap.json")
STATE=$(cast call "$STATICS_DIAMOND_ADDRESS" \
    'canonicalMarketState(bytes32)((uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,int256,uint40,int24,uint24,uint8,uint8))' \
    "$POOL_ID" --rpc-url "$RPC_URL" --json)
assert_eq "$(jq -r '.[0][6]' <<<"$STATE")" 3 "canonical count after boundary swap"
assert_eq "$(jq -r '.[0][8]' <<<"$STATE")" 3 "canonical sequence after boundary swap"
GAUGE_AFTER=$(cast call "$STATICS_DIAMOND_ADDRESS" \
    'gaugePool(bytes32)((bool,bool,uint40,int24,uint128,uint64,uint64))' "$POOL_ID" --rpc-url "$RPC_URL" --json)
REFERENCE_TICK=$(jq -r '.[0][3]' <<<"$GAUGE_AFTER")
LAST_TICK=$(jq -r '.[0][11]' <<<"$STATE")
assert_eq "$REFERENCE_TICK" "$LAST_TICK" "range-gauge reference tick after crossing"
record_result range-gauge boundary-crossing pass "tick $LAST_TICK"

# Exact-output uses the same immutable callback ABI and must carry its raw
# execution classification into both canonical state and the granular event.
rpc_warp_by 60
v4_swap_exact_out "$TRADER_INDEX" "$CURRENCY0" "$CURRENCY1" 3000 60 \
    "$STATICS_SWAP_FEE_HOOK_ADDRESS" false 10000000000000000 100000000000000000000 public-exact-output
STATE=$(cast call "$STATICS_DIAMOND_ADDRESS" \
    'canonicalMarketState(bytes32)((uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,int256,uint40,int24,uint24,uint8,uint8))' \
    "$POOL_ID" --rpc-url "$RPC_URL" --json)
assert_eq "$(jq -r '.[0][6]' <<<"$STATE")" 4 "canonical count after exact-output swap"
assert_eq "$(jq -r '.[0][8]' <<<"$STATE")" 4 "canonical sequence after exact-output swap"
assert_eq "$(jq -r '.[0][13]' <<<"$STATE")" 2 "exact-output MarketTape flags"
EXACT_EVENT_COUNT=$(jq --arg topic "${MARKET_EVENT_TOPIC,,}" \
    '[.logs[] | select((.topics[0] | ascii_downcase) == $topic)] | length' \
    "$RUN_DIR/public-exact-output-swap.json")
assert_eq "$EXACT_EVENT_COUNT" 1 "exact-output MarketTape event count"
record_result market-tape exact-output pass "sequence 4"

# Reconfigure the replaceable observation layer, grow its ring, and prove
# bounded wrap without affecting the gapless canonical sequence.
OBSERVATION_CALLDATA=$(cast calldata 'setMarketObservationConfig(bytes32,bool,uint32,uint16)' \
    "$POOL_ID" true 60 3)
timelock_call "$STATICS_DIAMOND_ADDRESS" 0 "$OBSERVATION_CALLDATA" public-observation-config
for index in 1 2 3 4; do
    rpc_warp_by 60
    v4_swap_exact_in "$TRADER_INDEX" "$CURRENCY0" "$CURRENCY1" 3000 60 \
        "$STATICS_SWAP_FEE_HOOK_ADDRESS" true 10000000000000000 "public-observation-$index"
done
OBSERVATION=$(cast call "$STATICS_DIAMOND_ADDRESS" \
    'marketObservationConfig(bytes32)((bool,bool,uint32,uint16,uint16,uint64,uint64,uint40,uint256,uint256))' \
    "$POOL_ID" --rpc-url "$RPC_URL" --json)
assert_eq "$(jq -r '.[0][2]' <<<"$OBSERVATION")" 60 "observation cadence"
assert_eq "$(jq -r '.[0][3]' <<<"$OBSERVATION")" 3 "observation cardinality"
assert_eq "$(jq -r '.[0][4]' <<<"$OBSERVATION")" 3 "observation target cardinality"
assert_eq "$(jq -r '.[0][5]' <<<"$OBSERVATION")" 3 "retained observation count"
assert_eq "$(jq -r '.[0][6]' <<<"$OBSERVATION")" 5 "latest observation id"
expect_call_revert "wrapped observation must be unavailable" \
    cast call "$STATICS_DIAMOND_ADDRESS" \
    'marketObservation(bytes32,uint64)((uint40,int24,uint24,uint8,uint256,int256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256))' \
    "$POOL_ID" 2 --rpc-url "$RPC_URL" >"$RUN_DIR/public-observation-wrapped-revert.txt"
CURRENT_AND_PRIOR=$(cast call "$STATICS_DIAMOND_ADDRESS" \
    'observeMarket(bytes32,uint32[])((uint40,int24,uint24,uint8,uint256,int256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256)[])' \
    "$POOL_ID" '[0,60]' --rpc-url "$RPC_URL" --json)
assert_eq "$(jq -r '.[0] | length' <<<"$CURRENT_AND_PRIOR")" 2 "bounded observation query result count"
record_result market-tape observation-cadence-and-wrap pass "latest observation 5, retained 3"

OBSERVATION=$(cast call "$STATICS_DIAMOND_ADDRESS" \
    'marketObservationConfig(bytes32)((bool,bool,uint32,uint16,uint16,uint64,uint64,uint40,uint256,uint256))' \
    "$POOL_ID" --rpc-url "$RPC_URL" --json)
OBSERVED_STORED=$(jq -r '.[0][5]' <<<"$OBSERVATION")
[[ "$OBSERVED_STORED" != "0" ]] || fail "observation ring did not record the canonical market"
record_result market-tape observation-ring pass "$OBSERVED_STORED observations"

jq -n \
    --arg poolId "$POOL_ID" \
    --argjson ordinaryGas "$ORDINARY_GAS" \
    --argjson steadyGas "$STEADY_GAS" \
    --argjson boundaryGas "$BOUNDARY_GAS" \
    --arg finalTick "$LAST_TICK" \
    '{poolId:$poolId,coldSwapGas:$ordinaryGas,steadySwapGas:$steadyGas,boundaryCrossingSwapGas:$boundaryGas,finalTick:$finalTick}' \
    >"$RUN_DIR/public-swap-gas.json"
record_result gas public-cold pass "$ORDINARY_GAS"
record_result gas public-steady pass "$STEADY_GAS"
record_result gas public-boundary-crossing pass "$BOUNDARY_GAS"

note "public MarketTape and managed-boundary scenarios passed"
