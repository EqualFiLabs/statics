#!/usr/bin/env bash

set -Eeuo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

require_commands cast jq awk bc
load_current_run
require_local_chain
reset_to_base

CREATOR_INDEX=12
STAKER_INDEX=13
TRADER_INDEX=14
MAINTAINER_INDEX=15
CREATOR=$(anvil_address "$CREATOR_INDEX")
STAKER=$(anvil_address "$STAKER_INDEX")
CREATOR_KEY=$(anvil_private_key "$CREATOR_INDEX")
STAKER_KEY=$(anvil_private_key "$STAKER_INDEX")
POSITION_FEE=1000000000000000
POOL_ID=$(create_public_pool "$STAKING_TOKEN" "$WETH_ADDRESS" "$CREATOR" 81 fee-policy)

if [[ "${WETH_ADDRESS,,}" < "${STAKING_TOKEN,,}" ]]; then
    CURRENCY0=$WETH_ADDRESS
    CURRENCY1=$STAKING_TOKEN
else
    CURRENCY0=$STAKING_TOKEN
    CURRENCY1=$WETH_ADDRESS
fi

# Productive liquidity and mature reward weight make every configured bucket
# observable through the real hook and Diamond accounting paths.
acquire_genesis_statics "$CREATOR_INDEX" 2000000000000000000 fee-policy-lp >/dev/null
wrap_weth "$CREATOR_INDEX" 100000000000000000000 fee-policy-lp
for asset in "$CURRENCY0" "$CURRENCY1"; do
    cast send "$asset" 'approve(address,uint256)' "$STATICS_DIAMOND_ADDRESS" "$(cast max-uint)" \
        --private-key "$CREATOR_KEY" --rpc-url "$RPC_URL" --legacy --json \
        >"$RUN_DIR/fee-policy-lp-approve-${asset,,}.json"
done
LP_POSITION=$(cast call "$STATICS_DIAMOND_ADDRESS" 'nextPositionId()(uint256)' --rpc-url "$RPC_URL" | awk '{print $1}')
cast send "$STATICS_DIAMOND_ADDRESS" 'createPosition(address)(uint256)' "$CREATOR" \
    --value "$POSITION_FEE" --private-key "$CREATOR_KEY" --rpc-url "$RPC_URL" --legacy --json \
    >"$RUN_DIR/fee-policy-lp-position.json"
DEADLINE=$(( $(cast block latest --field timestamp --rpc-url "$RPC_URL") + 3600 ))
cast send "$STATICS_DIAMOND_ADDRESS" \
    'provideLiquidity(uint256,(bytes32,int24,int24,uint128,uint256,uint256,uint256))((uint256,uint128,uint256,uint256,uint256,uint256))' \
    "$LP_POSITION" "($POOL_ID,-1200,1200,100000000000000000000,90000000000000000000,90000000000000000000,$DEADLINE)" \
    --private-key "$CREATOR_KEY" --rpc-url "$RPC_URL" --legacy --json \
    >"$RUN_DIR/fee-policy-provide.json"

acquire_genesis_statics "$STAKER_INDEX" 1000000000000000000 fee-policy-staker >/dev/null
cast send "$STAKING_TOKEN" 'approve(address,uint256)' "$STATICS_DIAMOND_ADDRESS" "$(cast max-uint)" \
    --private-key "$STAKER_KEY" --rpc-url "$RPC_URL" --legacy --json \
    >"$RUN_DIR/fee-policy-staker-approve.json"
cast send "$STATICS_DIAMOND_ADDRESS" 'createAndStake(uint256,address,address[])(uint256)' \
    1000000000000000000000 "$STAKER" "[$CURRENCY0,$CURRENCY1]" \
    --value "$POSITION_FEE" --private-key "$STAKER_KEY" --rpc-url "$RPC_URL" --legacy --json \
    >"$RUN_DIR/fee-policy-staker-position.json"
