#!/usr/bin/env bash

set -Eeuo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

require_commands cast jq awk bc
load_current_run
require_local_chain
reset_to_base

LP_INDEX=10
TRADER_INDEX=11
LP=$(anvil_address "$LP_INDEX")
LP_KEY=$(anvil_private_key "$LP_INDEX")
POSITION_FEE=1000000000000000
POOL_ID=$(create_public_pool "$STAKING_TOKEN" "$WETH_ADDRESS" "$LP" 33 managed-lp)

if [[ "${WETH_ADDRESS,,}" < "${STAKING_TOKEN,,}" ]]; then
    CURRENCY0=$WETH_ADDRESS
    CURRENCY1=$STAKING_TOKEN
else
    CURRENCY0=$STAKING_TOKEN
    CURRENCY1=$WETH_ADDRESS
fi

acquire_genesis_statics "$LP_INDEX" 3000000000000000000 managed-lp-owner >/dev/null
wrap_weth "$LP_INDEX" 150000000000000000000 managed-lp-owner
for asset in "$CURRENCY0" "$CURRENCY1"; do
    cast send "$asset" 'approve(address,uint256)' "$STATICS_DIAMOND_ADDRESS" "$(cast max-uint)" \
        --private-key "$LP_KEY" --rpc-url "$RPC_URL" --legacy --json \
        >"$RUN_DIR/managed-lp-approve-${asset,,}.json"
done

POSITION_ID=$(cast call "$STATICS_DIAMOND_ADDRESS" 'nextPositionId()(uint256)' --rpc-url "$RPC_URL" | awk '{print $1}')
cast send "$STATICS_DIAMOND_ADDRESS" 'createPosition(address)(uint256)' "$LP" \
    --value "$POSITION_FEE" --private-key "$LP_KEY" --rpc-url "$RPC_URL" --legacy --json \
    >"$RUN_DIR/managed-lp-create-position.json"
DEADLINE=$(( $(cast block latest --field timestamp --rpc-url "$RPC_URL") + 86400 ))
cast send "$STATICS_DIAMOND_ADDRESS" \
    'provideLiquidity(uint256,(bytes32,int24,int24,uint128,uint256,uint256,uint256))((uint256,uint128,uint256,uint256,uint256,uint256))' \
    "$POSITION_ID" "($POOL_ID,-1200,1200,100000000000000000000,90000000000000000000,90000000000000000000,$DEADLINE)" \
    --private-key "$LP_KEY" --rpc-url "$RPC_URL" --legacy --json >"$RUN_DIR/managed-lp-provide.json"
LEG=$(cast call "$STATICS_DIAMOND_ADDRESS" \
    'lpLeg(uint256,bytes32)((address,uint256,int24,int24,uint128,uint256[5],uint256[5],uint256[5]))' \
    "$POSITION_ID" "$POOL_ID" --rpc-url "$RPC_URL" --json)
ORIGINAL_POSM=$(jq -r '.[0][1]' <<<"$LEG")
assert_eq "$(jq -r '.[0][4]' <<<"$LEG")" 100000000000000000000 "initial managed LP liquidity"

# Real swaps create native v4 fees on the managed NFT.
wrap_weth "$TRADER_INDEX" 5000000000000000000 managed-lp-trader
acquire_genesis_statics "$TRADER_INDEX" 1000000000000000000 managed-lp-trader >/dev/null
v4_swap_exact_in "$TRADER_INDEX" "$CURRENCY0" "$CURRENCY1" 3000 60 "$STATICS_SWAP_FEE_HOOK_ADDRESS" true 500000000000000000 managed-lp-swap0
v4_swap_exact_in "$TRADER_INDEX" "$CURRENCY0" "$CURRENCY1" 3000 60 "$STATICS_SWAP_FEE_HOOK_ADDRESS" false 500000000000000000 managed-lp-swap1
BALANCE0_BEFORE=$(cast call "$CURRENCY0" 'balanceOf(address)(uint256)' "$LP" --rpc-url "$RPC_URL" | awk '{print $1}')
BALANCE1_BEFORE=$(cast call "$CURRENCY1" 'balanceOf(address)(uint256)' "$LP" --rpc-url "$RPC_URL" | awk '{print $1}')
cast send "$STATICS_DIAMOND_ADDRESS" 'collectNativeFees(uint256,bytes32,uint256,uint256,uint256)((uint256,uint128,uint256,uint256,uint256,uint256))' \
    "$POSITION_ID" "$POOL_ID" 0 0 "$DEADLINE" --private-key "$LP_KEY" \
    --rpc-url "$RPC_URL" --legacy --json >"$RUN_DIR/managed-lp-collect-fees.json"
FEE0=$(printf '%s - %s\n' "$(cast call "$CURRENCY0" 'balanceOf(address)(uint256)' "$LP" --rpc-url "$RPC_URL" | awk '{print $1}')" "$BALANCE0_BEFORE" | bc)
FEE1=$(printf '%s - %s\n' "$(cast call "$CURRENCY1" 'balanceOf(address)(uint256)' "$LP" --rpc-url "$RPC_URL" | awk '{print $1}')" "$BALANCE1_BEFORE" | bc)
assert_gt "$(printf '%s + %s\n' "$FEE0" "$FEE1" | bc)" 0 "managed LP native fee collection"

