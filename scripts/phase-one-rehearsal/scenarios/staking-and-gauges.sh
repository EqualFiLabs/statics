#!/usr/bin/env bash

set -Eeuo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

require_commands cast jq awk bc
load_current_run
require_local_chain
reset_to_base

USER_INDEX=4
USER=$(anvil_address "$USER_INDEX")
USER_KEY=$(anvil_private_key "$USER_INDEX")
POSITION_FEE=1000000000000000
INITIAL_STAKE=1000000000000000000000
TOP_UP=200000000000000000000
POOL_ID=$(create_public_pool "$STAKING_TOKEN" "$WETH_ADDRESS" "$USER" 1 staking-gauge)

acquire_genesis_statics "$USER_INDEX" 1000000000000000000 staking-user >/dev/null
cast send "$STAKING_TOKEN" 'approve(address,uint256)' "$STATICS_DIAMOND_ADDRESS" "$(cast max-uint)" \
    --private-key "$USER_KEY" --rpc-url "$RPC_URL" --legacy --json >"$RUN_DIR/staking-approve.json"

POSITION_ID=$(cast call "$STATICS_DIAMOND_ADDRESS" 'nextPositionId()(uint256)' --rpc-url "$RPC_URL" | awk '{print $1}')
cast send "$STATICS_DIAMOND_ADDRESS" 'createAndStake(uint256,address,address[])(uint256)' \
    "$INITIAL_STAKE" "$USER" "[$WETH_ADDRESS]" \
    --value "$POSITION_FEE" \
    --private-key "$USER_KEY" \
    --rpc-url "$RPC_URL" \
    --legacy \
    --json >"$RUN_DIR/staking-create-position.json"
assert_eq \
    "$(cast call "$STATICS_DIAMOND_ADDRESS" 'ownerOf(uint256)(address)' "$POSITION_ID" --rpc-url "$RPC_URL")" \
    "$USER" \
    "staked PositionNFT owner"

cooldown_revert=$(expect_call_revert "initial allocation during stake ingress cooldown" \
    cast call "$STATICS_DIAMOND_ADDRESS" 'setGaugeAllocations(uint256,bytes32[],uint256[])' \
    "$POSITION_ID" "[$POOL_ID]" "[$INITIAL_STAKE]" --from "$USER" --rpc-url "$RPC_URL")
[[ "$cooldown_revert" == *"GaugeAllocationIncreaseDuringCooldown"* || "$cooldown_revert" == *"execution reverted"* ]] \
    || fail "initial allocation reverted for an unexpected reason"
record_result gauges stake-ingress-cooldown pass "position $POSITION_ID"

allocation_state=$(cast call "$STATICS_DIAMOND_ADDRESS" \
    'gaugePositionAllocations(uint256)(uint40,uint256,(bytes32,uint256,bytes32)[],uint256)' \
    "$POSITION_ID" --from "$USER" --rpc-url "$RPC_URL")
NEXT_ALLOCATION_AT=$(printf '%s\n' "$allocation_state" | sed -n '1s/ .*//p')
rpc_warp_to "$NEXT_ALLOCATION_AT"
cast send "$STATICS_DIAMOND_ADDRESS" 'setGaugeAllocations(uint256,bytes32[],uint256[])' \
    "$POSITION_ID" "[$POOL_ID]" "[$INITIAL_STAKE]" \
    --private-key "$USER_KEY" --rpc-url "$RPC_URL" --legacy --json >"$RUN_DIR/gauge-allocate.json"
WEIGHT=$(cast call "$STATICS_DIAMOND_ADDRESS" \
    'gaugePoolWeight(bytes32)(uint256,bytes32,bytes32,uint64,uint256,uint256,bool)' \
    "$POOL_ID" --rpc-url "$RPC_URL" | sed -n '1s/ .*//p')
assert_eq "$WEIGHT" "$INITIAL_STAKE" "pool allocation weight"

unstake_revert=$(expect_call_revert "allocated stake must remain locked" \
    cast call "$STATICS_DIAMOND_ADDRESS" 'unstake(uint256,uint256,address)' \
    "$POSITION_ID" 1 "$USER" --from "$USER" --rpc-url "$RPC_URL")
[[ "$unstake_revert" == *"execution reverted"* ]] || fail "allocated unstake did not reach lock enforcement"
record_result gauges allocated-stake-lock pass "position $POSITION_ID"

