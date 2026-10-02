#!/usr/bin/env bash

set -Eeuo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

require_commands cast jq awk bc
load_current_run
require_local_chain
reset_to_base

ALICE_INDEX=4
BOB_INDEX=5
OPERATOR_INDEX=6
OUTSIDER_INDEX=7
TRADER_INDEX=8
ALICE=$(anvil_address "$ALICE_INDEX")
BOB=$(anvil_address "$BOB_INDEX")
OPERATOR=$(anvil_address "$OPERATOR_INDEX")
OUTSIDER=$(anvil_address "$OUTSIDER_INDEX")
POSITION_FEE=1000000000000000
STAKE=1000000000000000000000
POOL_ID=$(create_public_pool "$STAKING_TOKEN" "$WETH_ADDRESS" "$ALICE" 91 position-market)

if [[ "${WETH_ADDRESS,,}" < "${STAKING_TOKEN,,}" ]]; then
    CURRENCY0=$WETH_ADDRESS
    CURRENCY1=$STAKING_TOKEN
else
    CURRENCY0=$STAKING_TOKEN
    CURRENCY1=$WETH_ADDRESS
fi

acquire_genesis_statics "$ALICE_INDEX" 3000000000000000000 position-market-owner >/dev/null
wrap_weth "$ALICE_INDEX" 120000000000000000000 position-market-owner
for asset in "$STAKING_TOKEN" "$WETH_ADDRESS"; do
    cast send "$asset" 'approve(address,uint256)' "$STATICS_DIAMOND_ADDRESS" "$(cast max-uint)" \
        --private-key "$(anvil_private_key "$ALICE_INDEX")" --rpc-url "$RPC_URL" --legacy --json \
        >"$RUN_DIR/position-market-approve-${asset,,}.json"
done

POSITION_ID=$(cast call "$STATICS_DIAMOND_ADDRESS" 'nextPositionId()(uint256)' --rpc-url "$RPC_URL" | awk '{print $1}')
cast send "$STATICS_DIAMOND_ADDRESS" 'createAndStake(uint256,address,address[])(uint256)' \
    "$STAKE" "$ALICE" "[$CURRENCY0,$CURRENCY1]" --value "$POSITION_FEE" \
    --private-key "$(anvil_private_key "$ALICE_INDEX")" --rpc-url "$RPC_URL" --legacy --json \
    >"$RUN_DIR/position-market-create-stake.json"

ALLOCATION_STATE=$(cast call "$STATICS_DIAMOND_ADDRESS" \
    'gaugePositionAllocations(uint256)(uint40,uint256,(bytes32,uint256,bytes32)[],uint256)' \
    "$POSITION_ID" --from "$OUTSIDER" --rpc-url "$RPC_URL")
NEXT_ALLOCATION_AT=$(printf '%s\n' "$ALLOCATION_STATE" | sed -n '1s/ .*//p')
rpc_warp_to "$NEXT_ALLOCATION_AT"
cast send "$STATICS_DIAMOND_ADDRESS" 'checkpointRewardAssets(address[])' "[$CURRENCY0,$CURRENCY1]" \
    --private-key "$(anvil_private_key "$OUTSIDER_INDEX")" --rpc-url "$RPC_URL" --legacy --json \
    >"$RUN_DIR/position-market-checkpoint-assets.json"
cast send "$STATICS_DIAMOND_ADDRESS" 'setGaugeAllocations(uint256,bytes32[],uint256[])' \
    "$POSITION_ID" "[$POOL_ID]" "[$STAKE]" --private-key "$(anvil_private_key "$ALICE_INDEX")" \
    --rpc-url "$RPC_URL" --legacy --json >"$RUN_DIR/position-market-allocate.json"

DEADLINE=$(( $(cast block latest --field timestamp --rpc-url "$RPC_URL") + 3600 ))
cast send "$STATICS_DIAMOND_ADDRESS" \
    'provideLiquidity(uint256,(bytes32,int24,int24,uint128,uint256,uint256,uint256))((uint256,uint128,uint256,uint256,uint256,uint256))' \
    "$POSITION_ID" "($POOL_ID,-1200,1200,100000000000000000000,90000000000000000000,90000000000000000000,$DEADLINE)" \
    --private-key "$(anvil_private_key "$ALICE_INDEX")" --rpc-url "$RPC_URL" --legacy --json \
    >"$RUN_DIR/position-market-provide.json"

