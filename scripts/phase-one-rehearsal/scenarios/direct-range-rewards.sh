#!/usr/bin/env bash

set -Eeuo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

require_commands cast jq awk bc
load_current_run
require_local_chain
reset_to_base

LP_INDEX=18
LP=$(anvil_address "$LP_INDEX")
LP_KEY=$(anvil_private_key "$LP_INDEX")
POSITION_FEE=1000000000000000
POOL_ID=$(create_public_pool "$STAKING_TOKEN" "$WETH_ADDRESS" "$LP" 5 direct-rewards)

if [[ "${WETH_ADDRESS,,}" < "${STAKING_TOKEN,,}" ]]; then
    CURRENCY0=$WETH_ADDRESS
    CURRENCY1=$STAKING_TOKEN
else
    CURRENCY0=$STAKING_TOKEN
    CURRENCY1=$WETH_ADDRESS
fi

acquire_genesis_statics "$LP_INDEX" 2000000000000000000 direct-reward-lp >/dev/null
wrap_weth "$LP_INDEX" 100000000000000000000 direct-reward-lp
cast send "$CURRENCY0" 'approve(address,uint256)' "$STATICS_DIAMOND_ADDRESS" "$(cast max-uint)" \
    --private-key "$LP_KEY" --rpc-url "$RPC_URL" --legacy --json \
    >"$RUN_DIR/direct-reward-currency0-approve.json"
cast send "$CURRENCY1" 'approve(address,uint256)' "$STATICS_DIAMOND_ADDRESS" "$(cast max-uint)" \
    --private-key "$LP_KEY" --rpc-url "$RPC_URL" --legacy --json \
    >"$RUN_DIR/direct-reward-currency1-approve.json"

POSITION_ID=$(cast call "$STATICS_DIAMOND_ADDRESS" 'nextPositionId()(uint256)' --rpc-url "$RPC_URL" | awk '{print $1}')
cast send "$STATICS_DIAMOND_ADDRESS" 'createPosition(address)(uint256)' "$LP" \
    --value "$POSITION_FEE" --private-key "$LP_KEY" --rpc-url "$RPC_URL" --legacy --json \
    >"$RUN_DIR/direct-reward-create-position.json"
DEADLINE=$(( $(cast block latest --field timestamp --rpc-url "$RPC_URL") + 3600 ))
cast send "$STATICS_DIAMOND_ADDRESS" \
    'provideLiquidity(uint256,(bytes32,int24,int24,uint128,uint256,uint256,uint256))((uint256,uint128,uint256,uint256,uint256,uint256))' \
    "$POSITION_ID" "($POOL_ID,-1200,1200,100000000000000000000,90000000000000000000,90000000000000000000,$DEADLINE)" \
    --private-key "$LP_KEY" --rpc-url "$RPC_URL" --legacy --json \
    >"$RUN_DIR/direct-reward-provide.json"

ALLOW_CALLDATA=$(cast calldata 'setGaugeRewardAssetAllowed(address,bool)' "$WETH_ADDRESS" true)
timelock_call "$STATICS_DIAMOND_ADDRESS" 0 "$ALLOW_CALLDATA" direct-reward-allow-weth
assert_eq "$(cast call "$STATICS_DIAMOND_ADDRESS" 'gaugeRewardAssetAllowed(address)(bool)' \
    "$WETH_ADDRESS" --rpc-url "$RPC_URL")" true "direct reward asset allowlist"
cast send "$STATICS_DIAMOND_ADDRESS" 'appendPoolRewardAsset(bytes32,address)(uint8)' "$POOL_ID" "$WETH_ADDRESS" \
    --private-key "$LP_KEY" --rpc-url "$RPC_URL" --legacy --json \
    >"$RUN_DIR/direct-reward-append.json"
expect_call_revert "duplicate direct reward asset" \
    cast call "$STATICS_DIAMOND_ADDRESS" 'appendPoolRewardAsset(bytes32,address)(uint8)' \
    "$POOL_ID" "$WETH_ADDRESS" --from "$LP" --rpc-url "$RPC_URL" \
    >"$RUN_DIR/direct-reward-duplicate-asset-revert.txt"

CONFIG=$(cast call "$STATICS_DIAMOND_ADDRESS" \
    'poolRewardConfig(bytes32)((bool,uint8,address[5],uint16[5]))' "$POOL_ID" --rpc-url "$RPC_URL" --json)