rpc_warp_by 1
cast send "$STATICS_DIAMOND_ADDRESS" 'stake(uint256,uint256)' "$POSITION_ID" "$TOP_UP" \
    --private-key "$USER_KEY" --rpc-url "$RPC_URL" --legacy --json >"$RUN_DIR/gauge-top-up.json"
REDUCED=900000000000000000000
cast send "$STATICS_DIAMOND_ADDRESS" 'setGaugeAllocations(uint256,bytes32[],uint256[])' \
    "$POSITION_ID" "[$POOL_ID]" "[$REDUCED]" \
    --private-key "$USER_KEY" --rpc-url "$RPC_URL" --legacy --json >"$RUN_DIR/gauge-reduce-during-cooldown.json"
increase_revert=$(expect_call_revert "top-up cooldown must block allocation increases" \
    cast call "$STATICS_DIAMOND_ADDRESS" 'setGaugeAllocations(uint256,bytes32[],uint256[])' \
    "$POSITION_ID" "[$POOL_ID]" "[$INITIAL_STAKE]" --from "$USER" --rpc-url "$RPC_URL")
[[ "$increase_revert" == *"GaugeAllocationIncreaseDuringCooldown"* || "$increase_revert" == *"execution reverted"* ]] \
    || fail "top-up allocation increase reverted for an unexpected reason"
record_result gauges top-up-cooldown pass "reductions remain available"

cast send "$STATICS_DIAMOND_ADDRESS" 'setGaugeAllocations(uint256,bytes32[],uint256[])' \
    "$POSITION_ID" '[]' '[]' \
    --private-key "$USER_KEY" --rpc-url "$RPC_URL" --legacy --json >"$RUN_DIR/gauge-deallocate.json"
cast send "$STATICS_DIAMOND_ADDRESS" 'unstake(uint256,uint256,address)' \
    "$POSITION_ID" "$INITIAL_STAKE" "$USER" \
    --private-key "$USER_KEY" --rpc-url "$RPC_URL" --legacy --json >"$RUN_DIR/gauge-unstake.json"

SECOND_POSITION_ID=$(cast call "$STATICS_DIAMOND_ADDRESS" 'nextPositionId()(uint256)' --rpc-url "$RPC_URL" | awk '{print $1}')
cast send "$STATICS_DIAMOND_ADDRESS" 'createAndStake(uint256,address,address[])(uint256)' \
    "$INITIAL_STAKE" "$USER" '[]' \
    --value "$POSITION_FEE" \
    --private-key "$USER_KEY" \
    --rpc-url "$RPC_URL" \
    --legacy \
    --json >"$RUN_DIR/gauge-create-second-position.json"
migration_revert=$(expect_call_revert "new PositionNFT must not bypass allocation cooldown" \
    cast call "$STATICS_DIAMOND_ADDRESS" 'setGaugeAllocations(uint256,bytes32[],uint256[])' \
    "$SECOND_POSITION_ID" "[$POOL_ID]" "[$INITIAL_STAKE]" --from "$USER" --rpc-url "$RPC_URL")
[[ "$migration_revert" == *"GaugeAllocationIncreaseDuringCooldown"* || "$migration_revert" == *"execution reverted"* ]] \
    || fail "stake migration reverted for an unexpected reason"
record_result gauges position-migration-cooldown pass "positions $POSITION_ID to $SECOND_POSITION_ID"

second_allocation_state=$(cast call "$STATICS_DIAMOND_ADDRESS" \
    'gaugePositionAllocations(uint256)(uint40,uint256,(bytes32,uint256,bytes32)[],uint256)' \
    "$SECOND_POSITION_ID" --from "$USER" --rpc-url "$RPC_URL")
SECOND_NEXT_ALLOCATION_AT=$(printf '%s\n' "$second_allocation_state" | sed -n '1s/ .*//p')
rpc_warp_to "$SECOND_NEXT_ALLOCATION_AT"
cast send "$STATICS_DIAMOND_ADDRESS" 'setGaugeAllocations(uint256,bytes32[],uint256[])' \
    "$SECOND_POSITION_ID" "[$POOL_ID]" "[$INITIAL_STAKE]" \
    --private-key "$USER_KEY" --rpc-url "$RPC_URL" --legacy --json >"$RUN_DIR/gauge-second-allocate.json"

# Bind productive active-range liquidity to the same PositionNFT that carries
# routing weight so slot 0 can be proven from reserve commitment through claim.
wrap_weth "$USER_INDEX" 100000000000000000000 gauge-lp
cast send "$WETH_ADDRESS" 'approve(address,uint256)' "$STATICS_DIAMOND_ADDRESS" "$(cast max-uint)" \
    --private-key "$USER_KEY" --rpc-url "$RPC_URL" --legacy --json >"$RUN_DIR/gauge-lp-weth-approve.json"