# Create simultaneous LP, allocator, global reward, and native LP fee state.
ALLOW_CALLDATA=$(cast calldata 'setGaugeRewardAssetAllowed(address,bool)' "$WETH_ADDRESS" true)
timelock_call "$STATICS_DIAMOND_ADDRESS" 0 "$ALLOW_CALLDATA" position-market-allow-weth
cast send "$STATICS_DIAMOND_ADDRESS" 'appendPoolRewardAsset(bytes32,address)(uint8)' \
    "$POOL_ID" "$WETH_ADDRESS" --private-key "$(anvil_private_key "$ALICE_INDEX")" \
    --rpc-url "$RPC_URL" --legacy --json >"$RUN_DIR/position-market-append-slot.json"
cast send "$STATICS_DIAMOND_ADDRESS" 'setPoolRewardAllocatorShare(bytes32,uint8,uint16)' \
    "$POOL_ID" 1 5000 --private-key "$(anvil_private_key "$ALICE_INDEX")" \
    --rpc-url "$RPC_URL" --legacy --json >"$RUN_DIR/position-market-set-share.json"
FUND_AMOUNT=7000000000000000000
cast send "$WETH_ADDRESS" 'approve(address,uint256)' "$STATICS_DIAMOND_ADDRESS" "$FUND_AMOUNT" \
    --private-key "$(anvil_private_key "$ALICE_INDEX")" --rpc-url "$RPC_URL" --legacy --json \
    >"$RUN_DIR/position-market-fund-approve.json"
cast send "$STATICS_DIAMOND_ADDRESS" 'fundPoolReward(bytes32,uint8,uint256,uint40,uint16)(uint256)' \
    "$POOL_ID" 1 "$FUND_AMOUNT" 604800 5000 --private-key "$(anvil_private_key "$ALICE_INDEX")" \
    --rpc-url "$RPC_URL" --legacy --json >"$RUN_DIR/position-market-fund.json"

wrap_weth "$TRADER_INDEX" 5000000000000000000 position-market-trader
acquire_genesis_statics "$TRADER_INDEX" 1000000000000000000 position-market-trader >/dev/null
v4_swap_exact_in "$TRADER_INDEX" "$CURRENCY0" "$CURRENCY1" 3000 60 "$STATICS_SWAP_FEE_HOOK_ADDRESS" true 500000000000000000 position-market-swap0
v4_swap_exact_in "$TRADER_INDEX" "$CURRENCY0" "$CURRENCY1" 3000 60 "$STATICS_SWAP_FEE_HOOK_ADDRESS" false 500000000000000000 position-market-swap1
rpc_warp_by 86400
cast send "$STATICS_DIAMOND_ADDRESS" 'checkpointGaugePool(bytes32)(uint256,uint256)' "$POOL_ID" \
    --private-key "$(anvil_private_key "$OUTSIDER_INDEX")" --rpc-url "$RPC_URL" --legacy --json \
    >"$RUN_DIR/position-market-gauge-checkpoint.json"

# Every economically meaningful Phase 1 view is callable by a prospective buyer.
STAKE_VIEW=$(cast call "$STATICS_DIAMOND_ADDRESS" \
    'stakePosition(uint256)((uint256,uint16,uint256,uint256))' "$POSITION_ID" \
    --from "$OUTSIDER" --rpc-url "$RPC_URL" --json)
assert_eq "$(jq -r '.[0][0]' <<<"$STAKE_VIEW")" "$STAKE" "public staked balance"
assert_eq "$(jq -r '.[0][3]' <<<"$STAKE_VIEW")" 2 "public reward asset count"
REWARD_ASSETS=$(cast call "$STATICS_DIAMOND_ADDRESS" 'positionRewardAssets(uint256)(address[])' \
    "$POSITION_ID" --from "$OUTSIDER" --rpc-url "$RPC_URL" --json)
