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
SUCCESSOR_INDEX=10
LP_INDEX=11
TRADER_INDEX=12
OUTSIDER_INDEX=13
CREATOR=$(anvil_address "$CREATOR_INDEX")
SUCCESSOR=$(anvil_address "$SUCCESSOR_INDEX")
LP=$(anvil_address "$LP_INDEX")
TRADER=$(anvil_address "$TRADER_INDEX")

cast send "$STATICS_DEFAULT_VENUE_CONTROLLER_FACTORY" 'createController()(address)' \
    --private-key "$(anvil_private_key "$CREATOR_INDEX")" --rpc-url "$RPC_URL" --legacy --json \
    >"$RUN_DIR/permissioned-handover-create-controller.json"
CONTROLLER_TOPIC=$(cast keccak 'VenueControllerCreated(address,address)')
CONTROLLER=$(jq -r --arg topic "${CONTROLLER_TOPIC,,}" '
    .logs[] | select((.topics[0] | ascii_downcase) == $topic) | .topics[2] | "0x" + .[-40:]
' "$RUN_DIR/permissioned-handover-create-controller.json")
assert_nonzero_address "$CONTROLLER" "permissioned handover controller"

DEADLINE=$(( $(cast block latest --field timestamp --rpc-url "$RPC_URL") + 259200 ))
AGREEMENT=$(cast keccak 'permissioned-creator-handover')
ECONOMICS='(50,0,(8000,1000,1000,0))'
PARAMS="($STAKING_TOKEN,$WETH_ADDRESS,3000,60,79228162514264337593543950336,$CREATOR,$CONTROLLER,$ECONOMICS,71,$DEADLINE,$AGREEMENT)"
QUOTE=$(cast call "$STATICS_DIAMOND_ADDRESS" \
    'quotePermissionedPool((address,address,uint24,int24,uint160,address,address,(uint16,uint8,(uint16,uint16,uint16,uint16)),uint256,uint256,bytes32))(((address,address,uint24,int24,address),bytes32,uint160,bytes32))' \
    "$PARAMS" --rpc-url "$RPC_URL" --json)
POOL_ID=$(jq -r '.[0][1]' <<<"$QUOTE")
AUTHORIZATION=$(cast wallet sign --no-hash --private-key "$(anvil_private_key "$CREATOR_INDEX")" \
    "$(jq -r '.[0][3]' <<<"$QUOTE")")
CREATE_CALLDATA=$(cast calldata \
    'createPermissionedPool((address,address,uint24,int24,uint160,address,address,(uint16,uint8,(uint16,uint16,uint16,uint16)),uint256,uint256,bytes32),bytes)' \
    "$PARAMS" "$AUTHORIZATION")
timelock_call "$STATICS_DIAMOND_ADDRESS" 0 "$CREATE_CALLDATA" permissioned-handover-create

if [[ "${WETH_ADDRESS,,}" < "${STAKING_TOKEN,,}" ]]; then
    CURRENCY0=$WETH_ADDRESS
    CURRENCY1=$STAKING_TOKEN
else
    CURRENCY0=$STAKING_TOKEN
    CURRENCY1=$WETH_ADDRESS
fi
POOL_KEY="($CURRENCY0,$CURRENCY1,3000,60,$STATICS_PERMISSIONED_SWAP_FEE_HOOK_ADDRESS)"

# Establish live LP ownership, trading permissions, and creator credit before handover.
cast send "$CONTROLLER" 'setPermissions(bytes32,address[],uint256[])' "$POOL_ID" "[$LP,$TRADER]" '[2,1]' \
    --private-key "$(anvil_private_key "$CREATOR_INDEX")" --rpc-url "$RPC_URL" --legacy --json \
    >"$RUN_DIR/permissioned-handover-permissions.json"
acquire_genesis_statics "$LP_INDEX" 2000000000000000000 permissioned-handover-lp >/dev/null
wrap_weth "$LP_INDEX" 100000000000000000000 permissioned-handover-lp
approve_permit2_spender "$LP_INDEX" "$CURRENCY0" "$STATICS_PERMISSIONED_POSITION_MANAGER_ADDRESS" permissioned-handover-posm0
approve_permit2_spender "$LP_INDEX" "$CURRENCY1" "$STATICS_PERMISSIONED_POSITION_MANAGER_ADDRESS" permissioned-handover-posm1
TOKEN_ID=$(cast call "$STATICS_PERMISSIONED_POSITION_MANAGER_ADDRESS" 'nextTokenId()(uint256)' --rpc-url "$RPC_URL" | awk '{print $1}')
MINT_PARAM=$(cast abi-encode \
    'f((address,address,uint24,int24,address),int24,int24,uint256,uint128,uint128,address,bytes)' \
    "$POOL_KEY" -887220 887220 50000000000000000000 60000000000000000000 60000000000000000000 "$LP" 0x)
SETTLE_PARAM=$(cast abi-encode 'f(address,address)' "$CURRENCY0" "$CURRENCY1")
MINT_PLAN=$(cast abi-encode 'f(bytes,bytes[])' 0x020d "[$MINT_PARAM,$SETTLE_PARAM]")
POSITION_DEADLINE=$(( $(cast block latest --field timestamp --rpc-url "$RPC_URL") + 3600 ))
cast send "$STATICS_PERMISSIONED_POSITION_MANAGER_ADDRESS" 'modifyLiquidities(bytes,uint256)' \
    "$MINT_PLAN" "$POSITION_DEADLINE" --private-key "$(anvil_private_key "$LP_INDEX")" \
    --rpc-url "$RPC_URL" --gas-limit 3000000 --legacy --json \
    >"$RUN_DIR/permissioned-handover-mint.json"

wrap_weth "$TRADER_INDEX" 2000000000000000000 permissioned-handover-trader
approve_permit2_spender "$TRADER_INDEX" "$CURRENCY0" "$STATICS_PERMISSIONED_ROUTER_ADDRESS" permissioned-handover-router
SWAP_PARAMS="($POOL_KEY,true,100000000000000000,0,0x)"
SWAP_DEADLINE=$(( $(cast block latest --field timestamp --rpc-url "$RPC_URL") + 3600 ))
cast send "$STATICS_PERMISSIONED_ROUTER_ADDRESS" \
    'swapExactInputSingle(((address,address,uint24,int24,address),bool,uint128,uint128,bytes),uint256)(uint256)' \
    "$SWAP_PARAMS" "$SWAP_DEADLINE" --private-key "$(anvil_private_key "$TRADER_INDEX")" \
    --rpc-url "$RPC_URL" --gas-limit 3000000 --legacy --json \
    >"$RUN_DIR/permissioned-handover-swap-before.json"
CREATOR_CREDIT_BEFORE=$(cast call "$STATICS_DIAMOND_ADDRESS" 'creatorRevenue(bytes32,address)(uint256)' \
    "$POOL_ID" "$CURRENCY1" --rpc-url "$RPC_URL" | awk '{print $1}')
assert_gt "$CREATOR_CREDIT_BEFORE" 0 "permissioned creator credit before transfer"
TOTAL_CREATOR_BEFORE=$(cast call "$STATICS_DIAMOND_ADDRESS" 'totalCreatorRevenue(address)(uint256)' \
    "$CURRENCY1" --rpc-url "$RPC_URL" | awk '{print $1}')

# Produce valid creator-A approvals at nonce zero before authority changes.
CHANGED_ECONOMICS='(60,0,(8000,1000,1000,0))'
# The signed terms remain valid across two independent one-day timelock ceremonies.
SIGNED_DEADLINE=$(( $(cast block latest --field timestamp --rpc-url "$RPC_URL") + 2592000 ))
SIGNED_AGREEMENT=$(cast keccak 'permissioned-handover-signed-before-transfer')
OLD_TERMS_DIGEST=$(cast call "$STATICS_DIAMOND_ADDRESS" \
    'permissionedTermsDigest(bytes32,(uint16,uint8,(uint16,uint16,uint16,uint16)),uint256,uint256,bytes32)(bytes32)' \
    "$POOL_ID" "$CHANGED_ECONOMICS" 0 "$SIGNED_DEADLINE" "$SIGNED_AGREEMENT" --rpc-url "$RPC_URL")
OLD_TERMS_AUTH=$(cast wallet sign --no-hash --private-key "$(anvil_private_key "$CREATOR_INDEX")" "$OLD_TERMS_DIGEST")

cast send "$STATICS_DEFAULT_VENUE_CONTROLLER_FACTORY" 'createController()(address)' \
    --private-key "$(anvil_private_key "$SUCCESSOR_INDEX")" --rpc-url "$RPC_URL" --legacy --json \
    >"$RUN_DIR/permissioned-handover-create-replacement.json"
REPLACEMENT=$(jq -r --arg topic "${CONTROLLER_TOPIC,,}" '
    .logs[] | select((.topics[0] | ascii_downcase) == $topic) | .topics[2] | "0x" + .[-40:]
' "$RUN_DIR/permissioned-handover-create-replacement.json")
cast send "$REPLACEMENT" 'setPoolStatus(bytes32,uint8)' "$POOL_ID" 1 \
    --private-key "$(anvil_private_key "$SUCCESSOR_INDEX")" --rpc-url "$RPC_URL" --legacy --json \
    >"$RUN_DIR/permissioned-handover-replacement-halted.json"
OLD_CONTROLLER_DIGEST=$(cast call "$STATICS_DIAMOND_ADDRESS" \
    'permissionedControllerReplacementDigest(bytes32,address,address,uint256,uint256,bytes32)(bytes32)' \
    "$POOL_ID" "$CONTROLLER" "$REPLACEMENT" 0 "$SIGNED_DEADLINE" "$SIGNED_AGREEMENT" --rpc-url "$RPC_URL")
OLD_CONTROLLER_AUTH=$(cast wallet sign --no-hash --private-key "$(anvil_private_key "$CREATOR_INDEX")" "$OLD_CONTROLLER_DIGEST")

cast send "$STATICS_DIAMOND_ADDRESS" 'setCreatorRevenueRecipient(bytes32,address)' "$POOL_ID" "$CREATOR" \
    --private-key "$(anvil_private_key "$CREATOR_INDEX")" --rpc-url "$RPC_URL" --legacy --json \
    >"$RUN_DIR/permissioned-handover-recipient.json"
cast send "$STATICS_DIAMOND_ADDRESS" 'proposePoolCreator(bytes32,address)' "$POOL_ID" "$SUCCESSOR" \
    --private-key "$(anvil_private_key "$CREATOR_INDEX")" --rpc-url "$RPC_URL" --legacy --json \
    >"$RUN_DIR/permissioned-handover-propose.json"
cast send "$STATICS_DIAMOND_ADDRESS" 'acceptPoolCreator(bytes32)' "$POOL_ID" \
    --private-key "$(anvil_private_key "$SUCCESSOR_INDEX")" --rpc-url "$RPC_URL" --legacy --json \
    >"$RUN_DIR/permissioned-handover-accept.json"

POOL_VIEW=$(cast call "$STATICS_DIAMOND_ADDRESS" \
    'permissionedPool(bytes32)((bytes32,(address,address,uint24,int24,address),address,address,bool,uint256,(uint16,uint8,(uint16,uint16,uint16,uint16))))' \
    "$POOL_ID" --rpc-url "$RPC_URL" --json)
assert_eq "$(jq -r '.[0][2]' <<<"$POOL_VIEW")" "$SUCCESSOR" "permissioned transferred creator"
assert_eq "$(jq -r '.[0][3]' <<<"$POOL_VIEW")" "$CONTROLLER" "controller continuity"
assert_eq "$(jq -r '.[0][5]' <<<"$POOL_VIEW")" 1 "creator transfer configuration nonce"
assert_eq "$(cast call "$STATICS_PERMISSIONED_POSITION_MANAGER_ADDRESS" 'ownerOf(uint256)(address)' "$TOKEN_ID" --rpc-url "$RPC_URL")" "$LP" "permissioned LP owner continuity"
assert_eq "$(cast call "$STATICS_DIAMOND_ADDRESS" 'creatorRevenue(bytes32,address)(uint256)' "$POOL_ID" "$CURRENCY1" --rpc-url "$RPC_URL" | awk '{print $1}')" "$CREATOR_CREDIT_BEFORE" "permissioned creator credit continuity"
assert_eq "$(cast call "$STATICS_DIAMOND_ADDRESS" 'totalCreatorRevenue(address)(uint256)' "$CURRENCY1" --rpc-url "$RPC_URL" | awk '{print $1}')" "$TOTAL_CREATOR_BEFORE" "permissioned aggregate liability continuity"

OLD_TERMS_CALLDATA=$(cast calldata \
    'applyPermissionedPoolTerms(bytes32,(uint16,uint8,(uint16,uint16,uint16,uint16)),uint256,uint256,bytes32,bytes)' \
    "$POOL_ID" "$CHANGED_ECONOMICS" 0 "$SIGNED_DEADLINE" "$SIGNED_AGREEMENT" "$OLD_TERMS_AUTH")
OLD_CONTROLLER_CALLDATA=$(cast calldata \
    'replacePermissionedPoolController(bytes32,address,address,uint256,uint256,bytes32,bytes)' \
    "$POOL_ID" "$CONTROLLER" "$REPLACEMENT" 0 "$SIGNED_DEADLINE" "$SIGNED_AGREEMENT" "$OLD_CONTROLLER_AUTH")
expect_call_revert "old creator terms authorization" \
    cast call "$STATICS_DIAMOND_ADDRESS" "$OLD_TERMS_CALLDATA" --from "$STATICS_TIMELOCK_ADDRESS" --rpc-url "$RPC_URL" >/dev/null
expect_call_revert "old creator controller authorization" \
    cast call "$STATICS_DIAMOND_ADDRESS" "$OLD_CONTROLLER_CALLDATA" --from "$STATICS_TIMELOCK_ADDRESS" --rpc-url "$RPC_URL" >/dev/null

# Existing venue operation survives handover before any terms or controller change.
SWAP_DEADLINE=$(( $(cast block latest --field timestamp --rpc-url "$RPC_URL") + 3600 ))
cast send "$STATICS_PERMISSIONED_ROUTER_ADDRESS" \
    'swapExactInputSingle(((address,address,uint24,int24,address),bool,uint128,uint128,bytes),uint256)(uint256)' \
    "$SWAP_PARAMS" "$SWAP_DEADLINE" --private-key "$(anvil_private_key "$TRADER_INDEX")" \
    --rpc-url "$RPC_URL" --gas-limit 3000000 --legacy --json \
    >"$RUN_DIR/permissioned-handover-swap-after.json"
assert_gt "$(cast call "$STATICS_DIAMOND_ADDRESS" 'creatorRevenue(bytes32,address)(uint256)' \
    "$POOL_ID" "$CURRENCY1" --rpc-url "$RPC_URL" | awk '{print $1}')" "$CREATOR_CREDIT_BEFORE" "unsettled revenue follows pool authority"

# Current creator approvals at current nonces succeed through the real timelock.
CURRENT_TERMS_NONCE=1
CURRENT_TERMS_DIGEST=$(cast call "$STATICS_DIAMOND_ADDRESS" \
    'permissionedTermsDigest(bytes32,(uint16,uint8,(uint16,uint16,uint16,uint16)),uint256,uint256,bytes32)(bytes32)' \
    "$POOL_ID" "$CHANGED_ECONOMICS" "$CURRENT_TERMS_NONCE" "$SIGNED_DEADLINE" "$SIGNED_AGREEMENT" --rpc-url "$RPC_URL")
CURRENT_TERMS_AUTH=$(cast wallet sign --no-hash --private-key "$(anvil_private_key "$SUCCESSOR_INDEX")" "$CURRENT_TERMS_DIGEST")
CURRENT_TERMS_CALLDATA=$(cast calldata \
    'applyPermissionedPoolTerms(bytes32,(uint16,uint8,(uint16,uint16,uint16,uint16)),uint256,uint256,bytes32,bytes)' \
    "$POOL_ID" "$CHANGED_ECONOMICS" "$CURRENT_TERMS_NONCE" "$SIGNED_DEADLINE" "$SIGNED_AGREEMENT" "$CURRENT_TERMS_AUTH")
timelock_call "$STATICS_DIAMOND_ADDRESS" 0 "$CURRENT_TERMS_CALLDATA" permissioned-handover-current-terms

CURRENT_CONTROLLER_NONCE=2
CURRENT_CONTROLLER_DIGEST=$(cast call "$STATICS_DIAMOND_ADDRESS" \
    'permissionedControllerReplacementDigest(bytes32,address,address,uint256,uint256,bytes32)(bytes32)' \
    "$POOL_ID" "$CONTROLLER" "$REPLACEMENT" "$CURRENT_CONTROLLER_NONCE" "$SIGNED_DEADLINE" "$SIGNED_AGREEMENT" --rpc-url "$RPC_URL")
CURRENT_CONTROLLER_AUTH=$(cast wallet sign --no-hash --private-key "$(anvil_private_key "$SUCCESSOR_INDEX")" "$CURRENT_CONTROLLER_DIGEST")
CURRENT_CONTROLLER_CALLDATA=$(cast calldata \
    'replacePermissionedPoolController(bytes32,address,address,uint256,uint256,bytes32,bytes)' \
    "$POOL_ID" "$CONTROLLER" "$REPLACEMENT" "$CURRENT_CONTROLLER_NONCE" "$SIGNED_DEADLINE" "$SIGNED_AGREEMENT" "$CURRENT_CONTROLLER_AUTH")
timelock_call "$STATICS_DIAMOND_ADDRESS" 0 "$CURRENT_CONTROLLER_CALLDATA" permissioned-handover-current-controller
POOL_VIEW=$(cast call "$STATICS_DIAMOND_ADDRESS" \
    'permissionedPool(bytes32)((bytes32,(address,address,uint24,int24,address),address,address,bool,uint256,(uint16,uint8,(uint16,uint16,uint16,uint16))))' \
    "$POOL_ID" --rpc-url "$RPC_URL" --json)
assert_eq "$(jq -r '.[0][3]' <<<"$POOL_VIEW")" "$REPLACEMENT" "replacement controller"
assert_eq "$(jq -r '.[0][5]' <<<"$POOL_VIEW")" 3 "terms and replacement nonce"

expect_call_revert "replacement begins halted" \
    cast call "$STATICS_PERMISSIONED_ROUTER_ADDRESS" \
    'swapExactInputSingle(((address,address,uint24,int24,address),bool,uint128,uint128,bytes),uint256)(uint256)' \
    "$SWAP_PARAMS" "$SWAP_DEADLINE" --from "$TRADER" --rpc-url "$RPC_URL" >/dev/null
cast send "$REPLACEMENT" 'setPermissions(bytes32,address[],uint256[])' "$POOL_ID" "[$TRADER,$LP]" '[1,2]' \
    --private-key "$(anvil_private_key "$SUCCESSOR_INDEX")" --rpc-url "$RPC_URL" --legacy --json \
    >"$RUN_DIR/permissioned-handover-replacement-permissions.json"
cast send "$REPLACEMENT" 'setPoolStatus(bytes32,uint8)' "$POOL_ID" 0 \
    --private-key "$(anvil_private_key "$SUCCESSOR_INDEX")" --rpc-url "$RPC_URL" --legacy --json \
    >"$RUN_DIR/permissioned-handover-replacement-active.json"
SWAP_DEADLINE=$(( $(cast block latest --field timestamp --rpc-url "$RPC_URL") + 3600 ))
cast send "$STATICS_PERMISSIONED_ROUTER_ADDRESS" \
    'swapExactInputSingle(((address,address,uint24,int24,address),bool,uint128,uint128,bytes),uint256)(uint256)' \
    "$SWAP_PARAMS" "$SWAP_DEADLINE" --private-key "$(anvil_private_key "$TRADER_INDEX")" \
    --rpc-url "$RPC_URL" --gas-limit 3000000 --legacy --json \
    >"$RUN_DIR/permissioned-handover-swap-replacement.json"

# Returning authority to A cannot revive A's nonce-zero authorizations.
cast send "$STATICS_DIAMOND_ADDRESS" 'proposePoolCreator(bytes32,address)' "$POOL_ID" "$CREATOR" \
    --private-key "$(anvil_private_key "$SUCCESSOR_INDEX")" --rpc-url "$RPC_URL" --legacy --json \
    >"$RUN_DIR/permissioned-handover-roundtrip-propose.json"
cast send "$STATICS_DIAMOND_ADDRESS" 'acceptPoolCreator(bytes32)' "$POOL_ID" \
    --private-key "$(anvil_private_key "$CREATOR_INDEX")" --rpc-url "$RPC_URL" --legacy --json \
    >"$RUN_DIR/permissioned-handover-roundtrip-accept.json"
expect_call_revert "old creator authorization after round trip" \
    cast call "$STATICS_DIAMOND_ADDRESS" "$OLD_TERMS_CALLDATA" --from "$STATICS_TIMELOCK_ADDRESS" --rpc-url "$RPC_URL" >/dev/null

# Decommission preserves creator-management and financial rights, including a later handover.
DECOMMISSION_CALLDATA=$(cast calldata 'decommissionPermissionedPool(bytes32)' "$POOL_ID")
timelock_call "$STATICS_DIAMOND_ADDRESS" 0 "$DECOMMISSION_CALLDATA" permissioned-handover-decommission
cast send "$STATICS_DIAMOND_ADDRESS" 'proposePoolCreator(bytes32,address)' "$POOL_ID" "$SUCCESSOR" \
    --private-key "$(anvil_private_key "$CREATOR_INDEX")" --rpc-url "$RPC_URL" --legacy --json \
    >"$RUN_DIR/permissioned-handover-decommission-propose.json"
cast send "$STATICS_DIAMOND_ADDRESS" 'acceptPoolCreator(bytes32)' "$POOL_ID" \
    --private-key "$(anvil_private_key "$SUCCESSOR_INDEX")" --rpc-url "$RPC_URL" --legacy --json \
    >"$RUN_DIR/permissioned-handover-decommission-accept.json"
assert_eq "$(cast call "$STATICS_DIAMOND_ADDRESS" 'protocolPoolCreator(bytes32)(address)' "$POOL_ID" --rpc-url "$RPC_URL")" "$SUCCESSOR" "creator transfer after decommission"

FINAL_CREDIT=$(cast call "$STATICS_DIAMOND_ADDRESS" 'creatorRevenue(bytes32,address)(uint256)' \
    "$POOL_ID" "$CURRENCY1" --rpc-url "$RPC_URL" | awk '{print $1}')
SUCCESSOR_BEFORE=$(cast call "$CURRENCY1" 'balanceOf(address)(uint256)' "$SUCCESSOR" --rpc-url "$RPC_URL" | awk '{print $1}')
cast send "$STATICS_DIAMOND_ADDRESS" \
    'claimCreatorRevenue(bytes32,address,address,uint256)(uint256,uint256)' \
    "$POOL_ID" "$CURRENCY1" "$SUCCESSOR" 0 --private-key "$(anvil_private_key "$OUTSIDER_INDEX")" \
    --rpc-url "$RPC_URL" --legacy --json >"$RUN_DIR/permissioned-handover-claim.json"
assert_eq "$(printf '%s - %s\n' \
    "$(cast call "$CURRENCY1" 'balanceOf(address)(uint256)' "$SUCCESSOR" --rpc-url "$RPC_URL" | awk '{print $1}')" \
    "$SUCCESSOR_BEFORE" | bc)" "$FINAL_CREDIT" "decommissioned permissioned creator claim"

assert_phase_one_solvency permissioned-creator-handover "$CURRENCY0" "$CURRENCY1"
record_result permissioned creator-handover pass "$POOL_ID"
record_result permissioned stale-authorizations-invalidated pass "terms and controller nonce zero"
record_result permissioned controller-continuity-and-replacement pass "$CONTROLLER to $REPLACEMENT"
record_result permissioned decommissioned-creator-rights pass "$FINAL_CREDIT currency1 wei"
note "permissioned creator handover, signature invalidation, and controller scenarios passed"