DEADLINE=$(( $(cast block latest --field timestamp --rpc-url "$RPC_URL") + 3600 ))
cast send "$STATICS_DIAMOND_ADDRESS" \
    'provideLiquidity(uint256,(bytes32,int24,int24,uint128,uint256,uint256,uint256))((uint256,uint128,uint256,uint256,uint256,uint256))' \
    "$SECOND_POSITION_ID" "($POOL_ID,-1200,1200,100000000000000000000,90000000000000000000,90000000000000000000,$DEADLINE)" \
    --private-key "$USER_KEY" --rpc-url "$RPC_URL" --legacy --json >"$RUN_DIR/gauge-provide-liquidity.json"

cast send "$STAKING_TOKEN" 'approve(address,uint256)' "$STATICS_DIAMOND_ADDRESS" "$(cast max-uint)" \
    --private-key "$USER_KEY" --rpc-url "$RPC_URL" --legacy --json >"$RUN_DIR/gauge-reserve-approve.json"
RESERVE_FUND=100000000000000000000
cast send "$STATICS_DIAMOND_ADDRESS" 'fundGaugeReserve(uint256)(uint256)' "$RESERVE_FUND" \
    --private-key "$USER_KEY" --rpc-url "$RPC_URL" --legacy --json >"$RUN_DIR/gauge-reserve-fund.json"
ACTIVATE_CALLDATA=$(cast calldata 'activateGaugeSchedule()')
timelock_call "$STATICS_DIAMOND_ADDRESS" 0 "$ACTIVATE_CALLDATA" gauge-schedule-activate

RESERVE_VIEW=$(cast call "$STATICS_DIAMOND_ADDRESS" \
    'gaugeReserve()((bool,uint16,uint16,uint40,uint40,uint40,uint40,uint40,uint40,uint64,uint40,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256))' \
    --rpc-url "$RPC_URL")
[[ "$RESERVE_VIEW" == *"true"* ]] || fail "gauge reserve did not activate"

rpc_warp_by 86400
cast send "$STATICS_DIAMOND_ADDRESS" 'checkpointGaugePool(bytes32)(uint256,uint256)' "$POOL_ID" \
    --private-key "$USER_KEY" --rpc-url "$RPC_URL" --legacy --json >"$RUN_DIR/gauge-pool-credit.json"
rpc_warp_by 86400
STATICS_BEFORE=$(cast call "$STAKING_TOKEN" 'balanceOf(address)(uint256)' "$USER" --rpc-url "$RPC_URL" | awk '{print $1}')
cast send "$STATICS_DIAMOND_ADDRESS" \
    'claimLpRewards(uint256,bytes32,uint8[],uint256[],address)(uint256[])' \
    "$SECOND_POSITION_ID" "$POOL_ID" '[0]' '[0]' "$USER" \
    --private-key "$USER_KEY" --rpc-url "$RPC_URL" --gas-limit 3000000 --legacy --json \
    >"$RUN_DIR/gauge-slot-zero-claim.json"
STATICS_AFTER=$(cast call "$STAKING_TOKEN" 'balanceOf(address)(uint256)' "$USER" --rpc-url "$RPC_URL" | awk '{print $1}')
SLOT_ZERO_CLAIMED=$(printf '%s - %s\n' "$STATICS_AFTER" "$STATICS_BEFORE" | bc)
[[ "$SLOT_ZERO_CLAIMED" != 0 ]] || fail "protocol slot 0 produced no LP claim"
record_result gauges protocol-slot-zero-claim pass "$SLOT_ZERO_CLAIMED STATICS wei"

rpc_warp_by 1209600
cast send "$STATICS_DIAMOND_ADDRESS" 'checkpointGaugeSchedule(uint16)(uint64,uint16,uint256)' 1 \
    --private-key "$USER_KEY" --rpc-url "$RPC_URL" --legacy --json >"$RUN_DIR/gauge-catchup-one.json"
cast send "$STATICS_DIAMOND_ADDRESS" 'checkpointGaugeSchedule(uint16)(uint64,uint16,uint256)' 1 \
    --private-key "$USER_KEY" --rpc-url "$RPC_URL" --legacy --json >"$RUN_DIR/gauge-catchup-two.json"
record_result gauges bounded-weekly-catchup pass "two missed periods processed across bounded calls"