assert_eq "$(jq -r '.[0] | length' <<<"$REWARD_ASSETS")" 2 "public selected reward assets"
for asset in "$CURRENCY0" "$CURRENCY1"; do
    assert_eq "$(cast call "$STATICS_DIAMOND_ADDRESS" 'isRewardAssetOptedIn(uint256,address)(bool)' \
        "$POSITION_ID" "$asset" --from "$OUTSIDER" --rpc-url "$RPC_URL")" true "public opt-in for $asset"
    cast call "$STATICS_DIAMOND_ADDRESS" \
        'rewardSelection(uint256,address)((bool,uint256,uint256,uint256,uint256,uint40))' \
        "$POSITION_ID" "$asset" --from "$OUTSIDER" --rpc-url "$RPC_URL" >/dev/null
done
PENDING_GLOBAL=$(cast call "$STATICS_DIAMOND_ADDRESS" 'pendingRewards(uint256,address[])(uint256[])' \
    "$POSITION_ID" "[$CURRENCY0,$CURRENCY1]" --from "$OUTSIDER" --rpc-url "$RPC_URL" --json)
assert_gt "$(jq -r '.[0][0]' <<<"$PENDING_GLOBAL")" 0 "public currency0 pending reward"
assert_gt "$(jq -r '.[0][1]' <<<"$PENDING_GLOBAL")" 0 "public currency1 pending reward"
GLOBAL_PAGE=$(cast call "$STATICS_DIAMOND_ADDRESS" \
    'globalRewardAssetsOfPosition(uint256,uint256,uint256)(address[],uint256)' \
    "$POSITION_ID" 0 1 --from "$OUTSIDER" --rpc-url "$RPC_URL" --json)
assert_eq "$(jq -r '.[0] | length' <<<"$GLOBAL_PAGE")" 1 "bounded global reward asset page"
GLOBAL_NEXT=$(jq -r '.[1]' <<<"$GLOBAL_PAGE")
GLOBAL_SECOND=$(cast call "$STATICS_DIAMOND_ADDRESS" \
    'globalRewardAssetsOfPosition(uint256,uint256,uint256)(address[],uint256)' \
    "$POSITION_ID" "$GLOBAL_NEXT" 1 --from "$OUTSIDER" --rpc-url "$RPC_URL" --json)
assert_eq "$(jq -r '.[0] | length' <<<"$GLOBAL_SECOND")" 1 "second global reward asset page"
GLOBAL_END=$(cast call "$STATICS_DIAMOND_ADDRESS" \
    'globalRewardAssetsOfPosition(uint256,uint256,uint256)(address[],uint256)' \
    "$POSITION_ID" 99 1 --from "$OUTSIDER" --rpc-url "$RPC_URL" --json)
assert_eq "$(jq -r '.[0] | length' <<<"$GLOBAL_END")" 0 "global reward asset page past end"
expect_call_revert "zero global reward page" \
    cast call "$STATICS_DIAMOND_ADDRESS" \
    'globalRewardAssetsOfPosition(uint256,uint256,uint256)(address[],uint256)' \
    "$POSITION_ID" 0 0 --from "$OUTSIDER" --rpc-url "$RPC_URL" >/dev/null

GAUGE_ALLOCATIONS=$(cast call "$STATICS_DIAMOND_ADDRESS" \
    'gaugePositionAllocations(uint256)(uint40,uint256,(bytes32,uint256,bytes32)[],uint256)' \
    "$POSITION_ID" --from "$OUTSIDER" --rpc-url "$RPC_URL" --json)
assert_eq "$(jq -r '.[1]' <<<"$GAUGE_ALLOCATIONS")" "$STAKE" "public aggregate gauge allocation"
assert_eq "$(jq -r '.[2][0][0]' <<<"$GAUGE_ALLOCATIONS")" "$POOL_ID" "public allocated pool"
ALLOCATOR_POOLS=$(cast call "$STATICS_DIAMOND_ADDRESS" \
    'positionGaugeAllocatorPools(uint256,uint256,uint256)(bytes32[],uint256)' \
    "$POSITION_ID" 0 10 --from "$OUTSIDER" --rpc-url "$RPC_URL" --json)
