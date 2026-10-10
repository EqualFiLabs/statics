#!/usr/bin/env bash

set -Eeuo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
require_commands cast jq awk bc python3
load_current_run
require_local_chain
reset_to_base

NATIVE=0x0000000000000000000000000000000000000000
OWNER_INDEX=10
TRADER_INDEX=11
STAKER_INDEX=12
OWNER=$(anvil_address "$OWNER_INDEX")
OWNER_KEY=$(anvil_private_key "$OWNER_INDEX")
STAKER=$(anvil_address "$STAKER_INDEX")
STAKER_KEY=$(anvil_private_key "$STAKER_INDEX")
OPERATOR_KEY=$(anvil_private_key 3)
POSITION_MANAGER=$(jq -er '.contracts.positionManager.address' "$REPO_ROOT/deployments/robinhood-chain-4663.json")
POOL_ID=$(create_public_pool "$NATIVE" "$STAKING_TOKEN" "$OWNER" 601 native-eth)
ZERO_POOL=$(create_public_pool "$NATIVE" "$STAKING_TOKEN" "$OWNER" 602 native-eth-zero 0 60)
WETH_POOL=$(create_public_pool "$WETH_ADDRESS" "$STAKING_TOKEN" "$OWNER" 603 native-eth-weth)
POOL_KEY="($NATIVE,$STAKING_TOKEN,3000,60,$STATICS_SWAP_FEE_HOOK_ADDRESS)"
MAXIMUM=90000000000000000000
LIQUIDITY=100000000000000000000
PROVIDE_SIG='provideLiquidity(uint256,(bytes32,int24,int24,uint128,uint256,uint256,uint256))((uint256,uint128,uint256,uint256,uint256,uint256))'
EXIT_SIG='exitLiquidity(uint256,bytes32,uint256,uint256,uint256)((uint256,uint128,uint256,uint256,uint256,uint256))'

# Real Genesis acquisition supplies ERC-20 inventory; native pool funding is ETH.
acquire_genesis_statics "$OWNER_INDEX" 4000000000000000000 native-eth-owner >/dev/null
acquire_genesis_statics "$TRADER_INDEX" 2000000000000000000 native-eth-trader >/dev/null
acquire_genesis_statics "$STAKER_INDEX" 1000000000000000000 native-eth-staker >/dev/null
cast send "$STAKING_TOKEN" 'approve(address,uint256)' "$STATICS_DIAMOND_ADDRESS" "$(cast max-uint)" \
    --private-key "$OWNER_KEY" --rpc-url "$RPC_URL" --legacy --json >"$RUN_DIR/native-eth-owner-approve.json"

new_position() {
    local label=$1 id
    id=$(cast call "$STATICS_DIAMOND_ADDRESS" 'nextPositionId()(uint256)' --rpc-url "$RPC_URL" | awk '{print $1}')
    cast send "$STATICS_DIAMOND_ADDRESS" 'createPosition(address)(uint256)' "$OWNER" --value 1000000000000000 \
        --private-key "$OWNER_KEY" --rpc-url "$RPC_URL" --legacy --json >"$RUN_DIR/native-eth-$label-pnft.json"
    printf '%s\n' "$id"
}
refresh_deadline() {
    DEADLINE=$(( $(cast block latest --field timestamp --rpc-url "$RPC_URL") + 86400 ))
}
provide_native() {
    local position=$1 pool=$2 label=$3 preview before after spent
    refresh_deadline
    preview=$(cast call "$STATICS_DIAMOND_ADDRESS" "$PROVIDE_SIG" "$position" \
        "($pool,-1200,1200,$LIQUIDITY,$MAXIMUM,$MAXIMUM,$DEADLINE)" \
        --from "$OWNER" --value "$MAXIMUM" --rpc-url "$RPC_URL" --json)
    spent=$(jq -r '.[0][2]' <<<"$preview")
    assert_gt "$(jq -r '.[0][3]' <<<"$preview")" 0 "$label unused native input"
    assert_eq "$(printf '%s + %s\n' "$spent" "$(jq -r '.[0][3]' <<<"$preview")" | bc)" "$MAXIMUM" "$label exact input/refund quote"
    before=$(asset_balance "$NATIVE" "$OWNER")
    cast send "$STATICS_DIAMOND_ADDRESS" "$PROVIDE_SIG" "$position" \
        "($pool,-1200,1200,$LIQUIDITY,$MAXIMUM,$MAXIMUM,$DEADLINE)" --value "$MAXIMUM" \
        --private-key "$OWNER_KEY" --rpc-url "$RPC_URL" --legacy --json >"$RUN_DIR/native-eth-$label-provide.json"
    after=$(asset_balance "$NATIVE" "$OWNER")
    assert_eq "$(receipt_native_delta "$RUN_DIR/native-eth-$label-provide.json" "$before" "$after")" "-$spent" "$label exact native debit after refund"
    assert_eq "$(asset_balance "$NATIVE" "$STATICS_LIQUIDITY_MANAGER_ADDRESS")" 0 "$label manager refunds ETH"
    assert_eq "$(asset_balance "$NATIVE" "$POSITION_MANAGER")" 0 "$label PositionManager refunds ETH"
}
pol_reserve() {
    cast call "$STATICS_DIAMOND_ADDRESS" 'reservedByAccount(bytes32,address)(uint256)' "$POL_ACCOUNT" "$1" --rpc-url "$RPC_URL" | awk '{print $1}'
}

