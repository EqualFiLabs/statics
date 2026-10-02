#!/usr/bin/env bash

set -Eeuo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

require_commands cast forge jq awk bc
load_current_run
require_local_chain
reset_to_base
cd_repo

LP_INDEX=10
TRADER_INDEX=11
OUTSIDER_INDEX=12
LP=$(anvil_address "$LP_INDEX")
LP_KEY=$(anvil_private_key "$LP_INDEX")
DEPLOYER_KEY=$(anvil_private_key 0)
POSITION_FEE=1000000000000000
POOL_ID=$(create_public_pool "$STAKING_TOKEN" "$WETH_ADDRESS" "$LP" 118 manager-replacement)

if [[ "${WETH_ADDRESS,,}" < "${STAKING_TOKEN,,}" ]]; then
    CURRENCY0=$WETH_ADDRESS
    CURRENCY1=$STAKING_TOKEN
else
    CURRENCY0=$STAKING_TOKEN
    CURRENCY1=$WETH_ADDRESS
fi

acquire_genesis_statics "$LP_INDEX" 4000000000000000000 manager-replacement-lp >/dev/null
wrap_weth "$LP_INDEX" 150000000000000000000 manager-replacement-lp
for asset in "$CURRENCY0" "$CURRENCY1"; do
    cast send "$asset" 'approve(address,uint256)' "$STATICS_DIAMOND_ADDRESS" "$(cast max-uint)" \
        --private-key "$LP_KEY" --rpc-url "$RPC_URL" --legacy --json \
        >"$RUN_DIR/manager-replacement-approve-${asset,,}.json"
done

LEGACY_POSITION=$(cast call "$STATICS_DIAMOND_ADDRESS" 'nextPositionId()(uint256)' --rpc-url "$RPC_URL" | awk '{print $1}')
cast send "$STATICS_DIAMOND_ADDRESS" 'createPosition(address)(uint256)' "$LP" \
    --value "$POSITION_FEE" --private-key "$LP_KEY" --rpc-url "$RPC_URL" --legacy --json \
    >"$RUN_DIR/manager-replacement-create-legacy.json"
DEADLINE=$(( $(cast block latest --field timestamp --rpc-url "$RPC_URL") + 86400 ))
cast send "$STATICS_DIAMOND_ADDRESS" \
    'provideLiquidity(uint256,(bytes32,int24,int24,uint128,uint256,uint256,uint256))((uint256,uint128,uint256,uint256,uint256,uint256))' \
    "$LEGACY_POSITION" "($POOL_ID,-1200,1200,100000000000000000000,90000000000000000000,90000000000000000000,$DEADLINE)" \
    --private-key "$LP_KEY" --rpc-url "$RPC_URL" --legacy --json \
    >"$RUN_DIR/manager-replacement-provide-legacy.json"
LEGACY_BEFORE=$(cast call "$STATICS_DIAMOND_ADDRESS" \
    'lpLeg(uint256,bytes32)((address,uint256,int24,int24,uint128,uint256[5],uint256[5],uint256[5]))' \
    "$LEGACY_POSITION" "$POOL_ID" --rpc-url "$RPC_URL" --json)
OLD_MANAGER=$(jq -r '.[0][0]' <<<"$LEGACY_BEFORE")
OLD_POSM_TOKEN=$(jq -r '.[0][1]' <<<"$LEGACY_BEFORE")
assert_eq "$OLD_MANAGER" "$STATICS_LIQUIDITY_MANAGER_ADDRESS" "legacy manager before replacement"

# Establish both direct gauge rewards and native v4 fees before replacing the
# active manager. These liabilities must remain attached to the PositionNFT.
ALLOW_CALLDATA=$(cast calldata 'setGaugeRewardAssetAllowed(address,bool)' "$WETH_ADDRESS" true)
timelock_call "$STATICS_DIAMOND_ADDRESS" 0 "$ALLOW_CALLDATA" manager-replacement-allow-weth
cast send "$STATICS_DIAMOND_ADDRESS" 'appendPoolRewardAsset(bytes32,address)(uint8)' \
    "$POOL_ID" "$WETH_ADDRESS" --private-key "$LP_KEY" --rpc-url "$RPC_URL" --legacy --json \
    >"$RUN_DIR/manager-replacement-append-slot.json"
FUND_AMOUNT=7000000000000000000
cast send "$WETH_ADDRESS" 'approve(address,uint256)' "$STATICS_DIAMOND_ADDRESS" "$FUND_AMOUNT" \
    --private-key "$LP_KEY" --rpc-url "$RPC_URL" --legacy --json \
    >"$RUN_DIR/manager-replacement-fund-approve.json"
