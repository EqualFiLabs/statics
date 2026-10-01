#!/usr/bin/env bash

set -Eeuo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

require_commands cast jq awk bc
load_current_run
require_local_chain
reset_to_base

CREATOR_INDEX=4
STAKER_INDEX=5
LATER_INDEX=6
TRADER_INDEX=7
MAINTAINER_INDEX=8
CREATOR=$(anvil_address "$CREATOR_INDEX")
STAKER=$(anvil_address "$STAKER_INDEX")
LATER=$(anvil_address "$LATER_INDEX")
POSITION_FEE=1000000000000000
POOL_ID=$(create_public_pool "$STAKING_TOKEN" "$WETH_ADDRESS" "$CREATOR" 31 public-revenue)

if [[ "${WETH_ADDRESS,,}" < "${STAKING_TOKEN,,}" ]]; then
    CURRENCY0=$WETH_ADDRESS
    CURRENCY1=$STAKING_TOKEN
else
    CURRENCY0=$STAKING_TOKEN
    CURRENCY1=$WETH_ADDRESS
fi

# Seed productive liquidity through the real managed PositionNFT path.
acquire_genesis_statics "$CREATOR_INDEX" 2000000000000000000 public-revenue-lp >/dev/null
wrap_weth "$CREATOR_INDEX" 100000000000000000000 public-revenue-lp
cast send "$CURRENCY0" 'approve(address,uint256)' "$STATICS_DIAMOND_ADDRESS" "$(cast max-uint)" \
    --private-key "$(anvil_private_key "$CREATOR_INDEX")" --rpc-url "$RPC_URL" --legacy --json \
    >"$RUN_DIR/public-revenue-lp-approve0.json"
cast send "$CURRENCY1" 'approve(address,uint256)' "$STATICS_DIAMOND_ADDRESS" "$(cast max-uint)" \
    --private-key "$(anvil_private_key "$CREATOR_INDEX")" --rpc-url "$RPC_URL" --legacy --json \
    >"$RUN_DIR/public-revenue-lp-approve1.json"
LP_POSITION=$(cast call "$STATICS_DIAMOND_ADDRESS" 'nextPositionId()(uint256)' --rpc-url "$RPC_URL" | awk '{print $1}')
cast send "$STATICS_DIAMOND_ADDRESS" 'createPosition(address)(uint256)' "$CREATOR" \
    --value "$POSITION_FEE" --private-key "$(anvil_private_key "$CREATOR_INDEX")" \
    --rpc-url "$RPC_URL" --legacy --json >"$RUN_DIR/public-revenue-lp-position.json"
DEADLINE=$(( $(cast block latest --field timestamp --rpc-url "$RPC_URL") + 3600 ))
cast send "$STATICS_DIAMOND_ADDRESS" \
    'provideLiquidity(uint256,(bytes32,int24,int24,uint128,uint256,uint256,uint256))((uint256,uint128,uint256,uint256,uint256,uint256))' \
    "$LP_POSITION" "($POOL_ID,-1200,1200,100000000000000000000,90000000000000000000,90000000000000000000,$DEADLINE)" \
    --private-key "$(anvil_private_key "$CREATOR_INDEX")" --rpc-url "$RPC_URL" --legacy --json \
    >"$RUN_DIR/public-revenue-provide.json"

# Create and mature the real staker selection for both pool assets.
acquire_genesis_statics "$STAKER_INDEX" 1000000000000000000 public-revenue-staker >/dev/null
cast send "$STAKING_TOKEN" 'approve(address,uint256)' "$STATICS_DIAMOND_ADDRESS" "$(cast max-uint)" \
    --private-key "$(anvil_private_key "$STAKER_INDEX")" --rpc-url "$RPC_URL" --legacy --json \
    >"$RUN_DIR/public-revenue-staker-approve.json"
STAKER_POSITION=$(cast call "$STATICS_DIAMOND_ADDRESS" 'nextPositionId()(uint256)' --rpc-url "$RPC_URL" | awk '{print $1}')
cast send "$STATICS_DIAMOND_ADDRESS" 'createAndStake(uint256,address,address[])(uint256)' \
    1000000000000000000000 "$STAKER" "[$CURRENCY0,$CURRENCY1]" \
    --value "$POSITION_FEE" --private-key "$(anvil_private_key "$STAKER_INDEX")" \
    --rpc-url "$RPC_URL" --legacy --json >"$RUN_DIR/public-revenue-staker-position.json"
rpc_warp_by 90000
cast send "$STATICS_DIAMOND_ADDRESS" 'checkpointRewardAssets(address[])' "[$CURRENCY0,$CURRENCY1]" \
    --private-key "$(anvil_private_key "$MAINTAINER_INDEX")" --rpc-url "$RPC_URL" --legacy --json \
    >"$RUN_DIR/public-revenue-reward-checkpoint.json"
