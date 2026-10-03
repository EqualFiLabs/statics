#!/usr/bin/env bash

set -Eeuo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

require_commands cast jq awk bc
load_current_run
require_local_chain
reset_to_base

USER_INDEX=15
USER=$(anvil_address "$USER_INDEX")
USER_KEY=$(anvil_private_key "$USER_INDEX")
POSITION_FEE=1000000000000000
STAKE=1000000000000000000000
POOL_A=$(create_public_pool "$STAKING_TOKEN" "$WETH_ADDRESS" "$USER" 34 multi-gauge-a 3000 60)
POOL_B=$(create_public_pool "$STAKING_TOKEN" "$WETH_ADDRESS" "$USER" 35 multi-gauge-b 10000 200)
[[ "$POOL_A" != "$POOL_B" ]] || fail "multi-pool gauge fixture produced duplicate PoolIds"

if [[ "${WETH_ADDRESS,,}" < "${STAKING_TOKEN,,}" ]]; then
    CURRENCY0=$WETH_ADDRESS
    CURRENCY1=$STAKING_TOKEN
else
    CURRENCY0=$STAKING_TOKEN
    CURRENCY1=$WETH_ADDRESS
fi

acquire_genesis_statics "$USER_INDEX" 3000000000000000000 multi-gauge-user >/dev/null
wrap_weth "$USER_INDEX" 150000000000000000000 multi-gauge-user
cast send "$STAKING_TOKEN" 'approve(address,uint256)' "$STATICS_DIAMOND_ADDRESS" "$(cast max-uint)" \
    --private-key "$USER_KEY" --rpc-url "$RPC_URL" --legacy --json >"$RUN_DIR/multi-gauge-statics-approve.json"
cast send "$WETH_ADDRESS" 'approve(address,uint256)' "$STATICS_DIAMOND_ADDRESS" "$(cast max-uint)" \
    --private-key "$USER_KEY" --rpc-url "$RPC_URL" --legacy --json >"$RUN_DIR/multi-gauge-weth-approve.json"
POSITION_ID=$(cast call "$STATICS_DIAMOND_ADDRESS" 'nextPositionId()(uint256)' --rpc-url "$RPC_URL" | awk '{print $1}')
cast send "$STATICS_DIAMOND_ADDRESS" 'createAndStake(uint256,address,address[])(uint256)' \
    "$STAKE" "$USER" '[]' --value "$POSITION_FEE" --private-key "$USER_KEY" \
    --rpc-url "$RPC_URL" --legacy --json >"$RUN_DIR/multi-gauge-create-stake.json"
ALLOCATION_STATE=$(cast call "$STATICS_DIAMOND_ADDRESS" \
    'gaugePositionAllocations(uint256)(uint40,uint256,(bytes32,uint256,bytes32)[],uint256)' \
    "$POSITION_ID" --from "$USER" --rpc-url "$RPC_URL")
NEXT_ALLOCATION_AT=$(printf '%s\n' "$ALLOCATION_STATE" | sed -n '1s/ .*//p')
rpc_warp_to "$NEXT_ALLOCATION_AT"
WEIGHT_A=600000000000000000000
WEIGHT_B=400000000000000000000
cast send "$STATICS_DIAMOND_ADDRESS" 'setGaugeAllocations(uint256,bytes32[],uint256[])' \
    "$POSITION_ID" "[$POOL_A,$POOL_B]" "[$WEIGHT_A,$WEIGHT_B]" --private-key "$USER_KEY" \
    --rpc-url "$RPC_URL" --legacy --json >"$RUN_DIR/multi-gauge-allocate.json"
assert_eq "$(cast call "$STATICS_DIAMOND_ADDRESS" \
    'gaugePoolWeight(bytes32)(uint256,bytes32,bytes32,uint64,uint256,uint256,bool)' "$POOL_A" \
    --rpc-url "$RPC_URL" | sed -n '1s/ .*//p')" "$WEIGHT_A" "pool A allocation weight"
assert_eq "$(cast call "$STATICS_DIAMOND_ADDRESS" \
    'gaugePoolWeight(bytes32)(uint256,bytes32,bytes32,uint64,uint256,uint256,bool)' "$POOL_B" \
    --rpc-url "$RPC_URL" | sed -n '1s/ .*//p')" "$WEIGHT_B" "pool B allocation weight"