cast send "$STATICS_DIAMOND_ADDRESS" 'fundPoolReward(bytes32,uint8,uint256,uint40,uint16)(uint256)' \
    "$POOL_ID" 1 "$FUND_AMOUNT" 604800 0 --private-key "$LP_KEY" --rpc-url "$RPC_URL" --legacy --json \
    >"$RUN_DIR/manager-replacement-fund.json"
cast send "$WETH_ADDRESS" 'approve(address,uint256)' "$STATICS_DIAMOND_ADDRESS" "$(cast max-uint)" \
    --private-key "$LP_KEY" --rpc-url "$RPC_URL" --legacy --json \
    >"$RUN_DIR/manager-replacement-refill-allowance.json"

wrap_weth "$TRADER_INDEX" 5000000000000000000 manager-replacement-trader
acquire_genesis_statics "$TRADER_INDEX" 1000000000000000000 manager-replacement-trader >/dev/null
v4_swap_exact_in "$TRADER_INDEX" "$CURRENCY0" "$CURRENCY1" 3000 60 \
    "$STATICS_SWAP_FEE_HOOK_ADDRESS" true 500000000000000000 manager-replacement-swap0
v4_swap_exact_in "$TRADER_INDEX" "$CURRENCY0" "$CURRENCY1" 3000 60 \
    "$STATICS_SWAP_FEE_HOOK_ADDRESS" false 500000000000000000 manager-replacement-swap1
rpc_warp_by 86400
cast send "$STATICS_DIAMOND_ADDRESS" 'checkpointGaugePool(bytes32)(uint256,uint256)' "$POOL_ID" \
    --private-key "$(anvil_private_key "$OUTSIDER_INDEX")" --rpc-url "$RPC_URL" --legacy --json \
    >"$RUN_DIR/manager-replacement-checkpoint.json"
REWARD_BEFORE=$(cast call "$STATICS_DIAMOND_ADDRESS" \
    'previewLpRewards(uint256,bytes32)((uint8,address[5],uint256[5]))' \
    "$LEGACY_POSITION" "$POOL_ID" --rpc-url "$RPC_URL" --json)
assert_gt "$(jq -r '.[0][2][1]' <<<"$REWARD_BEFORE")" 0 "legacy direct reward before replacement"
NATIVE_BEFORE=$(cast call "$STATICS_DIAMOND_ADDRESS" \
    'previewNativeLpFees(uint256,bytes32)(uint256,uint256)' "$LEGACY_POSITION" "$POOL_ID" \
    --rpc-url "$RPC_URL" --json)
assert_gt "$(printf '%s + %s\n' "$(jq -r '.[0]' <<<"$NATIVE_BEFORE")" "$(jq -r '.[1]' <<<"$NATIVE_BEFORE")" | bc)" \
    0 "legacy native fees before replacement"

POSITION_MANAGER=$(cast call "$OLD_MANAGER" 'positionManager()(address)' --rpc-url "$RPC_URL")
POOL_MANAGER=$(cast call "$OLD_MANAGER" 'poolManager()(address)' --rpc-url "$RPC_URL")
PERMIT2=$(cast call "$OLD_MANAGER" 'permit2()(address)' --rpc-url "$RPC_URL")
BYTECODE=$(forge inspect src/liquidity/StaticsLiquidityManager.sol:StaticsLiquidityManager bytecode)
deploy_manager() {
    local diamond=$1
    local label=$2
    local args create_code receipt
    args=$(cast abi-encode 'constructor(address,address,address,address)' \
        "$diamond" "$POSITION_MANAGER" "$POOL_MANAGER" "$PERMIT2")
    create_code="${BYTECODE}${args#0x}"
    receipt="$RUN_DIR/manager-replacement-deploy-$label.json"
    cast send --private-key "$DEPLOYER_KEY" --rpc-url "$RPC_URL" \
        --gas-limit 6000000 --legacy --json --create "$create_code" >"$receipt"
    jq -er '.contractAddress' "$receipt"
}

BAD_MANAGER=$(deploy_manager "$LP" bad-binding)
expect_call_revert "replacement with mismatched Diamond binding" \
    cast call "$STATICS_DIAMOND_ADDRESS" 'replaceLiquidityManager(address)' "$BAD_MANAGER" \
    --from "$STATICS_TIMELOCK_ADDRESS" --rpc-url "$RPC_URL" >/dev/null
expect_call_revert "replacement with EOA" \
    cast call "$STATICS_DIAMOND_ADDRESS" 'replaceLiquidityManager(address)' "$LP" \
    --from "$STATICS_TIMELOCK_ADDRESS" --rpc-url "$RPC_URL" >/dev/null

