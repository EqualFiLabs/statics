#!/usr/bin/env bash

set -Eeuo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

require_commands cast jq awk bc
load_current_run
require_local_chain
reset_to_base

DIRECT_INDEX=4
SIGNED_INDEX=5
RELAYER_INDEX=6
WRONG_SIGNER_INDEX=7
DIRECT=$(anvil_address "$DIRECT_INDEX")
SIGNED=$(anvil_address "$SIGNED_INDEX")
RELAYER=$(anvil_address "$RELAYER_INDEX")
CREATION_FEE=10000000000000000
Q96=79228162514264337593543950336
ZERO=0x0000000000000000000000000000000000000000

quote_pool() {
    local params=$1
    cast call "$STATICS_DIAMOND_ADDRESS" \
        'quotePool((address,address,uint24,int24,uint160,(uint16,uint16),address,bool,uint256,uint256))(((address,address,uint24,int24,address),bytes32,uint160,uint256,uint256,uint256,bytes32))' \
        "$params" --rpc-url "$RPC_URL" --json
}

create_pool_call() {
    local params=$1
    local signature=$2
    local sender=$3
    local value=$4
    cast call "$STATICS_DIAMOND_ADDRESS" \
        'createPool((address,address,uint24,int24,uint160,(uint16,uint16),address,bool,uint256,uint256),bytes)(bytes32)' \
        "$params" "$signature" --from "$sender" --value "$value" --rpc-url "$RPC_URL"
}

SET_FEE_CALLDATA=$(cast calldata 'setPoolCreationFee(uint256)' "$CREATION_FEE")
timelock_call "$STATICS_DIAMOND_ADDRESS" 0 "$SET_FEE_CALLDATA" public-creation-fee
assert_eq "$(cast call "$STATICS_DIAMOND_ADDRESS" 'poolCreationFee()(uint256)' --rpc-url "$RPC_URL" | awk '{print $1}')" "$CREATION_FEE" "configured pool creation fee"

DEADLINE=$(( $(cast block latest --field timestamp --rpc-url "$RPC_URL") + 172800 ))
DIRECT_PARAMS="($STAKING_TOKEN,$WETH_ADDRESS,500,10,$Q96,(500,500),$DIRECT,false,101,$DEADLINE)"
DIRECT_QUOTE=$(quote_pool "$DIRECT_PARAMS")
DIRECT_POOL=$(jq -r '.[0][1]' <<<"$DIRECT_QUOTE")
DIRECT_TOTAL=$(jq -r '.[0][5]' <<<"$DIRECT_QUOTE")
assert_eq "$DIRECT_TOTAL" "$CREATION_FEE" "direct pool exact native fee quote"

TREASURY_ETH_BEFORE=$(cast balance "$TREASURY" --rpc-url "$RPC_URL")
expect_call_revert "pool creation underpayment" create_pool_call "$DIRECT_PARAMS" 0x "$DIRECT" "$(( CREATION_FEE - 1 ))" >/dev/null
expect_call_revert "pool creation overpayment" create_pool_call "$DIRECT_PARAMS" 0x "$DIRECT" "$(( CREATION_FEE + 1 ))" >/dev/null
assert_eq "$(cast balance "$TREASURY" --rpc-url "$RPC_URL")" "$TREASURY_ETH_BEFORE" "failed payment atomicity"
cast send "$STATICS_DIAMOND_ADDRESS" \
    'createPool((address,address,uint24,int24,uint160,(uint16,uint16),address,bool,uint256,uint256),bytes)(bytes32)' \
    "$DIRECT_PARAMS" 0x --value "$CREATION_FEE" --private-key "$(anvil_private_key "$DIRECT_INDEX")" \
    --rpc-url "$RPC_URL" --legacy --json >"$RUN_DIR/public-creation-direct.json"
assert_eq "$(cast call "$STATICS_DIAMOND_ADDRESS" 'isProtocolPool(bytes32)(bool)' "$DIRECT_POOL" --rpc-url "$RPC_URL")" true "direct permissionless pool registration"
assert_eq "$(printf '%s - %s\n' "$(cast balance "$TREASURY" --rpc-url "$RPC_URL")" "$TREASURY_ETH_BEFORE" | bc)" "$CREATION_FEE" "creation fee sent entirely to Treasury"
expect_call_revert "duplicate PoolKey" create_pool_call "$DIRECT_PARAMS" 0x "$DIRECT" "$CREATION_FEE" >/dev/null

# Same token pair remains permissionless across distinct tick spacing and native LP fee keys.
SPACING_PARAMS="($STAKING_TOKEN,$WETH_ADDRESS,500,60,$Q96,(500,500),$DIRECT,false,102,$DEADLINE)"
SPACING_POOL=$(quote_pool "$SPACING_PARAMS" | jq -r '.[0][1]')
cast send "$STATICS_DIAMOND_ADDRESS" \
    'createPool((address,address,uint24,int24,uint160,(uint16,uint16),address,bool,uint256,uint256),bytes)(bytes32)' \
    "$SPACING_PARAMS" 0x --value "$CREATION_FEE" --private-key "$(anvil_private_key "$DIRECT_INDEX")" \
    --rpc-url "$RPC_URL" --legacy --json >"$RUN_DIR/public-creation-spacing.json"