POSITION=$(new_position managed)
ZERO_POSITION=$(new_position zero)
refresh_deadline
expect_call_revert "native provide rejects missing value" cast call "$STATICS_DIAMOND_ADDRESS" "$PROVIDE_SIG" \
    "$POSITION" "($POOL_ID,-1200,1200,$LIQUIDITY,$MAXIMUM,$MAXIMUM,$DEADLINE)" --from "$OWNER" --rpc-url "$RPC_URL" \
    >"$RUN_DIR/native-eth-missing-value-revert.txt"
expect_call_revert "native provide rejects excess value" cast call "$STATICS_DIAMOND_ADDRESS" "$PROVIDE_SIG" \
    "$POSITION" "($POOL_ID,-1200,1200,$LIQUIDITY,$MAXIMUM,$MAXIMUM,$DEADLINE)" --value 90000000000000000001 \
    --from "$OWNER" --rpc-url "$RPC_URL" >"$RUN_DIR/native-eth-excess-value-revert.txt"
expect_call_revert "unexpected Diamond native sender" cast call "$STATICS_DIAMOND_ADDRESS" 0x --value 1 \
    --from "$OWNER" --rpc-url "$RPC_URL" >"$RUN_DIR/native-eth-unexpected-diamond-revert.txt"
expect_call_revert "unexpected manager native sender" cast call "$STATICS_LIQUIDITY_MANAGER_ADDRESS" 0x --value 1 \
    --from "$OWNER" --rpc-url "$RPC_URL" >"$RUN_DIR/native-eth-unexpected-manager-revert.txt"
provide_native "$POSITION" "$POOL_ID" managed
provide_native "$ZERO_POSITION" "$ZERO_POOL" zero
assert_gt "$(cast call "$STATICS_DIAMOND_ADDRESS" 'gaugeBoundary(bytes32,int24)((uint128,int128,uint256[5]))' \
    "$POOL_ID" -1200 --rpc-url "$RPC_URL" --json | jq -r '.[0][0]')" 0 "native LP gauge registration"

# Seed an ordinary WETH pool too, so a single selection is exercised across both sources.
wrap_weth "$OWNER_INDEX" 100000000000000000000 native-eth-weth-owner
wrap_weth "$TRADER_INDEX" 5000000000000000000 native-eth-weth-trader
cast send "$WETH_ADDRESS" 'approve(address,uint256)' "$STATICS_DIAMOND_ADDRESS" "$(cast max-uint)" \
    --private-key "$OWNER_KEY" --rpc-url "$RPC_URL" --legacy --json >"$RUN_DIR/native-eth-weth-approve.json"
WETH_POSITION=$(new_position weth)
refresh_deadline
cast send "$STATICS_DIAMOND_ADDRESS" "$PROVIDE_SIG" "$WETH_POSITION" \
    "($WETH_POOL,-1200,1200,$LIQUIDITY,$MAXIMUM,$MAXIMUM,$DEADLINE)" --private-key "$OWNER_KEY" \
    --rpc-url "$RPC_URL" --legacy --json >"$RUN_DIR/native-eth-weth-provide.json"
if [[ "${WETH_ADDRESS,,}" < "${STAKING_TOKEN,,}" ]]; then
    WETH_CURRENCY0=$WETH_ADDRESS
    WETH_CURRENCY1=$STAKING_TOKEN
else
    WETH_CURRENCY0=$STAKING_TOKEN
    WETH_CURRENCY1=$WETH_ADDRESS
