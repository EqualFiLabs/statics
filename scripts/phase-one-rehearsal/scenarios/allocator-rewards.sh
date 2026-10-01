#!/usr/bin/env bash

set -Eeuo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

require_commands cast jq awk bc
load_current_run
require_local_chain
reset_to_base

CREATOR_INDEX=9
CREATOR=$(anvil_address "$CREATOR_INDEX")
CREATOR_KEY=$(anvil_private_key "$CREATOR_INDEX")
POSITION_FEE=1000000000000000
STAKE=1000000000000000000000
POOL_ID=$(create_public_pool "$STAKING_TOKEN" "$WETH_ADDRESS" "$CREATOR" 32 allocator-rewards)

if [[ "${WETH_ADDRESS,,}" < "${STAKING_TOKEN,,}" ]]; then
    CURRENCY0=$WETH_ADDRESS
    CURRENCY1=$STAKING_TOKEN
else
    CURRENCY0=$STAKING_TOKEN
    CURRENCY1=$WETH_ADDRESS
fi

acquire_genesis_statics "$CREATOR_INDEX" 2000000000000000000 allocator-owner >/dev/null
wrap_weth "$CREATOR_INDEX" 100000000000000000000 allocator-owner
cast send "$STAKING_TOKEN" 'approve(address,uint256)' "$STATICS_DIAMOND_ADDRESS" "$(cast max-uint)" \
    --private-key "$CREATOR_KEY" --rpc-url "$RPC_URL" --legacy --json >"$RUN_DIR/allocator-statics-approve.json"
cast send "$WETH_ADDRESS" 'approve(address,uint256)' "$STATICS_DIAMOND_ADDRESS" "$(cast max-uint)" \
    --private-key "$CREATOR_KEY" --rpc-url "$RPC_URL" --legacy --json >"$RUN_DIR/allocator-weth-approve.json"

POSITION_ID=$(cast call "$STATICS_DIAMOND_ADDRESS" 'nextPositionId()(uint256)' --rpc-url "$RPC_URL" | awk '{print $1}')
cast send "$STATICS_DIAMOND_ADDRESS" 'createAndStake(uint256,address,address[])(uint256)' \
    "$STAKE" "$CREATOR" '[]' --value "$POSITION_FEE" --private-key "$CREATOR_KEY" \
    --rpc-url "$RPC_URL" --legacy --json >"$RUN_DIR/allocator-create-stake.json"
ALLOCATION_STATE=$(cast call "$STATICS_DIAMOND_ADDRESS" \
    'gaugePositionAllocations(uint256)(uint40,uint256,(bytes32,uint256,bytes32)[],uint256)' \
    "$POSITION_ID" --from "$CREATOR" --rpc-url "$RPC_URL")
NEXT_ALLOCATION_AT=$(printf '%s\n' "$ALLOCATION_STATE" | sed -n '1s/ .*//p')
rpc_warp_to "$NEXT_ALLOCATION_AT"
cast send "$STATICS_DIAMOND_ADDRESS" 'setGaugeAllocations(uint256,bytes32[],uint256[])' \
    "$POSITION_ID" "[$POOL_ID]" "[$STAKE]" --private-key "$CREATOR_KEY" \
    --rpc-url "$RPC_URL" --legacy --json >"$RUN_DIR/allocator-set-weight.json"

# Use the same PNFT as a productive LP so a single funded program proves the
# allocator and LP halves remain distinct and fully claimable.
cast send "$CURRENCY0" 'approve(address,uint256)' "$STATICS_DIAMOND_ADDRESS" "$(cast max-uint)" \
    --private-key "$CREATOR_KEY" --rpc-url "$RPC_URL" --legacy --json >"$RUN_DIR/allocator-liquidity-approve0.json"
cast send "$CURRENCY1" 'approve(address,uint256)' "$STATICS_DIAMOND_ADDRESS" "$(cast max-uint)" \
    --private-key "$CREATOR_KEY" --rpc-url "$RPC_URL" --legacy --json >"$RUN_DIR/allocator-liquidity-approve1.json"
DEADLINE=$(( $(cast block latest --field timestamp --rpc-url "$RPC_URL") + 3600 ))
cast send "$STATICS_DIAMOND_ADDRESS" \
    'provideLiquidity(uint256,(bytes32,int24,int24,uint128,uint256,uint256,uint256))((uint256,uint128,uint256,uint256,uint256,uint256))' \
    "$POSITION_ID" "($POOL_ID,-1200,1200,100000000000000000000,90000000000000000000,90000000000000000000,$DEADLINE)" \
    --private-key "$CREATOR_KEY" --rpc-url "$RPC_URL" --legacy --json >"$RUN_DIR/allocator-provide.json"

ALLOW_CALLDATA=$(cast calldata 'setGaugeRewardAssetAllowed(address,bool)' "$WETH_ADDRESS" true)
timelock_call "$STATICS_DIAMOND_ADDRESS" 0 "$ALLOW_CALLDATA" allocator-allow-weth
cast send "$STATICS_DIAMOND_ADDRESS" 'appendPoolRewardAsset(bytes32,address)(uint8)' \
    "$POOL_ID" "$WETH_ADDRESS" --private-key "$CREATOR_KEY" --rpc-url "$RPC_URL" --legacy --json \
    >"$RUN_DIR/allocator-append-slot.json"
