#!/usr/bin/env bash

set -Eeuo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

require_commands cast jq awk bc
load_current_run
require_local_chain
reset_to_base

OWNER_INDEX=8
OPERATOR_INDEX=9
TRADER_INDEX=10
OWNER=$(anvil_address "$OWNER_INDEX")
OPERATOR=$(anvil_address "$OPERATOR_INDEX")
OWNER_KEY=$(anvil_private_key "$OWNER_INDEX")
POSITION_FEE=1000000000000000
POSITION_MANAGER=$(jq -er '.contracts.positionManager.address' deployments/robinhood-chain-4663.json)
POOL_ID=$(create_public_pool "$STAKING_TOKEN" "$WETH_ADDRESS" "$OWNER" 211 attach-primary)
WRONG_POOL_ID=$(create_public_pool "$STAKING_TOKEN" "$WETH_ADDRESS" "$OWNER" 212 attach-wrong 500 10)

if [[ "${WETH_ADDRESS,,}" < "${STAKING_TOKEN,,}" ]]; then
    CURRENCY0=$WETH_ADDRESS
    CURRENCY1=$STAKING_TOKEN
else
    CURRENCY0=$STAKING_TOKEN
    CURRENCY1=$WETH_ADDRESS
fi
POOL_KEY="($CURRENCY0,$CURRENCY1,3000,60,$STATICS_SWAP_FEE_HOOK_ADDRESS)"

# Register a permissioned venue solely to prove its PoolId cannot enter the
# public range-gauge attachment path.
cast send "$STATICS_DEFAULT_VENUE_CONTROLLER_FACTORY" 'createController()(address)' \
    --private-key "$OWNER_KEY" --rpc-url "$RPC_URL" --legacy --json \
    >"$RUN_DIR/attach-create-controller.json"
