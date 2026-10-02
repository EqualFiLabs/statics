#!/usr/bin/env bash

set -Eeuo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

require_commands cast jq awk bc
load_current_run
require_local_chain
reset_to_base

CREATOR_INDEX=13
TRADER_INDEX=14
CREATOR=$(anvil_address "$CREATOR_INDEX")
CREATOR_KEY=$(anvil_private_key "$CREATOR_INDEX")
TRADER=$(anvil_address "$TRADER_INDEX")
OPERATOR_KEY=$(anvil_private_key 3)
POSITION_FEE=1000000000000000
POOL_ID=$(create_public_pool "$STAKING_TOKEN" "$WETH_ADDRESS" "$CREATOR" 3 protocol-pol)

if [[ "${WETH_ADDRESS,,}" < "${STAKING_TOKEN,,}" ]]; then
    CURRENCY0=$WETH_ADDRESS
    CURRENCY1=$STAKING_TOKEN
else
    CURRENCY0=$STAKING_TOKEN
    CURRENCY1=$WETH_ADDRESS
fi

# Seed user liquidity through the same managed PositionNFT path used in the
# public-market scenario. Protocol POL remains separately bound and owned.
acquire_genesis_statics "$CREATOR_INDEX" 2000000000000000000 protocol-pol-lp >/dev/null
wrap_weth "$CREATOR_INDEX" 100000000000000000000 protocol-pol-lp
cast send "$CURRENCY0" 'approve(address,uint256)' "$STATICS_DIAMOND_ADDRESS" "$(cast max-uint)" \
    --private-key "$CREATOR_KEY" --rpc-url "$RPC_URL" --legacy --json \
    >"$RUN_DIR/protocol-pol-lp-currency0-approve.json"
cast send "$CURRENCY1" 'approve(address,uint256)' "$STATICS_DIAMOND_ADDRESS" "$(cast max-uint)" \
    --private-key "$CREATOR_KEY" --rpc-url "$RPC_URL" --legacy --json \
    >"$RUN_DIR/protocol-pol-lp-currency1-approve.json"
USER_POSITION=$(cast call "$STATICS_DIAMOND_ADDRESS" 'nextPositionId()(uint256)' --rpc-url "$RPC_URL" | awk '{print $1}')
cast send "$STATICS_DIAMOND_ADDRESS" 'createPosition(address)(uint256)' "$CREATOR" \
    --value "$POSITION_FEE" --private-key "$CREATOR_KEY" --rpc-url "$RPC_URL" --legacy --json \
    >"$RUN_DIR/protocol-pol-create-user-position.json"
DEADLINE=$(( $(cast block latest --field timestamp --rpc-url "$RPC_URL") + 3600 ))
cast send "$STATICS_DIAMOND_ADDRESS" \
    'provideLiquidity(uint256,(bytes32,int24,int24,uint128,uint256,uint256,uint256))((uint256,uint128,uint256,uint256,uint256,uint256))' \
    "$USER_POSITION" "($POOL_ID,-1200,1200,100000000000000000000,90000000000000000000,90000000000000000000,$DEADLINE)" \
    --private-key "$CREATOR_KEY" --rpc-url "$RPC_URL" --legacy --json \
    >"$RUN_DIR/protocol-pol-provide-user-liquidity.json"

wrap_weth "$TRADER_INDEX" 10000000000000000000 protocol-pol-trader
acquire_genesis_statics "$TRADER_INDEX" 2000000000000000000 protocol-pol-trader >/dev/null

# Disabled general pools must route the would-be POL share away immediately,
# not leave a dormant inventory obligation.
v4_swap_exact_in "$TRADER_INDEX" "$CURRENCY0" "$CURRENCY1" 3000 60 \
    "$STATICS_SWAP_FEE_HOOK_ADDRESS" true 500000000000000000 protocol-pol-disabled
PENDING0=$(cast call "$STATICS_SWAP_FEE_HOOK_ADDRESS" 'pendingProtocolPol(bytes32,address)(uint256)' \
    "$POOL_ID" "$CURRENCY0" --rpc-url "$RPC_URL" | awk '{print $1}')
PENDING1=$(cast call "$STATICS_SWAP_FEE_HOOK_ADDRESS" 'pendingProtocolPol(bytes32,address)(uint256)' \
    "$POOL_ID" "$CURRENCY1" --rpc-url "$RPC_URL" | awk '{print $1}')
