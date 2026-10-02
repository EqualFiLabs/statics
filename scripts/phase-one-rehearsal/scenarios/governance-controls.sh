#!/usr/bin/env bash

set -Eeuo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

require_commands cast jq awk bc
load_current_run
require_local_chain
reset_to_base

GUARDIAN_KEY=$(anvil_private_key 1)
CREATOR_INDEX=17
TRADER_INDEX=18
STAKER_INDEX=16
MAINTAINER_INDEX=15
CREATOR=$(anvil_address "$CREATOR_INDEX")
STAKER=$(anvil_address "$STAKER_INDEX")
OUTSIDER=$(anvil_address 14)
POSITION_FEE=1000000000000000
STAKE=1000000000000000000000
POOL_ID=$(create_public_pool "$STAKING_TOKEN" "$WETH_ADDRESS" "$CREATOR" 4 governance)

if [[ "${WETH_ADDRESS,,}" < "${STAKING_TOKEN,,}" ]]; then
    CURRENCY0=$WETH_ADDRESS
    CURRENCY1=$STAKING_TOKEN
else
    CURRENCY0=$STAKING_TOKEN
    CURRENCY1=$WETH_ADDRESS
fi

# Establish live managed liquidity, a mature staker, and swap-generated state so
# every emergency control is tested against the behavior it is meant to stop.
acquire_genesis_statics "$CREATOR_INDEX" 3000000000000000000 governance-lp >/dev/null
wrap_weth "$CREATOR_INDEX" 100000000000000000000 governance-lp
for asset in "$CURRENCY0" "$CURRENCY1"; do
    cast send "$asset" 'approve(address,uint256)' "$STATICS_DIAMOND_ADDRESS" "$(cast max-uint)" \
        --private-key "$(anvil_private_key "$CREATOR_INDEX")" --rpc-url "$RPC_URL" --legacy --json \
        >"$RUN_DIR/governance-lp-approve-${asset,,}.json"
done
LP_POSITION=$(cast call "$STATICS_DIAMOND_ADDRESS" 'nextPositionId()(uint256)' --rpc-url "$RPC_URL" | awk '{print $1}')
cast send "$STATICS_DIAMOND_ADDRESS" 'createPosition(address)(uint256)' "$CREATOR" \
    --value "$POSITION_FEE" --private-key "$(anvil_private_key "$CREATOR_INDEX")" \
    --rpc-url "$RPC_URL" --legacy --json >"$RUN_DIR/governance-lp-position.json"
DEADLINE=$(( $(cast block latest --field timestamp --rpc-url "$RPC_URL") + 86400 ))
cast send "$STATICS_DIAMOND_ADDRESS" \
    'provideLiquidity(uint256,(bytes32,int24,int24,uint128,uint256,uint256,uint256))((uint256,uint128,uint256,uint256,uint256,uint256))' \
    "$LP_POSITION" "($POOL_ID,-1200,1200,100000000000000000000,90000000000000000000,90000000000000000000,$DEADLINE)" \
    --private-key "$(anvil_private_key "$CREATOR_INDEX")" --rpc-url "$RPC_URL" --legacy --json \
    >"$RUN_DIR/governance-provide.json"

acquire_genesis_statics "$STAKER_INDEX" 1000000000000000000 governance-staker >/dev/null
cast send "$STAKING_TOKEN" 'approve(address,uint256)' "$STATICS_DIAMOND_ADDRESS" "$(cast max-uint)" \
    --private-key "$(anvil_private_key "$STAKER_INDEX")" --rpc-url "$RPC_URL" --legacy --json \
    >"$RUN_DIR/governance-staker-approve.json"
STAKER_POSITION=$(cast call "$STATICS_DIAMOND_ADDRESS" 'nextPositionId()(uint256)' --rpc-url "$RPC_URL" | awk '{print $1}')
cast send "$STATICS_DIAMOND_ADDRESS" 'createAndStake(uint256,address,address[])(uint256)' \
    "$STAKE" "$STAKER" "[$CURRENCY0,$CURRENCY1]" --value "$POSITION_FEE" \
    --private-key "$(anvil_private_key "$STAKER_INDEX")" --rpc-url "$RPC_URL" --legacy --json \
    >"$RUN_DIR/governance-staker-position.json"