FEE_PARAMS="($STAKING_TOKEN,$WETH_ADDRESS,3000,10,$Q96,(500,500),$DIRECT,false,103,$DEADLINE)"
FEE_POOL=$(quote_pool "$FEE_PARAMS" | jq -r '.[0][1]')
cast send "$STATICS_DIAMOND_ADDRESS" \
    'createPool((address,address,uint24,int24,uint160,(uint16,uint16),address,bool,uint256,uint256),bytes)(bytes32)' \
    "$FEE_PARAMS" 0x --value "$CREATION_FEE" --private-key "$(anvil_private_key "$DIRECT_INDEX")" \
    --rpc-url "$RPC_URL" --legacy --json >"$RUN_DIR/public-creation-lp-fee.json"
[[ "${DIRECT_POOL,,}" != "${SPACING_POOL,,}" && "${DIRECT_POOL,,}" != "${FEE_POOL,,}" && "${SPACING_POOL,,}" != "${FEE_POOL,,}" ]] \
    || fail "distinct public pool keys collided"

# Invalid inputs fail before collecting native value or consuming creator state.
expect_call_revert "invalid tick spacing" quote_pool \
    "($STAKING_TOKEN,$WETH_ADDRESS,700,0,$Q96,(500,500),$DIRECT,false,104,$DEADLINE)" >/dev/null
expect_call_revert "invalid initial price" quote_pool \
    "($STAKING_TOKEN,$WETH_ADDRESS,700,10,0,(500,500),$DIRECT,false,105,$DEADLINE)" >/dev/null
expect_call_revert "zero creator" quote_pool \
    "($STAKING_TOKEN,$WETH_ADDRESS,700,10,$Q96,(500,500),$ZERO,false,106,$DEADLINE)" >/dev/null
expect_call_revert "expired creation authorization" create_pool_call \
    "($STAKING_TOKEN,$WETH_ADDRESS,700,10,$Q96,(500,500),$DIRECT,false,107,1)" 0x "$DIRECT" "$CREATION_FEE" >/dev/null

# Relayed EIP-712 authorization consumes the creator nonce and rejects invalid signatures and reuse.
SIGNED_PARAMS="($STAKING_TOKEN,$WETH_ADDRESS,10000,60,$Q96,(10,12),$SIGNED,false,201,$DEADLINE)"
SIGNED_QUOTE=$(quote_pool "$SIGNED_PARAMS")
SIGNED_POOL=$(jq -r '.[0][1]' <<<"$SIGNED_QUOTE")
SIGNED_DIGEST=$(jq -r '.[0][6]' <<<"$SIGNED_QUOTE")
SIGNED_AUTH=$(cast wallet sign --no-hash --private-key "$(anvil_private_key "$SIGNED_INDEX")" "$SIGNED_DIGEST")
WRONG_AUTH=$(cast wallet sign --no-hash --private-key "$(anvil_private_key "$WRONG_SIGNER_INDEX")" "$SIGNED_DIGEST")
assert_eq "$(cast call "$STATICS_DIAMOND_ADDRESS" 'isPoolCreationNonceUsed(address,uint256)(bool)' "$SIGNED" 201 --rpc-url "$RPC_URL")" false "fresh relayed creator nonce"
expect_call_revert "invalid creator signature" create_pool_call "$SIGNED_PARAMS" "$WRONG_AUTH" "$RELAYER" "$CREATION_FEE" >/dev/null
assert_eq "$(cast call "$STATICS_DIAMOND_ADDRESS" 'isPoolCreationNonceUsed(address,uint256)(bool)' "$SIGNED" 201 --rpc-url "$RPC_URL")" false "invalid signature preserves nonce"
cast send "$STATICS_DIAMOND_ADDRESS" \
    'createPool((address,address,uint24,int24,uint160,(uint16,uint16),address,bool,uint256,uint256),bytes)(bytes32)' \
    "$SIGNED_PARAMS" "$SIGNED_AUTH" --value "$CREATION_FEE" --private-key "$(anvil_private_key "$RELAYER_INDEX")" \
    --rpc-url "$RPC_URL" --legacy --json >"$RUN_DIR/public-creation-relayed.json"
assert_eq "$(cast call "$STATICS_DIAMOND_ADDRESS" 'protocolPoolCreator(bytes32)(address)' "$SIGNED_POOL" --rpc-url "$RPC_URL")" "$SIGNED" "relayed pool creator"
assert_eq "$(cast call "$STATICS_DIAMOND_ADDRESS" 'isPoolCreationNonceUsed(address,uint256)(bool)' "$SIGNED" 201 --rpc-url "$RPC_URL")" true "consumed relayed creator nonce"