assert_eq "$PENDING0" 0 "disabled POL currency0 pending"
assert_eq "$PENDING1" 0 "disabled POL currency1 pending"

TREASURY_BEFORE=$(cast balance "$TREASURY" --rpc-url "$RPC_URL")
expect_call_revert "non-creator POL activation" \
    cast call "$STATICS_DIAMOND_ADDRESS" 'activateProtocolPoolPol(bytes32)' "$POOL_ID" \
    --value 100000000000000000 --from "$TRADER" --rpc-url "$RPC_URL" \
    >"$RUN_DIR/protocol-pol-unauthorized-activation-revert.txt"
expect_call_revert "incorrect POL activation fee" \
    cast call "$STATICS_DIAMOND_ADDRESS" 'activateProtocolPoolPol(bytes32)' "$POOL_ID" \
    --from "$CREATOR" --rpc-url "$RPC_URL" \
    >"$RUN_DIR/protocol-pol-wrong-activation-fee-revert.txt"
cast send "$STATICS_DIAMOND_ADDRESS" 'activateProtocolPoolPol(bytes32)' "$POOL_ID" \
    --value 100000000000000000 \
    --private-key "$CREATOR_KEY" --rpc-url "$RPC_URL" --legacy --json \
    >"$RUN_DIR/protocol-pol-activate.json"
TREASURY_AFTER=$(cast balance "$TREASURY" --rpc-url "$RPC_URL")
assert_eq "$(printf '%s - %s\n' "$TREASURY_AFTER" "$TREASURY_BEFORE" | bc)" \
    100000000000000000 \
    "POL activation fee transfer"
expect_call_revert "duplicate POL activation" \
    cast call "$STATICS_DIAMOND_ADDRESS" 'activateProtocolPoolPol(bytes32)' "$POOL_ID" \
    --value 100000000000000000 --from "$CREATOR" --rpc-url "$RPC_URL" \
    >"$RUN_DIR/protocol-pol-duplicate-activation-revert.txt"

v4_swap_exact_in "$TRADER_INDEX" "$CURRENCY0" "$CURRENCY1" 3000 60 \
    "$STATICS_SWAP_FEE_HOOK_ADDRESS" true 500000000000000000 protocol-pol-funded-zero-for-one
v4_swap_exact_in "$TRADER_INDEX" "$CURRENCY0" "$CURRENCY1" 3000 60 \
    "$STATICS_SWAP_FEE_HOOK_ADDRESS" false 500000000000000000 protocol-pol-funded-one-for-zero
PENDING0=$(cast call "$STATICS_SWAP_FEE_HOOK_ADDRESS" 'pendingProtocolPol(bytes32,address)(uint256)' \
    "$POOL_ID" "$CURRENCY0" --rpc-url "$RPC_URL" | awk '{print $1}')
PENDING1=$(cast call "$STATICS_SWAP_FEE_HOOK_ADDRESS" 'pendingProtocolPol(bytes32,address)(uint256)' \
    "$POOL_ID" "$CURRENCY1" --rpc-url "$RPC_URL" | awk '{print $1}')
[[ "$PENDING0" != 0 && "$PENDING1" != 0 ]] || fail "activated POL did not accrue both pool assets"

MAINTAINER_INDEX=15
MAINTAINER_KEY=$(anvil_private_key "$MAINTAINER_INDEX")
cast send "$STATICS_DIAMOND_ADDRESS" 'settleProtocolPoolPol(bytes32,address,uint256)(uint256)' \
    "$POOL_ID" "$CURRENCY0" 0 \
    --private-key "$MAINTAINER_KEY" --rpc-url "$RPC_URL" --legacy --json \
    >"$RUN_DIR/protocol-pol-settle0.json"
cast send "$STATICS_DIAMOND_ADDRESS" 'settleProtocolPoolPol(bytes32,address,uint256)(uint256)' \
    "$POOL_ID" "$CURRENCY1" 0 \
    --private-key "$MAINTAINER_KEY" --rpc-url "$RPC_URL" --legacy --json \
    >"$RUN_DIR/protocol-pol-settle1.json"