assert_eq "$(cast call "$STATICS_DIAMOND_ADDRESS" 'canAccrueStakerRewards(address)(bool)' "$CURRENCY0" --rpc-url "$RPC_URL")" true "currency0 reward eligibility"
assert_eq "$(cast call "$STATICS_DIAMOND_ADDRESS" 'canAccrueStakerRewards(address)(bool)' "$CURRENCY1" --rpc-url "$RPC_URL")" true "currency1 reward eligibility"

# Trade both ways so each asset enters the public fee accounting.
wrap_weth "$TRADER_INDEX" 5000000000000000000 public-revenue-trader
acquire_genesis_statics "$TRADER_INDEX" 1000000000000000000 public-revenue-trader >/dev/null
v4_swap_exact_in "$TRADER_INDEX" "$CURRENCY0" "$CURRENCY1" 3000 60 "$STATICS_SWAP_FEE_HOOK_ADDRESS" true 500000000000000000 public-revenue-swap0
v4_swap_exact_in "$TRADER_INDEX" "$CURRENCY0" "$CURRENCY1" 3000 60 "$STATICS_SWAP_FEE_HOOK_ADDRESS" false 500000000000000000 public-revenue-swap1

PENDING=$(cast call "$STATICS_DIAMOND_ADDRESS" 'pendingRewards(uint256,address[])(uint256[])' \
    "$STAKER_POSITION" "[$CURRENCY0,$CURRENCY1]" --from "$STAKER" --rpc-url "$RPC_URL" --json)
PENDING0=$(jq -r '.[0][0]' <<<"$PENDING")
PENDING1=$(jq -r '.[0][1]' <<<"$PENDING")
assert_gt "$PENDING0" 0 "currency0 staker entitlement"
assert_gt "$PENDING1" 0 "currency1 staker entitlement"
UNFUNDED0=$(cast call "$STATICS_DIAMOND_ADDRESS" 'unfundedSwapRewards(address)(uint256)' "$CURRENCY0" --rpc-url "$RPC_URL" | awk '{print $1}')
UNFUNDED1=$(cast call "$STATICS_DIAMOND_ADDRESS" 'unfundedSwapRewards(address)(uint256)' "$CURRENCY1" --rpc-url "$RPC_URL" | awk '{print $1}')
assert_gt "$UNFUNDED0" 0 "currency0 unfunded crystallized liability"
assert_gt "$UNFUNDED1" 0 "currency1 unfunded crystallized liability"

# A later staker cannot capture the historical swap entitlement.
acquire_genesis_statics "$LATER_INDEX" 1000000000000000000 public-revenue-later >/dev/null
cast send "$STAKING_TOKEN" 'approve(address,uint256)' "$STATICS_DIAMOND_ADDRESS" "$(cast max-uint)" \
    --private-key "$(anvil_private_key "$LATER_INDEX")" --rpc-url "$RPC_URL" --legacy --json \
    >"$RUN_DIR/public-revenue-later-approve.json"
LATER_POSITION=$(cast call "$STATICS_DIAMOND_ADDRESS" 'nextPositionId()(uint256)' --rpc-url "$RPC_URL" | awk '{print $1}')
cast send "$STATICS_DIAMOND_ADDRESS" 'createAndStake(uint256,address,address[])(uint256)' \
    1000000000000000000000 "$LATER" "[$CURRENCY0,$CURRENCY1]" \
    --value "$POSITION_FEE" --private-key "$(anvil_private_key "$LATER_INDEX")" \
    --rpc-url "$RPC_URL" --legacy --json >"$RUN_DIR/public-revenue-later-position.json"
LATER_PENDING=$(cast call "$STATICS_DIAMOND_ADDRESS" 'pendingRewards(uint256,address[])(uint256[])' \
    "$LATER_POSITION" "[$CURRENCY0,$CURRENCY1]" --from "$LATER" --rpc-url "$RPC_URL" --json)
assert_eq "$(jq -r '.[0][0]' <<<"$LATER_PENDING")" 0 "later staker currency0 historical entitlement"
assert_eq "$(jq -r '.[0][1]' <<<"$LATER_PENDING")" 0 "later staker currency1 historical entitlement"