rpc_warp_by 90000
cast send "$STATICS_DIAMOND_ADDRESS" 'checkpointRewardAssets(address[])' "[$CURRENCY0,$CURRENCY1]" \
    --private-key "$(anvil_private_key "$MAINTAINER_INDEX")" --rpc-url "$RPC_URL" --legacy --json \
    >"$RUN_DIR/fee-policy-reward-checkpoint.json"

wrap_weth "$TRADER_INDEX" 10000000000000000000 fee-policy-trader
acquire_genesis_statics "$TRADER_INDEX" 2000000000000000000 fee-policy-trader >/dev/null
cast send "$STATICS_DIAMOND_ADDRESS" 'activateProtocolPoolPol(bytes32)' "$POOL_ID" \
    --value 100000000000000000 --private-key "$CREATOR_KEY" --rpc-url "$RPC_URL" --legacy --json \
    >"$RUN_DIR/fee-policy-activate-pol.json"

account_state() {
    local asset=$1 distribution creator treasury
    distribution=$(cast call "$STATICS_SWAP_FEE_HOOK_ADDRESS" \
        'pendingFeeDistribution(bytes32,address)((uint256,uint256,uint256,uint256))' \
        "$POOL_ID" "$asset" --rpc-url "$RPC_URL" --json)
    creator=$(jq -r '.[0][2]' <<<"$distribution")
    treasury=$(jq -r '.[0][3]' <<<"$distribution")
    printf '%s %s %s %s\n' \
        "$(cast call "$STATICS_SWAP_FEE_HOOK_ADDRESS" 'pendingProtocolPol(bytes32,address)(uint256)' "$POOL_ID" "$asset" --rpc-url "$RPC_URL" | awk '{print $1}')" \
        "$(cast call "$STATICS_DIAMOND_ADDRESS" 'unfundedSwapRewards(address)(uint256)' "$asset" --rpc-url "$RPC_URL" | awk '{print $1}')" \
        "$creator" "$treasury"
}

swap_and_assert_allocation() {
    local label=$1 direction=$2 pol_bps=$3 staker_bps=$4 asset before after
    local bpol bstaker bcreator btreasury apol astaker acreator atreasury
    local dpol dstaker dcreator dtreasury charged expected_creator expected_pol expected_staker expected_treasury
    local -A before_state
    for asset in "$CURRENCY0" "$CURRENCY1"; do before_state[$asset]=$(account_state "$asset"); done
    v4_swap_exact_in "$TRADER_INDEX" "$CURRENCY0" "$CURRENCY1" 3000 60 \
        "$STATICS_SWAP_FEE_HOOK_ADDRESS" "$direction" 200000000000000000 "$label"
    for asset in "$CURRENCY0" "$CURRENCY1"; do
        before=${before_state[$asset]}
        after=$(account_state "$asset")
        read -r bpol bstaker bcreator btreasury <<<"$before"
        read -r apol astaker acreator atreasury <<<"$after"
        dpol=$(printf '%s - %s\n' "$apol" "$bpol" | bc)
        dstaker=$(printf '%s - %s\n' "$astaker" "$bstaker" | bc)
        dcreator=$(printf '%s - %s\n' "$acreator" "$bcreator" | bc)
        dtreasury=$(printf '%s - %s\n' "$atreasury" "$btreasury" | bc)
        charged=$(printf '%s + %s + %s + %s\n' "$dpol" "$dstaker" "$dcreator" "$dtreasury" | bc)
        assert_gt "$charged" 0 "$label bilateral fee for $asset"
        expected_creator=$(printf '%s * 500 / 10000\n' "$charged" | bc)
        expected_pol=$(printf '%s * %s / 10000\n' "$charged" "$pol_bps" | bc)
        expected_staker=$(printf '%s * %s / 10000\n' "$charged" "$staker_bps" | bc)
        expected_treasury=$(printf '%s - %s - %s - %s\n' "$charged" "$expected_creator" "$expected_pol" "$expected_staker" | bc)
        assert_eq "$dcreator" "$expected_creator" "$label creator share for $asset"
        assert_eq "$dpol" "$expected_pol" "$label POL share for $asset"
        assert_eq "$dstaker" "$expected_staker" "$label staker share for $asset"
        assert_eq "$dtreasury" "$expected_treasury" "$label Treasury residual for $asset"
    done
}