DEADLINE=$(( $(cast block latest --field timestamp --rpc-url "$RPC_URL") + 86400 ))
cast send "$STATICS_DIAMOND_ADDRESS" \
    'provideLiquidity(uint256,(bytes32,int24,int24,uint128,uint256,uint256,uint256))((uint256,uint128,uint256,uint256,uint256,uint256))' \
    "$POSITION_ID" "($POOL_A,-1200,1200,50000000000000000000,50000000000000000000,50000000000000000000,$DEADLINE)" \
    --private-key "$USER_KEY" --rpc-url "$RPC_URL" --legacy --json >"$RUN_DIR/multi-gauge-provide-a.json"
cast send "$STATICS_DIAMOND_ADDRESS" \
    'provideLiquidity(uint256,(bytes32,int24,int24,uint128,uint256,uint256,uint256))((uint256,uint128,uint256,uint256,uint256,uint256))' \
    "$POSITION_ID" "($POOL_B,-2000,2000,50000000000000000000,50000000000000000000,50000000000000000000,$DEADLINE)" \
    --private-key "$USER_KEY" --rpc-url "$RPC_URL" --legacy --json >"$RUN_DIR/multi-gauge-provide-b.json"

RESERVE_FUND=100000000000000000000
cast send "$STATICS_DIAMOND_ADDRESS" 'fundGaugeReserve(uint256)(uint256)' "$RESERVE_FUND" \
    --private-key "$USER_KEY" --rpc-url "$RPC_URL" --legacy --json >"$RUN_DIR/multi-gauge-reserve-fund.json"
ACTIVATE_CALLDATA=$(cast calldata 'activateGaugeSchedule()')
timelock_call "$STATICS_DIAMOND_ADDRESS" 0 "$ACTIVATE_CALLDATA" multi-gauge-activate
rpc_warp_by 86400
cast send "$STATICS_DIAMOND_ADDRESS" 'checkpointGaugePool(bytes32)(uint256,uint256)' "$POOL_A" \
    --private-key "$USER_KEY" --rpc-url "$RPC_URL" --gas-limit 3000000 --legacy --json \
    >"$RUN_DIR/multi-gauge-credit-a.json"
cast send "$STATICS_DIAMOND_ADDRESS" 'checkpointGaugePool(bytes32)(uint256,uint256)' "$POOL_B" \
    --private-key "$USER_KEY" --rpc-url "$RPC_URL" --gas-limit 3000000 --legacy --json \
    >"$RUN_DIR/multi-gauge-credit-b.json"
rpc_warp_by 86400

BALANCE_BEFORE=$(cast call "$STAKING_TOKEN" 'balanceOf(address)(uint256)' "$USER" --rpc-url "$RPC_URL" | awk '{print $1}')
cast send "$STATICS_DIAMOND_ADDRESS" \
    'claimLpRewards(uint256,bytes32,uint8[],uint256[],address)(uint256[])' \
    "$POSITION_ID" "$POOL_A" '[0]' '[0]' "$USER" --private-key "$USER_KEY" \
    --rpc-url "$RPC_URL" --gas-limit 3000000 --legacy --json >"$RUN_DIR/multi-gauge-claim-a.json"
BALANCE_AFTER_A=$(cast call "$STAKING_TOKEN" 'balanceOf(address)(uint256)' "$USER" --rpc-url "$RPC_URL" | awk '{print $1}')
CLAIM_A=$(printf '%s - %s\n' "$BALANCE_AFTER_A" "$BALANCE_BEFORE" | bc)
cast send "$STATICS_DIAMOND_ADDRESS" \
    'claimLpRewards(uint256,bytes32,uint8[],uint256[],address)(uint256[])' \
    "$POSITION_ID" "$POOL_B" '[0]' '[0]' "$USER" --private-key "$USER_KEY" \
    --rpc-url "$RPC_URL" --gas-limit 3000000 --legacy --json >"$RUN_DIR/multi-gauge-claim-b.json"
BALANCE_AFTER_B=$(cast call "$STAKING_TOKEN" 'balanceOf(address)(uint256)' "$USER" --rpc-url "$RPC_URL" | awk '{print $1}')
CLAIM_B=$(printf '%s - %s\n' "$BALANCE_AFTER_B" "$BALANCE_AFTER_A" | bc)
assert_gt "$CLAIM_A" 0 "pool A protocol LP claim"
assert_gt "$CLAIM_B" 0 "pool B protocol LP claim"
assert_gt "$CLAIM_A" "$CLAIM_B" "larger allocation receives larger protocol reward"

record_result gauges multi-pool-allocation pass "$WEIGHT_A and $WEIGHT_B"
record_result gauges pro-rata-multi-pool-claims pass "$CLAIM_A and $CLAIM_B STATICS wei"
note "multi-pool allocation and pro-rata protocol reward scenarios passed"