POL_ACCOUNT=$(cast call "$STATICS_DIAMOND_ADDRESS" 'protocolPolCustodyAccount(bytes32)(bytes32)' \
    "$POOL_ID" --rpc-url "$RPC_URL")
RESERVE0=$(cast call "$STATICS_DIAMOND_ADDRESS" 'reservedByAccount(bytes32,address)(uint256)' \
    "$POL_ACCOUNT" "$CURRENCY0" --rpc-url "$RPC_URL" | awk '{print $1}')
RESERVE1=$(cast call "$STATICS_DIAMOND_ADDRESS" 'reservedByAccount(bytes32,address)(uint256)' \
    "$POL_ACCOUNT" "$CURRENCY1" --rpc-url "$RPC_URL" | awk '{print $1}')
[[ "$RESERVE0" != 0 && "$RESERVE1" != 0 ]] || fail "settled POL inventory was not reserved by PoolId"

DEADLINE=$(( $(cast block latest --field timestamp --rpc-url "$RPC_URL") + 86400 ))
OLD_OPERATOR=$(anvil_address 3)
NEW_OPERATOR_INDEX=16
NEW_OPERATOR=$(anvil_address "$NEW_OPERATOR_INDEX")
NEW_OPERATOR_KEY=$(anvil_private_key "$NEW_OPERATOR_INDEX")
SET_OPERATOR_CALLDATA=$(cast calldata 'setProtocolPolOperator(address)' "$NEW_OPERATOR")
timelock_call "$STATICS_DIAMOND_ADDRESS" 0 "$SET_OPERATOR_CALLDATA" protocol-pol-replace-operator
assert_eq \
    "$(cast call "$STATICS_DIAMOND_ADDRESS" 'protocolPolOperator()(address)' --rpc-url "$RPC_URL")" \
    "$NEW_OPERATOR" \
    "replacement POL operator"
DEADLINE=$(( $(cast block latest --field timestamp --rpc-url "$RPC_URL") + 86400 ))
expect_call_revert "old POL operator after replacement" \
    cast call "$STATICS_DIAMOND_ADDRESS" \
    'openProtocolPolPosition((bytes32,int24,int24,uint128,uint256,uint256,uint256))(uint256)' \
    "($POOL_ID,-600,600,100000000000000,$RESERVE0,$RESERVE1,$DEADLINE)" \
    --from "$OLD_OPERATOR" --rpc-url "$RPC_URL" \
    >"$RUN_DIR/protocol-pol-old-operator-revert.txt"
EXPIRED_DEADLINE=$(( $(cast block latest --field timestamp --rpc-url "$RPC_URL") - 1 ))
expect_call_revert "expired POL open deadline" \
    cast call "$STATICS_DIAMOND_ADDRESS" \
    'openProtocolPolPosition((bytes32,int24,int24,uint128,uint256,uint256,uint256))(uint256)' \
    "($POOL_ID,-600,600,100000000000000,$RESERVE0,$RESERVE1,$EXPIRED_DEADLINE)" \
    --from "$NEW_OPERATOR" --rpc-url "$RPC_URL" \
    >"$RUN_DIR/protocol-pol-expired-open-revert.txt"
assert_eq \
    "$(cast call "$STATICS_DIAMOND_ADDRESS" \
        'protocolPool(bytes32)((bytes32,(address,address,uint24,int24,address),uint8,bool,uint256,address,address,bool,bool,uint16,uint256))' \
        "$POOL_ID" --rpc-url "$RPC_URL" --json | jq -r '.[0][10]')" \
    0 \
    "failed POL opens preserve active position count"
OPERATOR_KEY=$NEW_OPERATOR_KEY
cast send "$STATICS_DIAMOND_ADDRESS" \
    'openProtocolPolPosition((bytes32,int24,int24,uint128,uint256,uint256,uint256))(uint256)' \
    "($POOL_ID,-600,600,100000000000000,$RESERVE0,$RESERVE1,$DEADLINE)" \
    --private-key "$OPERATOR_KEY" --rpc-url "$RPC_URL" --gas-limit 3000000 --legacy --json \
    >"$RUN_DIR/protocol-pol-open.json"
POSITION_IDS=$(cast call "$STATICS_DIAMOND_ADDRESS" 'protocolPolPositionIds(bytes32)(uint256[])' \
    "$POOL_ID" --rpc-url "$RPC_URL" --json)