assert_eq "$(jq -r '.[0][0]' <<<"$ALLOCATOR_POOLS")" "$POOL_ID" "public allocator pool portfolio"
expect_call_revert "zero allocator pool page" \
    cast call "$STATICS_DIAMOND_ADDRESS" \
    'positionGaugeAllocatorPools(uint256,uint256,uint256)(bytes32[],uint256)' \
    "$POSITION_ID" 0 0 --from "$OUTSIDER" --rpc-url "$RPC_URL" >/dev/null
RANGE_POOLS=$(cast call "$STATICS_DIAMOND_ADDRESS" \
    'positionGaugePools(uint256,uint256,uint256)(bytes32[],uint256)' \
    "$POSITION_ID" 0 10 --from "$OUTSIDER" --rpc-url "$RPC_URL" --json)
assert_eq "$(jq -r '.[0][0]' <<<"$RANGE_POOLS")" "$POOL_ID" "public managed range portfolio"
LP_LEG=$(cast call "$STATICS_DIAMOND_ADDRESS" \
    'lpLeg(uint256,bytes32)((address,uint256,int24,int24,uint128,uint256[5],uint256[5],uint256[5]))' \
    "$POSITION_ID" "$POOL_ID" --from "$OUTSIDER" --rpc-url "$RPC_URL" --json)
assert_gt "$(jq -r '.[0][4]' <<<"$LP_LEG")" 0 "public managed liquidity"
LP_PREVIEW=$(cast call "$STATICS_DIAMOND_ADDRESS" \
    'previewLpRewards(uint256,bytes32)((uint8,address[5],uint256[5]))' \
    "$POSITION_ID" "$POOL_ID" --from "$OUTSIDER" --rpc-url "$RPC_URL" --json)
assert_gt "$(jq -r '.[0][2][1]' <<<"$LP_PREVIEW")" 0 "public LP reward preview"
ALLOCATOR_PREVIEW=$(cast call "$STATICS_DIAMOND_ADDRESS" \
    'previewGaugeAllocatorRewards(uint256,bytes32,uint8[])((uint8,address,uint256,uint256)[])' \
    "$POSITION_ID" "$POOL_ID" '[1]' --from "$OUTSIDER" --rpc-url "$RPC_URL" --json)
assert_gt "$(jq -r '.[0][0][3]' <<<"$ALLOCATOR_PREVIEW")" 0 "public allocator reward preview"
NATIVE_PREVIEW=$(cast call "$STATICS_DIAMOND_ADDRESS" \
    'previewNativeLpFees(uint256,bytes32)(uint256,uint256)' "$POSITION_ID" "$POOL_ID" \
    --from "$OUTSIDER" --rpc-url "$RPC_URL" --json)
NATIVE_TOTAL=$(printf '%s + %s\n' "$(jq -r '.[0]' <<<"$NATIVE_PREVIEW")" "$(jq -r '.[1]' <<<"$NATIVE_PREVIEW")" | bc)
assert_gt "$NATIVE_TOTAL" 0 "public native LP fee preview"

# ERC-721 transfer moves the live financial account and clears token approval.
cast send "$STATICS_DIAMOND_ADDRESS" 'approve(address,uint256)' "$OPERATOR" "$POSITION_ID" \
    --private-key "$(anvil_private_key "$ALICE_INDEX")" --rpc-url "$RPC_URL" --legacy --json \
    >"$RUN_DIR/position-market-token-approve.json"
assert_eq "$(cast call "$STATICS_DIAMOND_ADDRESS" 'getApproved(uint256)(address)' "$POSITION_ID" --rpc-url "$RPC_URL")" "$OPERATOR" "pre-transfer token approval"
TREASURY_ETH_BEFORE=$(cast balance "$TREASURY" --rpc-url "$RPC_URL")
cast send "$STATICS_DIAMOND_ADDRESS" 'transferFrom(address,address,uint256)' "$ALICE" "$BOB" "$POSITION_ID" \
    --private-key "$(anvil_private_key "$ALICE_INDEX")" --rpc-url "$RPC_URL" --legacy --json \
    >"$RUN_DIR/position-market-transfer.json"