# Claiming funds the already crystallized liability without changing its owner.
BALANCE0_BEFORE=$(cast call "$CURRENCY0" 'balanceOf(address)(uint256)' "$STAKER" --rpc-url "$RPC_URL" | awk '{print $1}')
BALANCE1_BEFORE=$(cast call "$CURRENCY1" 'balanceOf(address)(uint256)' "$STAKER" --rpc-url "$RPC_URL" | awk '{print $1}')
cast send "$STATICS_DIAMOND_ADDRESS" 'claimRewards(uint256,address[],address,uint256[])(uint256[])' \
    "$STAKER_POSITION" "[$CURRENCY0,$CURRENCY1]" "$STAKER" '[0,0]' \
    --private-key "$(anvil_private_key "$STAKER_INDEX")" --rpc-url "$RPC_URL" --legacy --json \
    >"$RUN_DIR/public-revenue-staker-claim.json"
CLAIMED0=$(printf '%s - %s\n' "$(cast call "$CURRENCY0" 'balanceOf(address)(uint256)' "$STAKER" --rpc-url "$RPC_URL" | awk '{print $1}')" "$BALANCE0_BEFORE" | bc)
CLAIMED1=$(printf '%s - %s\n' "$(cast call "$CURRENCY1" 'balanceOf(address)(uint256)' "$STAKER" --rpc-url "$RPC_URL" | awk '{print $1}')" "$BALANCE1_BEFORE" | bc)
assert_eq "$CLAIMED0" "$PENDING0" "currency0 crystallized reward claim"
assert_eq "$CLAIMED1" "$PENDING1" "currency1 crystallized reward claim"
assert_eq "$(cast call "$STATICS_DIAMOND_ADDRESS" 'unfundedSwapRewards(address)(uint256)' "$CURRENCY0" --rpc-url "$RPC_URL" | awk '{print $1}')" 0 "currency0 funded liability"
assert_eq "$(cast call "$STATICS_DIAMOND_ADDRESS" 'unfundedSwapRewards(address)(uint256)' "$CURRENCY1" --rpc-url "$RPC_URL" | awk '{print $1}')" 0 "currency1 funded liability"

# Pull remaining public revenue, then exercise creator and Treasury claims.
for asset in "$CURRENCY0" "$CURRENCY1"; do
    cast send "$STATICS_DIAMOND_ADDRESS" 'settleProtocolPoolRevenue(bytes32,address)(uint256,uint256)' \
        "$POOL_ID" "$asset" --private-key "$(anvil_private_key "$MAINTAINER_INDEX")" \
        --rpc-url "$RPC_URL" --legacy --json >"$RUN_DIR/public-revenue-settle-${asset,,}.json"
    CREATOR_CREDIT=$(cast call "$STATICS_DIAMOND_ADDRESS" 'creatorRevenue(bytes32,address)(uint256)' \
        "$POOL_ID" "$asset" --rpc-url "$RPC_URL" | awk '{print $1}')
    assert_gt "$CREATOR_CREDIT" 0 "creator credit for $asset"
    CREATOR_BEFORE=$(cast call "$asset" 'balanceOf(address)(uint256)' "$CREATOR" --rpc-url "$RPC_URL" | awk '{print $1}')
    cast send "$STATICS_DIAMOND_ADDRESS" 'claimCreatorRevenue(bytes32,address,address,uint256)(uint256,uint256)' \
        "$POOL_ID" "$asset" "$CREATOR" 0 --private-key "$(anvil_private_key "$CREATOR_INDEX")" \
        --rpc-url "$RPC_URL" --legacy --json >"$RUN_DIR/public-revenue-creator-${asset,,}.json"
    CREATOR_RECEIVED=$(printf '%s - %s\n' "$(cast call "$asset" 'balanceOf(address)(uint256)' "$CREATOR" --rpc-url "$RPC_URL" | awk '{print $1}')" "$CREATOR_BEFORE" | bc)
    assert_eq "$CREATOR_RECEIVED" "$CREATOR_CREDIT" "creator claim for $asset"
    TREASURY_CREDIT=$(cast call "$STATICS_DIAMOND_ADDRESS" 'treasuryAccrued(address)(uint256)' "$asset" --rpc-url "$RPC_URL" | awk '{print $1}')
    assert_gt "$TREASURY_CREDIT" 0 "treasury credit for $asset"
    TREASURY_TOKEN_BEFORE=$(cast call "$asset" 'balanceOf(address)(uint256)' "$TREASURY" --rpc-url "$RPC_URL" | awk '{print $1}')
    cast send "$STATICS_DIAMOND_ADDRESS" 'distributeTreasuryFees(address)(uint256)' "$asset" \
        --private-key "$(anvil_private_key "$MAINTAINER_INDEX")" --rpc-url "$RPC_URL" --legacy --json \
        >"$RUN_DIR/public-revenue-treasury-${asset,,}.json"
    TREASURY_RECEIVED=$(printf '%s - %s\n' "$(cast call "$asset" 'balanceOf(address)(uint256)' "$TREASURY" --rpc-url "$RPC_URL" | awk '{print $1}')" "$TREASURY_TOKEN_BEFORE" | bc)
    assert_eq "$TREASURY_RECEIVED" "$TREASURY_CREDIT" "treasury distribution for $asset"