fi

# One WETH selection owns fees from ETH and WETH source claims.
cast send "$STAKING_TOKEN" 'approve(address,uint256)' "$STATICS_DIAMOND_ADDRESS" "$(cast max-uint)" \
    --private-key "$STAKER_KEY" --rpc-url "$RPC_URL" --legacy --json >"$RUN_DIR/native-eth-staker-approve.json"
STAKER_POSITION=$(cast call "$STATICS_DIAMOND_ADDRESS" 'nextPositionId()(uint256)' --rpc-url "$RPC_URL" | awk '{print $1}')
cast send "$STATICS_DIAMOND_ADDRESS" 'createAndStake(uint256,address,address[])(uint256)' \
    1000000000000000000000 "$STAKER" "[$WETH_ADDRESS]" --value 1000000000000000 \
    --private-key "$STAKER_KEY" --rpc-url "$RPC_URL" --legacy --json >"$RUN_DIR/native-eth-stake.json"
rpc_warp_by 604801
cast send "$STATICS_DIAMOND_ADDRESS" 'checkpointRewardAssets(address[])' "[$WETH_ADDRESS]" \
    --private-key "$STAKER_KEY" --rpc-url "$RPC_URL" --legacy --json >"$RUN_DIR/native-eth-checkpoint-weth.json"
assert_eq "$(cast call "$STATICS_DIAMOND_ADDRESS" 'canAccrueStakerRewards(address)(bool)' "$WETH_ADDRESS" --rpc-url "$RPC_URL")" true "WETH staking eligibility"
selection=$(cast call "$STATICS_DIAMOND_ADDRESS" 'rewardSelectionWithTiming(uint256,address)((bool,uint256,uint256,uint256,uint256,uint40),uint40)' \
    "$STAKER_POSITION" "$WETH_ADDRESS" --rpc-url "$RPC_URL" --json)
assert_eq "$(jq -r '.[0][0]' <<<"$selection")" true "WETH reward selection timing view"
assert_gt "$(jq -r '.[0][1]' <<<"$selection")" 0 "WETH reward selection eligible stake"
cast send "$STATICS_DIAMOND_ADDRESS" 'setGaugeAllocations(uint256,bytes32[],uint256[])' \
    "$STAKER_POSITION" "[$POOL_ID]" '[1000000000000000000000]' --private-key "$STAKER_KEY" \
    --rpc-url "$RPC_URL" --legacy --json >"$RUN_DIR/native-eth-allocation.json"
assert_gt "$(cast call "$STATICS_DIAMOND_ADDRESS" 'gaugePoolWeight(bytes32)(uint256,bytes32,bytes32,uint64,uint256,uint256,bool)' \
    "$POOL_ID" --rpc-url "$RPC_URL" | head -1 | awk '{print $1}')" 0 "native gauge STATICS allocation"
cast send "$STATICS_DIAMOND_ADDRESS" 'activateProtocolPoolPol(bytes32)' "$POOL_ID" --value "$STATICS_POL_ACTIVATION_FEE" \
    --private-key "$OWNER_KEY" --rpc-url "$RPC_URL" --legacy --json >"$RUN_DIR/native-eth-pol-activate.json"

WETH_SUPPLY=$(cast call "$WETH_ADDRESS" 'totalSupply()(uint256)' --rpc-url "$RPC_URL" | awk '{print $1}')
for direction in true false; do
    v4_swap_exact_in "$TRADER_INDEX" "$NATIVE" "$STAKING_TOKEN" 3000 60 "$STATICS_SWAP_FEE_HOOK_ADDRESS" \
        "$direction" 500000000000000000 "native-eth-in-$direction"
    v4_swap_exact_out "$TRADER_INDEX" "$NATIVE" "$STAKING_TOKEN" 3000 60 "$STATICS_SWAP_FEE_HOOK_ADDRESS" \
        "$direction" 100000000000000000 1000000000000000000 "native-eth-out-$direction"
    v4_swap_exact_in "$TRADER_INDEX" "$NATIVE" "$STAKING_TOKEN" 0 60 "$STATICS_SWAP_FEE_HOOK_ADDRESS" \
        "$direction" 100000000000000000 "native-eth-zero-$direction"
done
for direction in true false; do
    v4_swap_exact_in "$TRADER_INDEX" "$WETH_CURRENCY0" "$WETH_CURRENCY1" 3000 60 "$STATICS_SWAP_FEE_HOOK_ADDRESS" \
        "$direction" 100000000000000000 "native-eth-weth-source-$direction"
