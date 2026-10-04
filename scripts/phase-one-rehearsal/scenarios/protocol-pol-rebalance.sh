#!/usr/bin/env bash

set -Eeuo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
require_commands cast jq awk bc python3
load_current_run
require_local_chain
reset_to_base
cd_repo

CREATOR_INDEX=13
TRADER_INDEX=14
CREATOR=$(anvil_address "$CREATOR_INDEX")
CREATOR_KEY=$(anvil_private_key "$CREATOR_INDEX")
TRADER=$(anvil_address "$TRADER_INDEX")
DEPLOYER=$(anvil_address 0)
POSITION_MANAGER=$(jq -er '.contracts.positionManager.address' deployments/robinhood-chain-4663.json)
POOL_MANAGER=$(jq -er '.contracts.poolManager.address' deployments/robinhood-chain-4663.json)
STATE_VIEW=$(jq -er '.contracts.stateView.address' deployments/robinhood-chain-4663.json)
PERMIT2=$(jq -er '.contracts.permit2.address' deployments/robinhood-chain-4663.json)
if [[ "${WETH_ADDRESS,,}" < "${STAKING_TOKEN,,}" ]]; then
    CURRENCY0=$WETH_ADDRESS
    CURRENCY1=$STAKING_TOKEN
else
    CURRENCY0=$STAKING_TOKEN
    CURRENCY1=$WETH_ADDRESS
fi

# Acquire live Genesis tokens and use real managed user liquidity. No storage,
# reserve or token balance injection supplies the POL book.
acquire_genesis_statics "$CREATOR_INDEX" 4000000000000000000 pol-rebalance-lp >/dev/null
wrap_weth "$CREATOR_INDEX" 150000000000000000000 pol-rebalance-lp
acquire_genesis_statics "$TRADER_INDEX" 4000000000000000000 pol-rebalance-trader >/dev/null
wrap_weth "$TRADER_INDEX" 100000000000000000000 pol-rebalance-trader
for asset in "$CURRENCY0" "$CURRENCY1"; do
    cast send "$asset" 'approve(address,uint256)' "$STATICS_DIAMOND_ADDRESS" "$(cast max-uint)" \
        --private-key "$CREATOR_KEY" --rpc-url "$RPC_URL" --legacy --json \
        >"$RUN_DIR/pol-rebalance-approve-${asset,,}.json"
done
POOL_ID=$(create_public_pool "$STAKING_TOKEN" "$WETH_ADDRESS" "$CREATOR" 403 pol-rebalance)
FOREIGN_POOL_ID=$(create_public_pool "$STAKING_TOKEN" "$WETH_ADDRESS" "$CREATOR" 404 pol-rebalance-foreign 10000 120)
INACTIVE_POOL_ID=$(create_public_pool "$STAKING_TOKEN" "$WETH_ADDRESS" "$CREATOR" 405 pol-rebalance-inactive 500 10)

for label in primary foreign; do
    pool=$POOL_ID
    fee=3000
    spacing=60
    if [[ "$label" == foreign ]]; then pool=$FOREIGN_POOL_ID; fee=10000; spacing=120; fi
    position=$(cast call "$STATICS_DIAMOND_ADDRESS" 'nextPositionId()(uint256)' --rpc-url "$RPC_URL" | awk '{print $1}')
    cast send "$STATICS_DIAMOND_ADDRESS" 'createPosition(address)(uint256)' "$CREATOR" \
        --value 1000000000000000 --private-key "$CREATOR_KEY" --rpc-url "$RPC_URL" --legacy --json \
        >"$RUN_DIR/pol-rebalance-$label-user-position.json"
    [[ "$label" != primary ]] || USER_POSITION=$position
    deadline=$(( $(cast block latest --field timestamp --rpc-url "$RPC_URL") + 3600 ))
    cast send "$STATICS_DIAMOND_ADDRESS" \
        'provideLiquidity(uint256,(bytes32,int24,int24,uint128,uint256,uint256,uint256))((uint256,uint128,uint256,uint256,uint256,uint256))' \
        "$position" "($pool,-1200,1200,100000000000000000000,90000000000000000000,90000000000000000000,$deadline)" \
        --private-key "$CREATOR_KEY" --rpc-url "$RPC_URL" --legacy --json \
        >"$RUN_DIR/pol-rebalance-$label-user-liquidity.json"
    cast send "$STATICS_DIAMOND_ADDRESS" 'activateProtocolPoolPol(bytes32)' "$pool" \
        --value 100000000000000000 --private-key "$CREATOR_KEY" --rpc-url "$RPC_URL" --legacy --json \
        >"$RUN_DIR/pol-rebalance-$label-activation.json"
    for zero_for_one in true false; do
        v4_swap_exact_in "$TRADER_INDEX" "$CURRENCY0" "$CURRENCY1" "$fee" "$spacing" \
            "$STATICS_SWAP_FEE_HOOK_ADDRESS" "$zero_for_one" 1000000000000000000 "pol-rebalance-$label-fund-$zero_for_one"
    done
    for asset in "$CURRENCY0" "$CURRENCY1"; do
        cast send "$STATICS_DIAMOND_ADDRESS" 'settleProtocolPoolPol(bytes32,address,uint256)(uint256)' "$pool" "$asset" 0 \
            --private-key "$(anvil_private_key 15)" --rpc-url "$RPC_URL" --legacy --json \
            >"$RUN_DIR/pol-rebalance-$label-settle-${asset,,}.json"
    done
done

export RPC_URL RUN_DIR STATICS_DIAMOND_ADDRESS STATICS_SWAP_FEE_HOOK_ADDRESS
export STATICS_LIQUIDITY_MANAGER_ADDRESS PHASE_ONE_OUT POL_OPERATOR GUARDIAN
export POOL_ID FOREIGN_POOL_ID INACTIVE_POOL_ID CURRENCY0 CURRENCY1
export POSITION_MANAGER POOL_MANAGER STATE_VIEW PERMIT2 CREATOR TRADER DEPLOYER USER_POSITION
export REHEARSAL_SCRIPT_DIR="$REHEARSAL_DIR"
python3 "$REHEARSAL_DIR/helpers/pol-rebalance.py"
assert_phase_one_solvency pol-rebalance-terminal "$CURRENCY0" "$CURRENCY1"
note "atomic POL success and mined adversarial rollback scenarios passed"