assert_eq "$(jq -r '.[0][1]' <<<"$CONFIG")" 2 "range reward slot count"
assert_eq "$(jq -r '.[0][2][1]' <<<"$CONFIG")" "$WETH_ADDRESS" "direct reward asset"
REWARD_ACCOUNT=$(cast call "$STATICS_DIAMOND_ADDRESS" \
    'poolRewardCustodyAccount(bytes32,uint8)(bytes32,bool)' "$POOL_ID" 1 --rpc-url "$RPC_URL" --json)
assert_eq "$(jq -r '.[1]' <<<"$REWARD_ACCOUNT")" true "direct reward custody assignment"
assert_eq "$(jq -r '.[0]' <<<"$REWARD_ACCOUNT")" \
    "$(cast call "$STATICS_DIAMOND_ADDRESS" 'poolRewardCustodyAccount(bytes32,uint8)(bytes32,bool)' \
        "$POOL_ID" 1 --rpc-url "$RPC_URL" | head -n 1)" "stable direct reward custody account"
BOUNDARY=$(cast call "$STATICS_DIAMOND_ADDRESS" \
    'gaugeBoundary(bytes32,int24)((uint128,int128,uint256[5]))' "$POOL_ID" -1200 \
    --rpc-url "$RPC_URL" --json)
assert_gt "$(jq -r '.[0][0]' <<<"$BOUNDARY")" 0 "managed lower gauge boundary"

FUND_AMOUNT=7000000000000000000
cast send "$WETH_ADDRESS" 'approve(address,uint256)' "$STATICS_DIAMOND_ADDRESS" "$FUND_AMOUNT" \
    --private-key "$LP_KEY" --rpc-url "$RPC_URL" --legacy --json \
    >"$RUN_DIR/direct-reward-fund-approve.json"
expect_call_revert "protocol slot zero direct funding" \
    cast call "$STATICS_DIAMOND_ADDRESS" 'fundPoolReward(bytes32,uint8,uint256,uint40,uint16)(uint256)' \
    "$POOL_ID" 0 "$FUND_AMOUNT" 604800 0 --from "$LP" --rpc-url "$RPC_URL" \
    >"$RUN_DIR/direct-reward-slot-zero-fund-revert.txt"
cast send "$STATICS_DIAMOND_ADDRESS" 'fundPoolReward(bytes32,uint8,uint256,uint40,uint16)(uint256)' \
    "$POOL_ID" 1 "$FUND_AMOUNT" 604800 0 \
    --private-key "$LP_KEY" --rpc-url "$RPC_URL" --legacy --json \
    >"$RUN_DIR/direct-reward-fund.json"

rpc_warp_by 86400
PREVIEW=$(cast call "$STATICS_DIAMOND_ADDRESS" \
    'previewLpRewards(uint256,bytes32)((uint8,address[5],uint256[5]))' "$POSITION_ID" "$POOL_ID" \
    --rpc-url "$RPC_URL" --json)
PREVIEW_AMOUNT=$(jq -r '.[0][2][1]' <<<"$PREVIEW")
[[ "$PREVIEW_AMOUNT" != 0 ]] || fail "direct LP reward preview did not accrue"
expect_call_revert "direct reward minimum output" \
    cast call "$STATICS_DIAMOND_ADDRESS" \
    'claimLpRewards(uint256,bytes32,uint8[],uint256[],address)(uint256[])' \
    "$POSITION_ID" "$POOL_ID" '[1]' "[$(( PREVIEW_AMOUNT + 1 ))]" "$LP" \
    --from "$LP" --rpc-url "$RPC_URL" >"$RUN_DIR/direct-reward-minimum-revert.txt"
PREVIEW_AFTER_FAILED_CLAIM=$(cast call "$STATICS_DIAMOND_ADDRESS" \
    'previewLpRewards(uint256,bytes32)((uint8,address[5],uint256[5]))' "$POSITION_ID" "$POOL_ID" \
    --rpc-url "$RPC_URL" --json | jq -r '.[0][2][1]')
assert_ge "$PREVIEW_AFTER_FAILED_CLAIM" "$PREVIEW_AMOUNT" "failed minimum preserves LP entitlement"
BALANCE_BEFORE=$(cast call "$WETH_ADDRESS" 'balanceOf(address)(uint256)' "$LP" --rpc-url "$RPC_URL" | awk '{print $1}')
cast send "$STATICS_DIAMOND_ADDRESS" \
    'claimLpRewards(uint256,bytes32,uint8[],uint256[],address)(uint256[])' \
    "$POSITION_ID" "$POOL_ID" '[1]' '[0]' "$LP" \
    --private-key "$LP_KEY" --rpc-url "$RPC_URL" --legacy --json >"$RUN_DIR/direct-reward-claim.json"