done
assert_gt "$(cast call "$STATICS_SWAP_FEE_HOOK_ADDRESS" 'pendingStakerRewards(address)(uint256)' "$WETH_ADDRESS" --rpc-url "$RPC_URL" | awk '{print $1}')" 0 "WETH hook staker claim"
assert_eq "$(cast call "$WETH_ADDRESS" 'totalSupply()(uint256)' --rpc-url "$RPC_URL" | awk '{print $1}')" "$WETH_SUPPLY" "native swaps defer WETH wrapping"
assert_gt "$(cast call "$STATICS_SWAP_FEE_HOOK_ADDRESS" 'pendingStakerRewards(address)(uint256)' "$NATIVE" --rpc-url "$RPC_URL" | awk '{print $1}')" 0 "native hook staker claim"
record_result native-eth swaps-and-zero-lp-fee pass "both directions, exact input/output, lazy wrapping"

# Hold native POL custody while rewards are wrapped, then prove its reservation is unchanged.
POL_ACCOUNT=$(cast call "$STATICS_DIAMOND_ADDRESS" 'protocolPolCustodyAccount(bytes32)(bytes32)' "$POOL_ID" --rpc-url "$RPC_URL")
for asset in "$NATIVE" "$STAKING_TOKEN"; do
    cast send "$STATICS_DIAMOND_ADDRESS" 'settleProtocolPoolPol(bytes32,address,uint256)(uint256)' "$POOL_ID" "$asset" 0 \
        --private-key "$OPERATOR_KEY" --rpc-url "$RPC_URL" --legacy --json >"$RUN_DIR/native-eth-pol-settle-$asset.json"
done
POL_NATIVE_BEFORE=$(pol_reserve "$NATIVE")
assert_gt "$POL_NATIVE_BEFORE" 0 "native POL reservation"
cast send "$STATICS_DIAMOND_ADDRESS" 'settlePublicSwapRewards(address,uint256)(uint256)' "$WETH_ADDRESS" "$(cast max-uint)" \
    --private-key "$STAKER_KEY" --rpc-url "$RPC_URL" --legacy --json >"$RUN_DIR/native-eth-staker-materialize.json"
assert_eq "$(pol_reserve "$NATIVE")" "$POL_NATIVE_BEFORE" "reward wrapping preserves native POL reservation"
STAKER_BEFORE=$(asset_balance "$WETH_ADDRESS" "$STAKER")
cast send "$STATICS_DIAMOND_ADDRESS" 'batchClaimRewardsAggregated((uint256,address[],uint256[])[],(uint256,bytes32,uint8[],uint256[])[],(uint256,bytes32,uint8[],uint256[])[],address)' \
    "[($STAKER_POSITION,[$WETH_ADDRESS],[0])]" '[]' '[]' "$STAKER" --private-key "$STAKER_KEY" \
    --rpc-url "$RPC_URL" --legacy --json >"$RUN_DIR/native-eth-staker-claim.json"
assert_gt "$(asset_balance "$WETH_ADDRESS" "$STAKER")" "$STAKER_BEFORE" "native fee staker paid WETH"

cast send "$STATICS_DIAMOND_ADDRESS" 'settleProtocolPoolRevenue(bytes32,address)(uint256,uint256)' "$POOL_ID" "$NATIVE" \
    --private-key "$STAKER_KEY" --rpc-url "$RPC_URL" --legacy --json >"$RUN_DIR/native-eth-revenue-settle.json"