DEFAULT_RATE=$(cast call "$STATICS_DIAMOND_ADDRESS" 'defaultProtocolPoolFeeRate()((uint16,uint16))' --rpc-url "$RPC_URL" --json)
assert_eq "$(jq -r '.[0][0]' <<<"$DEFAULT_RATE")" 5 "default input fee"
assert_eq "$(jq -r '.[0][1]' <<<"$DEFAULT_RATE")" 5 "default output fee"
timelock_call "$STATICS_DIAMOND_ADDRESS" 0 \
    "$(cast calldata 'setProtocolPoolFeeRate(bytes32,(uint16,uint16))' "$POOL_ID" '(10,20)')" fee-policy-pool-override
timelock_call "$STATICS_DIAMOND_ADDRESS" 0 \
    "$(cast calldata 'setDefaultProtocolPoolFeeRate((uint16,uint16))' '(30,40)')" fee-policy-default-change
POOL_RATE=$(cast call "$STATICS_DIAMOND_ADDRESS" 'protocolPoolFeeRate(bytes32)((uint16,uint16,bool))' "$POOL_ID" --rpc-url "$RPC_URL" --json)
assert_eq "$(jq -r '.[0][0]' <<<"$POOL_RATE")" 10 "pool input fee override"
assert_eq "$(jq -r '.[0][1]' <<<"$POOL_RATE")" 20 "pool output fee override"
assert_eq "$(jq -r '.[0][2]' <<<"$POOL_RATE")" true "pool fee override marker"
swap_and_assert_allocation fee-policy-override-swap true 4000 3500

timelock_call "$STATICS_DIAMOND_ADDRESS" 0 \
    "$(cast calldata 'clearProtocolPoolFeeRate(bytes32)' "$POOL_ID")" fee-policy-clear-rate
POOL_RATE=$(cast call "$STATICS_DIAMOND_ADDRESS" 'protocolPoolFeeRate(bytes32)((uint16,uint16,bool))' "$POOL_ID" --rpc-url "$RPC_URL" --json)
assert_eq "$(jq -r '.[0][0]' <<<"$POOL_RATE")" 30 "cleared pool input fee"
assert_eq "$(jq -r '.[0][1]' <<<"$POOL_RATE")" 40 "cleared pool output fee"
assert_eq "$(jq -r '.[0][2]' <<<"$POOL_RATE")" false "cleared pool fee marker"

timelock_call "$STATICS_DIAMOND_ADDRESS" 0 \
    "$(cast calldata 'setGeneralFeeAllocation((uint16,uint16,uint16))' '(3000,4000,2500)')" fee-policy-allocation
GENERAL_ALLOCATION=$(cast call "$STATICS_DIAMOND_ADDRESS" \
    'generalFeeAllocation()((uint16,uint16,uint16))' --rpc-url "$RPC_URL" --json)
assert_eq "$(jq -r '.[0][0]' <<<"$GENERAL_ALLOCATION")" 3000 "general POL allocation"
assert_eq "$(jq -r '.[0][1]' <<<"$GENERAL_ALLOCATION")" 4000 "general staker allocation"
assert_eq "$(jq -r '.[0][2]' <<<"$GENERAL_ALLOCATION")" 2500 "general Treasury allocation"
swap_and_assert_allocation fee-policy-global-allocation false 3000 4000
timelock_call "$STATICS_DIAMOND_ADDRESS" 0 \
    "$(cast calldata 'setProtocolPoolPolShare(bytes32,uint16)' "$POOL_ID" 0)" fee-policy-zero-pol
