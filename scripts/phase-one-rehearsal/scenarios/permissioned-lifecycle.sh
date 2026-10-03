#!/usr/bin/env bash

set -Eeuo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

require_commands cast jq awk bc
load_current_run
require_local_chain
reset_to_base

CREATOR_INDEX=10
LP_INDEX=11
TRADER_INDEX=12
CREATOR=$(anvil_address "$CREATOR_INDEX")
CREATOR_KEY=$(anvil_private_key "$CREATOR_INDEX")
LP=$(anvil_address "$LP_INDEX")
LP_KEY=$(anvil_private_key "$LP_INDEX")
TRADER=$(anvil_address "$TRADER_INDEX")
TRADER_KEY=$(anvil_private_key "$TRADER_INDEX")

cast send "$STATICS_DEFAULT_VENUE_CONTROLLER_FACTORY" 'createController()(address)' \
    --private-key "$CREATOR_KEY" --rpc-url "$RPC_URL" --legacy --json \
    >"$RUN_DIR/permissioned-create-controller.json"
CONTROLLER_TOPIC=$(cast keccak 'VenueControllerCreated(address,address)')
CONTROLLER=$(jq -r --arg topic "${CONTROLLER_TOPIC,,}" '
    .logs[] | select((.topics[0] | ascii_downcase) == $topic) | .topics[2] | "0x" + .[-40:]
' "$RUN_DIR/permissioned-create-controller.json")
assert_nonzero_address "$CONTROLLER" "permissioned controller"

DEADLINE=$(( $(cast block latest --field timestamp --rpc-url "$RPC_URL") + 172800 ))
AGREEMENT=$(cast keccak 'phase-one-permissioned-rehearsal')
ECONOMICS='(50,0,(8000,1000,1000,0))'
PARAMS="($STAKING_TOKEN,$WETH_ADDRESS,3000,60,79228162514264337593543950336,$CREATOR,$CONTROLLER,$ECONOMICS,1,$DEADLINE,$AGREEMENT)"
QUOTE=$(cast call "$STATICS_DIAMOND_ADDRESS" \
    'quotePermissionedPool((address,address,uint24,int24,uint160,address,address,(uint16,uint8,(uint16,uint16,uint16,uint16)),uint256,uint256,bytes32))(((address,address,uint24,int24,address),bytes32,uint160,bytes32))' \
    "$PARAMS" --rpc-url "$RPC_URL" --json)
POOL_ID=$(jq -r '.[0][1]' <<<"$QUOTE")
DIGEST=$(jq -r '.[0][3]' <<<"$QUOTE")
AUTHORIZATION=$(cast wallet sign --no-hash "$DIGEST" --private-key "$CREATOR_KEY")
CREATE_CALLDATA=$(cast calldata \
    'createPermissionedPool((address,address,uint24,int24,uint160,address,address,(uint16,uint8,(uint16,uint16,uint16,uint16)),uint256,uint256,bytes32),bytes)' \
    "$PARAMS" "$AUTHORIZATION")
timelock_call "$STATICS_DIAMOND_ADDRESS" 0 "$CREATE_CALLDATA" permissioned-create
assert_eq \
    "$(cast call "$STATICS_DIAMOND_ADDRESS" 'isPermissionedPool(bytes32)(bool)' "$POOL_ID" --rpc-url "$RPC_URL")" \
    true \
    "permissioned pool registration"

# A creator can invalidate an unused creation authorization before governance
# attempts to consume it. Use a distinct PoolKey so duplicate-pool rejection
# cannot mask the nonce check.
INVALIDATED_CREATION_NONCE=2
INVALIDATED_PARAMS="($STAKING_TOKEN,$WETH_ADDRESS,500,10,79228162514264337593543950336,$CREATOR,$CONTROLLER,$ECONOMICS,$INVALIDATED_CREATION_NONCE,$DEADLINE,$AGREEMENT)"
INVALIDATED_QUOTE=$(cast call "$STATICS_DIAMOND_ADDRESS" \
    'quotePermissionedPool((address,address,uint24,int24,uint160,address,address,(uint16,uint8,(uint16,uint16,uint16,uint16)),uint256,uint256,bytes32))(((address,address,uint24,int24,address),bytes32,uint160,bytes32))' \
    "$INVALIDATED_PARAMS" --rpc-url "$RPC_URL" --json)
INVALIDATED_DIGEST=$(jq -r '.[0][3]' <<<"$INVALIDATED_QUOTE")
INVALIDATED_AUTHORIZATION=$(cast wallet sign --no-hash "$INVALIDATED_DIGEST" --private-key "$CREATOR_KEY")
cast send "$STATICS_DIAMOND_ADDRESS" 'invalidatePermissionedAuthorizationNonce(uint256)' \
    "$INVALIDATED_CREATION_NONCE" --private-key "$CREATOR_KEY" --rpc-url "$RPC_URL" --legacy --json \
    >"$RUN_DIR/permissioned-invalidate-creation-nonce.json"
assert_eq "$(cast call "$STATICS_DIAMOND_ADDRESS" \
    'isPermissionedAuthorizationNonceUsed(address,uint256)(bool)' \
    "$CREATOR" "$INVALIDATED_CREATION_NONCE" --rpc-url "$RPC_URL")" true \
    "permissioned creation nonce invalidated"
expect_call_revert "invalidated permissioned creation authorization" \
    cast call "$STATICS_DIAMOND_ADDRESS" \
    'createPermissionedPool((address,address,uint24,int24,uint160,address,address,(uint16,uint8,(uint16,uint16,uint16,uint16)),uint256,uint256,bytes32),bytes)' \
    "$INVALIDATED_PARAMS" "$INVALIDATED_AUTHORIZATION" --from "$STATICS_TIMELOCK_ADDRESS" --rpc-url "$RPC_URL" \
    >"$RUN_DIR/permissioned-invalidated-creation-revert.txt"
expect_call_revert "duplicate permissioned creation nonce invalidation" \
    cast call "$STATICS_DIAMOND_ADDRESS" 'invalidatePermissionedAuthorizationNonce(uint256)' \
    "$INVALIDATED_CREATION_NONCE" --from "$CREATOR" --rpc-url "$RPC_URL" >/dev/null

# Pool-specific configuration nonces are independently creator-controlled.
# Invalidation advances the live nonce and permanently makes nonce zero stale.
expect_call_revert "outsider permissioned configuration invalidation" \
    cast call "$STATICS_DIAMOND_ADDRESS" 'invalidatePermissionedConfigurationNonce(bytes32,uint256)' \
    "$POOL_ID" 0 --from "$TRADER" --rpc-url "$RPC_URL" >/dev/null
cast send "$STATICS_DIAMOND_ADDRESS" 'invalidatePermissionedConfigurationNonce(bytes32,uint256)' \
    "$POOL_ID" 0 --private-key "$CREATOR_KEY" --rpc-url "$RPC_URL" --legacy --json \
    >"$RUN_DIR/permissioned-invalidate-configuration-nonce.json"
expect_call_revert "stale permissioned configuration nonce" \
    cast call "$STATICS_DIAMOND_ADDRESS" 'invalidatePermissionedConfigurationNonce(bytes32,uint256)' \
    "$POOL_ID" 0 --from "$CREATOR" --rpc-url "$RPC_URL" >/dev/null

# Only the LP is eligible initially. The trader proves that admission is
# enforced before the controller enables its swap permission.
cast send "$CONTROLLER" 'setPermissions(bytes32,address[],uint256[])' "$POOL_ID" "[$LP]" '[2]' \
    --private-key "$CREATOR_KEY" --rpc-url "$RPC_URL" --legacy --json \
    >"$RUN_DIR/permissioned-lp-permission.json"

if [[ "${WETH_ADDRESS,,}" < "${STAKING_TOKEN,,}" ]]; then
    CURRENCY0=$WETH_ADDRESS
    CURRENCY1=$STAKING_TOKEN
else
    CURRENCY0=$STAKING_TOKEN
    CURRENCY1=$WETH_ADDRESS
fi
POOL_KEY="($CURRENCY0,$CURRENCY1,3000,60,$STATICS_PERMISSIONED_SWAP_FEE_HOOK_ADDRESS)"

acquire_genesis_statics "$LP_INDEX" 2000000000000000000 permissioned-lp >/dev/null
wrap_weth "$LP_INDEX" 100000000000000000000 permissioned-lp
approve_permit2_spender "$LP_INDEX" "$CURRENCY0" "$STATICS_PERMISSIONED_POSITION_MANAGER_ADDRESS" \
    permissioned-position-currency0
approve_permit2_spender "$LP_INDEX" "$CURRENCY1" "$STATICS_PERMISSIONED_POSITION_MANAGER_ADDRESS" \
    permissioned-position-currency1

TOKEN_ID=$(cast call "$STATICS_PERMISSIONED_POSITION_MANAGER_ADDRESS" 'nextTokenId()(uint256)' \
    --rpc-url "$RPC_URL" | awk '{print $1}')
MINT_PARAM=$(cast abi-encode \
    'f((address,address,uint24,int24,address),int24,int24,uint256,uint128,uint128,address,bytes)' \
    "$POOL_KEY" -887220 887220 50000000000000000000 \
    60000000000000000000 60000000000000000000 "$LP" 0x)
SETTLE_PARAM=$(cast abi-encode 'f(address,address)' "$CURRENCY0" "$CURRENCY1")
MINT_PLAN=$(cast abi-encode 'f(bytes,bytes[])' 0x020d "[$MINT_PARAM,$SETTLE_PARAM]")
POSITION_DEADLINE=$(( $(cast block latest --field timestamp --rpc-url "$RPC_URL") + 3600 ))
cast send "$STATICS_PERMISSIONED_POSITION_MANAGER_ADDRESS" 'modifyLiquidities(bytes,uint256)' \
    "$MINT_PLAN" "$POSITION_DEADLINE" \
    --private-key "$LP_KEY" --rpc-url "$RPC_URL" --gas-limit 3000000 --legacy --json \
    >"$RUN_DIR/permissioned-mint-liquidity.json"
assert_eq \
    "$(cast call "$STATICS_PERMISSIONED_POSITION_MANAGER_ADDRESS" 'ownerOf(uint256)(address)' "$TOKEN_ID" \
        --rpc-url "$RPC_URL")" \
    "$LP" \
    "permissioned position owner"

wrap_weth "$TRADER_INDEX" 1000000000000000000 permissioned-trader
approve_permit2_spender "$TRADER_INDEX" "$CURRENCY0" "$STATICS_PERMISSIONED_ROUTER_ADDRESS" permissioned-router
SWAP_PARAMS="($POOL_KEY,true,100000000000000000,0,0x)"
SWAP_DEADLINE=$(( $(cast block latest --field timestamp --rpc-url "$RPC_URL") + 3600 ))
expect_call_revert "unapproved permissioned trader" \
    cast call "$STATICS_PERMISSIONED_ROUTER_ADDRESS" \
    'swapExactInputSingle(((address,address,uint24,int24,address),bool,uint128,uint128,bytes),uint256)(uint256)' \
    "$SWAP_PARAMS" "$SWAP_DEADLINE" --from "$TRADER" --rpc-url "$RPC_URL" \
    >"$RUN_DIR/permissioned-unapproved-trader-revert.txt"

cast send "$CONTROLLER" 'setPermissions(bytes32,address[],uint256[])' "$POOL_ID" "[$TRADER]" '[1]' \
    --private-key "$CREATOR_KEY" --rpc-url "$RPC_URL" --legacy --json \
    >"$RUN_DIR/permissioned-trader-permission.json"
cast send "$STATICS_PERMISSIONED_ROUTER_ADDRESS" \
    'swapExactInputSingle(((address,address,uint24,int24,address),bool,uint128,uint128,bytes),uint256)(uint256)' \
    "$SWAP_PARAMS" "$SWAP_DEADLINE" \
    --private-key "$TRADER_KEY" --rpc-url "$RPC_URL" --gas-limit 3000000 --legacy --json \
    >"$RUN_DIR/permissioned-cold-swap.json"
rpc_warp_by 60
SWAP_DEADLINE=$(( $(cast block latest --field timestamp --rpc-url "$RPC_URL") + 3600 ))
cast send "$STATICS_PERMISSIONED_ROUTER_ADDRESS" \
    'swapExactInputSingle(((address,address,uint24,int24,address),bool,uint128,uint128,bytes),uint256)(uint256)' \
    "$SWAP_PARAMS" "$SWAP_DEADLINE" \
    --private-key "$TRADER_KEY" --rpc-url "$RPC_URL" --gas-limit 3000000 --legacy --json \
    >"$RUN_DIR/permissioned-steady-swap.json"

MARKET=$(cast call "$STATICS_DIAMOND_ADDRESS" \
    'canonicalMarketState(bytes32)((uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,int256,uint40,int24,uint24,uint8,uint8))' \
    "$POOL_ID" --rpc-url "$RPC_URL" --json)
assert_eq "$(jq -r '.[0][6]' <<<"$MARKET")" 2 "permissioned external swap count"
assert_eq "$(jq -r '.[0][8]' <<<"$MARKET")" 2 "permissioned canonical sequence"
assert_eq "$(jq -r '.[0][13]' <<<"$MARKET")" 5 "permissioned zero-for-one flags"

# A restricted output keeps creator and Treasury revenue in that currency while
# converting only the staker share into the paired rewardable asset. The
# normalization is recorded separately from headline external volume.
STAKER_INDEX=13
STAKER=$(anvil_address "$STAKER_INDEX")
POSITION_FEE=1000000000000000
acquire_genesis_statics "$STAKER_INDEX" 1000000000000000000 permissioned-staker >/dev/null
cast send "$STAKING_TOKEN" 'approve(address,uint256)' "$STATICS_DIAMOND_ADDRESS" "$(cast max-uint)" \
    --private-key "$(anvil_private_key "$STAKER_INDEX")" --rpc-url "$RPC_URL" --legacy --json \
    >"$RUN_DIR/permissioned-staker-approve.json"
STAKER_POSITION=$(cast call "$STATICS_DIAMOND_ADDRESS" 'nextPositionId()(uint256)' --rpc-url "$RPC_URL" | awk '{print $1}')
cast send "$STATICS_DIAMOND_ADDRESS" 'createAndStake(uint256,address,address[])(uint256)' \
    1000000000000000000000 "$STAKER" "[$CURRENCY0]" --value "$POSITION_FEE" \
    --private-key "$(anvil_private_key "$STAKER_INDEX")" --rpc-url "$RPC_URL" --legacy --json \
    >"$RUN_DIR/permissioned-staker-position.json"
rpc_warp_by 90000
cast send "$STATICS_DIAMOND_ADDRESS" 'checkpointRewardAssets(address[])' "[$CURRENCY0]" \
    --private-key "$(anvil_private_key 14)" --rpc-url "$RPC_URL" --legacy --json \
    >"$RUN_DIR/permissioned-staker-checkpoint.json"
cast send "$STATICS_DIAMOND_ADDRESS" 'addRewardRestriction(address)' "$CURRENCY1" \
    --private-key "$(anvil_private_key 1)" --rpc-url "$RPC_URL" --legacy --json \
    >"$RUN_DIR/permissioned-restrict-output.json"
REWARD_RESERVE_BEFORE=$(cast call "$STATICS_DIAMOND_ADDRESS" \
    'rewardAsset(address)((uint256,uint256,uint256,uint256,uint256,uint256,uint256))' "$CURRENCY0" \
    --rpc-url "$RPC_URL" --json | jq -r '.[0][5]')
SWAP_DEADLINE=$(( $(cast block latest --field timestamp --rpc-url "$RPC_URL") + 3600 ))
cast send "$STATICS_PERMISSIONED_ROUTER_ADDRESS" \
    'swapExactInputSingle(((address,address,uint24,int24,address),bool,uint128,uint128,bytes),uint256)(uint256)' \
    "$SWAP_PARAMS" "$SWAP_DEADLINE" --private-key "$TRADER_KEY" --rpc-url "$RPC_URL" \
    --gas-limit 3000000 --legacy --json >"$RUN_DIR/permissioned-normalized-swap.json"

MARKET=$(cast call "$STATICS_DIAMOND_ADDRESS" \
    'canonicalMarketState(bytes32)((uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,int256,uint40,int24,uint24,uint8,uint8))' \
    "$POOL_ID" --rpc-url "$RPC_URL" --json)
assert_eq "$(jq -r '.[0][6]' <<<"$MARKET")" 3 "permissioned external count after normalization"
assert_eq "$(jq -r '.[0][7]' <<<"$MARKET")" 1 "permissioned internal normalization count"
assert_eq "$(jq -r '.[0][8]' <<<"$MARKET")" 4 "permissioned sequence after normalization"
assert_eq "$(jq -r '.[0][13]' <<<"$MARKET")" 5 "permissioned final external flags"
MARKET_EVENT_TOPIC=$(cast keccak 'MarketSwapRecorded(bytes32,uint256,int256,uint256,int24,uint24,uint8)')
NORMALIZATION_EVENTS=$(jq --arg topic "${MARKET_EVENT_TOPIC,,}" \
    '[.logs[] | select((.topics[0] | ascii_downcase) == $topic)]' \
    "$RUN_DIR/permissioned-normalized-swap.json")
assert_eq "$(jq 'length' <<<"$NORMALIZATION_EVENTS")" 2 "normalization MarketTape event count"
assert_eq "$(cast to-dec "0x$(jq -r '.[0].data[-64:]' <<<"$NORMALIZATION_EVENTS")")" 12 \
    "permissioned internal event flags"
assert_eq "$(cast to-dec "0x$(jq -r '.[1].data[-64:]' <<<"$NORMALIZATION_EVENTS")")" 5 \
    "permissioned external event flags"
assert_eq "$(cast to-dec "$(jq -r '.[0].topics[2]' <<<"$NORMALIZATION_EVENTS")")" 3 \
    "permissioned internal event sequence"
assert_eq "$(cast to-dec "$(jq -r '.[1].topics[2]' <<<"$NORMALIZATION_EVENTS")")" 4 \
    "permissioned external event sequence"
REWARD_RESERVE_AFTER=$(cast call "$STATICS_DIAMOND_ADDRESS" \
    'rewardAsset(address)((uint256,uint256,uint256,uint256,uint256,uint256,uint256))' "$CURRENCY0" \
    --rpc-url "$RPC_URL" --json | jq -r '.[0][5]')
assert_gt "$REWARD_RESERVE_AFTER" "$REWARD_RESERVE_BEFORE" "normalized staker reward reserve"

STAKER_PENDING=$(cast call "$STATICS_DIAMOND_ADDRESS" 'pendingRewards(uint256,address[])(uint256[])' \
    "$STAKER_POSITION" "[$CURRENCY0]" --from "$STAKER" --rpc-url "$RPC_URL" --json | jq -r '.[0][0]')
assert_gt "$STAKER_PENDING" 0 "permissioned normalized staker entitlement"
STAKER_BALANCE_BEFORE=$(cast call "$CURRENCY0" 'balanceOf(address)(uint256)' "$STAKER" --rpc-url "$RPC_URL" | awk '{print $1}')
cast send "$STATICS_DIAMOND_ADDRESS" 'claimRewards(uint256,address[],address,uint256[])(uint256[])' \
    "$STAKER_POSITION" "[$CURRENCY0]" "$STAKER" '[0]' --private-key "$(anvil_private_key "$STAKER_INDEX")" \
    --rpc-url "$RPC_URL" --legacy --json >"$RUN_DIR/permissioned-staker-claim.json"
STAKER_RECEIVED=$(printf '%s - %s\n' \
    "$(cast call "$CURRENCY0" 'balanceOf(address)(uint256)' "$STAKER" --rpc-url "$RPC_URL" | awk '{print $1}')" \
    "$STAKER_BALANCE_BEFORE" | bc)
assert_eq "$STAKER_RECEIVED" "$STAKER_PENDING" "permissioned normalized reward claim"

CREATOR_CREDIT=$(cast call "$STATICS_DIAMOND_ADDRESS" 'creatorRevenue(bytes32,address)(uint256)' \
    "$POOL_ID" "$CURRENCY1" --rpc-url "$RPC_URL" | awk '{print $1}')
TREASURY_CREDIT=$(cast call "$STATICS_DIAMOND_ADDRESS" 'treasuryAccrued(address)(uint256)' \
    "$CURRENCY1" --rpc-url "$RPC_URL" | awk '{print $1}')
assert_gt "$CREATOR_CREDIT" 0 "permissioned creator output credit"
assert_gt "$TREASURY_CREDIT" 0 "permissioned Treasury output credit"
cast send "$STATICS_DIAMOND_ADDRESS" 'claimCreatorRevenue(bytes32,address,address,uint256)(uint256,uint256)' \
    "$POOL_ID" "$CURRENCY1" "$CREATOR" 0 --private-key "$CREATOR_KEY" \
    --rpc-url "$RPC_URL" --legacy --json >"$RUN_DIR/permissioned-creator-claim.json"
cast send "$STATICS_DIAMOND_ADDRESS" 'distributeTreasuryFees(address)(uint256)' "$CURRENCY1" \
    --private-key "$(anvil_private_key 14)" --rpc-url "$RPC_URL" --legacy --json \
    >"$RUN_DIR/permissioned-treasury-distribution.json"

# Halting blocks further swaps and enables the venue operator's forced unwind.
cast send "$CONTROLLER" 'setPoolStatus(bytes32,uint8)' "$POOL_ID" 1 \
    --private-key "$CREATOR_KEY" --rpc-url "$RPC_URL" --legacy --json \
    >"$RUN_DIR/permissioned-halt.json"
expect_call_revert "halted permissioned pool swap" \
    cast call "$STATICS_PERMISSIONED_ROUTER_ADDRESS" \
    'swapExactInputSingle(((address,address,uint24,int24,address),bool,uint128,uint128,bytes),uint256)(uint256)' \
    "$SWAP_PARAMS" "$SWAP_DEADLINE" --from "$TRADER" --rpc-url "$RPC_URL" \
    >"$RUN_DIR/permissioned-halted-swap-revert.txt"

cast send "$STATICS_PERMISSIONED_POSITION_CLAIMS_ADDRESS" \
    'forceUnwind(uint256,uint128,uint128,bytes)' "$TOKEN_ID" 0 0 0x \
    --private-key "$CREATOR_KEY" --rpc-url "$RPC_URL" --gas-limit 3000000 --legacy --json \
    >"$RUN_DIR/permissioned-force-unwind.json"
CREDIT0=$(cast call "$STATICS_PERMISSIONED_POSITION_CLAIMS_ADDRESS" \
    'creditOf(bytes32,address,address)(uint256)' "$POOL_ID" "$LP" "$CURRENCY0" --rpc-url "$RPC_URL" | awk '{print $1}')
CREDIT1=$(cast call "$STATICS_PERMISSIONED_POSITION_CLAIMS_ADDRESS" \
    'creditOf(bytes32,address,address)(uint256)' "$POOL_ID" "$LP" "$CURRENCY1" --rpc-url "$RPC_URL" | awk '{print $1}')
[[ "$CREDIT0" != 0 && "$CREDIT1" != 0 ]] || fail "forced unwind did not create two-sided owner credit"

cast send "$STATICS_PERMISSIONED_POSITION_CLAIMS_ADDRESS" \
    'claim(bytes32,address,address,uint256)' "$POOL_ID" "$CURRENCY0" "$LP" "$CREDIT0" \
    --private-key "$LP_KEY" --rpc-url "$RPC_URL" --legacy --json >"$RUN_DIR/permissioned-claim0.json"
cast send "$STATICS_PERMISSIONED_POSITION_CLAIMS_ADDRESS" \
    'claim(bytes32,address,address,uint256)' "$POOL_ID" "$CURRENCY1" "$LP" "$CREDIT1" \
    --private-key "$LP_KEY" --rpc-url "$RPC_URL" --legacy --json >"$RUN_DIR/permissioned-claim1.json"

COLD_GAS=$(receipt_gas_used "$RUN_DIR/permissioned-cold-swap.json")
STEADY_GAS=$(receipt_gas_used "$RUN_DIR/permissioned-steady-swap.json")
jq -n \
    --arg poolId "$POOL_ID" \
    --arg controller "$CONTROLLER" \
    --argjson coldGas "$COLD_GAS" \
    --argjson steadyGas "$STEADY_GAS" \
    --arg credit0 "$CREDIT0" \
    --arg credit1 "$CREDIT1" \
    '{poolId:$poolId,controller:$controller,coldSwapGas:$coldGas,steadySwapGas:$steadyGas,forcedCredits:[$credit0,$credit1]}' \
    >"$RUN_DIR/permissioned-lifecycle.json"
record_result permissioned admission pass "$POOL_ID"
record_result permissioned forced-unwind pass "position $TOKEN_ID"
record_result permissioned normalized-staker-reward pass "$STAKER_RECEIVED $CURRENCY0 wei"
record_result permissioned creator-and-treasury-revenue pass "$CURRENCY1"
record_result permissioned nonce-invalidation pass "creation $INVALIDATED_CREATION_NONCE and configuration 0"
record_result market-tape permissioned-internal-normalization pass "sequence 4"
record_result gas permissioned-cold pass "$COLD_GAS"
record_result gas permissioned-steady pass "$STEADY_GAS"
note "permissioned admission, swap, halt, unwind, and claim scenarios passed"