for recipient in creator treasury; do
    if [[ "$recipient" == creator ]]; then
        credit=$(cast call "$STATICS_DIAMOND_ADDRESS" 'creatorRevenue(bytes32,address)(uint256)' "$POOL_ID" "$WETH_ADDRESS" --rpc-url "$RPC_URL" | awk '{print $1}')
        before=$(asset_balance "$WETH_ADDRESS" "$OWNER")
        cast send "$STATICS_DIAMOND_ADDRESS" 'claimCreatorRevenue(bytes32,address,address,uint256)(uint256,uint256)' \
            "$POOL_ID" "$WETH_ADDRESS" "$OWNER" 0 --private-key "$OWNER_KEY" --rpc-url "$RPC_URL" --legacy --json \
            >"$RUN_DIR/native-eth-creator-claim.json"
        after=$(asset_balance "$WETH_ADDRESS" "$OWNER")
    else
        credit=$(cast call "$STATICS_DIAMOND_ADDRESS" 'treasuryAccrued(address)(uint256)' "$WETH_ADDRESS" --rpc-url "$RPC_URL" | awk '{print $1}')
        before=$(asset_balance "$WETH_ADDRESS" "$TREASURY")
        cast send "$STATICS_DIAMOND_ADDRESS" 'distributeTreasuryFees(address)(uint256)' "$WETH_ADDRESS" \
            --private-key "$STAKER_KEY" --rpc-url "$RPC_URL" --legacy --json >"$RUN_DIR/native-eth-treasury-claim.json"
        after=$(asset_balance "$WETH_ADDRESS" "$TREASURY")
    fi
    assert_gt "$credit" 0 "$recipient WETH revenue"
    assert_eq "$(printf '%s - %s\n' "$after" "$before" | bc)" "$credit" "$recipient WETH payout"
done
record_result native-eth weth-revenue-and-pol-isolation pass "staker, creator, Treasury; native POL remains reserved"

# LP fees are delivered as actual ETH, and every managed mutation remains live.
refresh_deadline
before=$(asset_balance "$NATIVE" "$OWNER")
fees=$(cast call "$STATICS_DIAMOND_ADDRESS" 'collectNativeFees(uint256,bytes32,uint256,uint256,uint256)((uint256,uint128,uint256,uint256,uint256,uint256))' \
    "$POSITION" "$POOL_ID" 0 0 "$DEADLINE" --from "$OWNER" --rpc-url "$RPC_URL" --json | jq -r '.[0][3]')
cast send "$STATICS_DIAMOND_ADDRESS" 'collectNativeFees(uint256,bytes32,uint256,uint256,uint256)((uint256,uint128,uint256,uint256,uint256,uint256))' \
    "$POSITION" "$POOL_ID" 0 0 "$DEADLINE" --private-key "$OWNER_KEY" --rpc-url "$RPC_URL" --legacy --json >"$RUN_DIR/native-eth-lp-fees.json"
assert_gt "$fees" 0 "native LP ETH fees"
assert_eq "$(receipt_native_delta "$RUN_DIR/native-eth-lp-fees.json" "$before" "$(asset_balance "$NATIVE" "$OWNER")")" "$fees" "native LP fee delivery"
cast send "$STATICS_DIAMOND_ADDRESS" 'increaseLiquidity(uint256,bytes32,(uint128,uint256,uint256,uint256))((uint256,uint128,uint256,uint256,uint256,uint256))' \
    "$POSITION" "$POOL_ID" "(1000000000000000000,$MAXIMUM,$MAXIMUM,$DEADLINE)" --value "$MAXIMUM" \
    --private-key "$OWNER_KEY" --rpc-url "$RPC_URL" --legacy --json >"$RUN_DIR/native-eth-increase.json"
cast send "$STATICS_DIAMOND_ADDRESS" 'decreaseLiquidity(uint256,bytes32,(uint128,uint256,uint256,uint256))((uint256,uint128,uint256,uint256,uint256,uint256))' \
    "$POSITION" "$POOL_ID" "(1000000000000000000,0,0,$DEADLINE)" --private-key "$OWNER_KEY" \
    --rpc-url "$RPC_URL" --legacy --json >"$RUN_DIR/native-eth-decrease.json"
cast send "$STATICS_DIAMOND_ADDRESS" 'rebalanceLiquidity(uint256,bytes32,(int24,int24,uint128,uint256,uint256,uint256,uint256,uint256))((uint256,uint128,uint256,uint256,uint256,uint256))' \
    "$POSITION" "$POOL_ID" "(-1800,1800,10000000000000000000,1000000000000000000,1000000000000000000,0,0,$DEADLINE)" \
    --value 1000000000000000000 --private-key "$OWNER_KEY" --rpc-url "$RPC_URL" --legacy --json >"$RUN_DIR/native-eth-rebalance.json"

# External native POSM liquidity enters exactly the same gauge and exit path.
ATTACHED_POSITION=$(new_position attach)
approve_permit2_spender "$OWNER_INDEX" "$STAKING_TOKEN" "$POSITION_MANAGER" native-eth-posm
POSM_ID=$(cast call "$POSITION_MANAGER" 'nextTokenId()(uint256)' --rpc-url "$RPC_URL" | awk '{print $1}')
mint=$(cast abi-encode 'f((address,address,uint24,int24,address),int24,int24,uint256,uint128,uint128,address,bytes)' \
    "$POOL_KEY" 600 1200 1000000000000000000 "$MAXIMUM" "$MAXIMUM" "$OWNER" 0x)