assert_eq "$(cast call "$STATICS_DIAMOND_ADDRESS" 'ownerOf(uint256)(address)' "$POSITION_ID" --rpc-url "$RPC_URL")" "$BOB" "transferred PositionNFT owner"
assert_eq "$(cast call "$STATICS_DIAMOND_ADDRESS" 'getApproved(uint256)(address)' "$POSITION_ID" --rpc-url "$RPC_URL")" \
    0x0000000000000000000000000000000000000000 "cleared token approval"
assert_eq "$(cast balance "$TREASURY" --rpc-url "$RPC_URL")" "$TREASURY_ETH_BEFORE" "raw transfer charges no royalty"
POST_STAKE=$(cast call "$STATICS_DIAMOND_ADDRESS" 'stakePosition(uint256)((uint256,uint16,uint256,uint256))' \
    "$POSITION_ID" --from "$OUTSIDER" --rpc-url "$RPC_URL" --json)
assert_eq "$(jq -r '.[0][0]' <<<"$POST_STAKE")" "$STAKE" "stake survives transfer"
POST_ALLOCATIONS=$(cast call "$STATICS_DIAMOND_ADDRESS" \
    'gaugePositionAllocations(uint256)(uint40,uint256,(bytes32,uint256,bytes32)[],uint256)' \
    "$POSITION_ID" --from "$OUTSIDER" --rpc-url "$RPC_URL" --json)
assert_eq "$(jq -r '.[1]' <<<"$POST_ALLOCATIONS")" "$STAKE" "allocation survives transfer"
POST_LEG=$(cast call "$STATICS_DIAMOND_ADDRESS" \
    'lpLeg(uint256,bytes32)((address,uint256,int24,int24,uint128,uint256[5],uint256[5],uint256[5]))' \
    "$POSITION_ID" "$POOL_ID" --from "$OUTSIDER" --rpc-url "$RPC_URL" --json)
assert_eq "$(jq -r '.[0][1]' <<<"$POST_LEG")" "$(jq -r '.[0][1]' <<<"$LP_LEG")" "managed POSM survives transfer"
assert_eq "$(jq -r '.[0][4]' <<<"$POST_LEG")" "$(jq -r '.[0][4]' <<<"$LP_LEG")" "managed liquidity survives transfer"

expect_call_revert "previous owner position mutation" \
    cast call "$STATICS_DIAMOND_ADDRESS" 'setGaugeAllocations(uint256,bytes32[],uint256[])' \
    "$POSITION_ID" "[$POOL_ID]" "[$STAKE]" --from "$ALICE" --rpc-url "$RPC_URL" >/dev/null
expect_call_revert "cleared operator position mutation" \
    cast call "$STATICS_DIAMOND_ADDRESS" 'setGaugeAllocations(uint256,bytes32[],uint256[])' \
    "$POSITION_ID" "[$POOL_ID]" "[$STAKE]" --from "$OPERATOR" --rpc-url "$RPC_URL" >/dev/null
expect_call_revert "previous owner fee collection" \
    cast call "$STATICS_DIAMOND_ADDRESS" \
    'collectNativeFees(uint256,bytes32,uint256,uint256,uint256)((uint256,uint128,uint256,uint256,uint256,uint256))' \
    "$POSITION_ID" "$POOL_ID" 0 0 "$(( DEADLINE + 172800 ))" --from "$ALICE" --rpc-url "$RPC_URL" >/dev/null
rpc_warp_by 14401
cast send "$STATICS_DIAMOND_ADDRESS" 'setGaugeAllocations(uint256,bytes32[],uint256[])' \
    "$POSITION_ID" "[$POOL_ID]" "[$STAKE]" --private-key "$(anvil_private_key "$BOB_INDEX")" \
    --rpc-url "$RPC_URL" --legacy --json >"$RUN_DIR/position-market-bob-allocation.json"
