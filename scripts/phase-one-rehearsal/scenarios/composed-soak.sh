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
SUCCESSOR_INDEX=5
TRADER_INDEX=6
MAINTAINER_INDEX=7
CREATOR=$(anvil_address "$CREATOR_INDEX")
SUCCESSOR=$(anvil_address "$SUCCESSOR_INDEX")
CREATOR_KEY=$(anvil_private_key "$CREATOR_INDEX")
SUCCESSOR_KEY=$(anvil_private_key "$SUCCESSOR_INDEX")
POSITION_FEE=1000000000000000
STAKE=1000000000000000000000
POOL_ID=$(create_public_pool "$STAKING_TOKEN" "$WETH_ADDRESS" "$CREATOR" 901 composed-soak)

if [[ "${WETH_ADDRESS,,}" < "${STAKING_TOKEN,,}" ]]; then
    CURRENCY0=$WETH_ADDRESS
    CURRENCY1=$STAKING_TOKEN
else
    CURRENCY0=$STAKING_TOKEN
    CURRENCY1=$WETH_ADDRESS
fi

# Build one PositionNFT carrying stake, reward selections, allocation weight,
# managed liquidity, direct LP rewards, allocator rewards, and protocol slot 0.
acquire_genesis_statics "$CREATOR_INDEX" 4000000000000000000 composed-owner >/dev/null
wrap_weth "$CREATOR_INDEX" 150000000000000000000 composed-owner
for asset in "$CURRENCY0" "$CURRENCY1"; do
    cast send "$asset" 'approve(address,uint256)' "$STATICS_DIAMOND_ADDRESS" "$(cast max-uint)" \
        --private-key "$CREATOR_KEY" --rpc-url "$RPC_URL" --legacy --json \
        >"$RUN_DIR/composed-approve-${asset,,}.json"
done
POSITION_ID=$(cast call "$STATICS_DIAMOND_ADDRESS" 'nextPositionId()(uint256)' --rpc-url "$RPC_URL" | awk '{print $1}')
cast send "$STATICS_DIAMOND_ADDRESS" 'createAndStake(uint256,address,address[])(uint256)' \
    "$STAKE" "$CREATOR" "[$CURRENCY0,$CURRENCY1]" --value "$POSITION_FEE" \
    --private-key "$CREATOR_KEY" --rpc-url "$RPC_URL" --legacy --json \
    >"$RUN_DIR/composed-create-stake.json"
ALLOCATION_STATE=$(cast call "$STATICS_DIAMOND_ADDRESS" \
    'gaugePositionAllocations(uint256)(uint40,uint256,(bytes32,uint256,bytes32)[],uint256)' \
    "$POSITION_ID" --rpc-url "$RPC_URL")
rpc_warp_to "$(printf '%s\n' "$ALLOCATION_STATE" | sed -n '1s/ .*//p')"
cast send "$STATICS_DIAMOND_ADDRESS" 'setGaugeAllocations(uint256,bytes32[],uint256[])' \
    "$POSITION_ID" "[$POOL_ID]" "[$STAKE]" --private-key "$CREATOR_KEY" \
    --rpc-url "$RPC_URL" --legacy --json >"$RUN_DIR/composed-allocate.json"
DEADLINE=$(( $(cast block latest --field timestamp --rpc-url "$RPC_URL") + 86400 ))
cast send "$STATICS_DIAMOND_ADDRESS" \
    'provideLiquidity(uint256,(bytes32,int24,int24,uint128,uint256,uint256,uint256))((uint256,uint128,uint256,uint256,uint256,uint256))' \
    "$POSITION_ID" "($POOL_ID,-1200,1200,100000000000000000000,90000000000000000000,90000000000000000000,$DEADLINE)" \
    --private-key "$CREATOR_KEY" --rpc-url "$RPC_URL" --legacy --json \
    >"$RUN_DIR/composed-provide.json"

timelock_call "$STATICS_DIAMOND_ADDRESS" 0 \
    "$(cast calldata 'setGaugeRewardAssetAllowed(address,bool)' "$WETH_ADDRESS" true)" composed-allow-reward
cast send "$STATICS_DIAMOND_ADDRESS" 'appendPoolRewardAsset(bytes32,address)(uint8)' \
    "$POOL_ID" "$WETH_ADDRESS" --private-key "$CREATOR_KEY" --rpc-url "$RPC_URL" \
    --legacy --json >"$RUN_DIR/composed-append-reward.json"