close0=$(cast abi-encode 'f(address)' "$NATIVE")
close1=$(cast abi-encode 'f(address)' "$STAKING_TOKEN")
sweep=$(cast abi-encode 'f(address,address)' "$NATIVE" "$OWNER")
plan=$(cast abi-encode 'f(bytes,bytes[])' 0x02121214 "[$mint,$close0,$close1,$sweep]")
cast send "$POSITION_MANAGER" 'modifyLiquidities(bytes,uint256)' "$plan" "$DEADLINE" --value "$MAXIMUM" \
    --private-key "$OWNER_KEY" --rpc-url "$RPC_URL" --legacy --json >"$RUN_DIR/native-eth-external-mint.json"
cast send "$POSITION_MANAGER" 'approve(address,uint256)' "$STATICS_LIQUIDITY_MANAGER_ADDRESS" "$POSM_ID" \
    --private-key "$OWNER_KEY" --rpc-url "$RPC_URL" --legacy --json >"$RUN_DIR/native-eth-external-approve.json"
active_before=$(cast call "$STATICS_DIAMOND_ADDRESS" 'gaugePool(bytes32)((bool,bool,uint40,int24,uint128,uint64,uint64))' \
    "$POOL_ID" --rpc-url "$RPC_URL" --json | jq -r '.[0][4]')
cast send "$STATICS_DIAMOND_ADDRESS" 'attachLiquidity(uint256,bytes32,uint256)((uint256,uint128,uint256,uint256,uint256,uint256))' \
    "$ATTACHED_POSITION" "$POOL_ID" "$POSM_ID" --private-key "$OWNER_KEY" --rpc-url "$RPC_URL" --legacy --json \
    >"$RUN_DIR/native-eth-attach.json"
assert_eq "$(cast call "$POSITION_MANAGER" 'ownerOf(uint256)(address)' "$POSM_ID" --rpc-url "$RPC_URL")" \
    "$STATICS_LIQUIDITY_MANAGER_ADDRESS" "native attached POSM custody"

assert_eq "$(cast call "$STATICS_DIAMOND_ADDRESS" 'gaugePool(bytes32)((bool,bool,uint40,int24,uint128,uint64,uint64))' \
    "$POOL_ID" --rpc-url "$RPC_URL" --json | jq -r '.[0][4]')" "$active_before" "out-of-range attached native liquidity has no active weight"

# Native POL inventory funds native positions; only harvested Treasury fees wrap.
reserve0=$(pol_reserve "$NATIVE")
reserve1=$(pol_reserve "$STAKING_TOKEN")
cast send "$STATICS_DIAMOND_ADDRESS" 'openProtocolPolPosition((bytes32,int24,int24,uint128,uint256,uint256,uint256))(uint256)' \
    "($POOL_ID,-600,600,100000000000000,$reserve0,$reserve1,$DEADLINE)" --private-key "$OPERATOR_KEY" \
    --rpc-url "$RPC_URL" --legacy --json >"$RUN_DIR/native-eth-pol-open.json"
POL_POSITION=$(cast call "$STATICS_DIAMOND_ADDRESS" 'protocolPolPositionIds(bytes32)(uint256[])' "$POOL_ID" --rpc-url "$RPC_URL" --json | jq -r '.[0][-1]')
cast send "$STATICS_DIAMOND_ADDRESS" 'increaseProtocolPolPosition((uint256,uint128,uint256,uint256,uint256))' \
    "($POL_POSITION,100000000000000,$(pol_reserve "$NATIVE"),$(pol_reserve "$STAKING_TOKEN"),$DEADLINE)" \
    --private-key "$OPERATOR_KEY" --rpc-url "$RPC_URL" --legacy --json >"$RUN_DIR/native-eth-pol-increase.json"
for direction in true false; do
    v4_swap_exact_in "$TRADER_INDEX" "$NATIVE" "$STAKING_TOKEN" 3000 60 "$STATICS_SWAP_FEE_HOOK_ADDRESS" \
        "$direction" 100000000000000000 "native-eth-pol-fees-$direction"
