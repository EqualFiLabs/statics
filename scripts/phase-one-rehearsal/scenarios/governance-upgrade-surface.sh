#!/usr/bin/env bash

set -Eeuo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

require_commands cast forge jq
load_current_run
require_local_chain
reset_to_base
cd_repo

DEPLOYER_KEY=$(anvil_private_key 0)
OUTSIDER=$(anvil_address 14)
NEW_OWNER=$(anvil_address 19)
ZERO_ADDRESS=0x0000000000000000000000000000000000000000

BYTECODE=$(forge inspect \
    scripts/phase-one-rehearsal/helpers/PhaseOneRehearsalFacet.sol:PhaseOneRehearsalFacet bytecode)
cast send --private-key "$DEPLOYER_KEY" --rpc-url "$RPC_URL" --gas-limit 1000000 \
    --legacy --json --create "$BYTECODE" >"$RUN_DIR/governance-upgrade-helper-deploy.json"
HELPER=$(jq -er '.contractAddress' "$RUN_DIR/governance-upgrade-helper-deploy.json")
assert_nonzero_address "$HELPER" "rehearsal facet"

PING_SELECTOR=$(cast sig 'rehearsalPing()')
ADD_CALLDATA=$(cast calldata 'diamondCut((address,uint8,bytes4[])[],address,bytes)' \
    "[($HELPER,0,[$PING_SELECTOR])]" "$ZERO_ADDRESS" 0x)
expect_call_revert "unauthorized Diamond cut" \
    cast call "$STATICS_DIAMOND_ADDRESS" 'diamondCut((address,uint8,bytes4[])[],address,bytes)' \
    "[($HELPER,0,[$PING_SELECTOR])]" "$ZERO_ADDRESS" 0x --from "$OUTSIDER" \
    --rpc-url "$RPC_URL" >/dev/null

timelock_call "$STATICS_DIAMOND_ADDRESS" 0 "$ADD_CALLDATA" governance-add-rehearsal-facet
assert_eq "$(cast call "$STATICS_DIAMOND_ADDRESS" 'facetAddress(bytes4)(address)' \
    "$PING_SELECTOR" --rpc-url "$RPC_URL")" "$HELPER" "added rehearsal selector route"
assert_eq "$(cast call "$STATICS_DIAMOND_ADDRESS" 'rehearsalPing()(bytes32)' --rpc-url "$RPC_URL")" \
    "$(cast keccak 'statics-phase-one-rehearsal')" "rehearsal facet invocation"

REMOVE_CALLDATA=$(cast calldata 'diamondCut((address,uint8,bytes4[])[],address,bytes)' \
    "[($ZERO_ADDRESS,2,[$PING_SELECTOR])]" "$ZERO_ADDRESS" 0x)
timelock_call "$STATICS_DIAMOND_ADDRESS" 0 "$REMOVE_CALLDATA" governance-remove-rehearsal-facet
assert_eq "$(cast call "$STATICS_DIAMOND_ADDRESS" 'facetAddress(bytes4)(address)' \
    "$PING_SELECTOR" --rpc-url "$RPC_URL")" "$ZERO_ADDRESS" "removed rehearsal selector route"
expect_call_revert "removed rehearsal selector invocation" \
    cast call "$STATICS_DIAMOND_ADDRESS" 'rehearsalPing()(bytes32)' --rpc-url "$RPC_URL" >/dev/null

assert_eq "$(cast call "$STATICS_DIAMOND_ADDRESS" 'owner()(address)' --rpc-url "$RPC_URL")" \
    "$STATICS_TIMELOCK_ADDRESS" "pre-transfer Diamond owner"
expect_call_revert "unauthorized Diamond ownership transfer" \
    cast call "$STATICS_DIAMOND_ADDRESS" 'transferOwnership(address)' "$NEW_OWNER" \
    --from "$OUTSIDER" --rpc-url "$RPC_URL" >/dev/null
timelock_call "$STATICS_DIAMOND_ADDRESS" 0 \
    "$(cast calldata 'transferOwnership(address)' "$NEW_OWNER")" governance-transfer-diamond-ownership
assert_eq "$(cast call "$STATICS_DIAMOND_ADDRESS" 'owner()(address)' --rpc-url "$RPC_URL")" \
    "$NEW_OWNER" "timelocked Diamond ownership transfer"

record_result governance diamond-upgrade-surface pass "add, invoke, and remove $PING_SELECTOR"
record_result governance diamond-ownership-surface pass "$STATICS_TIMELOCK_ADDRESS to $NEW_OWNER"
note "live Diamond cut and ownership governance surfaces passed"