cast send "$STATICS_DIAMOND_ADDRESS" 'setPoolRewardAllocatorShare(bytes32,uint8,uint16)' \
    "$POOL_ID" 1 2500 --private-key "$CREATOR_KEY" --rpc-url "$RPC_URL" \
    --legacy --json >"$RUN_DIR/composed-allocator-share.json"
FUND_AMOUNT=7000000000000000000
cast send "$WETH_ADDRESS" 'approve(address,uint256)' "$STATICS_DIAMOND_ADDRESS" "$FUND_AMOUNT" \
    --private-key "$CREATOR_KEY" --rpc-url "$RPC_URL" --legacy --json \
    >"$RUN_DIR/composed-direct-approve.json"
cast send "$STATICS_DIAMOND_ADDRESS" 'fundPoolReward(bytes32,uint8,uint256,uint40,uint16)(uint256)' \
    "$POOL_ID" 1 "$FUND_AMOUNT" 604800 2500 --private-key "$CREATOR_KEY" \
    --rpc-url "$RPC_URL" --legacy --json >"$RUN_DIR/composed-direct-fund.json"

cast send "$STAKING_TOKEN" 'approve(address,uint256)' "$STATICS_DIAMOND_ADDRESS" "$(cast max-uint)" \
    --private-key "$CREATOR_KEY" --rpc-url "$RPC_URL" --legacy --json \
    >"$RUN_DIR/composed-reserve-approve.json"
cast send "$STATICS_DIAMOND_ADDRESS" 'fundGaugeReserve(uint256)(uint256)' 100000000000000000000 \
    --private-key "$CREATOR_KEY" --rpc-url "$RPC_URL" --legacy --json \
    >"$RUN_DIR/composed-reserve-fund.json"
timelock_call "$STATICS_DIAMOND_ADDRESS" 0 "$(cast calldata 'activateGaugeSchedule()')" composed-activate-schedule
cast send "$STATICS_DIAMOND_ADDRESS" 'activateProtocolPoolPol(bytes32)' "$POOL_ID" \
    --value 100000000000000000 --private-key "$CREATOR_KEY" --rpc-url "$RPC_URL" \
    --legacy --json >"$RUN_DIR/composed-activate-pol.json"
cast send "$STATICS_DIAMOND_ADDRESS" 'checkpointRewardAssets(address[])' "[$CURRENCY0,$CURRENCY1]" \
    --private-key "$(anvil_private_key "$MAINTAINER_INDEX")" --rpc-url "$RPC_URL" \
    --legacy --json >"$RUN_DIR/composed-checkpoint-reward-assets.json"

wrap_weth "$TRADER_INDEX" 10000000000000000000 composed-trader
acquire_genesis_statics "$TRADER_INDEX" 2000000000000000000 composed-trader >/dev/null
v4_swap_exact_in "$TRADER_INDEX" "$CURRENCY0" "$CURRENCY1" 3000 60 \
    "$STATICS_SWAP_FEE_HOOK_ADDRESS" true 500000000000000000 composed-swap0
v4_swap_exact_in "$TRADER_INDEX" "$CURRENCY0" "$CURRENCY1" 3000 60 \
    "$STATICS_SWAP_FEE_HOOK_ADDRESS" false 500000000000000000 composed-swap1
rpc_warp_by 86400
cast send "$STATICS_DIAMOND_ADDRESS" 'checkpointGaugePool(bytes32)(uint256,uint256)' "$POOL_ID" \
    --private-key "$(anvil_private_key "$MAINTAINER_INDEX")" --rpc-url "$RPC_URL" \
    --gas-limit 3000000 --legacy --json >"$RUN_DIR/composed-checkpoint-pool.json"

LP_PREVIEW=$(cast call "$STATICS_DIAMOND_ADDRESS" \
    'previewLpRewards(uint256,bytes32)((uint8,address[5],uint256[5]))' "$POSITION_ID" "$POOL_ID" \
    --rpc-url "$RPC_URL" --json)
assert_gt "$(jq -r '.[0][2][0] + .[0][2][1]' <<<"$LP_PREVIEW")" 0 "composed LP rewards"
ALLOCATOR_PREVIEW=$(cast call "$STATICS_DIAMOND_ADDRESS" \
    'previewGaugeAllocatorRewards(uint256,bytes32,uint8[])((uint8,address,uint256,uint256)[])' \
    "$POSITION_ID" "$POOL_ID" '[1]' --rpc-url "$RPC_URL" --json | jq -r '.[0][0][3]')
assert_gt "$ALLOCATOR_PREVIEW" 0 "composed allocator rewards"
GLOBAL_PREVIEW=$(cast call "$STATICS_DIAMOND_ADDRESS" 'pendingRewards(uint256,address[])(uint256[])' \
    "$POSITION_ID" "[$CURRENCY0,$CURRENCY1]" --rpc-url "$RPC_URL" --json)
