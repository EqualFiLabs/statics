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
THIRD_INDEX=6
RECIPIENT_INDEX=7
OUTSIDER_INDEX=8
TRADER_INDEX=9
CREATOR=$(anvil_address "$CREATOR_INDEX")
SUCCESSOR=$(anvil_address "$SUCCESSOR_INDEX")
THIRD=$(anvil_address "$THIRD_INDEX")
RECIPIENT=$(anvil_address "$RECIPIENT_INDEX")
OUTSIDER=$(anvil_address "$OUTSIDER_INDEX")
POSITION_FEE=1000000000000000
POOL_ID=$(create_public_pool "$STAKING_TOKEN" "$WETH_ADDRESS" "$CREATOR" 81 creator-handover)

if [[ "${WETH_ADDRESS,,}" < "${STAKING_TOKEN,,}" ]]; then
    CURRENCY0=$WETH_ADDRESS
    CURRENCY1=$STAKING_TOKEN
else
    CURRENCY0=$STAKING_TOKEN
    CURRENCY1=$WETH_ADDRESS
fi

# Create real managed liquidity and fee balances before transferring authority.
acquire_genesis_statics "$CREATOR_INDEX" 2000000000000000000 creator-handover-lp >/dev/null
wrap_weth "$CREATOR_INDEX" 100000000000000000000 creator-handover-lp
for asset in "$CURRENCY0" "$CURRENCY1"; do
    cast send "$asset" 'approve(address,uint256)' "$STATICS_DIAMOND_ADDRESS" "$(cast max-uint)" \
        --private-key "$(anvil_private_key "$CREATOR_INDEX")" --rpc-url "$RPC_URL" --legacy --json \
        >"$RUN_DIR/creator-handover-approve-${asset,,}.json"
done
LP_POSITION=$(cast call "$STATICS_DIAMOND_ADDRESS" 'nextPositionId()(uint256)' --rpc-url "$RPC_URL" | awk '{print $1}')
cast send "$STATICS_DIAMOND_ADDRESS" 'createPosition(address)(uint256)' "$CREATOR" \
    --value "$POSITION_FEE" --private-key "$(anvil_private_key "$CREATOR_INDEX")" \
    --rpc-url "$RPC_URL" --legacy --json >"$RUN_DIR/creator-handover-position.json"
DEADLINE=$(( $(cast block latest --field timestamp --rpc-url "$RPC_URL") + 3600 ))
cast send "$STATICS_DIAMOND_ADDRESS" \
    'provideLiquidity(uint256,(bytes32,int24,int24,uint128,uint256,uint256,uint256))((uint256,uint128,uint256,uint256,uint256,uint256))' \
    "$LP_POSITION" "($POOL_ID,-1200,1200,100000000000000000000,90000000000000000000,90000000000000000000,$DEADLINE)" \
    --private-key "$(anvil_private_key "$CREATOR_INDEX")" --rpc-url "$RPC_URL" --legacy --json \
    >"$RUN_DIR/creator-handover-provide.json"
wrap_weth "$TRADER_INDEX" 5000000000000000000 creator-handover-trader
acquire_genesis_statics "$TRADER_INDEX" 1000000000000000000 creator-handover-trader >/dev/null
v4_swap_exact_in "$TRADER_INDEX" "$CURRENCY0" "$CURRENCY1" 3000 60 "$STATICS_SWAP_FEE_HOOK_ADDRESS" true 500000000000000000 creator-handover-swap0
v4_swap_exact_in "$TRADER_INDEX" "$CURRENCY0" "$CURRENCY1" 3000 60 "$STATICS_SWAP_FEE_HOOK_ADDRESS" false 500000000000000000 creator-handover-swap1
for asset in "$CURRENCY0" "$CURRENCY1"; do
    cast send "$STATICS_DIAMOND_ADDRESS" 'settleProtocolPoolRevenue(bytes32,address)(uint256,uint256)' \
        "$POOL_ID" "$asset" --private-key "$(anvil_private_key "$OUTSIDER_INDEX")" \
        --rpc-url "$RPC_URL" --legacy --json >"$RUN_DIR/creator-handover-settle-${asset,,}.json"