POL_POSITION_ID=$(jq -r '.[0][0]' <<<"$POSITION_IDS")
POSITION=$(cast call "$STATICS_DIAMOND_ADDRESS" \
    'protocolPolPosition(uint256)((uint256,bytes32,address,uint256,int24,int24,uint128,bool))' \
    "$POL_POSITION_ID" --rpc-url "$RPC_URL" --json)
OPEN_LIQUIDITY=$(jq -r '.[0][6]' <<<"$POSITION")
assert_eq "$OPEN_LIQUIDITY" 100000000000000 "opened POL liquidity"

# The empty-position lifecycle is deliberate: full decrease, no-op harvest,
# refill, and final close must all remain live.
cast send "$STATICS_DIAMOND_ADDRESS" \
    'decreaseProtocolPolPosition((uint256,uint128,uint256,uint256,uint256))' \
    "($POL_POSITION_ID,$OPEN_LIQUIDITY,0,0,$DEADLINE)" \
    --private-key "$OPERATOR_KEY" --rpc-url "$RPC_URL" --gas-limit 3000000 --legacy --json \
    >"$RUN_DIR/protocol-pol-full-decrease.json"
cast send "$STATICS_DIAMOND_ADDRESS" 'collectProtocolPolFees(uint256,uint256)' "$POL_POSITION_ID" "$DEADLINE" \
    --private-key "$OPERATOR_KEY" --rpc-url "$RPC_URL" --legacy --json \
    >"$RUN_DIR/protocol-pol-empty-harvest.json"

RESERVE0=$(cast call "$STATICS_DIAMOND_ADDRESS" 'reservedByAccount(bytes32,address)(uint256)' \
    "$POL_ACCOUNT" "$CURRENCY0" --rpc-url "$RPC_URL" | awk '{print $1}')
RESERVE1=$(cast call "$STATICS_DIAMOND_ADDRESS" 'reservedByAccount(bytes32,address)(uint256)' \
    "$POL_ACCOUNT" "$CURRENCY1" --rpc-url "$RPC_URL" | awk '{print $1}')
cast send "$STATICS_DIAMOND_ADDRESS" \
    'increaseProtocolPolPosition((uint256,uint128,uint256,uint256,uint256))' \
    "($POL_POSITION_ID,$OPEN_LIQUIDITY,$RESERVE0,$RESERVE1,$DEADLINE)" \
    --private-key "$OPERATOR_KEY" --rpc-url "$RPC_URL" --gas-limit 3000000 --legacy --json \
    >"$RUN_DIR/protocol-pol-refill.json"

# Native Uniswap LP fees earned by protocol-owned positions are Treasury
# revenue. They must not silently compound into pool-specific POL principal.
TREASURY_FEE0_BEFORE=$(cast call "$STATICS_DIAMOND_ADDRESS" 'treasuryAccrued(address)(uint256)' \
    "$CURRENCY0" --rpc-url "$RPC_URL" | awk '{print $1}')
TREASURY_FEE1_BEFORE=$(cast call "$STATICS_DIAMOND_ADDRESS" 'treasuryAccrued(address)(uint256)' \
    "$CURRENCY1" --rpc-url "$RPC_URL" | awk '{print $1}')
v4_swap_exact_in "$TRADER_INDEX" "$CURRENCY0" "$CURRENCY1" 3000 60 \
    "$STATICS_SWAP_FEE_HOOK_ADDRESS" true 1000000000000000000 protocol-pol-native-fee-swap0
v4_swap_exact_in "$TRADER_INDEX" "$CURRENCY0" "$CURRENCY1" 3000 60 \
    "$STATICS_SWAP_FEE_HOOK_ADDRESS" false 1000000000000000000 protocol-pol-native-fee-swap1
cast send "$STATICS_DIAMOND_ADDRESS" 'collectProtocolPolFees(uint256,uint256)' "$POL_POSITION_ID" "$DEADLINE" \
    --private-key "$OPERATOR_KEY" --rpc-url "$RPC_URL" --legacy --json \
    >"$RUN_DIR/protocol-pol-native-fee-collect.json"