swap_and_assert_allocation fee-policy-zero-pol-swap true 0 4000
timelock_call "$STATICS_DIAMOND_ADDRESS" 0 \
    "$(cast calldata 'clearProtocolPoolPolShare(bytes32)' "$POOL_ID")" fee-policy-clear-pol
swap_and_assert_allocation fee-policy-restored-pol-swap false 3000 4000

expect_call_revert "POL share above current POL plus Treasury bucket" \
    cast call "$STATICS_DIAMOND_ADDRESS" 'setProtocolPoolPolShare(bytes32,uint16)' "$POOL_ID" 5501 \
    --from "$STATICS_TIMELOCK_ADDRESS" --rpc-url "$RPC_URL" \
    >"$RUN_DIR/fee-policy-excess-pol-revert.txt"
timelock_call "$STATICS_DIAMOND_ADDRESS" 0 \
    "$(cast calldata 'setProtocolPoolPolShare(bytes32,uint16)' "$POOL_ID" 5000)" fee-policy-pol-override
timelock_call "$STATICS_DIAMOND_ADDRESS" 0 \
    "$(cast calldata 'setGeneralFeeAllocation((uint16,uint16,uint16))' '(0,9000,500)')" fee-policy-cap-allocation
POOL_VIEW=$(cast call "$STATICS_DIAMOND_ADDRESS" \
    'protocolPool(bytes32)((bytes32,(address,address,uint24,int24,address),uint8,bool,uint256,address,address,bool,bool,uint16,uint256))' \
    "$POOL_ID" --rpc-url "$RPC_URL" --json)
assert_eq "$(jq -r '.[0][9]' <<<"$POOL_VIEW")" 500 "effective POL override cap"
swap_and_assert_allocation fee-policy-capped-pol-swap true 500 9000

read -r _ _ _ TREASURY_PENDING_BEFORE <<<"$(account_state "$CURRENCY0")"
assert_gt "$TREASURY_PENDING_BEFORE" 0 "pending Treasury amount before maintenance"
MAINTAINER=$(anvil_address "$MAINTAINER_INDEX")
MAINTAINER_BALANCE_BEFORE=$(cast call "$CURRENCY0" 'balanceOf(address)(uint256)' "$MAINTAINER" --rpc-url "$RPC_URL" | awk '{print $1}')
cast send "$STATICS_DIAMOND_ADDRESS" 'settleProtocolPoolRevenue(bytes32,address)(uint256,uint256)' \
    "$POOL_ID" "$CURRENCY0" --private-key "$(anvil_private_key "$MAINTAINER_INDEX")" \
    --rpc-url "$RPC_URL" --legacy --json >"$RUN_DIR/fee-policy-maintenance-settle.json"
MAINTAINER_BALANCE_AFTER=$(cast call "$CURRENCY0" 'balanceOf(address)(uint256)' "$MAINTAINER" --rpc-url "$RPC_URL" | awk '{print $1}')
TIP=$(printf '%s - %s\n' "$MAINTAINER_BALANCE_AFTER" "$MAINTAINER_BALANCE_BEFORE" | bc)
assert_eq "$TIP" "$(printf '%s * 500 / 10000\n' "$TREASURY_PENDING_BEFORE" | bc)" "maintenance Treasury-funded tip"

assert_phase_one_solvency fee-policy "$CURRENCY0" "$CURRENCY1" "$STAKING_TOKEN"
record_result protocol-fees rate-precedence pass "$POOL_ID"
record_result protocol-fees allocation-transitions pass "creator, staker, POL, and Treasury reconcile"
record_result protocol-fees pol-override-cap pass "effective 500 BPS"
record_result protocol-fees maintenance-tip pass "$TIP wei"
note "fee-rate, allocation, POL override, and maintenance-tip scenarios passed"
