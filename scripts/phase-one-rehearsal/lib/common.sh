#!/usr/bin/env bash

set -Eeuo pipefail

export FOUNDRY_DISABLE_NIGHTLY_WARNING=1

REHEARSAL_LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REHEARSAL_DIR=$(cd "$REHEARSAL_LIB_DIR/.." && pwd)
REPO_ROOT=$(cd "$REHEARSAL_DIR/../.." && pwd)
ARTIFACT_ROOT=${STATICS_REHEARSAL_ARTIFACT_ROOT:-"$REPO_ROOT/artifacts/phase-one-rehearsal"}
CURRENT_RUN_FILE="$ARTIFACT_ROOT/current.env"
RPC_URL=${STATICS_REHEARSAL_RPC_URL:-http://127.0.0.1:8545}
ANVIL_MNEMONIC=${STATICS_REHEARSAL_MNEMONIC:-"test test test test test test test test test test test junk"}

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

note() {
    printf '[phase-one-rehearsal] %s\n' "$*"
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

require_commands() {
    local command_name
    for command_name in "$@"; do
        require_command "$command_name"
    done
}

anvil_private_key() {
    cast wallet private-key "$ANVIL_MNEMONIC" "$1"
}

anvil_address() {
    cast wallet address --private-key "$(anvil_private_key "$1")"
}

load_current_run() {
    [[ -f "$CURRENT_RUN_FILE" ]] || fail "no active rehearsal; run start-fork.sh first"
    # The state file is generated exclusively by these scripts and contains no private keys.
    # shellcheck disable=SC1090
    source "$CURRENT_RUN_FILE"
    [[ -n "${RUN_DIR:-}" && -d "$RUN_DIR" ]] || fail "active rehearsal state is invalid"
    [[ -f "$RUN_DIR/state.env" ]] || fail "rehearsal state is missing"
    # shellcheck disable=SC1091
    source "$RUN_DIR/state.env"
}

append_state() {
    local key=$1
    local value=$2
    [[ "$key" =~ ^[A-Z0-9_]+$ ]] || fail "invalid state key: $key"
    printf '%s=%q\n' "$key" "$value" >>"$RUN_DIR/state.env"
    export "$key=$value"
}

label_value() {
    local label=$1
    local log_file=$2
    awk -v expected="$label" '$1 == expected && NF >= 2 { value = $2 } END { print value }' "$log_file"
}

label_next_value() {
    local label=$1
    local log_file=$2
    awk -v expected="$label" '
        $1 == expected { found = 1; next }
        found && NF { print $1; exit }
    ' "$log_file"
}

require_label() {
    local label=$1
    local log_file=$2
    local value
    value=$(label_value "$label" "$log_file")
    [[ -n "$value" ]] || fail "missing $label in $log_file"
    printf '%s\n' "$value"
}

require_next_label() {
    local label=$1
    local log_file=$2
    local value
    value=$(label_next_value "$label" "$log_file")
    [[ -n "$value" ]] || fail "missing value after $label in $log_file"
    printf '%s\n' "$value"
}

require_local_chain() {
    local chain_id
    chain_id=$(cast chain-id --rpc-url "$RPC_URL")
    [[ "$chain_id" == "4663" ]] || fail "expected local chain 4663, found $chain_id"
    cast rpc --rpc-url "$RPC_URL" anvil_nodeInfo >/dev/null
}

rpc_snapshot() {
    cast rpc --rpc-url "$RPC_URL" evm_snapshot | tr -d '"'
}

rpc_revert() {
    local snapshot=$1
    local result
    result=$(cast rpc --rpc-url "$RPC_URL" evm_revert "$snapshot")
    [[ "$result" == "true" ]] || fail "failed to revert snapshot $snapshot"
}

rpc_warp_by() {
    local seconds=$1
    cast rpc --rpc-url "$RPC_URL" evm_increaseTime "$seconds" >/dev/null
    cast rpc --rpc-url "$RPC_URL" anvil_mine 1 >/dev/null
}

rpc_warp_to() {
    local timestamp=$1
    cast rpc --rpc-url "$RPC_URL" evm_setNextBlockTimestamp "$timestamp" >/dev/null
    cast rpc --rpc-url "$RPC_URL" anvil_mine 1 >/dev/null
}

reset_to_base() {
    load_current_run
    [[ -n "${BASE_SNAPSHOT:-}" ]] || fail "base snapshot is unavailable"
    rpc_revert "$BASE_SNAPSHOT"
    append_state BASE_SNAPSHOT "$(rpc_snapshot)"
}

expect_call_revert() {
    local context=$1
    shift
    local output
    if output=$("$@" 2>&1); then
        fail "$context: expected revert, but call succeeded"
    fi
    printf '%s\n' "$output"
}

timelock_call() {
    local target=$1
    local value=$2
    local data=$3
    local label=$4
    local executor_key delay salt
    local predecessor=0x0000000000000000000000000000000000000000000000000000000000000000
    executor_key=$(anvil_private_key 5)
    delay=$(cast call "$STATICS_TIMELOCK_ADDRESS" 'getMinDelay()(uint256)' --rpc-url "$RPC_URL" | awk '{print $1}')
    salt=$(cast keccak "$RUN_ID-$label-$(cast block-number --rpc-url "$RPC_URL")")

    cast send "$STATICS_TIMELOCK_ADDRESS" \
        'schedule(address,uint256,bytes,bytes32,bytes32,uint256)' \
        "$target" "$value" "$data" "$predecessor" "$salt" "$delay" \
        --from "$GOVERNANCE" \
        --unlocked \
        --rpc-url "$RPC_URL" \
        --legacy \
        --json >"$RUN_DIR/timelock-$label-schedule.json"
    rpc_warp_by "$(( delay + 1 ))"
    cast send "$STATICS_TIMELOCK_ADDRESS" \
        'execute(address,uint256,bytes,bytes32,bytes32)' \
        "$target" "$value" "$data" "$predecessor" "$salt" \
        --private-key "$executor_key" \
        --rpc-url "$RPC_URL" \
        --legacy \
        --json >"$RUN_DIR/timelock-$label-execute.json"
}

acquire_genesis_statics() {
    local account_index=$1
    local amount_in=$2
    local label=$3
    local account account_key permit2 universal_router deadline before after delta
    local exact_param settle_param take_param plan
    account=$(anvil_address "$account_index")
    account_key=$(anvil_private_key "$account_index")
    permit2=$(jq -er '.contracts.permit2.address' "$REPO_ROOT/deployments/robinhood-chain-4663.json")
    universal_router=$(jq -er '.contracts.universalRouter.address' "$REPO_ROOT/deployments/robinhood-chain-4663.json")
    before=$(cast call "$STAKING_TOKEN" 'balanceOf(address)(uint256)' "$account" --rpc-url "$RPC_URL" | awk '{print $1}')

    cast send "$WETH_ADDRESS" 'deposit()' \
        --value "$amount_in" \
        --private-key "$account_key" \
        --rpc-url "$RPC_URL" \
        --legacy \
        --json >"$RUN_DIR/$label-wrap.json"
    cast send "$WETH_ADDRESS" 'approve(address,uint256)' "$permit2" "$(cast max-uint)" \
        --private-key "$account_key" \
        --rpc-url "$RPC_URL" \
        --legacy \
        --json >"$RUN_DIR/$label-approve-permit2.json"
    cast send "$permit2" 'approve(address,address,uint160,uint48)' \
        "$WETH_ADDRESS" "$universal_router" "$(cast max-uint uint160)" "$(cast max-uint uint48)" \
        --private-key "$account_key" \
        --rpc-url "$RPC_URL" \
        --legacy \
        --json >"$RUN_DIR/$label-permit2-allowance.json"

    exact_param=$(cast abi-encode \
        'f(((address,address,uint24,int24,address),bool,uint128,uint128,uint256,bytes))' \
        "(($WETH_ADDRESS,$STAKING_TOKEN,$STATICS_DOPPLER_POOL_FEE,$STATICS_DOPPLER_POOL_TICK_SPACING,$STATICS_DOPPLER_POOL_INITIALIZER_ADDRESS),true,$amount_in,0,0,0x)")
    settle_param=$(cast abi-encode 'f(address,uint256)' "$WETH_ADDRESS" "$amount_in")
    take_param=$(cast abi-encode 'f(address,uint256)' "$STAKING_TOKEN" 0)
    plan=$(cast abi-encode 'f(bytes,bytes[])' 0x060c0f "[$exact_param,$settle_param,$take_param]")
    deadline=$(( $(cast block latest --field timestamp --rpc-url "$RPC_URL") + 3600 ))
    cast send "$universal_router" 'execute(bytes,bytes[],uint256)' 0x10 "[$plan]" "$deadline" \
        --private-key "$account_key" \
        --rpc-url "$RPC_URL" \
        --legacy \
        --json >"$RUN_DIR/$label-acquire-statics.json"

    after=$(cast call "$STAKING_TOKEN" 'balanceOf(address)(uint256)' "$account" --rpc-url "$RPC_URL" | awk '{print $1}')
    delta=$(printf '%s - %s\n' "$after" "$before" | bc)
    [[ "$delta" != "0" ]] || fail "$label: Genesis swap produced no STATICS"
    record_result funding "$label" pass "$delta STATICS wei"
    printf '%s\n' "$delta"
}

create_public_pool() {
    local token_a=$1
    local token_b=$2
    local creator=$3
    local nonce=$4
    local label=$5
    local lp_fee=${6:-3000}
    local tick_spacing=${7:-60}
    local deadline params calldata currency0 currency1 encoded pool_id
    deadline=$(( $(cast block latest --field timestamp --rpc-url "$RPC_URL") + 172800 ))
    params="($token_a,$token_b,$lp_fee,$tick_spacing,79228162514264337593543950336,(5,5),$creator,false,$nonce,$deadline)"
    calldata=$(cast calldata \
        'createPool((address,address,uint24,int24,uint160,(uint16,uint16),address,bool,uint256,uint256),bytes)' \
        "$params" 0x)
    timelock_call "$STATICS_DIAMOND_ADDRESS" 0 "$calldata" "$label-create-public-pool"

    if [[ "${token_a,,}" < "${token_b,,}" ]]; then
        currency0=$token_a
        currency1=$token_b
    else
        currency0=$token_b
        currency1=$token_a
    fi
    encoded=$(cast abi-encode 'f(address,address,uint24,int24,address)' \
        "$currency0" "$currency1" "$lp_fee" "$tick_spacing" "$STATICS_SWAP_FEE_HOOK_ADDRESS")
    pool_id=$(cast keccak "$encoded")
    assert_eq \
        "$(cast call "$STATICS_DIAMOND_ADDRESS" 'isProtocolPool(bytes32)(bool)' "$pool_id" --rpc-url "$RPC_URL")" \
        true \
        "$label protocol pool registration"
    record_result pools "$label" pass "$pool_id"
    printf '%s\n' "$pool_id"
}

approve_permit2_spender() {
    local account_index=$1
    local token=$2
    local spender=$3
    local label=$4
    local account_key permit2
    account_key=$(anvil_private_key "$account_index")
    permit2=$(jq -er '.contracts.permit2.address' "$REPO_ROOT/deployments/robinhood-chain-4663.json")
    cast send "$token" 'approve(address,uint256)' "$permit2" "$(cast max-uint)" \
        --private-key "$account_key" --rpc-url "$RPC_URL" --legacy --json \
        >"$RUN_DIR/$label-token-approve.json"
    cast send "$permit2" 'approve(address,address,uint160,uint48)' \
        "$token" "$spender" "$(cast max-uint uint160)" "$(cast max-uint uint48)" \
        --private-key "$account_key" --rpc-url "$RPC_URL" --legacy --json \
        >"$RUN_DIR/$label-permit2-approve.json"
}

wrap_weth() {
    local account_index=$1
    local amount=$2
    local label=$3
    cast send "$WETH_ADDRESS" 'deposit()' \
        --value "$amount" \
        --private-key "$(anvil_private_key "$account_index")" \
        --rpc-url "$RPC_URL" \
        --legacy \
        --json >"$RUN_DIR/$label-wrap-weth.json"
}

v4_swap_exact_in() {
    local account_index=$1
    local currency0=$2
    local currency1=$3
    local fee=$4
    local tick_spacing=$5
    local hook=$6
    local zero_for_one=$7
    local amount_in=$8
    local label=$9
    local account_key permit2 universal_router input_token exact_param settle_param take_param plan deadline
    account_key=$(anvil_private_key "$account_index")
    permit2=$(jq -er '.contracts.permit2.address' "$REPO_ROOT/deployments/robinhood-chain-4663.json")
    universal_router=$(jq -er '.contracts.universalRouter.address' "$REPO_ROOT/deployments/robinhood-chain-4663.json")
    input_token=$currency1
    [[ "$zero_for_one" == "true" ]] && input_token=$currency0
    approve_permit2_spender "$account_index" "$input_token" "$universal_router" "$label-router"

    exact_param=$(cast abi-encode \
        'f(((address,address,uint24,int24,address),bool,uint128,uint128,uint256,bytes))' \
        "(($currency0,$currency1,$fee,$tick_spacing,$hook),$zero_for_one,$amount_in,0,0,0x)")
    settle_param=$(cast abi-encode 'f(address,uint256)' "$input_token" "$amount_in")
    if [[ "$zero_for_one" == "true" ]]; then
        take_param=$(cast abi-encode 'f(address,uint256)' "$currency1" 0)
    else
        take_param=$(cast abi-encode 'f(address,uint256)' "$currency0" 0)
    fi
    plan=$(cast abi-encode 'f(bytes,bytes[])' 0x060c0f "[$exact_param,$settle_param,$take_param]")
    deadline=$(( $(cast block latest --field timestamp --rpc-url "$RPC_URL") + 3600 ))
    cast send "$universal_router" 'execute(bytes,bytes[],uint256)' 0x10 "[$plan]" "$deadline" \
        --private-key "$account_key" \
        --rpc-url "$RPC_URL" \
        --gas-limit 3000000 \
        --legacy \
        --json >"$RUN_DIR/$label-swap.json"
}

v4_swap_exact_out() {
    local account_index=$1
    local currency0=$2
    local currency1=$3
    local fee=$4
    local tick_spacing=$5
    local hook=$6
    local zero_for_one=$7
    local amount_out=$8
    local amount_in_maximum=$9
    local label=${10}
    local account_key permit2 universal_router input_token output_token exact_param settle_param take_param plan deadline
    account_key=$(anvil_private_key "$account_index")
    permit2=$(jq -er '.contracts.permit2.address' "$REPO_ROOT/deployments/robinhood-chain-4663.json")
    universal_router=$(jq -er '.contracts.universalRouter.address' "$REPO_ROOT/deployments/robinhood-chain-4663.json")
    input_token=$currency1
    output_token=$currency0
    if [[ "$zero_for_one" == "true" ]]; then
        input_token=$currency0
        output_token=$currency1
    fi
    approve_permit2_spender "$account_index" "$input_token" "$universal_router" "$label-router"

    exact_param=$(cast abi-encode \
        'f(((address,address,uint24,int24,address),bool,uint128,uint128,uint256,bytes))' \
        "(($currency0,$currency1,$fee,$tick_spacing,$hook),$zero_for_one,$amount_out,$amount_in_maximum,0,0x)")
    settle_param=$(cast abi-encode 'f(address,uint256)' "$input_token" "$amount_in_maximum")
    take_param=$(cast abi-encode 'f(address,uint256)' "$output_token" "$amount_out")
    plan=$(cast abi-encode 'f(bytes,bytes[])' 0x080c0f "[$exact_param,$settle_param,$take_param]")
    deadline=$(( $(cast block latest --field timestamp --rpc-url "$RPC_URL") + 3600 ))
    cast send "$universal_router" 'execute(bytes,bytes[],uint256)' 0x10 "[$plan]" "$deadline" \
        --private-key "$account_key" --rpc-url "$RPC_URL" --gas-limit 3000000 --legacy --json \
        >"$RUN_DIR/$label-swap.json"
}

receipt_gas_used() {
    local receipt=$1
    cast to-dec "$(jq -er '.gasUsed' "$receipt")"
}

assert_all_receipts_succeeded() {
    local context=$1
    local failed_file status
    [[ -n "${RUN_DIR:-}" ]] || load_current_run
    failed_file=
    while IFS= read -r receipt; do
        status=$(jq -r 'if type == "object" and has("status") then .status else empty end' "$receipt" 2>/dev/null || true)
        if [[ -n "$status" && "$status" != "0x1" ]]; then
            failed_file=$receipt
            break
        fi
    done < <(find "$RUN_DIR" -maxdepth 1 -type f -name '*.json' -print | sort)
    [[ -z "$failed_file" ]] || fail "$context: failed transaction receipt $(basename "$failed_file")"
}

assert_eq() {
    local actual=$1
    local expected=$2
    local context=$3
    [[ "${actual,,}" == "${expected,,}" ]] || fail "$context: expected $expected, found $actual"
}

assert_gt() {
    local actual=$1
    local threshold=$2
    local context=$3
    [[ $(printf '%s > %s\n' "$actual" "$threshold" | bc) == "1" ]] \
        || fail "$context: expected more than $threshold, found $actual"
}

assert_ge() {
    local actual=$1
    local threshold=$2
    local context=$3
    [[ $(printf '%s >= %s\n' "$actual" "$threshold" | bc) == "1" ]] \
        || fail "$context: expected at least $threshold, found $actual"
}

assert_le() {
    local actual=$1
    local threshold=$2
    local context=$3
    [[ $(printf '%s <= %s\n' "$actual" "$threshold" | bc) == "1" ]] \
        || fail "$context: expected no more than $threshold, found $actual"
}

assert_nonzero_address() {
    local value=$1
    local context=$2
    [[ "$value" =~ ^0x[0-9a-fA-F]{40}$ ]] || fail "$context is not an address: $value"
    [[ "${value,,}" != "0x0000000000000000000000000000000000000000" ]] || fail "$context is zero"
}

assert_token_solvency() {
    local token=$1
    local context=$2
    local reserved balance
    reserved=$(cast call "$STATICS_DIAMOND_ADDRESS" 'globalReservedByToken(address)(uint256)' \
        "$token" --rpc-url "$RPC_URL" | awk '{print $1}')
    balance=$(cast call "$token" 'balanceOf(address)(uint256)' \
        "$STATICS_DIAMOND_ADDRESS" --rpc-url "$RPC_URL" | awk '{print $1}')
    assert_le "$reserved" "$balance" "$context custody solvency"
}

assert_phase_one_solvency() {
    local context=$1
    shift
    local token
    for token in "$@"; do
        assert_token_solvency "$token" "$context $token"
    done
    record_result accounting "$context" pass "$# token balances cover global reserves"
}

assert_runtime_matches_artifact() {
    local address=$1
    local artifact=$2
    local context=$3
    local expected actual start length offset width
    [[ -f "$artifact" ]] || fail "$context artifact is missing: $artifact"
    expected=$(jq -er '.deployedBytecode.object' "$artifact")
    actual=$(cast code "$address" --rpc-url "$RPC_URL")
    expected=${expected#0x}
    actual=${actual#0x}
    assert_eq "${#actual}" "${#expected}" "$context runtime length"

    # Foundry artifacts retain zero placeholders for constructor immutables.
    # Substitute the deployed immutable words before comparing all remaining
    # runtime bytes to the source artifact.
    while read -r start length; do
        offset=$(( start * 2 ))
        width=$(( length * 2 ))
        expected="${expected:0:offset}${actual:offset:width}${expected:offset+width}"
    done < <(jq -r '.deployedBytecode.immutableReferences // {} | .[][] | "\(.start) \(.length)"' "$artifact")
    assert_eq "$actual" "$expected" "$context runtime bytecode"
}

assert_runtime_matches_build_context() {
    local address=$1
    local deploy_artifact=$2
    local deploy_source=$3
    local deploy_contract=$4
    local target_source=$5
    local target_contract=$6
    local build_info_dir=$7
    local context=$8
    local build_info candidate expected actual start length offset width
    local deploy_via_ir deploy_optimizer deploy_optimizer_runs deploy_evm_version
    [[ -f "$deploy_artifact" ]] || fail "$context deployment artifact is missing: $deploy_artifact"
    deploy_via_ir=$(jq -er '.metadata.settings.viaIR' "$deploy_artifact")
    deploy_optimizer=$(jq -er '.metadata.settings.optimizer.enabled' "$deploy_artifact")
    deploy_optimizer_runs=$(jq -er '.metadata.settings.optimizer.runs' "$deploy_artifact")
    deploy_evm_version=$(jq -er '.metadata.settings.evmVersion' "$deploy_artifact")

    build_info=
    for candidate in "$build_info_dir"/*.json; do
        if jq -e \
            --rawfile deployContent "$deploy_source" \
            --rawfile targetContent "$target_source" \
            --arg deploySource "$deploy_source" \
            --arg deployContract "$deploy_contract" \
            --arg targetSource "$target_source" \
            --arg targetContract "$target_contract" \
            --argjson viaIR "$deploy_via_ir" \
            --argjson optimizer "$deploy_optimizer" \
            --argjson optimizerRuns "$deploy_optimizer_runs" \
            --arg evmVersion "$deploy_evm_version" \
            '(.input.sources[$deploySource].content == $deployContent)
            and (.input.sources[$targetSource].content == $targetContent)
            and (.input.settings.viaIR == $viaIR)
            and (.input.settings.optimizer.enabled == $optimizer)
            and (.input.settings.optimizer.runs == $optimizerRuns)
            and (.input.settings.evmVersion == $evmVersion)
            and (.output.contracts[$deploySource][$deployContract] != null)
            and (.output.contracts[$targetSource][$targetContract] != null)' \
            "$candidate" >/dev/null; then
            build_info=$candidate
            break
        fi
    done
    [[ -n "$build_info" ]] || fail "$context deployment build context was not found"

    expected=$(jq -er --arg source "$target_source" --arg contract "$target_contract" \
        '.output.contracts[$source][$contract].evm.deployedBytecode.object' "$build_info")
    actual=$(cast code "$address" --rpc-url "$RPC_URL")
    expected=${expected#0x}
    actual=${actual#0x}
    assert_eq "${#actual}" "${#expected}" "$context runtime length"

    while read -r start length; do
        offset=$(( start * 2 ))
        width=$(( length * 2 ))
        expected="${expected:0:offset}${actual:offset:width}${expected:offset+width}"
    done < <(jq -r --arg source "$target_source" --arg contract "$target_contract" \
        '(.output.contracts[$source][$contract].evm.deployedBytecode.immutableReferences // {})
        | .[][]
        | "\(.start) \(.length)"' \
        "$build_info")
    assert_eq "$actual" "$expected" "$context runtime bytecode"
}

record_result() {
    local suite=$1
    local scenario=$2
    local status=$3
    local detail=$4
    jq -cn \
        --arg suite "$suite" \
        --arg scenario "$scenario" \
        --arg status "$status" \
        --arg detail "$detail" \
        '{suite:$suite,scenario:$scenario,status:$status,detail:$detail}' \
        >>"$RUN_DIR/results.jsonl"
}

cd_repo() {
    cd "$REPO_ROOT"
}