done

cast send "$STATICS_DIAMOND_ADDRESS" 'setCreatorRevenueRecipient(bytes32,address)' "$POOL_ID" "$RECIPIENT" \
    --private-key "$(anvil_private_key "$CREATOR_INDEX")" --rpc-url "$RPC_URL" --legacy --json \
    >"$RUN_DIR/creator-handover-recipient.json"

CREDIT0=$(cast call "$STATICS_DIAMOND_ADDRESS" 'creatorRevenue(bytes32,address)(uint256)' "$POOL_ID" "$CURRENCY0" --rpc-url "$RPC_URL" | awk '{print $1}')
CREDIT1=$(cast call "$STATICS_DIAMOND_ADDRESS" 'creatorRevenue(bytes32,address)(uint256)' "$POOL_ID" "$CURRENCY1" --rpc-url "$RPC_URL" | awk '{print $1}')
assert_gt "$CREDIT0" 0 "settled creator currency0 credit"
assert_gt "$CREDIT1" 0 "settled creator currency1 credit"
TOTAL0=$(cast call "$STATICS_DIAMOND_ADDRESS" 'totalCreatorRevenue(address)(uint256)' "$CURRENCY0" --rpc-url "$RPC_URL" | awk '{print $1}')
TOTAL1=$(cast call "$STATICS_DIAMOND_ADDRESS" 'totalCreatorRevenue(address)(uint256)' "$CURRENCY1" --rpc-url "$RPC_URL" | awk '{print $1}')
RESERVED0=$(cast call "$STATICS_DIAMOND_ADDRESS" 'globalReservedByToken(address)(uint256)' "$CURRENCY0" --rpc-url "$RPC_URL" | awk '{print $1}')
RESERVED1=$(cast call "$STATICS_DIAMOND_ADDRESS" 'globalReservedByToken(address)(uint256)' "$CURRENCY1" --rpc-url "$RPC_URL" | awk '{print $1}')

# Exercise replacement, cancellation, wrong acceptor, and atomic failure paths.
expect_call_revert "outsider creator proposal" \
    cast call "$STATICS_DIAMOND_ADDRESS" 'proposePoolCreator(bytes32,address)' "$POOL_ID" "$SUCCESSOR" \
    --from "$OUTSIDER" --rpc-url "$RPC_URL" >/dev/null
expect_call_revert "self creator proposal" \
    cast call "$STATICS_DIAMOND_ADDRESS" 'proposePoolCreator(bytes32,address)' "$POOL_ID" "$CREATOR" \
    --from "$CREATOR" --rpc-url "$RPC_URL" >/dev/null
expect_call_revert "Diamond creator proposal" \
    cast call "$STATICS_DIAMOND_ADDRESS" 'proposePoolCreator(bytes32,address)' "$POOL_ID" "$STATICS_DIAMOND_ADDRESS" \
    --from "$CREATOR" --rpc-url "$RPC_URL" >/dev/null
cast send "$STATICS_DIAMOND_ADDRESS" 'proposePoolCreator(bytes32,address)' "$POOL_ID" "$SUCCESSOR" \
    --private-key "$(anvil_private_key "$CREATOR_INDEX")" --rpc-url "$RPC_URL" --legacy --json \
    >"$RUN_DIR/creator-handover-propose-successor.json"
cast send "$STATICS_DIAMOND_ADDRESS" 'proposePoolCreator(bytes32,address)' "$POOL_ID" "$THIRD" \
    --private-key "$(anvil_private_key "$CREATOR_INDEX")" --rpc-url "$RPC_URL" --legacy --json \
    >"$RUN_DIR/creator-handover-replace-third.json"
expect_call_revert "replaced successor acceptance" \
    cast call "$STATICS_DIAMOND_ADDRESS" 'acceptPoolCreator(bytes32)' "$POOL_ID" \
    --from "$SUCCESSOR" --rpc-url "$RPC_URL" >/dev/null