rpc_warp_by 90000
cast send "$STATICS_DIAMOND_ADDRESS" 'checkpointRewardAssets(address[])' "[$CURRENCY0,$CURRENCY1]" \
    --private-key "$(anvil_private_key "$MAINTAINER_INDEX")" --rpc-url "$RPC_URL" --legacy --json \
    >"$RUN_DIR/governance-reward-checkpoint.json"

wrap_weth "$TRADER_INDEX" 10000000000000000000 governance-trader
acquire_genesis_statics "$TRADER_INDEX" 2000000000000000000 governance-trader >/dev/null
v4_swap_exact_in "$TRADER_INDEX" "$CURRENCY0" "$CURRENCY1" 3000 60 \
    "$STATICS_SWAP_FEE_HOOK_ADDRESS" true 500000000000000000 governance-seed-swap0
v4_swap_exact_in "$TRADER_INDEX" "$CURRENCY0" "$CURRENCY1" 3000 60 \
    "$STATICS_SWAP_FEE_HOOK_ADDRESS" false 500000000000000000 governance-seed-swap1
DEADLINE=$(( $(cast block latest --field timestamp --rpc-url "$RPC_URL") + 86400 ))

expect_call_revert "outsider pause" \
    cast call "$STATICS_DIAMOND_ADDRESS" 'pause(uint256)' 32 --from "$OUTSIDER" --rpc-url "$RPC_URL" \
    >"$RUN_DIR/governance-outsider-pause-revert.txt"

# PAUSE_LIQUIDITY blocks every tested exposure-increasing path while preserving
# fee collection and partial withdrawal of already-owned liquidity.
cast send "$STATICS_DIAMOND_ADDRESS" 'activateProtocolPoolPol(bytes32)' "$POOL_ID" \
    --value 100000000000000000 --private-key "$(anvil_private_key "$CREATOR_INDEX")" \
    --rpc-url "$RPC_URL" --legacy --json >"$RUN_DIR/governance-pol-activate.json"
cast send "$STATICS_DIAMOND_ADDRESS" 'pause(uint256)' 32 \
    --private-key "$GUARDIAN_KEY" --rpc-url "$RPC_URL" --legacy --json >"$RUN_DIR/governance-pause-liquidity.json"
assert_eq "$(cast call "$STATICS_DIAMOND_ADDRESS" 'isPaused(uint256)(bool)' 32 --rpc-url "$RPC_URL")" \
    true "guardian liquidity pause"
expect_call_revert "increase while liquidity paused" \
    cast call "$STATICS_DIAMOND_ADDRESS" \
    'increaseLiquidity(uint256,bytes32,(uint128,uint256,uint256,uint256))((uint256,uint128,uint256,uint256,uint256,uint256))' \
    "$LP_POSITION" "$POOL_ID" "(1000000000000000000,90000000000000000000,90000000000000000000,$DEADLINE)" \
    --from "$CREATOR" --rpc-url "$RPC_URL" >/dev/null
expect_call_revert "POL growth while liquidity paused" \
    cast call "$STATICS_DIAMOND_ADDRESS" \
    'openProtocolPolPosition((bytes32,int24,int24,uint128,uint256,uint256,uint256))(uint256)' \
    "($POOL_ID,-600,600,1,0,0,$DEADLINE)" --from "$(anvil_address 3)" --rpc-url "$RPC_URL" >/dev/null
cast send "$STATICS_DIAMOND_ADDRESS" \
    'collectNativeFees(uint256,bytes32,uint256,uint256,uint256)((uint256,uint128,uint256,uint256,uint256,uint256))' \
    "$LP_POSITION" "$POOL_ID" 0 0 "$DEADLINE" --private-key "$(anvil_private_key "$CREATOR_INDEX")" \
    --rpc-url "$RPC_URL" --legacy --json >"$RUN_DIR/governance-paused-collect.json"