BALANCE_AFTER=$(cast call "$WETH_ADDRESS" 'balanceOf(address)(uint256)' "$LP" --rpc-url "$RPC_URL" | awk '{print $1}')
CLAIMED=$(printf '%s - %s\n' "$BALANCE_AFTER" "$BALANCE_BEFORE" | bc)
[[ "$CLAIMED" != 0 ]] || fail "direct LP reward claim transferred no WETH"

STREAM=$(cast call "$STATICS_DIAMOND_ADDRESS" \
    'poolRewardStream(bytes32,uint8)((bool,uint8,address,uint40,uint40,uint40,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256))' \
    "$POOL_ID" 1 --rpc-url "$RPC_URL" --json)
assert_eq "$(jq -r '.[0][2]' <<<"$STREAM")" "$WETH_ADDRESS" "direct stream reward asset"

# Exit principal while a later slice of the stream is still owed. The claim
# survives exit and remains an explicit PositionNFT close obligation.
rpc_warp_by 86400
DEADLINE=$(( $(cast block latest --field timestamp --rpc-url "$RPC_URL") + 3600 ))
cast send "$STATICS_DIAMOND_ADDRESS" \
    'exitLiquidity(uint256,bytes32,uint256,uint256,uint256)((uint256,uint128,uint256,uint256,uint256,uint256))' \
    "$POSITION_ID" "$POOL_ID" 0 0 "$DEADLINE" --private-key "$LP_KEY" \
    --rpc-url "$RPC_URL" --gas-limit 3000000 --legacy --json >"$RUN_DIR/direct-reward-exit.json"
EXITED_PREVIEW=$(cast call "$STATICS_DIAMOND_ADDRESS" \
    'previewLpRewards(uint256,bytes32)((uint8,address[5],uint256[5]))' "$POSITION_ID" "$POOL_ID" \
    --rpc-url "$RPC_URL" --json | jq -r '.[0][2][1]')
assert_gt "$EXITED_PREVIEW" 0 "exited LP retained reward entitlement"
expect_call_revert "outstanding LP claim blocks PositionNFT close" \
    cast call "$STATICS_DIAMOND_ADDRESS" 'closePosition(uint256)' "$POSITION_ID" \
    --from "$LP" --rpc-url "$RPC_URL" >"$RUN_DIR/direct-reward-close-blocked.txt"
# Let the direct stream finish so resolving the exited position's final claim
# can retire the otherwise-empty gauge leg.
rpc_warp_by 518400
cast send "$STATICS_DIAMOND_ADDRESS" \
    'claimLpRewards(uint256,bytes32,uint8[],uint256[],address)(uint256[])' \
    "$POSITION_ID" "$POOL_ID" '[1]' '[0]' "$LP" --private-key "$LP_KEY" \
    --rpc-url "$RPC_URL" --legacy --json >"$RUN_DIR/direct-reward-exited-claim.json"
cast send "$STATICS_DIAMOND_ADDRESS" 'closePosition(uint256)' "$POSITION_ID" \
    --private-key "$LP_KEY" --rpc-url "$RPC_URL" --legacy --json \
    >"$RUN_DIR/direct-reward-close-after-claim.json"

# A second account proves explicit forfeiture is an alternative liveness path
# and removes the same close obligation without transferring the reward.
SECOND_POSITION=$(cast call "$STATICS_DIAMOND_ADDRESS" 'nextPositionId()(uint256)' --rpc-url "$RPC_URL" | awk '{print $1}')
cast send "$STATICS_DIAMOND_ADDRESS" 'createPosition(address)(uint256)' "$LP" \
    --value "$POSITION_FEE" --private-key "$LP_KEY" --rpc-url "$RPC_URL" --legacy --json \
    >"$RUN_DIR/direct-reward-second-position.json"
for asset in "$CURRENCY0" "$CURRENCY1"; do
    cast send "$asset" 'approve(address,uint256)' "$STATICS_DIAMOND_ADDRESS" "$(cast max-uint)" \
        --private-key "$LP_KEY" --rpc-url "$RPC_URL" --legacy --json \
        >"$RUN_DIR/direct-reward-second-approve-${asset,,}.json"