NEW_MANAGER=$(deploy_manager "$STATICS_DIAMOND_ADDRESS" compatible)
REPLACE_CALLDATA=$(cast calldata 'replaceLiquidityManager(address)' "$NEW_MANAGER")
timelock_call "$STATICS_DIAMOND_ADDRESS" 0 "$REPLACE_CALLDATA" manager-replacement-install
MANAGER_VIEW=$(cast call "$STATICS_DIAMOND_ADDRESS" 'liquidityManager()(address,bool)' --rpc-url "$RPC_URL" --json)
assert_eq "$(jq -r '.[0]' <<<"$MANAGER_VIEW")" "$NEW_MANAGER" "active replacement manager"
assert_eq "$(jq -r '.[1]' <<<"$MANAGER_VIEW")" true "replacement manager installed"
expect_call_revert "unchanged manager replacement" \
    cast call "$STATICS_DIAMOND_ADDRESS" 'replaceLiquidityManager(address)' "$NEW_MANAGER" \
    --from "$STATICS_TIMELOCK_ADDRESS" --rpc-url "$RPC_URL" >/dev/null

# The legacy leg stays bound to Manager A and remains usable until a rebalance
# deliberately burns and remints it under Manager B.
LEGACY_AFTER_INSTALL=$(cast call "$STATICS_DIAMOND_ADDRESS" \
    'lpLeg(uint256,bytes32)((address,uint256,int24,int24,uint128,uint256[5],uint256[5],uint256[5]))' \
    "$LEGACY_POSITION" "$POOL_ID" --rpc-url "$RPC_URL" --json)
assert_eq "$(jq -r '.[0][0]' <<<"$LEGACY_AFTER_INSTALL")" "$OLD_MANAGER" "legacy leg keeps Manager A"
assert_eq "$(jq -r '.[0][1]' <<<"$LEGACY_AFTER_INSTALL")" "$OLD_POSM_TOKEN" "legacy POSM remains bound"
DEADLINE=$(( $(cast block latest --field timestamp --rpc-url "$RPC_URL") + 86400 ))
cast send "$STATICS_DIAMOND_ADDRESS" \
    'collectNativeFees(uint256,bytes32,uint256,uint256,uint256)((uint256,uint128,uint256,uint256,uint256,uint256))' \
    "$LEGACY_POSITION" "$POOL_ID" 0 0 "$DEADLINE" --private-key "$LP_KEY" \
    --rpc-url "$RPC_URL" --legacy --json >"$RUN_DIR/manager-replacement-legacy-collect.json"
cast send "$STATICS_DIAMOND_ADDRESS" \
    'increaseLiquidity(uint256,bytes32,(uint128,uint256,uint256,uint256))((uint256,uint128,uint256,uint256,uint256,uint256))' \
    "$LEGACY_POSITION" "$POOL_ID" "(1000000000000000000,20000000000000000000,20000000000000000000,$DEADLINE)" \
    --private-key "$LP_KEY" --rpc-url "$RPC_URL" --legacy --json \
    >"$RUN_DIR/manager-replacement-legacy-increase.json"
assert_eq "$(cast call "$STATICS_DIAMOND_ADDRESS" 'recordedLiquidityManager(uint256,bytes32)(address)' \
    "$LEGACY_POSITION" "$POOL_ID" --rpc-url "$RPC_URL")" "$OLD_MANAGER" "legacy mutation uses Manager A"

# A newly opened leg uses Manager B immediately.
NEW_POSITION=$(cast call "$STATICS_DIAMOND_ADDRESS" 'nextPositionId()(uint256)' --rpc-url "$RPC_URL" | awk '{print $1}')
cast send "$STATICS_DIAMOND_ADDRESS" 'createPosition(address)(uint256)' "$LP" \
    --value "$POSITION_FEE" --private-key "$LP_KEY" --rpc-url "$RPC_URL" --legacy --json \
    >"$RUN_DIR/manager-replacement-create-new.json"
cast send "$STATICS_DIAMOND_ADDRESS" \
    'provideLiquidity(uint256,(bytes32,int24,int24,uint128,uint256,uint256,uint256))((uint256,uint128,uint256,uint256,uint256,uint256))' \
    "$NEW_POSITION" "($POOL_ID,-1800,1800,10000000000000000000,20000000000000000000,20000000000000000000,$DEADLINE)" \
    --private-key "$LP_KEY" --rpc-url "$RPC_URL" --gas-limit 3000000 --legacy --json \
    >"$RUN_DIR/manager-replacement-provide-new.json"