done

# Restriction changes future routing only. Existing ownership was already paid.
cast send "$STATICS_DIAMOND_ADDRESS" 'addRewardRestriction(address)' "$CURRENCY0" \
    --private-key "$(anvil_private_key 1)" --rpc-url "$RPC_URL" --legacy --json \
    >"$RUN_DIR/public-revenue-restrict.json"
assert_eq "$(cast call "$STATICS_DIAMOND_ADDRESS" 'canAccrueStakerRewards(address)(bool)' "$CURRENCY0" --rpc-url "$RPC_URL")" false "restricted reward eligibility"
RESTRICTED_UNFUNDED_BEFORE=$(cast call "$STATICS_DIAMOND_ADDRESS" 'unfundedSwapRewards(address)(uint256)' "$CURRENCY0" --rpc-url "$RPC_URL" | awk '{print $1}')
TREASURY_BUCKET_BEFORE=$(cast call "$STATICS_SWAP_FEE_HOOK_ADDRESS" \
    'pendingFeeDistribution(bytes32,address)((uint256,uint256,uint256,uint256))' "$POOL_ID" "$CURRENCY0" \
    --rpc-url "$RPC_URL" --json | jq -r '.[0][3]')
v4_swap_exact_in "$TRADER_INDEX" "$CURRENCY0" "$CURRENCY1" 3000 60 "$STATICS_SWAP_FEE_HOOK_ADDRESS" true 100000000000000000 public-revenue-restricted-swap0
v4_swap_exact_in "$TRADER_INDEX" "$CURRENCY0" "$CURRENCY1" 3000 60 "$STATICS_SWAP_FEE_HOOK_ADDRESS" false 100000000000000000 public-revenue-restricted-swap1
assert_eq "$(cast call "$STATICS_DIAMOND_ADDRESS" 'unfundedSwapRewards(address)(uint256)' "$CURRENCY0" --rpc-url "$RPC_URL" | awk '{print $1}')" "$RESTRICTED_UNFUNDED_BEFORE" "restricted asset creates no new staker liability"
TREASURY_BUCKET_AFTER=$(cast call "$STATICS_SWAP_FEE_HOOK_ADDRESS" \
    'pendingFeeDistribution(bytes32,address)((uint256,uint256,uint256,uint256))' "$POOL_ID" "$CURRENCY0" \
    --rpc-url "$RPC_URL" --json | jq -r '.[0][3]')
assert_gt "$TREASURY_BUCKET_AFTER" "$TREASURY_BUCKET_BEFORE" "restricted staker share Treasury fallback"
REMOVE_CALLDATA=$(cast calldata 'removeRewardRestriction(address)' "$CURRENCY0")
timelock_call "$STATICS_DIAMOND_ADDRESS" 0 "$REMOVE_CALLDATA" public-revenue-unrestrict
assert_eq "$(cast call "$STATICS_DIAMOND_ADDRESS" 'canAccrueStakerRewards(address)(bool)' "$CURRENCY0" --rpc-url "$RPC_URL")" true "restored reward eligibility"
RESUMED_BEFORE=$(cast call "$STATICS_SWAP_FEE_HOOK_ADDRESS" 'pendingStakerRewards(address)(uint256)' "$CURRENCY0" --rpc-url "$RPC_URL" | awk '{print $1}')
v4_swap_exact_in "$TRADER_INDEX" "$CURRENCY0" "$CURRENCY1" 3000 60 "$STATICS_SWAP_FEE_HOOK_ADDRESS" true 100000000000000000 public-revenue-resumed
RESUMED_AFTER=$(cast call "$STATICS_SWAP_FEE_HOOK_ADDRESS" 'pendingStakerRewards(address)(uint256)' "$CURRENCY0" --rpc-url "$RPC_URL" | awk '{print $1}')
assert_gt "$RESUMED_AFTER" "$RESUMED_BEFORE" "staker accrual after restriction removal"

record_result global-rewards crystallized-claim pass "$CLAIMED0 currency0 wei, $CLAIMED1 currency1 wei"
record_result global-rewards later-staker-isolation pass "position $LATER_POSITION"
record_result protocol-revenue creator-and-treasury-claims pass "$POOL_ID"
record_result reward-policy restriction-fallback-and-resume pass "$CURRENCY0"
note "public revenue, global reward, and restriction scenarios passed"