done
DEADLINE=$(( $(cast block latest --field timestamp --rpc-url "$RPC_URL") + 3600 ))
cast send "$STATICS_DIAMOND_ADDRESS" \
    'provideLiquidity(uint256,(bytes32,int24,int24,uint128,uint256,uint256,uint256))((uint256,uint128,uint256,uint256,uint256,uint256))' \
    "$SECOND_POSITION" "($POOL_ID,-1200,1200,1000000000000000000,10000000000000000000,10000000000000000000,$DEADLINE)" \
    --private-key "$LP_KEY" --rpc-url "$RPC_URL" --legacy --json \
    >"$RUN_DIR/direct-reward-second-provide.json"
cast send "$WETH_ADDRESS" 'approve(address,uint256)' "$STATICS_DIAMOND_ADDRESS" "$FUND_AMOUNT" \
    --private-key "$LP_KEY" --rpc-url "$RPC_URL" --legacy --json \
    >"$RUN_DIR/direct-reward-second-fund-approve.json"
CURRENT_STREAM=$(cast call "$STATICS_DIAMOND_ADDRESS" \
    'poolRewardStream(bytes32,uint8)((bool,uint8,address,uint40,uint40,uint40,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256))' \
    "$POOL_ID" 1 --rpc-url "$RPC_URL" --json)
STREAM_FINISH=$(jq -r '.[0][4]' <<<"$CURRENT_STREAM")
NOW=$(cast block latest --field timestamp --rpc-url "$RPC_URL")
REMAINING_DURATION=$(( STREAM_FINISH - NOW ))
assert_gt "$REMAINING_DURATION" 0 "direct reward top-up remaining duration"
# Anvil may advance the next transaction timestamp by one second after this
# read. Stay just inside the live stream instead of submitting a stale maximum.
TOP_UP_DURATION=$(( REMAINING_DURATION - 10 ))
assert_gt "$TOP_UP_DURATION" 0 "direct reward top-up execution margin"
cast send "$STATICS_DIAMOND_ADDRESS" 'fundPoolReward(bytes32,uint8,uint256,uint40,uint16)(uint256)' \
    "$POOL_ID" 1 "$FUND_AMOUNT" "$TOP_UP_DURATION" 0 --private-key "$LP_KEY" \
    --rpc-url "$RPC_URL" --legacy --json >"$RUN_DIR/direct-reward-second-fund.json"
rpc_warp_by 86400
DEADLINE=$(( $(cast block latest --field timestamp --rpc-url "$RPC_URL") + 3600 ))
cast send "$STATICS_DIAMOND_ADDRESS" \
    'exitLiquidity(uint256,bytes32,uint256,uint256,uint256)((uint256,uint128,uint256,uint256,uint256,uint256))' \
    "$SECOND_POSITION" "$POOL_ID" 0 0 "$DEADLINE" --private-key "$LP_KEY" \
    --rpc-url "$RPC_URL" --gas-limit 3000000 --legacy --json >"$RUN_DIR/direct-reward-second-exit.json"
FORFEIT_PREVIEW=$(cast call "$STATICS_DIAMOND_ADDRESS" \
    'previewLpRewards(uint256,bytes32)((uint8,address[5],uint256[5]))' "$SECOND_POSITION" "$POOL_ID" \
    --rpc-url "$RPC_URL" --json | jq -r '.[0][2][1]')
assert_gt "$FORFEIT_PREVIEW" 0 "second exited LP reward entitlement"
NOW=$(cast block latest --field timestamp --rpc-url "$RPC_URL")
rpc_warp_by "$(( STREAM_FINISH - NOW + 1 ))"
cast send "$STATICS_DIAMOND_ADDRESS" 'forfeitLpReward(uint256,bytes32,uint8)(uint256)' \
    "$SECOND_POSITION" "$POOL_ID" 1 --private-key "$LP_KEY" --rpc-url "$RPC_URL" \
    --legacy --json >"$RUN_DIR/direct-reward-forfeit.json"
cast send "$STATICS_DIAMOND_ADDRESS" 'closePosition(uint256)' "$SECOND_POSITION" \
    --private-key "$LP_KEY" --rpc-url "$RPC_URL" --legacy --json \
    >"$RUN_DIR/direct-reward-close-after-forfeit.json"

record_result range-gauge direct-reward-funding pass "$FUND_AMOUNT WETH wei"
record_result range-gauge direct-reward-claim pass "$CLAIMED WETH wei"
record_result range-gauge exited-claim-liveness pass "$EXITED_PREVIEW WETH wei"
record_result range-gauge explicit-forfeiture-liveness pass "$FORFEIT_PREVIEW WETH wei"
record_result range-gauge direct-slot-guards pass "duplicate and slot-zero funding rejected"
note "direct range-gauge funding, exit, claim, and forfeiture scenarios passed"