assert_eq "$(cast call "$STATICS_DIAMOND_ADDRESS" 'recordedLiquidityManager(uint256,bytes32)(address)' \
    "$NEW_POSITION" "$POOL_ID" --rpc-url "$RPC_URL")" "$NEW_MANAGER" "new leg uses Manager B"

PRE_MIGRATION=$(cast call "$STATICS_DIAMOND_ADDRESS" \
    'lpLeg(uint256,bytes32)((address,uint256,int24,int24,uint128,uint256[5],uint256[5],uint256[5]))' \
    "$LEGACY_POSITION" "$POOL_ID" --rpc-url "$RPC_URL" --json)
PRE_MIGRATION_REWARD=$(cast call "$STATICS_DIAMOND_ADDRESS" \
    'previewLpRewards(uint256,bytes32)((uint8,address[5],uint256[5]))' \
    "$LEGACY_POSITION" "$POOL_ID" --rpc-url "$RPC_URL" --json)
LEGACY_LIQUIDITY=$(jq -r '.[0][4]' <<<"$PRE_MIGRATION")
cast send "$STATICS_DIAMOND_ADDRESS" \
    'rebalanceLiquidity(uint256,bytes32,(int24,int24,uint128,uint256,uint256,uint256,uint256,uint256))((uint256,uint128,uint256,uint256,uint256,uint256))' \
    "$LEGACY_POSITION" "$POOL_ID" "(-600,600,$LEGACY_LIQUIDITY,50000000000000000000,50000000000000000000,0,0,$DEADLINE)" \
    --private-key "$LP_KEY" --rpc-url "$RPC_URL" --gas-limit 3000000 --legacy --json \
    >"$RUN_DIR/manager-replacement-lazy-migration.json"
MIGRATED=$(cast call "$STATICS_DIAMOND_ADDRESS" \
    'lpLeg(uint256,bytes32)((address,uint256,int24,int24,uint128,uint256[5],uint256[5],uint256[5]))' \
    "$LEGACY_POSITION" "$POOL_ID" --rpc-url "$RPC_URL" --json)
NEW_POSM_TOKEN=$(jq -r '.[0][1]' <<<"$MIGRATED")
assert_eq "$(jq -r '.[0][0]' <<<"$MIGRATED")" "$NEW_MANAGER" "rebalanced legacy leg migrates to Manager B"
[[ "$NEW_POSM_TOKEN" != "$OLD_POSM_TOKEN" ]] || fail "lazy migration retained the legacy POSM token"
assert_eq "$(jq -r '.[0][4]' <<<"$MIGRATED")" "$LEGACY_LIQUIDITY" "lazy migration liquidity"
assert_eq "$(cast call "$STATICS_DIAMOND_ADDRESS" 'posmBinding(uint256)(bytes32)' \
    "$OLD_POSM_TOKEN" --rpc-url "$RPC_URL")" \
    0x0000000000000000000000000000000000000000000000000000000000000000 \
    "retired POSM binding cleared"
expect_call_revert "retired POSM owner lookup" \
    cast call "$POSITION_MANAGER" 'ownerOf(uint256)(address)' "$OLD_POSM_TOKEN" --rpc-url "$RPC_URL" >/dev/null
assert_eq "$(cast call "$POSITION_MANAGER" 'ownerOf(uint256)(address)' "$NEW_POSM_TOKEN" --rpc-url "$RPC_URL")" \
    "$NEW_MANAGER" "migrated POSM owned by Manager B"
MIGRATED_REWARD=$(cast call "$STATICS_DIAMOND_ADDRESS" \
    'previewLpRewards(uint256,bytes32)((uint8,address[5],uint256[5]))' \
    "$LEGACY_POSITION" "$POOL_ID" --rpc-url "$RPC_URL" --json)
assert_ge "$(jq -r '.[0][2][1]' <<<"$MIGRATED_REWARD")" \
    "$(jq -r '.[0][2][1]' <<<"$PRE_MIGRATION_REWARD")" "reward entitlement survives migration"

assert_phase_one_solvency manager-replacement "$CURRENCY0" "$CURRENCY1"
record_result range-gauge manager-binding-rejection pass "$BAD_MANAGER"
record_result range-gauge compatible-manager-replacement pass "$OLD_MANAGER to $NEW_MANAGER"
record_result range-gauge legacy-manager-operation pass "$OLD_POSM_TOKEN"
record_result range-gauge lazy-manager-migration pass "$OLD_POSM_TOKEN to $NEW_POSM_TOKEN"
note "liquidity manager replacement and lazy migration scenarios passed"