CONTROLLER_TOPIC=$(cast keccak 'VenueControllerCreated(address,address)')
CONTROLLER=$(jq -r --arg topic "${CONTROLLER_TOPIC,,}" '
    .logs[] | select((.topics[0] | ascii_downcase) == $topic) | .topics[2] | "0x" + .[-40:]
' "$RUN_DIR/attach-create-controller.json")
PERMISSIONED_DEADLINE=$(( $(cast block latest --field timestamp --rpc-url "$RPC_URL") + 2592000 ))
ECONOMICS='(50,0,(8000,1000,1000,0))'
AGREEMENT=$(cast keccak 'phase-one-attach-permissioned-boundary')
PERMISSIONED_PARAMS="($STAKING_TOKEN,$WETH_ADDRESS,3000,60,79228162514264337593543950336,$OWNER,$CONTROLLER,$ECONOMICS,211,$PERMISSIONED_DEADLINE,$AGREEMENT)"
PERMISSIONED_QUOTE=$(cast call "$STATICS_DIAMOND_ADDRESS" \
    'quotePermissionedPool((address,address,uint24,int24,uint160,address,address,(uint16,uint8,(uint16,uint16,uint16,uint16)),uint256,uint256,bytes32))(((address,address,uint24,int24,address),bytes32,uint160,bytes32))' \
    "$PERMISSIONED_PARAMS" --rpc-url "$RPC_URL" --json)
PERMISSIONED_POOL_ID=$(jq -r '.[0][1]' <<<"$PERMISSIONED_QUOTE")
PERMISSIONED_DIGEST=$(jq -r '.[0][3]' <<<"$PERMISSIONED_QUOTE")
PERMISSIONED_AUTH=$(cast wallet sign --no-hash "$PERMISSIONED_DIGEST" --private-key "$OWNER_KEY")
PERMISSIONED_CREATE=$(cast calldata \
    'createPermissionedPool((address,address,uint24,int24,uint160,address,address,(uint16,uint8,(uint16,uint16,uint16,uint16)),uint256,uint256,bytes32),bytes)' \
    "$PERMISSIONED_PARAMS" "$PERMISSIONED_AUTH")
timelock_call "$STATICS_DIAMOND_ADDRESS" 0 "$PERMISSIONED_CREATE" attach-permissioned-create

acquire_genesis_statics "$OWNER_INDEX" 4000000000000000000 attach-owner >/dev/null
wrap_weth "$OWNER_INDEX" 150000000000000000000 attach-owner
for asset in "$CURRENCY0" "$CURRENCY1"; do
    cast send "$asset" 'approve(address,uint256)' "$STATICS_DIAMOND_ADDRESS" "$(cast max-uint)" \
        --private-key "$OWNER_KEY" --rpc-url "$RPC_URL" --legacy --json \
        >"$RUN_DIR/attach-diamond-approve-${asset,,}.json"
    approve_permit2_spender "$OWNER_INDEX" "$asset" "$POSITION_MANAGER" "attach-posm-${asset,,}"
done

POSITION_ID=$(cast call "$STATICS_DIAMOND_ADDRESS" 'nextPositionId()(uint256)' --rpc-url "$RPC_URL" | awk '{print $1}')
cast send "$STATICS_DIAMOND_ADDRESS" 'createPosition(address)(uint256)' "$OWNER" \
    --value "$POSITION_FEE" --private-key "$OWNER_KEY" --rpc-url "$RPC_URL" --legacy --json \
    >"$RUN_DIR/attach-create-position.json"
SECOND_POSITION=$(cast call "$STATICS_DIAMOND_ADDRESS" 'nextPositionId()(uint256)' --rpc-url "$RPC_URL" | awk '{print $1}')
cast send "$STATICS_DIAMOND_ADDRESS" 'createPosition(address)(uint256)' "$OWNER" \
    --value "$POSITION_FEE" --private-key "$OWNER_KEY" --rpc-url "$RPC_URL" --legacy --json \
    >"$RUN_DIR/attach-create-second-position.json"

POSM_TOKEN_ID=$(cast call "$POSITION_MANAGER" 'nextTokenId()(uint256)' --rpc-url "$RPC_URL" | awk '{print $1}')
MINT_PARAM=$(cast abi-encode \
    'f((address,address,uint24,int24,address),int24,int24,uint256,uint128,uint128,address,bytes)' \
    "$POOL_KEY" 600 1200 100000000000000000000 \
    90000000000000000000 90000000000000000000 "$OWNER" 0x)
SETTLE_PARAM=$(cast abi-encode 'f(address,address)' "$CURRENCY0" "$CURRENCY1")
MINT_PLAN=$(cast abi-encode 'f(bytes,bytes[])' 0x020d "[$MINT_PARAM,$SETTLE_PARAM]")
DEADLINE=$(( $(cast block latest --field timestamp --rpc-url "$RPC_URL") + 86400 ))
cast send "$POSITION_MANAGER" 'modifyLiquidities(bytes,uint256)' "$MINT_PLAN" "$DEADLINE" \
    --private-key "$OWNER_KEY" --rpc-url "$RPC_URL" --gas-limit 3000000 --legacy --json \
    >"$RUN_DIR/attach-mint-external-posm.json"
assert_eq "$(cast call "$POSITION_MANAGER" 'ownerOf(uint256)(address)' "$POSM_TOKEN_ID" --rpc-url "$RPC_URL")" \
    "$OWNER" "external POSM owner"

# Mint a second real v4 position and deliberately transfer it into the
# liquidity manager without a PositionNFT binding. Only timelocked governance
# may recover this otherwise-stranded NFT, and recovery must preserve the NFT
# rather than treating it as protocol POL or user-managed gauge state.
RECOVERY_POSM_TOKEN_ID=$(cast call "$POSITION_MANAGER" 'nextTokenId()(uint256)' --rpc-url "$RPC_URL" | awk '{print $1}')
RECOVERY_MINT_PARAM=$(cast abi-encode \
    'f((address,address,uint24,int24,address),int24,int24,uint256,uint128,uint128,address,bytes)' \
    "$POOL_KEY" -600 600 1000000000000000000 \
    5000000000000000000 5000000000000000000 "$OWNER" 0x)
RECOVERY_MINT_PLAN=$(cast abi-encode 'f(bytes,bytes[])' 0x020d "[$RECOVERY_MINT_PARAM,$SETTLE_PARAM]")
cast send "$POSITION_MANAGER" 'modifyLiquidities(bytes,uint256)' "$RECOVERY_MINT_PLAN" "$DEADLINE" \
    --private-key "$OWNER_KEY" --rpc-url "$RPC_URL" --gas-limit 3000000 --legacy --json \
    >"$RUN_DIR/attach-mint-recovery-posm.json"
cast send "$POSITION_MANAGER" 'transferFrom(address,address,uint256)' \
    "$OWNER" "$STATICS_LIQUIDITY_MANAGER_ADDRESS" "$RECOVERY_POSM_TOKEN_ID" \
    --private-key "$OWNER_KEY" --rpc-url "$RPC_URL" --legacy --json \
    >"$RUN_DIR/attach-strand-recovery-posm.json"
assert_eq "$(cast call "$POSITION_MANAGER" 'ownerOf(uint256)(address)' \
    "$RECOVERY_POSM_TOKEN_ID" --rpc-url "$RPC_URL")" "$STATICS_LIQUIDITY_MANAGER_ADDRESS" \
    "unbound POSM held by liquidity manager"
expect_call_revert "non-governance unbound POSM recovery" \
    cast call "$STATICS_DIAMOND_ADDRESS" 'recoverUnboundPosm(address,uint256,address)' \
    "$STATICS_LIQUIDITY_MANAGER_ADDRESS" "$RECOVERY_POSM_TOKEN_ID" "$OWNER" \
    --from "$OWNER" --rpc-url "$RPC_URL" >/dev/null
RECOVERY_CALLDATA=$(cast calldata 'recoverUnboundPosm(address,uint256,address)' \
    "$STATICS_LIQUIDITY_MANAGER_ADDRESS" "$RECOVERY_POSM_TOKEN_ID" "$OWNER")
timelock_call "$STATICS_DIAMOND_ADDRESS" 0 "$RECOVERY_CALLDATA" attach-recover-unbound-posm
assert_eq "$(cast call "$POSITION_MANAGER" 'ownerOf(uint256)(address)' \
    "$RECOVERY_POSM_TOKEN_ID" --rpc-url "$RPC_URL")" "$OWNER" \
    "governance recovered unbound POSM"

# A PositionNFT operator controls the financial account but cannot take a POSM
# owned by somebody else. Pool-kind and PoolId checks also precede any transfer.
cast send "$STATICS_DIAMOND_ADDRESS" 'approve(address,uint256)' "$OPERATOR" "$POSITION_ID" \
    --private-key "$OWNER_KEY" --rpc-url "$RPC_URL" --legacy --json >"$RUN_DIR/attach-pnft-approve.json"
expect_call_revert "PNFT operator cannot steal POSM" \
    cast call "$STATICS_DIAMOND_ADDRESS" 'attachLiquidity(uint256,bytes32,uint256)((uint256,uint128,uint256,uint256,uint256,uint256))' \
    "$POSITION_ID" "$POOL_ID" "$POSM_TOKEN_ID" --from "$OPERATOR" --rpc-url "$RPC_URL" >/dev/null
expect_call_revert "wrong public PoolId attachment" \
    cast call "$STATICS_DIAMOND_ADDRESS" 'attachLiquidity(uint256,bytes32,uint256)((uint256,uint128,uint256,uint256,uint256,uint256))' \
    "$POSITION_ID" "$WRONG_POOL_ID" "$POSM_TOKEN_ID" --from "$OWNER" --rpc-url "$RPC_URL" >/dev/null
expect_call_revert "permissioned PoolId attachment" \
    cast call "$STATICS_DIAMOND_ADDRESS" 'attachLiquidity(uint256,bytes32,uint256)((uint256,uint128,uint256,uint256,uint256,uint256))' \
    "$POSITION_ID" "$PERMISSIONED_POOL_ID" "$POSM_TOKEN_ID" --from "$OWNER" --rpc-url "$RPC_URL" >/dev/null

cast send "$POSITION_MANAGER" 'approve(address,uint256)' "$STATICS_LIQUIDITY_MANAGER_ADDRESS" "$POSM_TOKEN_ID" \
    --private-key "$OWNER_KEY" --rpc-url "$RPC_URL" --legacy --json >"$RUN_DIR/attach-posm-approve.json"
cast send "$STATICS_DIAMOND_ADDRESS" \
    'attachLiquidity(uint256,bytes32,uint256)((uint256,uint128,uint256,uint256,uint256,uint256))' \
    "$POSITION_ID" "$POOL_ID" "$POSM_TOKEN_ID" --private-key "$OWNER_KEY" \
    --rpc-url "$RPC_URL" --gas-limit 3000000 --legacy --json >"$RUN_DIR/attach-valid.json"
assert_eq "$(cast call "$POSITION_MANAGER" 'ownerOf(uint256)(address)' "$POSM_TOKEN_ID" --rpc-url "$RPC_URL")" \
    "$STATICS_LIQUIDITY_MANAGER_ADDRESS" "attached POSM custody"
expect_call_revert "duplicate attached leg" \
    cast call "$STATICS_DIAMOND_ADDRESS" 'attachLiquidity(uint256,bytes32,uint256)((uint256,uint128,uint256,uint256,uint256,uint256))' \
    "$POSITION_ID" "$POOL_ID" "$POSM_TOKEN_ID" --from "$OWNER" --rpc-url "$RPC_URL" >/dev/null
expect_call_revert "bound POSM cannot use unbound recovery" \
    cast call "$STATICS_DIAMOND_ADDRESS" 'recoverUnboundPosm(address,uint256,address)' \
    "$STATICS_LIQUIDITY_MANAGER_ADDRESS" "$POSM_TOKEN_ID" "$OWNER" \
    --from "$STATICS_TIMELOCK_ADDRESS" --rpc-url "$RPC_URL" >/dev/null

GAUGE=$(cast call "$STATICS_DIAMOND_ADDRESS" \
    'gaugePool(bytes32)((bool,bool,uint40,int24,uint128,uint64,uint64))' "$POOL_ID" --rpc-url "$RPC_URL" --json)
assert_eq "$(jq -r '.[0][4]' <<<"$GAUGE")" 0 "out-of-range attachment has zero active weight"

# The attached position follows the complete managed lifecycle.
DEADLINE=$(( $(cast block latest --field timestamp --rpc-url "$RPC_URL") + 86400 ))
cast send "$STATICS_DIAMOND_ADDRESS" \
    'increaseLiquidity(uint256,bytes32,(uint128,uint256,uint256,uint256))((uint256,uint128,uint256,uint256,uint256,uint256))' \
    "$POSITION_ID" "$POOL_ID" "(1000000000000000000,20000000000000000000,20000000000000000000,$DEADLINE)" \
    --private-key "$OWNER_KEY" --rpc-url "$RPC_URL" --legacy --json >"$RUN_DIR/attach-increase.json"
cast send "$STATICS_DIAMOND_ADDRESS" \
    'decreaseLiquidity(uint256,bytes32,(uint128,uint256,uint256,uint256))((uint256,uint128,uint256,uint256,uint256,uint256))' \
    "$POSITION_ID" "$POOL_ID" "(1000000000000000000,0,0,$DEADLINE)" \
    --private-key "$OWNER_KEY" --rpc-url "$RPC_URL" --legacy --json >"$RUN_DIR/attach-decrease.json"
cast send "$STATICS_DIAMOND_ADDRESS" \
    'rebalanceLiquidity(uint256,bytes32,(int24,int24,uint128,uint256,uint256,uint256,uint256,uint256))((uint256,uint128,uint256,uint256,uint256,uint256))' \
    "$POSITION_ID" "$POOL_ID" "(-1200,1200,100000000000000000000,50000000000000000000,50000000000000000000,0,0,$DEADLINE)" \
    --private-key "$OWNER_KEY" --rpc-url "$RPC_URL" --gas-limit 3000000 --legacy --json \
    >"$RUN_DIR/attach-rebalance.json"
GAUGE=$(cast call "$STATICS_DIAMOND_ADDRESS" \
    'gaugePool(bytes32)((bool,bool,uint40,int24,uint128,uint64,uint64))' "$POOL_ID" --rpc-url "$RPC_URL" --json)
assert_gt "$(jq -r '.[0][4]' <<<"$GAUGE")" 0 "rebalanced attachment active weight"

ALLOW_CALLDATA=$(cast calldata 'setGaugeRewardAssetAllowed(address,bool)' "$WETH_ADDRESS" true)
timelock_call "$STATICS_DIAMOND_ADDRESS" 0 "$ALLOW_CALLDATA" attach-allow-weth
cast send "$STATICS_DIAMOND_ADDRESS" 'appendPoolRewardAsset(bytes32,address)(uint8)' \
    "$POOL_ID" "$WETH_ADDRESS" --private-key "$OWNER_KEY" --rpc-url "$RPC_URL" --legacy --json \
    >"$RUN_DIR/attach-reward-slot.json"
FUND_AMOUNT=7000000000000000000
cast send "$WETH_ADDRESS" 'approve(address,uint256)' "$STATICS_DIAMOND_ADDRESS" "$FUND_AMOUNT" \
    --private-key "$OWNER_KEY" --rpc-url "$RPC_URL" --legacy --json >"$RUN_DIR/attach-reward-approve.json"
cast send "$STATICS_DIAMOND_ADDRESS" 'fundPoolReward(bytes32,uint8,uint256,uint40,uint16)(uint256)' \
    "$POOL_ID" 1 "$FUND_AMOUNT" 604800 0 --private-key "$OWNER_KEY" --rpc-url "$RPC_URL" --legacy --json \
    >"$RUN_DIR/attach-reward-fund.json"
rpc_warp_by 86400
cast send "$STATICS_DIAMOND_ADDRESS" 'checkpointGaugePool(bytes32)(uint256,uint256)' "$POOL_ID" \
    --private-key "$(anvil_private_key "$OPERATOR_INDEX")" --rpc-url "$RPC_URL" --legacy --json \
    >"$RUN_DIR/attach-reward-checkpoint.json"
REWARD=$(cast call "$STATICS_DIAMOND_ADDRESS" \
    'previewLpRewards(uint256,bytes32)((uint8,address[5],uint256[5]))' \
    "$POSITION_ID" "$POOL_ID" --rpc-url "$RPC_URL" --json)
assert_gt "$(jq -r '.[0][2][1]' <<<"$REWARD")" 0 "attached LP direct reward"

wrap_weth "$TRADER_INDEX" 5000000000000000000 attach-trader
acquire_genesis_statics "$TRADER_INDEX" 1000000000000000000 attach-trader >/dev/null
v4_swap_exact_in "$TRADER_INDEX" "$CURRENCY0" "$CURRENCY1" 3000 60 \
    "$STATICS_SWAP_FEE_HOOK_ADDRESS" true 500000000000000000 attach-swap0
v4_swap_exact_in "$TRADER_INDEX" "$CURRENCY0" "$CURRENCY1" 3000 60 \
    "$STATICS_SWAP_FEE_HOOK_ADDRESS" false 500000000000000000 attach-swap1
DEADLINE=$(( $(cast block latest --field timestamp --rpc-url "$RPC_URL") + 86400 ))
cast send "$STATICS_DIAMOND_ADDRESS" \
    'collectNativeFees(uint256,bytes32,uint256,uint256,uint256)((uint256,uint128,uint256,uint256,uint256,uint256))' \
    "$POSITION_ID" "$POOL_ID" 0 0 "$DEADLINE" --private-key "$OWNER_KEY" \
    --rpc-url "$RPC_URL" --legacy --json >"$RUN_DIR/attach-collect-native.json"
cast send "$STATICS_DIAMOND_ADDRESS" \
    'claimLpRewards(uint256,bytes32,uint8[],uint256[],address)(uint256[])' \
    "$POSITION_ID" "$POOL_ID" '[1]' '[0]' "$OWNER" --private-key "$OWNER_KEY" \
    --rpc-url "$RPC_URL" --legacy --json >"$RUN_DIR/attach-claim-reward.json"
cast send "$STATICS_DIAMOND_ADDRESS" \
    'exitLiquidity(uint256,bytes32,uint256,uint256,uint256)((uint256,uint128,uint256,uint256,uint256,uint256))' \
    "$POSITION_ID" "$POOL_ID" 0 0 "$DEADLINE" --private-key "$OWNER_KEY" \
    --rpc-url "$RPC_URL" --gas-limit 3000000 --legacy --json >"$RUN_DIR/attach-exit.json"
# If Anvil advances the exit beyond the pre-exit claim timestamp, the exit
# checkpoints one final entitlement. Prove that obligation is real and resolve
# it; a same-timestamp exit can retire the leg immediately.
AFTER_EXIT_LEGS=$(cast call "$STATICS_DIAMOND_ADDRESS" 'activeLegCount(uint256)(uint256)' \
    "$POSITION_ID" --rpc-url "$RPC_URL" | awk '{print $1}')
if [[ "$AFTER_EXIT_LEGS" == 1 ]]; then
    EXIT_REWARD=$(cast call "$STATICS_DIAMOND_ADDRESS" \
        'previewLpRewards(uint256,bytes32)((uint8,address[5],uint256[5]))' \
        "$POSITION_ID" "$POOL_ID" --rpc-url "$RPC_URL" --json | jq -r '.[0][2][1]')
    assert_gt "$EXIT_REWARD" 0 "attached LP final exit reward"
    cast send "$STATICS_DIAMOND_ADDRESS" \
        'claimLpRewards(uint256,bytes32,uint8[],uint256[],address)(uint256[])' \
        "$POSITION_ID" "$POOL_ID" '[1]' '[0]' "$OWNER" --private-key "$OWNER_KEY" \
        --rpc-url "$RPC_URL" --legacy --json >"$RUN_DIR/attach-exit-residual-claim.json"
fi
assert_eq "$(cast call "$STATICS_DIAMOND_ADDRESS" 'activeLegCount(uint256)(uint256)' \
    "$POSITION_ID" --rpc-url "$RPC_URL" | awk '{print $1}')" 0 "attached leg exited"

assert_phase_one_solvency external-posm "$CURRENCY0" "$CURRENCY1"
record_result range-gauge external-posm-authority pass "$POSM_TOKEN_ID"
record_result range-gauge external-posm-pool-boundaries pass "$WRONG_POOL_ID and $PERMISSIONED_POOL_ID"
record_result range-gauge external-posm-lifecycle pass "$POSITION_ID"
record_result range-gauge unbound-posm-recovery pass "$RECOVERY_POSM_TOKEN_ID"
note "external POSM attachment and managed lifecycle scenarios passed"