cast send "$STATICS_DIAMOND_ADDRESS" 'proposePoolCreator(bytes32,address)' "$POOL_ID" \
    0x0000000000000000000000000000000000000000 \
    --private-key "$(anvil_private_key "$CREATOR_INDEX")" --rpc-url "$RPC_URL" --legacy --json \
    >"$RUN_DIR/creator-handover-cancel.json"
expect_call_revert "cancelled proposal acceptance" \
    cast call "$STATICS_DIAMOND_ADDRESS" 'acceptPoolCreator(bytes32)' "$POOL_ID" \
    --from "$THIRD" --rpc-url "$RPC_URL" >/dev/null
read -r current pending recipient <<<"$(
    cast call "$STATICS_DIAMOND_ADDRESS" 'poolCreatorConfiguration(bytes32)(address,address,address)' \
        "$POOL_ID" --rpc-url "$RPC_URL" | tr '\n' ' '
)"
assert_eq "$current" "$CREATOR" "creator after cancellation"
assert_eq "$pending" 0x0000000000000000000000000000000000000000 "pending creator after cancellation"
assert_eq "$recipient" "$RECIPIENT" "recipient after cancellation"

cast send "$STATICS_DIAMOND_ADDRESS" 'proposePoolCreator(bytes32,address)' "$POOL_ID" "$SUCCESSOR" \
    --private-key "$(anvil_private_key "$CREATOR_INDEX")" --rpc-url "$RPC_URL" --legacy --json \
    >"$RUN_DIR/creator-handover-propose-final.json"
expect_call_revert "wrong pending creator acceptance" \
    cast call "$STATICS_DIAMOND_ADDRESS" 'acceptPoolCreator(bytes32)' "$POOL_ID" \
    --from "$OUTSIDER" --rpc-url "$RPC_URL" >/dev/null
cast send "$STATICS_DIAMOND_ADDRESS" 'acceptPoolCreator(bytes32)' "$POOL_ID" \
    --private-key "$(anvil_private_key "$SUCCESSOR_INDEX")" --rpc-url "$RPC_URL" --legacy --json \
    >"$RUN_DIR/creator-handover-accept.json"
read -r current pending recipient <<<"$(
    cast call "$STATICS_DIAMOND_ADDRESS" 'poolCreatorConfiguration(bytes32)(address,address,address)' \
        "$POOL_ID" --rpc-url "$RPC_URL" | tr '\n' ' '
)"
assert_eq "$current" "$SUCCESSOR" "transferred creator"
assert_eq "$pending" 0x0000000000000000000000000000000000000000 "cleared pending creator"
assert_eq "$recipient" "$SUCCESSOR" "recipient reset on transfer"
assert_eq "$(cast call "$STATICS_DIAMOND_ADDRESS" 'creatorRevenue(bytes32,address)(uint256)' "$POOL_ID" "$CURRENCY0" --rpc-url "$RPC_URL" | awk '{print $1}')" "$CREDIT0" "currency0 pool-local credit continuity"
assert_eq "$(cast call "$STATICS_DIAMOND_ADDRESS" 'creatorRevenue(bytes32,address)(uint256)' "$POOL_ID" "$CURRENCY1" --rpc-url "$RPC_URL" | awk '{print $1}')" "$CREDIT1" "currency1 pool-local credit continuity"
assert_eq "$(cast call "$STATICS_DIAMOND_ADDRESS" 'totalCreatorRevenue(address)(uint256)' "$CURRENCY0" --rpc-url "$RPC_URL" | awk '{print $1}')" "$TOTAL0" "currency0 aggregate liability continuity"
assert_eq "$(cast call "$STATICS_DIAMOND_ADDRESS" 'totalCreatorRevenue(address)(uint256)' "$CURRENCY1" --rpc-url "$RPC_URL" | awk '{print $1}')" "$TOTAL1" "currency1 aggregate liability continuity"
assert_eq "$(cast call "$STATICS_DIAMOND_ADDRESS" 'globalReservedByToken(address)(uint256)' "$CURRENCY0" --rpc-url "$RPC_URL" | awk '{print $1}')" "$RESERVED0" "currency0 custody continuity"
assert_eq "$(cast call "$STATICS_DIAMOND_ADDRESS" 'globalReservedByToken(address)(uint256)' "$CURRENCY1" --rpc-url "$RPC_URL" | awk '{print $1}')" "$RESERVED1" "currency1 custody continuity"
expect_call_revert "repeated creator acceptance" \
    cast call "$STATICS_DIAMOND_ADDRESS" 'acceptPoolCreator(bytes32)' "$POOL_ID" \
    --from "$SUCCESSOR" --rpc-url "$RPC_URL" >/dev/null