cast send "$STATICS_DIAMOND_ADDRESS" 'setPoolRewardAllocatorShare(bytes32,uint8,uint16)' \
    "$POOL_ID" 1 5000 --private-key "$CREATOR_KEY" --rpc-url "$RPC_URL" --legacy --json \
    >"$RUN_DIR/allocator-set-share.json"

FUND_AMOUNT=7000000000000000000
cast send "$WETH_ADDRESS" 'approve(address,uint256)' "$STATICS_DIAMOND_ADDRESS" "$FUND_AMOUNT" \
    --private-key "$CREATOR_KEY" --rpc-url "$RPC_URL" --legacy --json >"$RUN_DIR/allocator-fund-approve.json"
cast send "$STATICS_DIAMOND_ADDRESS" 'fundPoolReward(bytes32,uint8,uint256,uint40,uint16)(uint256)' \
    "$POOL_ID" 1 "$FUND_AMOUNT" 604800 5000 --private-key "$CREATOR_KEY" \
    --rpc-url "$RPC_URL" --legacy --json >"$RUN_DIR/allocator-fund.json"

rpc_warp_by 86400
cast send "$STATICS_DIAMOND_ADDRESS" 'checkpointGaugePool(bytes32)(uint256,uint256)' "$POOL_ID" \
    --private-key "$(anvil_private_key 8)" --rpc-url "$RPC_URL" --legacy --json \
    >"$RUN_DIR/allocator-pool-checkpoint.json"
ALLOCATOR_PREVIEW=$(cast call "$STATICS_DIAMOND_ADDRESS" \
    'previewGaugeAllocatorRewards(uint256,bytes32,uint8[])((uint8,address,uint256,uint256)[])' \
    "$POSITION_ID" "$POOL_ID" '[1]' --from "$CREATOR" --rpc-url "$RPC_URL" --json)
ALLOCATOR_PENDING=$(jq -r '.[0][0][3]' <<<"$ALLOCATOR_PREVIEW")
LP_PREVIEW=$(cast call "$STATICS_DIAMOND_ADDRESS" \
    'previewLpRewards(uint256,bytes32)((uint8,address[5],uint256[5]))' "$POSITION_ID" "$POOL_ID" \
    --rpc-url "$RPC_URL" --json)
LP_PENDING=$(jq -r '.[0][2][1]' <<<"$LP_PREVIEW")
assert_gt "$ALLOCATOR_PENDING" 0 "allocator reward preview"
assert_gt "$LP_PENDING" 0 "LP reward preview for split stream"

BALANCE_BEFORE=$(cast call "$WETH_ADDRESS" 'balanceOf(address)(uint256)' "$CREATOR" --rpc-url "$RPC_URL" | awk '{print $1}')
cast send "$STATICS_DIAMOND_ADDRESS" \
    'claimGaugeAllocatorRewards(uint256,bytes32,uint8[],uint256[],address)(uint256[])' \
    "$POSITION_ID" "$POOL_ID" '[1]' '[0]' "$CREATOR" --private-key "$CREATOR_KEY" \
    --rpc-url "$RPC_URL" --legacy --json >"$RUN_DIR/allocator-claim.json"
BALANCE_AFTER_ALLOCATOR=$(cast call "$WETH_ADDRESS" 'balanceOf(address)(uint256)' "$CREATOR" --rpc-url "$RPC_URL" | awk '{print $1}')
ALLOCATOR_CLAIMED=$(printf '%s - %s\n' "$BALANCE_AFTER_ALLOCATOR" "$BALANCE_BEFORE" | bc)
assert_eq "$ALLOCATOR_CLAIMED" "$ALLOCATOR_PENDING" "allocator claim"

cast send "$STATICS_DIAMOND_ADDRESS" \
    'claimLpRewards(uint256,bytes32,uint8[],uint256[],address)(uint256[])' \
    "$POSITION_ID" "$POOL_ID" '[1]' '[0]' "$CREATOR" --private-key "$CREATOR_KEY" \
    --rpc-url "$RPC_URL" --legacy --json >"$RUN_DIR/allocator-lp-claim.json"
BALANCE_AFTER_LP=$(cast call "$WETH_ADDRESS" 'balanceOf(address)(uint256)' "$CREATOR" --rpc-url "$RPC_URL" | awk '{print $1}')
LP_CLAIMED=$(printf '%s - %s\n' "$BALANCE_AFTER_LP" "$BALANCE_AFTER_ALLOCATOR" | bc)
assert_eq "$LP_CLAIMED" "$LP_PENDING" "LP claim from split stream"
DIFFERENCE=$(printf '%s - %s\n' "$ALLOCATOR_CLAIMED" "$LP_CLAIMED" | bc | sed 's/^-//')
assert_le "$DIFFERENCE" 3 "allocator and LP half-stream rounding"

expect_call_revert "protocol slot cannot be an allocator stream" \
    cast call "$STATICS_DIAMOND_ADDRESS" \
    'gaugeAllocatorReward(bytes32,uint8)((address,bytes32,uint64,uint40,uint40,uint40,uint256,uint256,uint256,uint256,uint256,bool))' \
    "$POOL_ID" 0 --rpc-url "$RPC_URL" >"$RUN_DIR/allocator-slot-zero-revert.txt"

record_result range-gauge allocator-reward-claim pass "$ALLOCATOR_CLAIMED WETH wei"
record_result range-gauge mixed-lp-allocator-split pass "$LP_CLAIMED WETH wei"
record_result range-gauge slot-zero-allocator-isolation pass "$POOL_ID"
note "allocator and mixed LP reward split scenarios passed"