assert_gt "$(jq -r '.[0][0] + .[0][1]' <<<"$GLOBAL_PREVIEW")" 0 "composed global rewards"

# Settle PoolId-local POL and open a live protocol position before changing
# creator and PositionNFT ownership.
for asset in "$CURRENCY0" "$CURRENCY1"; do
    cast send "$STATICS_DIAMOND_ADDRESS" 'settleProtocolPoolPol(bytes32,address,uint256)(uint256)' \
        "$POOL_ID" "$asset" 0 --private-key "$(anvil_private_key "$MAINTAINER_INDEX")" \
        --rpc-url "$RPC_URL" --legacy --json >"$RUN_DIR/composed-settle-pol-${asset,,}.json"
done
POL_ACCOUNT=$(cast call "$STATICS_DIAMOND_ADDRESS" 'protocolPolCustodyAccount(bytes32)(bytes32)' "$POOL_ID" --rpc-url "$RPC_URL")
RESERVE0=$(cast call "$STATICS_DIAMOND_ADDRESS" 'reservedByAccount(bytes32,address)(uint256)' "$POL_ACCOUNT" "$CURRENCY0" --rpc-url "$RPC_URL" | awk '{print $1}')
RESERVE1=$(cast call "$STATICS_DIAMOND_ADDRESS" 'reservedByAccount(bytes32,address)(uint256)' "$POL_ACCOUNT" "$CURRENCY1" --rpc-url "$RPC_URL" | awk '{print $1}')
assert_gt "$RESERVE0" 0 "composed POL currency0 reserve"
assert_gt "$RESERVE1" 0 "composed POL currency1 reserve"
DEADLINE=$(( $(cast block latest --field timestamp --rpc-url "$RPC_URL") + 86400 ))
cast send "$STATICS_DIAMOND_ADDRESS" \
    'openProtocolPolPosition((bytes32,int24,int24,uint128,uint256,uint256,uint256))(uint256)' \
    "($POOL_ID,-600,600,1000000000000,$RESERVE0,$RESERVE1,$DEADLINE)" \
    --private-key "$(anvil_private_key 3)" --rpc-url "$RPC_URL" --gas-limit 3000000 \
    --legacy --json >"$RUN_DIR/composed-open-pol.json"
POL_POSITION=$(cast call "$STATICS_DIAMOND_ADDRESS" 'protocolPolPositionIds(bytes32)(uint256[])' "$POOL_ID" --rpc-url "$RPC_URL" --json | jq -r '.[0][0]')

# Both transferable authorities move while every economic subsystem is live.
cast send "$STATICS_DIAMOND_ADDRESS" 'proposePoolCreator(bytes32,address)' "$POOL_ID" "$SUCCESSOR" \
    --private-key "$CREATOR_KEY" --rpc-url "$RPC_URL" --legacy --json \
    >"$RUN_DIR/composed-propose-creator.json"
cast send "$STATICS_DIAMOND_ADDRESS" 'acceptPoolCreator(bytes32)' "$POOL_ID" \
    --private-key "$SUCCESSOR_KEY" --rpc-url "$RPC_URL" --legacy --json \
    >"$RUN_DIR/composed-accept-creator.json"
cast send "$STATICS_DIAMOND_ADDRESS" 'transferFrom(address,address,uint256)' "$CREATOR" "$SUCCESSOR" "$POSITION_ID" \
    --private-key "$CREATOR_KEY" --rpc-url "$RPC_URL" --legacy --json \
    >"$RUN_DIR/composed-transfer-position.json"
expect_call_revert "former PositionNFT owner after transfer" \
    cast call "$STATICS_DIAMOND_ADDRESS" 'setGaugeAllocations(uint256,bytes32[],uint256[])' \
    "$POSITION_ID" '[]' '[]' --from "$CREATOR" --rpc-url "$RPC_URL" \
    >"$RUN_DIR/composed-former-owner-revert.txt"
cast send "$STATICS_DIAMOND_ADDRESS" 'setGaugeAllocations(uint256,bytes32[],uint256[])' \
    "$POSITION_ID" '[]' '[]' --private-key "$SUCCESSOR_KEY" --rpc-url "$RPC_URL" \
    --gas-limit 3000000 --legacy --json >"$RUN_DIR/composed-deallocate.json"

# Reward policy changes and emergency controls execute against the accumulated
# state rather than isolated fixtures.
cast send "$STATICS_DIAMOND_ADDRESS" 'addRewardRestriction(address)' "$CURRENCY0" \
    --private-key "$(anvil_private_key 1)" --rpc-url "$RPC_URL" --legacy --json \
    >"$RUN_DIR/composed-restrict.json"