cast send "$STATICS_DIAMOND_ADDRESS" \
    'decreaseLiquidity(uint256,bytes32,(uint128,uint256,uint256,uint256))((uint256,uint128,uint256,uint256,uint256,uint256))' \
    "$LP_POSITION" "$POOL_ID" "(1000000000000000000,0,0,$DEADLINE)" \
    --private-key "$(anvil_private_key "$CREATOR_INDEX")" --rpc-url "$RPC_URL" --legacy --json \
    >"$RUN_DIR/governance-paused-decrease.json"
expect_call_revert "guardian unpause" \
    cast call "$STATICS_DIAMOND_ADDRESS" 'unpause(uint256)' 32 --from "$GUARDIAN" --rpc-url "$RPC_URL" \
    >"$RUN_DIR/governance-guardian-unpause-revert.txt"
UNPAUSE_CALLDATA=$(cast calldata 'unpause(uint256)' 32)
timelock_call_prove_delay "$STATICS_DIAMOND_ADDRESS" 0 "$UNPAUSE_CALLDATA" governance-unpause-liquidity
DEADLINE=$(( $(cast block latest --field timestamp --rpc-url "$RPC_URL") + 86400 ))
cast send "$STATICS_DIAMOND_ADDRESS" \
    'increaseLiquidity(uint256,bytes32,(uint128,uint256,uint256,uint256))((uint256,uint128,uint256,uint256,uint256,uint256))' \
    "$LP_POSITION" "$POOL_ID" "(1000000000000000000,90000000000000000000,90000000000000000000,$DEADLINE)" \
    --private-key "$(anvil_private_key "$CREATOR_INDEX")" --rpc-url "$RPC_URL" --legacy --json \
    >"$RUN_DIR/governance-unpaused-increase.json"

# Settle the currently accrued reward before testing the staking ingress pause.
PENDING=$(cast call "$STATICS_DIAMOND_ADDRESS" 'pendingRewards(uint256,address[])(uint256[])' \
    "$STAKER_POSITION" "[$CURRENCY0,$CURRENCY1]" --rpc-url "$RPC_URL" --json)
assert_gt "$(jq -r '.[0][0] + .[0][1]' <<<"$PENDING")" 0 "staker claim before pause"
cast send "$STATICS_DIAMOND_ADDRESS" 'optOutRewardAssets(uint256,address[])' \
    "$STAKER_POSITION" "[$CURRENCY0]" --private-key "$(anvil_private_key "$STAKER_INDEX")" \
    --rpc-url "$RPC_URL" --legacy --json >"$RUN_DIR/governance-prepause-opt-out.json"
cast send "$STATICS_DIAMOND_ADDRESS" 'pause(uint256)' 128 \
    --private-key "$GUARDIAN_KEY" --rpc-url "$RPC_URL" --legacy --json >"$RUN_DIR/governance-pause-stake.json"
expect_call_revert "create and stake while paused" \
    cast call "$STATICS_DIAMOND_ADDRESS" 'createAndStake(uint256,address,address[])(uint256)' \
    1 "$STAKER" "[$CURRENCY0]" --value "$POSITION_FEE" --from "$STAKER" --rpc-url "$RPC_URL" >/dev/null
expect_call_revert "stake while paused" \
    cast call "$STATICS_DIAMOND_ADDRESS" 'stake(uint256,uint256)' "$STAKER_POSITION" 1 \
    --from "$STAKER" --rpc-url "$RPC_URL" >/dev/null
expect_call_revert "opt in while paused" \
    cast call "$STATICS_DIAMOND_ADDRESS" 'optInRewardAssets(uint256,address[])' \
    "$STAKER_POSITION" "[$CURRENCY0]" --from "$STAKER" --rpc-url "$RPC_URL" >/dev/null
cast send "$STATICS_DIAMOND_ADDRESS" 'optOutRewardAssets(uint256,address[])' \
    "$STAKER_POSITION" "[$CURRENCY1]" --private-key "$(anvil_private_key "$STAKER_INDEX")" \
    --rpc-url "$RPC_URL" --legacy --json >"$RUN_DIR/governance-paused-opt-out.json"