cast send "$STATICS_DIAMOND_ADDRESS" \
    'increaseLiquidity(uint256,bytes32,(uint128,uint256,uint256,uint256))((uint256,uint128,uint256,uint256,uint256,uint256))' \
    "$POSITION_ID" "$POOL_ID" "(10000000000000000000,20000000000000000000,20000000000000000000,$DEADLINE)" \
    --private-key "$LP_KEY" --rpc-url "$RPC_URL" --legacy --json >"$RUN_DIR/managed-lp-increase.json"
LEG=$(cast call "$STATICS_DIAMOND_ADDRESS" \
    'lpLeg(uint256,bytes32)((address,uint256,int24,int24,uint128,uint256[5],uint256[5],uint256[5]))' \
    "$POSITION_ID" "$POOL_ID" --rpc-url "$RPC_URL" --json)
assert_eq "$(jq -r '.[0][4]' <<<"$LEG")" 110000000000000000000 "increased managed LP liquidity"

cast send "$STATICS_DIAMOND_ADDRESS" \
    'decreaseLiquidity(uint256,bytes32,(uint128,uint256,uint256,uint256))((uint256,uint128,uint256,uint256,uint256,uint256))' \
    "$POSITION_ID" "$POOL_ID" "(10000000000000000000,0,0,$DEADLINE)" \
    --private-key "$LP_KEY" --rpc-url "$RPC_URL" --legacy --json >"$RUN_DIR/managed-lp-decrease.json"
LEG=$(cast call "$STATICS_DIAMOND_ADDRESS" \
    'lpLeg(uint256,bytes32)((address,uint256,int24,int24,uint128,uint256[5],uint256[5],uint256[5]))' \
    "$POSITION_ID" "$POOL_ID" --rpc-url "$RPC_URL" --json)
assert_eq "$(jq -r '.[0][4]' <<<"$LEG")" 100000000000000000000 "partially decreased managed LP liquidity"

cast send "$STATICS_DIAMOND_ADDRESS" \
    'rebalanceLiquidity(uint256,bytes32,(int24,int24,uint128,uint256,uint256,uint256,uint256,uint256))((uint256,uint128,uint256,uint256,uint256,uint256))' \
    "$POSITION_ID" "$POOL_ID" "(-1800,1800,80000000000000000000,20000000000000000000,20000000000000000000,0,0,$DEADLINE)" \
    --private-key "$LP_KEY" --rpc-url "$RPC_URL" --gas-limit 3000000 --legacy --json \
    >"$RUN_DIR/managed-lp-rebalance.json"
LEG=$(cast call "$STATICS_DIAMOND_ADDRESS" \
    'lpLeg(uint256,bytes32)((address,uint256,int24,int24,uint128,uint256[5],uint256[5],uint256[5]))' \
    "$POSITION_ID" "$POOL_ID" --rpc-url "$RPC_URL" --json)
NEW_POSM=$(jq -r '.[0][1]' <<<"$LEG")
[[ "$NEW_POSM" != "$ORIGINAL_POSM" ]] || fail "rebalance did not replace the POSM NFT"
assert_eq "$(jq -r '.[0][2]' <<<"$LEG")" -1800 "rebalanced lower tick"
assert_eq "$(jq -r '.[0][3]' <<<"$LEG")" 1800 "rebalanced upper tick"
assert_eq "$(jq -r '.[0][4]' <<<"$LEG")" 80000000000000000000 "rebalanced liquidity"

cast send "$STATICS_DIAMOND_ADDRESS" \
    'exitLiquidity(uint256,bytes32,uint256,uint256,uint256)((uint256,uint128,uint256,uint256,uint256,uint256))' \
    "$POSITION_ID" "$POOL_ID" 0 0 "$DEADLINE" --private-key "$LP_KEY" \
    --rpc-url "$RPC_URL" --gas-limit 3000000 --legacy --json >"$RUN_DIR/managed-lp-exit.json"
assert_eq "$(cast call "$STATICS_DIAMOND_ADDRESS" 'activeLegCount(uint256)(uint256)' "$POSITION_ID" --rpc-url "$RPC_URL" | awk '{print $1}')" 0 "managed LP active leg count after exit"
cast send "$STATICS_DIAMOND_ADDRESS" 'closePosition(uint256)' "$POSITION_ID" \
    --private-key "$LP_KEY" --rpc-url "$RPC_URL" --legacy --json >"$RUN_DIR/managed-lp-close-position.json"
expect_call_revert "closed PositionNFT owner lookup" \
    cast call "$STATICS_DIAMOND_ADDRESS" 'ownerOf(uint256)(address)' "$POSITION_ID" --rpc-url "$RPC_URL" \
    >"$RUN_DIR/managed-lp-closed-owner-revert.txt"

record_result range-gauge managed-native-fees pass "$FEE0 currency0 wei, $FEE1 currency1 wei"
record_result range-gauge managed-liquidity-mutations pass "POSM $ORIGINAL_POSM to $NEW_POSM"
record_result position-nft managed-exit-and-close pass "$POSITION_ID"
note "managed LP fee, mutation, rebalance, exit, and close scenarios passed"