v4_swap_exact_in "$TRADER_INDEX" "$CURRENCY0" "$CURRENCY1" 3000 60 \
    "$STATICS_SWAP_FEE_HOOK_ADDRESS" true 100000000000000000 composed-restricted-swap
timelock_call "$STATICS_DIAMOND_ADDRESS" 0 \
    "$(cast calldata 'removeRewardRestriction(address)' "$CURRENCY0")" composed-unrestrict
cast send "$STATICS_DIAMOND_ADDRESS" 'pause(uint256)' 128 \
    --private-key "$(anvil_private_key 1)" --rpc-url "$RPC_URL" --legacy --json \
    >"$RUN_DIR/composed-pause-stake.json"
expect_call_revert "stake ingress in composed pause" \
    cast call "$STATICS_DIAMOND_ADDRESS" 'stake(uint256,uint256)' "$POSITION_ID" 1 \
    --from "$SUCCESSOR" --rpc-url "$RPC_URL" >"$RUN_DIR/composed-paused-stake-revert.txt"
timelock_call "$STATICS_DIAMOND_ADDRESS" 0 "$(cast calldata 'unpause(uint256)' 128)" composed-unpause-stake

# Decommission with live user rewards, creator revenue, and POL. Resolve each
# liability incrementally, then reconcile custody after finalization.
timelock_call "$STATICS_DIAMOND_ADDRESS" 0 \
    "$(cast calldata 'beginGeneralPoolDecommission(bytes32)' "$POOL_ID")" composed-begin-decommission
expect_call_revert "reward surplus reconciliation with unresolved gauge leg" \
    cast call "$STATICS_DIAMOND_ADDRESS" 'reconcilePoolRewardSurplus(bytes32,uint8)(uint256)' \
    "$POOL_ID" 1 --from "$(anvil_address "$MAINTAINER_INDEX")" --rpc-url "$RPC_URL" >/dev/null
expect_call_revert "composed finalization with active POL" \
    cast call "$STATICS_DIAMOND_ADDRESS" 'finalizeGeneralPoolDecommission(bytes32)(uint256,uint256)' \
    "$POOL_ID" --from "$STATICS_TIMELOCK_ADDRESS" --rpc-url "$RPC_URL" \
    >"$RUN_DIR/composed-active-pol-finalize-revert.txt"
DEADLINE=$(( $(cast block latest --field timestamp --rpc-url "$RPC_URL") + 86400 ))
cast send "$STATICS_DIAMOND_ADDRESS" \
    'exitLiquidity(uint256,bytes32,uint256,uint256,uint256)((uint256,uint128,uint256,uint256,uint256,uint256))' \
    "$POSITION_ID" "$POOL_ID" 0 0 "$DEADLINE" --private-key "$SUCCESSOR_KEY" \
    --rpc-url "$RPC_URL" --gas-limit 3000000 --legacy --json >"$RUN_DIR/composed-exit-liquidity.json"
cast send "$STATICS_DIAMOND_ADDRESS" \
    'claimLpRewards(uint256,bytes32,uint8[],uint256[],address)(uint256[])' \
    "$POSITION_ID" "$POOL_ID" '[0,1]' '[0,0]' "$SUCCESSOR" --private-key "$SUCCESSOR_KEY" \
    --rpc-url "$RPC_URL" --gas-limit 3000000 --legacy --json >"$RUN_DIR/composed-claim-lp.json"
cast send "$STATICS_DIAMOND_ADDRESS" \
    'claimGaugeAllocatorRewards(uint256,bytes32,uint8[],uint256[],address)(uint256[])' \
    "$POSITION_ID" "$POOL_ID" '[1]' '[0]' "$SUCCESSOR" --private-key "$SUCCESSOR_KEY" \
    --rpc-url "$RPC_URL" --gas-limit 3000000 --legacy --json >"$RUN_DIR/composed-claim-allocator.json"
cast send "$STATICS_DIAMOND_ADDRESS" 'claimRewards(uint256,address[],address,uint256[])(uint256[])' \
    "$POSITION_ID" "[$CURRENCY0,$CURRENCY1]" "$SUCCESSOR" '[0,0]' --private-key "$SUCCESSOR_KEY" \
    --rpc-url "$RPC_URL" --gas-limit 3000000 --legacy --json >"$RUN_DIR/composed-claim-global.json"