done
pol_before=$(pol_reserve "$NATIVE")
treasury_before=$(cast call "$STATICS_DIAMOND_ADDRESS" 'treasuryAccrued(address)(uint256)' "$WETH_ADDRESS" --rpc-url "$RPC_URL" | awk '{print $1}')
cast send "$STATICS_DIAMOND_ADDRESS" 'collectProtocolPolFees(uint256,uint256)' "$POL_POSITION" "$DEADLINE" \
    --private-key "$OPERATOR_KEY" --rpc-url "$RPC_URL" --legacy --json >"$RUN_DIR/native-eth-pol-harvest.json"
assert_eq "$(pol_reserve "$NATIVE")" "$pol_before" "native POL fee classification preserves principal"
assert_gt "$(cast call "$STATICS_DIAMOND_ADDRESS" 'treasuryAccrued(address)(uint256)' "$WETH_ADDRESS" --rpc-url "$RPC_URL" | awk '{print $1}')" "$treasury_before" "native POL fees become Treasury WETH"
cast send "$STATICS_DIAMOND_ADDRESS" 'decreaseProtocolPolPosition((uint256,uint128,uint256,uint256,uint256))' \
    "($POL_POSITION,100000000000000,0,0,$DEADLINE)" --private-key "$OPERATOR_KEY" --rpc-url "$RPC_URL" --legacy --json >"$RUN_DIR/native-eth-pol-decrease.json"
assert_gt "$(pol_reserve "$NATIVE")" "$pol_before" "native POL decrease returns ETH reservation"
cast send "$STATICS_DIAMOND_ADDRESS" 'rebalanceProtocolPolPositions((bytes32,(uint256,uint256,uint256)[],(int24,int24,uint128,uint256,uint256)[],uint256,uint256,uint256))(uint256[])' \
    "($POOL_ID,[($POL_POSITION,0,0)],[(-1200,1200,100000000000000,$(pol_reserve "$NATIVE"),$(pol_reserve "$STAKING_TOKEN"))],$(pol_reserve "$NATIVE"),$(pol_reserve "$STAKING_TOKEN"),$DEADLINE)" \
    --private-key "$OPERATOR_KEY" --rpc-url "$RPC_URL" --legacy --json >"$RUN_DIR/native-eth-pol-rebalance.json"
POL_POSITION=$(cast call "$STATICS_DIAMOND_ADDRESS" 'protocolPolPositionIds(bytes32)(uint256[])' "$POOL_ID" --rpc-url "$RPC_URL" --json | jq -r '.[0][-1]')
cast send "$STATICS_DIAMOND_ADDRESS" 'closeProtocolPolPosition(uint256,uint256,uint256,uint256)' "$POL_POSITION" 0 0 "$DEADLINE" \
    --private-key "$OPERATOR_KEY" --rpc-url "$RPC_URL" --legacy --json >"$RUN_DIR/native-eth-pol-close.json"
assert_gt "$(pol_reserve "$NATIVE")" 0 "closed native POL retains ETH inventory"
record_result native-eth pol-lifecycle pass "activation, native settlement, open, increase, harvest, decrease, rebalance, close"

# ERC-20 gauge rails remain fully supported for native pool liquidity.
timelock_call "$STATICS_DIAMOND_ADDRESS" 0 "$(cast calldata 'setGaugeRewardAssetAllowed(address,bool)' "$WETH_ADDRESS" true)" native-eth-allow-rewards
cast send "$STATICS_DIAMOND_ADDRESS" 'appendPoolRewardAsset(bytes32,address)(uint8)' "$POOL_ID" "$WETH_ADDRESS" \
    --private-key "$OWNER_KEY" --rpc-url "$RPC_URL" --legacy --json >"$RUN_DIR/native-eth-gauge-slot.json"
wrap_weth "$OWNER_INDEX" 7000000000000000000 native-eth-direct
cast send "$WETH_ADDRESS" 'approve(address,uint256)' "$STATICS_DIAMOND_ADDRESS" 7000000000000000000 \
    --private-key "$OWNER_KEY" --rpc-url "$RPC_URL" --legacy --json >"$RUN_DIR/native-eth-direct-approve.json"
cast send "$STATICS_DIAMOND_ADDRESS" 'fundPoolReward(bytes32,uint8,uint256,uint40,uint16)(uint256)' \
    "$POOL_ID" 1 7000000000000000000 604800 0 --private-key "$OWNER_KEY" --rpc-url "$RPC_URL" --legacy --json >"$RUN_DIR/native-eth-direct-fund.json"
