#!/usr/bin/env bash

set -Eeuo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

require_commands cast jq awk
load_current_run
require_local_chain
reset_to_base

GUARDIAN_KEY=$(anvil_private_key 1)
OUTSIDER=$(anvil_address 16)
POOL_CREATOR=$(anvil_address 17)
POOL_ID=$(create_public_pool "$STAKING_TOKEN" "$WETH_ADDRESS" "$POOL_CREATOR" 4 governance)

expect_call_revert "outsider pause" \
    cast call "$STATICS_DIAMOND_ADDRESS" 'pause(uint256)' 32 --from "$OUTSIDER" --rpc-url "$RPC_URL" \
    >"$RUN_DIR/governance-outsider-pause-revert.txt"
cast send "$STATICS_DIAMOND_ADDRESS" 'pause(uint256)' 32 \
    --private-key "$GUARDIAN_KEY" --rpc-url "$RPC_URL" --legacy --json >"$RUN_DIR/governance-pause-liquidity.json"
assert_eq "$(cast call "$STATICS_DIAMOND_ADDRESS" 'isPaused(uint256)(bool)' 32 --rpc-url "$RPC_URL")" \
    true \
    "guardian liquidity pause"
expect_call_revert "guardian unpause" \
    cast call "$STATICS_DIAMOND_ADDRESS" 'unpause(uint256)' 32 --from "$GUARDIAN" --rpc-url "$RPC_URL" \
    >"$RUN_DIR/governance-guardian-unpause-revert.txt"
UNPAUSE_CALLDATA=$(cast calldata 'unpause(uint256)' 32)
timelock_call "$STATICS_DIAMOND_ADDRESS" 0 "$UNPAUSE_CALLDATA" governance-unpause-liquidity
assert_eq "$(cast call "$STATICS_DIAMOND_ADDRESS" 'isPaused(uint256)(bool)' 32 --rpc-url "$RPC_URL")" \
    false \
    "timelock liquidity unpause"

cast send "$STATICS_DIAMOND_ADDRESS" 'quarantineProtocolPool(bytes32)' "$POOL_ID" \
    --private-key "$GUARDIAN_KEY" --rpc-url "$RPC_URL" --legacy --json \
    >"$RUN_DIR/governance-quarantine-pool.json"
assert_eq \
    "$(cast call "$STATICS_DIAMOND_ADDRESS" 'protocolPoolSwapsBlocked(bytes32)(bool)' "$POOL_ID" --rpc-url "$RPC_URL")" \
    true \
    "pool quarantine"
RELEASE_CALLDATA=$(cast calldata 'releaseProtocolPoolQuarantine(bytes32)' "$POOL_ID")
timelock_call "$STATICS_DIAMOND_ADDRESS" 0 "$RELEASE_CALLDATA" governance-release-pool
assert_eq \
    "$(cast call "$STATICS_DIAMOND_ADDRESS" 'protocolPoolSwapsBlocked(bytes32)(bool)' "$POOL_ID" --rpc-url "$RPC_URL")" \
    false \
    "pool quarantine release"

cast send "$STATICS_DIAMOND_ADDRESS" 'pauseProtocolSwaps()' \
    --private-key "$GUARDIAN_KEY" --rpc-url "$RPC_URL" --legacy --json \
    >"$RUN_DIR/governance-pause-public-swaps.json"
assert_eq "$(cast call "$STATICS_DIAMOND_ADDRESS" 'protocolSwapsPaused()(bool)' --rpc-url "$RPC_URL")" \
    true \
    "global public swap pause"
assert_eq \
    "$(cast call "$STATICS_DIAMOND_ADDRESS" 'protocolPoolSwapsBlocked(bytes32)(bool)' "$POOL_ID" --rpc-url "$RPC_URL")" \
    true \
    "global pool swap block"
UNPAUSE_SWAPS_CALLDATA=$(cast calldata 'unpauseProtocolSwaps()')
timelock_call "$STATICS_DIAMOND_ADDRESS" 0 "$UNPAUSE_SWAPS_CALLDATA" governance-unpause-public-swaps
assert_eq "$(cast call "$STATICS_DIAMOND_ADDRESS" 'protocolSwapsPaused()(bool)' --rpc-url "$RPC_URL")" \
    false \
    "global public swap unpause"

record_result governance guardian-pause pass "liquidity action"
record_result governance pool-quarantine pass "$POOL_ID"
record_result governance global-public-swap-pause pass "$POOL_ID"
note "guardian and timelock governance scenarios passed"