# Old authority loses creator-only controls; the successor inherits POL and gauge administration.
expect_call_revert "old creator recipient update" \
    cast call "$STATICS_DIAMOND_ADDRESS" 'setCreatorRevenueRecipient(bytes32,address)' "$POOL_ID" "$CREATOR" \
    --from "$CREATOR" --rpc-url "$RPC_URL" >/dev/null
expect_call_revert "old creator POL activation" \
    cast call "$STATICS_DIAMOND_ADDRESS" 'activateProtocolPoolPol(bytes32)' "$POOL_ID" \
    --value 100000000000000000 --from "$CREATOR" --rpc-url "$RPC_URL" >/dev/null
cast send "$STATICS_DIAMOND_ADDRESS" 'activateProtocolPoolPol(bytes32)' "$POOL_ID" \
    --value 100000000000000000 --private-key "$(anvil_private_key "$SUCCESSOR_INDEX")" \
    --rpc-url "$RPC_URL" --legacy --json >"$RUN_DIR/creator-handover-pol-activate.json"
read -r pol_activated _ _ <<<"$(
    cast call "$STATICS_DIAMOND_ADDRESS" 'protocolPolFundingConfig(bytes32)(bool,bool,uint16)' \
        "$POOL_ID" --rpc-url "$RPC_URL" | tr '\n' ' '
)"
assert_eq "$pol_activated" true "successor POL activation"

ALLOW_CALLDATA=$(cast calldata 'setGaugeRewardAssetAllowed(address,bool)' "$CURRENCY0" true)
timelock_call "$STATICS_DIAMOND_ADDRESS" 0 "$ALLOW_CALLDATA" creator-handover-allow-reward
expect_call_revert "old creator gauge administration" \
    cast call "$STATICS_DIAMOND_ADDRESS" 'appendPoolRewardAsset(bytes32,address)(uint8)' \
    "$POOL_ID" "$CURRENCY0" --from "$CREATOR" --rpc-url "$RPC_URL" >/dev/null
cast send "$STATICS_DIAMOND_ADDRESS" 'appendPoolRewardAsset(bytes32,address)(uint8)' \
    "$POOL_ID" "$CURRENCY0" --private-key "$(anvil_private_key "$SUCCESSOR_INDEX")" \
    --rpc-url "$RPC_URL" --legacy --json >"$RUN_DIR/creator-handover-gauge-slot.json"

# Claims are permissionless but cannot be redirected or made to violate minimum output atomically.
expect_call_revert "creator revenue redirection" \
    cast call "$STATICS_DIAMOND_ADDRESS" \
    'claimCreatorRevenue(bytes32,address,address,uint256)(uint256,uint256)' \
    "$POOL_ID" "$CURRENCY0" "$OUTSIDER" 0 --from "$OUTSIDER" --rpc-url "$RPC_URL" >/dev/null
MIN_TOO_HIGH=$(printf '%s + 1\n' "$CREDIT0" | bc)
expect_call_revert "creator revenue minimum output" \
    cast call "$STATICS_DIAMOND_ADDRESS" \
    'claimCreatorRevenue(bytes32,address,address,uint256)(uint256,uint256)' \
    "$POOL_ID" "$CURRENCY0" "$SUCCESSOR" "$MIN_TOO_HIGH" --from "$OUTSIDER" --rpc-url "$RPC_URL" >/dev/null