COLLECT_DEADLINE=$(( $(cast block latest --field timestamp --rpc-url "$RPC_URL") + 3600 ))
cast send "$STATICS_DIAMOND_ADDRESS" \
    'collectNativeFees(uint256,bytes32,uint256,uint256,uint256)((uint256,uint128,uint256,uint256,uint256,uint256))' \
    "$POSITION_ID" "$POOL_ID" 0 0 "$COLLECT_DEADLINE" --private-key "$(anvil_private_key "$BOB_INDEX")" \
    --rpc-url "$RPC_URL" --legacy --json >"$RUN_DIR/position-market-bob-collect.json"

# Royalty policy is timelocked signaling only and remains isolated from raw transfer mechanics.
expect_call_revert "unauthorized royalty setter" \
    cast call "$STATICS_DIAMOND_ADDRESS" 'setPositionRoyalty(address,uint16)' "$OUTSIDER" 100 \
    --from "$OUTSIDER" --rpc-url "$RPC_URL" >/dev/null
expect_call_revert "royalty above cap" \
    cast call "$STATICS_DIAMOND_ADDRESS" 'setPositionRoyalty(address,uint16)' "$OUTSIDER" 1001 \
    --from "$STATICS_TIMELOCK_ADDRESS" --rpc-url "$RPC_URL" >/dev/null
expect_call_revert "invalid zero royalty receiver" \
    cast call "$STATICS_DIAMOND_ADDRESS" 'setPositionRoyalty(address,uint16)' \
    0x0000000000000000000000000000000000000000 100 \
    --from "$STATICS_TIMELOCK_ADDRESS" --rpc-url "$RPC_URL" >/dev/null
ROYALTY_CALLDATA=$(cast calldata 'setPositionRoyalty(address,uint16)' "$OUTSIDER" 1000)
timelock_call "$STATICS_DIAMOND_ADDRESS" 0 "$ROYALTY_CALLDATA" position-market-max-royalty
read -r royalty_receiver royalty_bps <<<"$(
    cast call "$STATICS_DIAMOND_ADDRESS" 'positionRoyalty()(address,uint16)' --rpc-url "$RPC_URL" | tr '\n' ' '
)"
assert_eq "$royalty_receiver" "$OUTSIDER" "governed royalty receiver"
assert_eq "$royalty_bps" 1000 "maximum royalty BPS"
read -r quote_receiver quote_amount <<<"$(
    cast call "$STATICS_DIAMOND_ADDRESS" 'royaltyInfo(uint256,uint256)(address,uint256)' \
        "$POSITION_ID" 1000000000000000000 --rpc-url "$RPC_URL" | awk '{print $1}' | tr '\n' ' '
)"
assert_eq "$quote_receiver" "$OUTSIDER" "updated royalty quote receiver"
assert_eq "$quote_amount" 100000000000000000 "updated royalty quote amount"
ZERO_ROYALTY_CALLDATA=$(cast calldata 'setPositionRoyalty(address,uint16)' "$OUTSIDER" 0)
timelock_call "$STATICS_DIAMOND_ADDRESS" 0 "$ZERO_ROYALTY_CALLDATA" position-market-zero-royalty
assert_eq "$(cast call "$STATICS_DIAMOND_ADDRESS" 'royaltyInfo(uint256,uint256)(address,uint256)' \
    "$POSITION_ID" 1000000000000000000 --rpc-url "$RPC_URL" | tail -n 1 | awk '{print $1}')" 0 "zero royalty amount"

assert_phase_one_solvency position-market-transfer "$CURRENCY0" "$CURRENCY1"
record_result position-market public-introspection pass "stake, rewards, allocations, range, and fee views"
record_result position-market live-account-transfer pass "position $POSITION_ID from $ALICE to $BOB"
record_result position-market approval-clearing pass "$OPERATOR"
record_result position-market royalty-governance pass "0 to 1000 BPS signaling"
note "PositionNFT introspection, transfer, authority, and royalty scenarios passed"