cast send "$STATICS_DIAMOND_ADDRESS" 'fundGaugeReserve(uint256)(uint256)' 1000000000000000000000 \
    --private-key "$OWNER_KEY" --rpc-url "$RPC_URL" --legacy --json >"$RUN_DIR/native-eth-statics-fund.json"
timelock_call "$STATICS_DIAMOND_ADDRESS" 0 "$(cast calldata 'activateGaugeSchedule()')" native-eth-activate-gauge
rpc_warp_by 86400
cast send "$STATICS_DIAMOND_ADDRESS" 'checkpointGaugePool(bytes32)(uint256,uint256)' "$POOL_ID" \
    --private-key "$OWNER_KEY" --rpc-url "$RPC_URL" --gas-limit 3000000 --legacy --json \
    >"$RUN_DIR/native-eth-gauge-checkpoint.json"
rpc_warp_by 86400
preview=$(cast call "$STATICS_DIAMOND_ADDRESS" 'previewLpRewards(uint256,bytes32)((uint8,address[5],uint256[5]))' "$POSITION" "$POOL_ID" --rpc-url "$RPC_URL" --json)
assert_gt "$(jq -r '.[0][2][0]' <<<"$preview")" 0 "native LP STATICS gauge accrual"
assert_gt "$(jq -r '.[0][2][1]' <<<"$preview")" 0 "native LP direct WETH reward accrual"
cast send "$STATICS_DIAMOND_ADDRESS" 'claimLpRewards(uint256,bytes32,uint8[],uint256[],address)(uint256[])' \
    "$POSITION" "$POOL_ID" '[0,1]' '[0,0]' "$OWNER" --private-key "$OWNER_KEY" --rpc-url "$RPC_URL" --gas-limit 3000000 --legacy --json >"$RUN_DIR/native-eth-gauge-claim.json"
refresh_deadline
for position in "$POSITION" "$ZERO_POSITION" "$ATTACHED_POSITION"; do
    pool=$POOL_ID
    [[ "$position" == "$ZERO_POSITION" ]] && pool=$ZERO_POOL
    before=$(asset_balance "$NATIVE" "$OWNER")
    cast send "$STATICS_DIAMOND_ADDRESS" "$EXIT_SIG" "$position" "$pool" 0 0 "$DEADLINE" \
        --private-key "$OWNER_KEY" --rpc-url "$RPC_URL" --legacy --json >"$RUN_DIR/native-eth-exit-$position.json"
    assert_gt "$(receipt_native_delta "$RUN_DIR/native-eth-exit-$position.json" "$before" "$(asset_balance "$NATIVE" "$OWNER")")" 0 "native LP exit returns ETH"
    # The exit transaction may checkpoint one final reward slice after the
    # pre-exit claim. Resolve that claim-only stub before asserting retirement.
    after_exit_legs=$(cast call "$STATICS_DIAMOND_ADDRESS" 'activeLegCount(uint256)(uint256)' "$position" --rpc-url "$RPC_URL" | awk '{print $1}')
    if [[ "$after_exit_legs" == 1 ]]; then
        residual=$(cast call "$STATICS_DIAMOND_ADDRESS" 'previewLpRewards(uint256,bytes32)((uint8,address[5],uint256[5]))' \
            "$position" "$pool" --rpc-url "$RPC_URL" --json)
        assert_gt "$(jq -r '.[0][2][0] + .[0][2][1]' <<<"$residual")" 0 "native exit retains final gauge reward"
        cast send "$STATICS_DIAMOND_ADDRESS" 'claimLpRewards(uint256,bytes32,uint8[],uint256[],address)(uint256[])' \
            "$position" "$pool" '[0,1]' '[0,0]' "$OWNER" --private-key "$OWNER_KEY" \
            --rpc-url "$RPC_URL" --gas-limit 3000000 --legacy --json >"$RUN_DIR/native-eth-exit-$position-residual-claim.json"
    fi
    assert_eq "$(cast call "$STATICS_DIAMOND_ADDRESS" 'activeLegCount(uint256)(uint256)' "$position" --rpc-url "$RPC_URL" | awk '{print $1}')" 0 "native exit clears leg"
done
assert_phase_one_solvency native-eth-final "$NATIVE" "$STAKING_TOKEN" "$WETH_ADDRESS"
record_result native-eth managed-and-attached-lifecycle pass "provide/refund, collect ETH fees, increase, decrease, rebalance, attach, exit"
record_result native-eth gauge-rewards pass "STATICS allocation and direct WETH reward claims"
note "native ETH lifecycle passed"