cast send "$STATICS_DIAMOND_ADDRESS" 'unstake(uint256,uint256,address)' \
    "$STAKER_POSITION" 1 "$STAKER" --private-key "$(anvil_private_key "$STAKER_INDEX")" \
    --rpc-url "$RPC_URL" --legacy --json >"$RUN_DIR/governance-paused-unstake.json"
cast send "$STATICS_DIAMOND_ADDRESS" 'claimRewards(uint256,address[],address,uint256[])(uint256[])' \
    "$STAKER_POSITION" "[$CURRENCY0,$CURRENCY1]" "$STAKER" '[0,0]' \
    --private-key "$(anvil_private_key "$STAKER_INDEX")" --rpc-url "$RPC_URL" --legacy --json \
    >"$RUN_DIR/governance-paused-claim.json"
UNPAUSE_STAKE_CALLDATA=$(cast calldata 'unpause(uint256)' 128)
timelock_call "$STATICS_DIAMOND_ADDRESS" 0 "$UNPAUSE_STAKE_CALLDATA" governance-unpause-stake

# Settle hook revenue, then prove Treasury pause preserves both the settled
# liability and newly generated unsettled hook state until governance unpauses.
for asset in "$CURRENCY0" "$CURRENCY1"; do
    cast send "$STATICS_DIAMOND_ADDRESS" 'settleProtocolPoolRevenue(bytes32,address)(uint256,uint256)' \
        "$POOL_ID" "$asset" --private-key "$(anvil_private_key "$MAINTAINER_INDEX")" \
        --rpc-url "$RPC_URL" --legacy --json >"$RUN_DIR/governance-settle-${asset,,}.json"
done
TREASURY_ASSET=$CURRENCY0
TREASURY_CREDIT=$(cast call "$STATICS_DIAMOND_ADDRESS" 'treasuryAccrued(address)(uint256)' \
    "$TREASURY_ASSET" --rpc-url "$RPC_URL" | awk '{print $1}')
if [[ "$TREASURY_CREDIT" == 0 ]]; then
    TREASURY_ASSET=$CURRENCY1
    TREASURY_CREDIT=$(cast call "$STATICS_DIAMOND_ADDRESS" 'treasuryAccrued(address)(uint256)' \
        "$TREASURY_ASSET" --rpc-url "$RPC_URL" | awk '{print $1}')
fi
assert_gt "$TREASURY_CREDIT" 0 "settled Treasury credit"
cast send "$STATICS_DIAMOND_ADDRESS" 'pause(uint256)' 64 \
    --private-key "$GUARDIAN_KEY" --rpc-url "$RPC_URL" --legacy --json >"$RUN_DIR/governance-pause-treasury.json"
expect_call_revert "Treasury distribution while paused" \
    cast call "$STATICS_DIAMOND_ADDRESS" 'distributeTreasuryFees(address)(uint256)' \
    "$TREASURY_ASSET" --from "$OUTSIDER" --rpc-url "$RPC_URL" >/dev/null
assert_eq "$(cast call "$STATICS_DIAMOND_ADDRESS" 'treasuryAccrued(address)(uint256)' \
    "$TREASURY_ASSET" --rpc-url "$RPC_URL" | awk '{print $1}')" "$TREASURY_CREDIT" \
    "Treasury pause preserves settled liability"
v4_swap_exact_in "$TRADER_INDEX" "$CURRENCY0" "$CURRENCY1" 3000 60 \
    "$STATICS_SWAP_FEE_HOOK_ADDRESS" true 100000000000000000 governance-treasury-paused-swap
expect_call_revert "revenue settlement while Treasury paused" \
    cast call "$STATICS_DIAMOND_ADDRESS" 'settleProtocolPoolRevenue(bytes32,address)(uint256,uint256)' \
    "$POOL_ID" "$CURRENCY1" --from "$OUTSIDER" --rpc-url "$RPC_URL" >/dev/null