PERIOD_BEFORE_LONG_GAP=$(cast call "$STATICS_DIAMOND_ADDRESS" 'currentGaugePeriod()(uint64)' \
    --rpc-url "$RPC_URL" | awk '{print $1}')
rpc_warp_by $(( 105 * 7 * 86400 ))
long_gap_revert=$(expect_call_revert "pool checkpoint must require explicit long-gap catch-up" \
    cast call "$STATICS_DIAMOND_ADDRESS" 'checkpointGaugePool(bytes32)(uint256,uint256)' "$POOL_ID" \
    --from "$USER" --rpc-url "$RPC_URL")
[[ "$long_gap_revert" == *"GaugeScheduleCatchupRequired"* || "$long_gap_revert" == *"execution reverted"* ]] \
    || fail "long-gap pool checkpoint reverted for an unexpected reason"

cast send "$STATICS_DIAMOND_ADDRESS" 'checkpointGaugeSchedule(uint16)(uint64,uint16,uint256)' 52 \
    --private-key "$USER_KEY" --rpc-url "$RPC_URL" --legacy --json >"$RUN_DIR/gauge-long-catchup-first.json"
assert_eq \
    "$(cast call "$STATICS_DIAMOND_ADDRESS" 'currentGaugePeriod()(uint64)' --rpc-url "$RPC_URL" | awk '{print $1}')" \
    "$(( PERIOD_BEFORE_LONG_GAP + 52 ))" \
    "first bounded long-gap checkpoint"

cast send "$STATICS_DIAMOND_ADDRESS" 'checkpointGaugeSchedule(uint16)(uint64,uint16,uint256)' 52 \
    --private-key "$USER_KEY" --rpc-url "$RPC_URL" --legacy --json >"$RUN_DIR/gauge-long-catchup-second.json"
assert_eq \
    "$(cast call "$STATICS_DIAMOND_ADDRESS" 'currentGaugePeriod()(uint64)' --rpc-url "$RPC_URL" | awk '{print $1}')" \
    "$(( PERIOD_BEFORE_LONG_GAP + 104 ))" \
    "second bounded long-gap checkpoint"

cast send "$STATICS_DIAMOND_ADDRESS" 'checkpointGaugeSchedule(uint16)(uint64,uint16,uint256)' 1 \
    --private-key "$USER_KEY" --rpc-url "$RPC_URL" --legacy --json >"$RUN_DIR/gauge-long-catchup-final.json"
assert_eq \
    "$(cast call "$STATICS_DIAMOND_ADDRESS" 'currentGaugePeriod()(uint64)' --rpc-url "$RPC_URL" | awk '{print $1}')" \
    "$(( PERIOD_BEFORE_LONG_GAP + 105 ))" \
    "final bounded long-gap checkpoint"

cast send "$STATICS_DIAMOND_ADDRESS" 'checkpointGaugePool(bytes32)(uint256,uint256)' "$POOL_ID" \
    --private-key "$USER_KEY" --rpc-url "$RPC_URL" --legacy --json >"$RUN_DIR/gauge-long-gap-pool-credit.json"
LONG_GAP_BALANCE_BEFORE=$(cast call "$STAKING_TOKEN" 'balanceOf(address)(uint256)' "$USER" \
    --rpc-url "$RPC_URL" | awk '{print $1}')
cast send "$STATICS_DIAMOND_ADDRESS" \
    'claimLpRewards(uint256,bytes32,uint8[],uint256[],address)(uint256[])' \
    "$SECOND_POSITION_ID" "$POOL_ID" '[0]' '[0]' "$USER" \
    --private-key "$USER_KEY" --rpc-url "$RPC_URL" --gas-limit 3000000 --legacy --json \
    >"$RUN_DIR/gauge-long-gap-slot-zero-claim.json"
LONG_GAP_BALANCE_AFTER=$(cast call "$STAKING_TOKEN" 'balanceOf(address)(uint256)' "$USER" \
    --rpc-url "$RPC_URL" | awk '{print $1}')
LONG_GAP_CLAIMED=$(printf '%s - %s\n' "$LONG_GAP_BALANCE_AFTER" "$LONG_GAP_BALANCE_BEFORE" | bc)
[[ "$LONG_GAP_CLAIMED" != 0 ]] || fail "long-gap catch-up produced no protocol slot-0 claim"
record_result gauges long-gap-catchup pass "105 periods processed across 52, 52, and 1 period calls"
record_result gauges long-gap-slot-zero-claim pass "$LONG_GAP_CLAIMED STATICS wei"

note "staking and gauge scenarios passed"