TREASURY_FEE0_AFTER=$(cast call "$STATICS_DIAMOND_ADDRESS" 'treasuryAccrued(address)(uint256)' \
    "$CURRENCY0" --rpc-url "$RPC_URL" | awk '{print $1}')
TREASURY_FEE1_AFTER=$(cast call "$STATICS_DIAMOND_ADDRESS" 'treasuryAccrued(address)(uint256)' \
    "$CURRENCY1" --rpc-url "$RPC_URL" | awk '{print $1}')
NATIVE_FEE0=$(printf '%s - %s\n' "$TREASURY_FEE0_AFTER" "$TREASURY_FEE0_BEFORE" | bc)
NATIVE_FEE1=$(printf '%s - %s\n' "$TREASURY_FEE1_AFTER" "$TREASURY_FEE1_BEFORE" | bc)
assert_gt "$(printf '%s + %s\n' "$NATIVE_FEE0" "$NATIVE_FEE1" | bc)" 0 \
    "POL native fees routed to Treasury"

BEGIN_CALLDATA=$(cast calldata 'beginGeneralPoolDecommission(bytes32)' "$POOL_ID")
timelock_call "$STATICS_DIAMOND_ADDRESS" 0 "$BEGIN_CALLDATA" protocol-pol-begin-decommission
expect_call_revert "decommission with active POL" \
    cast call "$STATICS_DIAMOND_ADDRESS" 'finalizeGeneralPoolDecommission(bytes32)(uint256,uint256)' \
    "$POOL_ID" --from "$STATICS_TIMELOCK_ADDRESS" --rpc-url "$RPC_URL" \
    >"$RUN_DIR/protocol-pol-active-decommission-revert.txt"

DEADLINE=$(( $(cast block latest --field timestamp --rpc-url "$RPC_URL") + 86400 ))
cast send "$STATICS_DIAMOND_ADDRESS" \
    'closeProtocolPolPosition(uint256,uint256,uint256,uint256)' "$POL_POSITION_ID" 0 0 "$DEADLINE" \
    --private-key "$OPERATOR_KEY" --rpc-url "$RPC_URL" --gas-limit 3000000 --legacy --json \
    >"$RUN_DIR/protocol-pol-close.json"
FINALIZE_CALLDATA=$(cast calldata 'finalizeGeneralPoolDecommission(bytes32)' "$POOL_ID")
timelock_call "$STATICS_DIAMOND_ADDRESS" 0 "$FINALIZE_CALLDATA" protocol-pol-finalize-decommission

POOL=$(cast call "$STATICS_DIAMOND_ADDRESS" \
    'protocolPool(bytes32)((bytes32,(address,address,uint24,int24,address),uint8,bool,uint256,address,address,bool,bool,uint16,uint256))' \
    "$POOL_ID" --rpc-url "$RPC_URL" --json)
assert_eq "$(jq -r '.[0][3]' <<<"$POOL")" true "decommissioned public pool"
assert_eq "$(jq -r '.[0][10]' <<<"$POOL")" 0 "active POL position count"
assert_eq \
    "$(cast call "$STATICS_DIAMOND_ADDRESS" 'reservedByAccount(bytes32,address)(uint256)' \
        "$POL_ACCOUNT" "$CURRENCY0" --rpc-url "$RPC_URL" | awk '{print $1}')" \
    0 \
    "decommissioned POL currency0 reserve"
assert_eq \
    "$(cast call "$STATICS_DIAMOND_ADDRESS" 'reservedByAccount(bytes32,address)(uint256)' \
        "$POL_ACCOUNT" "$CURRENCY1" --rpc-url "$RPC_URL" | awk '{print $1}')" \
    0 \
    "decommissioned POL currency1 reserve"

record_result protocol-pol disabled-fallback pass "$POOL_ID"
record_result protocol-pol activation-and-custody pass "$POL_POSITION_ID"
record_result protocol-pol operator-replacement pass "$OLD_OPERATOR to $NEW_OPERATOR"
record_result protocol-pol empty-position-lifecycle pass "$POL_POSITION_ID"
record_result protocol-pol native-fees-to-treasury pass "$NATIVE_FEE0 currency0 wei, $NATIVE_FEE1 currency1 wei"
record_result protocol-pol incremental-decommission pass "$POOL_ID"
note "protocol POL activation, custody, empty-position, and decommission scenarios passed"