assert_eq "$(cast call "$STATICS_DIAMOND_ADDRESS" 'creatorRevenue(bytes32,address)(uint256)' "$POOL_ID" "$CURRENCY0" --rpc-url "$RPC_URL" | awk '{print $1}')" "$CREDIT0" "failed claim preserves credit"
SUCCESSOR_BALANCE_BEFORE=$(cast call "$CURRENCY0" 'balanceOf(address)(uint256)' "$SUCCESSOR" --rpc-url "$RPC_URL" | awk '{print $1}')
cast send "$STATICS_DIAMOND_ADDRESS" \
    'claimCreatorRevenue(bytes32,address,address,uint256)(uint256,uint256)' \
    "$POOL_ID" "$CURRENCY0" "$SUCCESSOR" 0 --private-key "$(anvil_private_key "$OUTSIDER_INDEX")" \
    --rpc-url "$RPC_URL" --legacy --json >"$RUN_DIR/creator-handover-permissionless-claim.json"
SUCCESSOR_RECEIVED=$(printf '%s - %s\n' \
    "$(cast call "$CURRENCY0" 'balanceOf(address)(uint256)' "$SUCCESSOR" --rpc-url "$RPC_URL" | awk '{print $1}')" \
    "$SUCCESSOR_BALANCE_BEFORE" | bc)
assert_eq "$SUCCESSOR_RECEIVED" "$CREDIT0" "fixed-recipient permissionless claim"

cast send "$STATICS_DIAMOND_ADDRESS" 'setCreatorRevenueRecipient(bytes32,address)' "$POOL_ID" "$RECIPIENT" \
    --private-key "$(anvil_private_key "$SUCCESSOR_INDEX")" --rpc-url "$RPC_URL" --legacy --json \
    >"$RUN_DIR/creator-handover-new-recipient.json"
cast send "$STATICS_DIAMOND_ADDRESS" 'setCreatorRevenueRecipient(bytes32,address)' "$POOL_ID" \
    0x0000000000000000000000000000000000000000 \
    --private-key "$(anvil_private_key "$SUCCESSOR_INDEX")" --rpc-url "$RPC_URL" --legacy --json \
    >"$RUN_DIR/creator-handover-reset-recipient.json"
read -r _ _ recipient <<<"$(
    cast call "$STATICS_DIAMOND_ADDRESS" 'poolCreatorConfiguration(bytes32)(address,address,address)' \
        "$POOL_ID" --rpc-url "$RPC_URL" | tr '\n' ' '
)"
assert_eq "$recipient" "$SUCCESSOR" "zero recipient restores creator"

# A round trip must use a fresh proposal; old acceptance state cannot revive.
cast send "$STATICS_DIAMOND_ADDRESS" 'proposePoolCreator(bytes32,address)' "$POOL_ID" "$CREATOR" \
    --private-key "$(anvil_private_key "$SUCCESSOR_INDEX")" --rpc-url "$RPC_URL" --legacy --json \
    >"$RUN_DIR/creator-handover-roundtrip-propose.json"
cast send "$STATICS_DIAMOND_ADDRESS" 'acceptPoolCreator(bytes32)' "$POOL_ID" \
    --private-key "$(anvil_private_key "$CREATOR_INDEX")" --rpc-url "$RPC_URL" --legacy --json \
    >"$RUN_DIR/creator-handover-roundtrip-accept.json"
assert_eq "$(cast call "$STATICS_DIAMOND_ADDRESS" 'protocolPoolCreator(bytes32)(address)' "$POOL_ID" --rpc-url "$RPC_URL")" "$CREATOR" "creator round trip"

assert_phase_one_solvency creator-handover "$CURRENCY0" "$CURRENCY1"
record_result creator-authority proposal-state-machine pass "$POOL_ID"
record_result creator-authority settled-credit-transfer pass "$CREDIT0 currency0 wei, $CREDIT1 currency1 wei"
record_result creator-authority inherited-controls pass "POL and gauge administration"
record_result creator-revenue fixed-recipient-claims pass "$SUCCESSOR_RECEIVED currency0 wei"
note "public creator handover and revenue authority scenarios passed"