REUSE_PARAMS="($STAKING_TOKEN,$WETH_ADDRESS,10000,10,$Q96,(10,12),$SIGNED,false,201,$DEADLINE)"
REUSE_DIGEST=$(quote_pool "$REUSE_PARAMS" | jq -r '.[0][6]')
REUSE_AUTH=$(cast wallet sign --no-hash --private-key "$(anvil_private_key "$SIGNED_INDEX")" "$REUSE_DIGEST")
expect_call_revert "creator nonce replay" create_pool_call "$REUSE_PARAMS" "$REUSE_AUTH" "$RELAYER" "$CREATION_FEE" >/dev/null

cast send "$STATICS_DIAMOND_ADDRESS" 'invalidatePoolCreationNonce(uint256)' 202 \
    --private-key "$(anvil_private_key "$SIGNED_INDEX")" --rpc-url "$RPC_URL" --legacy --json \
    >"$RUN_DIR/public-creation-invalidate-nonce.json"
INVALIDATED_PARAMS="($STAKING_TOKEN,$WETH_ADDRESS,12000,10,$Q96,(10,12),$SIGNED,false,202,$DEADLINE)"
INVALIDATED_DIGEST=$(quote_pool "$INVALIDATED_PARAMS" | jq -r '.[0][6]')
INVALIDATED_AUTH=$(cast wallet sign --no-hash --private-key "$(anvil_private_key "$SIGNED_INDEX")" "$INVALIDATED_DIGEST")
expect_call_revert "invalidated creator nonce" create_pool_call "$INVALIDATED_PARAMS" "$INVALIDATED_AUTH" "$RELAYER" "$CREATION_FEE" >/dev/null

# Reciprocal token input order normalizes both price and PoolId.
DOUBLE_Q96=$(printf '%s * 2\n' "$Q96" | bc)
HALF_Q96=$(printf '%s / 2\n' "$Q96" | bc)
FORWARD=$(quote_pool "($STAKING_TOKEN,$WETH_ADDRESS,14000,10,$DOUBLE_Q96,(500,500),$DIRECT,false,301,$DEADLINE)")
REVERSE=$(quote_pool "($WETH_ADDRESS,$STAKING_TOKEN,14000,10,$HALF_Q96,(500,500),$DIRECT,false,301,$DEADLINE)")
assert_eq "$(jq -r '.[0][1]' <<<"$FORWARD")" "$(jq -r '.[0][1]' <<<"$REVERSE")" "reciprocal PoolId normalization"
assert_eq "$(jq -r '.[0][2]' <<<"$FORWARD")" "$(jq -r '.[0][2]' <<<"$REVERSE")" "reciprocal price normalization"

# A creator can select valid rates below a later governance default.
BELOW_DEFAULT_PARAMS="($STAKING_TOKEN,$WETH_ADDRESS,15000,10,$Q96,(500,500),$DIRECT,false,401,$DEADLINE)"
BELOW_DEFAULT_POOL=$(quote_pool "$BELOW_DEFAULT_PARAMS" | jq -er '.[0][1]')
SET_DEFAULT_CALLDATA=$(cast calldata 'setDefaultProtocolPoolFeeRate((uint16,uint16))' '(600,600)')
timelock_call "$STATICS_DIAMOND_ADDRESS" 0 "$SET_DEFAULT_CALLDATA" public-creation-default-fee
cast send "$STATICS_DIAMOND_ADDRESS" \
    'createPool((address,address,uint24,int24,uint160,(uint16,uint16),address,bool,uint256,uint256),bytes)(bytes32)' \
    "$BELOW_DEFAULT_PARAMS" 0x --value "$CREATION_FEE" --private-key "$(anvil_private_key "$DIRECT_INDEX")" \
    --rpc-url "$RPC_URL" --legacy --json >"$RUN_DIR/public-creation-below-default.json"
BELOW_DEFAULT_RATE=$(cast call "$STATICS_DIAMOND_ADDRESS" \
    'protocolPoolFeeRate(bytes32)((uint16,uint16,bool))' "$BELOW_DEFAULT_POOL" --rpc-url "$RPC_URL" --json)
assert_eq "$(jq -r '.[0][0]' <<<"$BELOW_DEFAULT_RATE")" 500 "below-default input fee"
assert_eq "$(jq -r '.[0][1]' <<<"$BELOW_DEFAULT_RATE")" 500 "below-default output fee"
assert_eq "$(jq -r '.[0][2]' <<<"$BELOW_DEFAULT_RATE")" true "below-default fee override marker"
expect_call_revert "below 10-pip input floor" quote_pool \
    "($STAKING_TOKEN,$WETH_ADDRESS,15000,10,$Q96,(9,10),$DIRECT,false,402,$DEADLINE)" >/dev/null

assert_phase_one_solvency public-pool-creation "$STAKING_TOKEN" "$WETH_ADDRESS"
record_result public-pools direct-creation pass "$DIRECT_POOL"
record_result public-pools distinct-key-creation pass "$SPACING_POOL $FEE_POOL"
record_result public-pools relayed-authorization pass "$SIGNED_POOL"
record_result public-pools invalid-creation-paths pass "payment, key, signature, nonce, expiry, and quote"
record_result public-pools reciprocal-normalization pass "$(jq -r '.[0][1]' <<<"$FORWARD")"
note "permissionless public pool creation and authorization scenarios passed"