RECONCILED_REWARD_SURPLUS=$(cast call "$STATICS_DIAMOND_ADDRESS" \
    'reconcilePoolRewardSurplus(bytes32,uint8)(uint256)' "$POOL_ID" 1 \
    --from "$(anvil_address "$MAINTAINER_INDEX")" --rpc-url "$RPC_URL" | awk '{print $1}')
cast send "$STATICS_DIAMOND_ADDRESS" 'reconcilePoolRewardSurplus(bytes32,uint8)(uint256)' \
    "$POOL_ID" 1 --private-key "$(anvil_private_key "$MAINTAINER_INDEX")" \
    --rpc-url "$RPC_URL" --legacy --json >"$RUN_DIR/composed-reconcile-reward-surplus.json"
cast send "$STATICS_DIAMOND_ADDRESS" 'unstake(uint256,uint256,address)' \
    "$POSITION_ID" "$STAKE" "$SUCCESSOR" --private-key "$SUCCESSOR_KEY" \
    --rpc-url "$RPC_URL" --legacy --json >"$RUN_DIR/composed-unstake.json"
cast send "$STATICS_DIAMOND_ADDRESS" 'closeProtocolPolPosition(uint256,uint256,uint256,uint256)' \
    "$POL_POSITION" 0 0 "$DEADLINE" --private-key "$(anvil_private_key 3)" \
    --rpc-url "$RPC_URL" --gas-limit 3000000 --legacy --json >"$RUN_DIR/composed-close-pol.json"
timelock_call "$STATICS_DIAMOND_ADDRESS" 0 \
    "$(cast calldata 'finalizeGeneralPoolDecommission(bytes32)' "$POOL_ID")" composed-finalize-decommission

for asset in "$CURRENCY0" "$CURRENCY1"; do
    cast send "$STATICS_DIAMOND_ADDRESS" 'settleProtocolPoolRevenue(bytes32,address)(uint256,uint256)' \
        "$POOL_ID" "$asset" --private-key "$(anvil_private_key "$MAINTAINER_INDEX")" \
        --rpc-url "$RPC_URL" --legacy --json >"$RUN_DIR/composed-settle-revenue-${asset,,}.json"
    CREDIT=$(cast call "$STATICS_DIAMOND_ADDRESS" 'creatorRevenue(bytes32,address)(uint256)' "$POOL_ID" "$asset" --rpc-url "$RPC_URL" | awk '{print $1}')
    if [[ "$CREDIT" != 0 ]]; then
        cast send "$STATICS_DIAMOND_ADDRESS" 'claimCreatorRevenue(bytes32,address,address,uint256)(uint256,uint256)' \
            "$POOL_ID" "$asset" "$SUCCESSOR" 0 --private-key "$(anvil_private_key "$MAINTAINER_INDEX")" \
            --rpc-url "$RPC_URL" --legacy --json >"$RUN_DIR/composed-claim-creator-${asset,,}.json"
    fi
    TREASURY_CREDIT=$(cast call "$STATICS_DIAMOND_ADDRESS" 'treasuryAccrued(address)(uint256)' "$asset" --rpc-url "$RPC_URL" | awk '{print $1}')
    if [[ "$TREASURY_CREDIT" != 0 ]]; then
        cast send "$STATICS_DIAMOND_ADDRESS" 'distributeTreasuryFees(address)(uint256)' "$asset" \
            --private-key "$(anvil_private_key "$MAINTAINER_INDEX")" --rpc-url "$RPC_URL" \
            --legacy --json >"$RUN_DIR/composed-distribute-${asset,,}.json"
    fi
done

assert_phase_one_solvency composed-soak "$CURRENCY0" "$CURRENCY1" "$STAKING_TOKEN"
assert_eq "$(cast call "$STATICS_DIAMOND_ADDRESS" 'protocolPoolCreator(bytes32)(address)' "$POOL_ID" --rpc-url "$RPC_URL")" \
    "$SUCCESSOR" "composed successor creator"
assert_eq "$(cast call "$STATICS_DIAMOND_ADDRESS" 'ownerOf(uint256)(address)' "$POSITION_ID" --rpc-url "$RPC_URL")" \
    "$SUCCESSOR" "composed successor PositionNFT owner"
record_result composed-soak accumulated-state-lifecycle pass "$POOL_ID"
record_result composed-soak authority-transfers pass "creator and PositionNFT moved to $SUCCESSOR"
record_result composed-soak incremental-shutdown pass "LP, allocator, global, creator, POL, and Treasury resolved"
record_result composed-soak reward-surplus-reconciliation pass "$RECONCILED_REWARD_SURPLUS WETH wei"
note "composed no-reset Phase 1 soak passed"