UNPAUSE_TREASURY_CALLDATA=$(cast calldata 'unpause(uint256)' 64)
timelock_call "$STATICS_DIAMOND_ADDRESS" 0 "$UNPAUSE_TREASURY_CALLDATA" governance-unpause-treasury
TREASURY_BALANCE_BEFORE=$(cast call "$TREASURY_ASSET" 'balanceOf(address)(uint256)' "$TREASURY" \
    --rpc-url "$RPC_URL" | awk '{print $1}')
cast send "$STATICS_DIAMOND_ADDRESS" 'distributeTreasuryFees(address)(uint256)' "$TREASURY_ASSET" \
    --private-key "$(anvil_private_key "$MAINTAINER_INDEX")" --rpc-url "$RPC_URL" --legacy --json \
    >"$RUN_DIR/governance-unpaused-treasury-distribution.json"
TREASURY_BALANCE_AFTER=$(cast call "$TREASURY_ASSET" 'balanceOf(address)(uint256)' "$TREASURY" \
    --rpc-url "$RPC_URL" | awk '{print $1}')
assert_eq "$(printf '%s - %s\n' "$TREASURY_BALANCE_AFTER" "$TREASURY_BALANCE_BEFORE" | bc)" \
    "$TREASURY_CREDIT" "Treasury distribution after unpause"

# Pool quarantine and the global public-swap pause must stop an actual router
# execution, then permit the same prepared trade once governance releases it.
cast send "$STATICS_DIAMOND_ADDRESS" 'quarantineProtocolPool(bytes32)' "$POOL_ID" \
    --private-key "$GUARDIAN_KEY" --rpc-url "$RPC_URL" --legacy --json \
    >"$RUN_DIR/governance-quarantine-pool.json"
expect_call_revert "quarantined pool swap" \
    v4_swap_exact_in_simulate "$TRADER_INDEX" "$CURRENCY0" "$CURRENCY1" 3000 60 \
    "$STATICS_SWAP_FEE_HOOK_ADDRESS" true 100000000000000000 >/dev/null
RELEASE_CALLDATA=$(cast calldata 'releaseProtocolPoolQuarantine(bytes32)' "$POOL_ID")
timelock_call "$STATICS_DIAMOND_ADDRESS" 0 "$RELEASE_CALLDATA" governance-release-pool
v4_swap_exact_in "$TRADER_INDEX" "$CURRENCY0" "$CURRENCY1" 3000 60 \
    "$STATICS_SWAP_FEE_HOOK_ADDRESS" true 100000000000000000 governance-released-swap

cast send "$STATICS_DIAMOND_ADDRESS" 'pauseProtocolSwaps()' \
    --private-key "$GUARDIAN_KEY" --rpc-url "$RPC_URL" --legacy --json \
    >"$RUN_DIR/governance-pause-public-swaps.json"
expect_call_revert "globally paused public swap" \
    v4_swap_exact_in_simulate "$TRADER_INDEX" "$CURRENCY0" "$CURRENCY1" 3000 60 \
    "$STATICS_SWAP_FEE_HOOK_ADDRESS" false 100000000000000000 >/dev/null
UNPAUSE_SWAPS_CALLDATA=$(cast calldata 'unpauseProtocolSwaps()')
timelock_call "$STATICS_DIAMOND_ADDRESS" 0 "$UNPAUSE_SWAPS_CALLDATA" governance-unpause-public-swaps
v4_swap_exact_in "$TRADER_INDEX" "$CURRENCY0" "$CURRENCY1" 3000 60 \
    "$STATICS_SWAP_FEE_HOOK_ADDRESS" false 100000000000000000 governance-global-unpaused-swap

assert_phase_one_solvency governance "$CURRENCY0" "$CURRENCY1"
record_result governance liquidity-pause pass "ingress blocked; collect and decrease preserved"
record_result governance stake-pause pass "stake ingress blocked; opt-out, unstake, and claim preserved"
record_result governance treasury-pause pass "settlement and distribution blocked atomically"
record_result governance pool-quarantine pass "$POOL_ID real router execution"
record_result governance global-public-swap-pause pass "$POOL_ID real router execution"
note "guardian and timelock governance enforcement scenarios passed"
