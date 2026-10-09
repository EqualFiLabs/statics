#!/usr/bin/env bash

set -Eeuo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

require_commands forge cast jq awk
load_current_run
require_local_chain
cd_repo

DEPLOYER_KEY=$(anvil_private_key 0)
GENESIS_MANIFEST="$REPO_ROOT/deployments/robinhood-mainnet-genesis.json"
GOVERNANCE=$(jq -er '.roles.governance' "$GENESIS_MANIFEST")
GUARDIAN=$(anvil_address 1)
TREASURY=$(jq -er '.roles.treasury' "$GENESIS_MANIFEST")
POL_OPERATOR=$(anvil_address 3)
WETH=$(jq -er '.externalDependencies.weth.address' "$GENESIS_MANIFEST")
STATICS_TOKEN=$(jq -er '.contracts.staticsToken.address' "$GENESIS_MANIFEST")
STATICS_DOPPLER_POOL_INITIALIZER_ADDRESS=$(jq -er '.canonicalPool.poolKey.hooks' "$GENESIS_MANIFEST")
STATICS_DOPPLER_POOL_ID=$(jq -er '.canonicalPool.poolId' "$GENESIS_MANIFEST")
STATICS_DOPPLER_POOL_FEE=$(jq -er '.canonicalPool.poolKey.fee' "$GENESIS_MANIFEST")
STATICS_DOPPLER_POOL_TICK_SPACING=$(jq -er '.canonicalPool.poolKey.tickSpacing' "$GENESIS_MANIFEST")
GENESIS_NFT=$(jq -er '.contracts.operatorsNft.address' "$GENESIS_MANIFEST")
GENESIS_VAULT=$(jq -er '.contracts.genesisVault.address' "$GENESIS_MANIFEST")
GENESIS_DISTRIBUTOR=$(jq -er '.contracts.launchDistributor.address' "$GENESIS_MANIFEST")
STATICS_TREASURY_VESTING_ADDRESS=$(jq -er '.contracts.treasuryVesting.address' "$GENESIS_MANIFEST")

append_state GOVERNANCE "$GOVERNANCE"
append_state GUARDIAN "$GUARDIAN"
append_state TREASURY "$TREASURY"
append_state POL_OPERATOR "$POL_OPERATOR"
append_state WETH_ADDRESS "$WETH"
assert_nonzero_address "$STATICS_TOKEN" "Genesis STATICS token"
# cast codehash uses eth_getProof, which this provider prunes independently of
# historical bytecode. Hash the actual runtime and retain the exact manifest pin.
assert_eq "$(cast keccak "$(cast code "$STATICS_TOKEN" --rpc-url "$RPC_URL")")" \
    "$(jq -er '.contracts.staticsToken.runtimeCodeHash' "$GENESIS_MANIFEST")" \
    "live Genesis STATICS runtime"
append_state STAKING_TOKEN "$STATICS_TOKEN"
append_state STATICS_DOPPLER_POOL_INITIALIZER_ADDRESS "$STATICS_DOPPLER_POOL_INITIALIZER_ADDRESS"
append_state STATICS_DOPPLER_POOL_ID "$STATICS_DOPPLER_POOL_ID"
append_state STATICS_DOPPLER_POOL_FEE "$STATICS_DOPPLER_POOL_FEE"
append_state STATICS_DOPPLER_POOL_TICK_SPACING "$STATICS_DOPPLER_POOL_TICK_SPACING"
append_state STATICS_GENESIS_NFT_ADDRESS "$GENESIS_NFT"
append_state STATICS_GENESIS_VAULT_ADDRESS "$GENESIS_VAULT"
append_state STATICS_GENESIS_DISTRIBUTOR_ADDRESS "$GENESIS_DISTRIBUTOR"
append_state STATICS_TREASURY_VESTING_ADDRESS "$STATICS_TREASURY_VESTING_ADDRESS"

PHASE_ONE_LOG="$RUN_DIR/deploy-phase-one.log"
note "deploying Phase 1 against the live Genesis bindings"
PHASE_ONE_OUT="$RUN_DIR/out-phase-one"
PHASE_ONE_CACHE="$RUN_DIR/cache-phase-one"
PHASE_ONE_BUILD_INFO="$RUN_DIR/build-info-phase-one"
PRIVATE_KEY="$DEPLOYER_KEY" \
MULTISIG="$GOVERNANCE" \
GUARDIAN="$GUARDIAN" \
TREASURY="$TREASURY" \
STAKING_TOKEN="$STATICS_TOKEN" \
WETH_ADDRESS="$WETH" \
POSITION_CREATION_FEE_AMOUNT=1000000000000000 \
WEEKLY_GAUGE_RELEASE_BPS=400 \
forge script script/DeployStaticsPhaseOne.s.sol:DeployStaticsPhaseOne \
    --sig 'run()' \
    --out "$PHASE_ONE_OUT" \
    --cache-path "$PHASE_ONE_CACHE" \
    --build-info \
    --build-info-path "$PHASE_ONE_BUILD_INFO" \
    --rpc-url "$RPC_URL" \
    --broadcast \
    --legacy \
    --slow \
    -vv \
    2>&1 | tee "$PHASE_ONE_LOG"

STATICS_DIAMOND_ADDRESS=$(require_label STATICS_DIAMOND_ADDRESS "$PHASE_ONE_LOG")
STATICS_TIMELOCK_ADDRESS=$(require_label STATICS_TIMELOCK_ADDRESS "$PHASE_ONE_LOG")
STATICS_LIQUIDITY_MANAGER_ADDRESS=$(require_label STATICS_LIQUIDITY_MANAGER_ADDRESS "$PHASE_ONE_LOG")
STATICS_SWAP_FEE_HOOK_ADDRESS=$(require_label STATICS_SWAP_FEE_HOOK_ADDRESS "$PHASE_ONE_LOG")
STATICS_PERMISSIONED_SWAP_FEE_HOOK_ADDRESS=$(
    require_label STATICS_PERMISSIONED_SWAP_FEE_HOOK_ADDRESS "$PHASE_ONE_LOG"
)
STATICS_DEFAULT_VENUE_CONTROLLER_FACTORY=$(
    require_label STATICS_DEFAULT_VENUE_CONTROLLER_FACTORY "$PHASE_ONE_LOG"
)
append_state STATICS_DIAMOND_ADDRESS "$STATICS_DIAMOND_ADDRESS"
append_state STATICS_TIMELOCK_ADDRESS "$STATICS_TIMELOCK_ADDRESS"
append_state STATICS_LIQUIDITY_MANAGER_ADDRESS "$STATICS_LIQUIDITY_MANAGER_ADDRESS"
append_state STATICS_SWAP_FEE_HOOK_ADDRESS "$STATICS_SWAP_FEE_HOOK_ADDRESS"
append_state STATICS_PERMISSIONED_SWAP_FEE_HOOK_ADDRESS "$STATICS_PERMISSIONED_SWAP_FEE_HOOK_ADDRESS"
append_state STATICS_DEFAULT_VENUE_CONTROLLER_FACTORY "$STATICS_DEFAULT_VENUE_CONTROLLER_FACTORY"

PERIPHERY_LOG="$RUN_DIR/deploy-permissioned-periphery.log"
note "deploying the permissioned periphery"
PERIPHERY_OUT="$RUN_DIR/out-periphery"
PERIPHERY_CACHE="$RUN_DIR/cache-periphery"
PERIPHERY_BUILD_INFO="$RUN_DIR/build-info-periphery"
PRIVATE_KEY="$DEPLOYER_KEY" \
WETH_ADDRESS="$WETH" \
STATICS_PERMISSIONED_SWAP_FEE_HOOK_ADDRESS="$STATICS_PERMISSIONED_SWAP_FEE_HOOK_ADDRESS" \
forge script script/DeployStaticsPermissionedPeriphery.s.sol:DeployStaticsPermissionedPeriphery \
    --out "$PERIPHERY_OUT" \
    --cache-path "$PERIPHERY_CACHE" \
    --build-info \
    --build-info-path "$PERIPHERY_BUILD_INFO" \
    --rpc-url "$RPC_URL" \
    --broadcast \
    --legacy \
    --slow \
    -vv \
    2>&1 | tee "$PERIPHERY_LOG"

STATICS_PERMISSIONED_ROUTER_ADDRESS=$(require_label STATICS_PERMISSIONED_ROUTER_ADDRESS "$PERIPHERY_LOG")
STATICS_PERMISSIONED_POSITION_MANAGER_ADDRESS=$(
    require_label STATICS_PERMISSIONED_POSITION_MANAGER_ADDRESS "$PERIPHERY_LOG"
)
STATICS_PERMISSIONED_POSITION_CLAIMS_ADDRESS=$(
    require_label STATICS_PERMISSIONED_POSITION_CLAIMS_ADDRESS "$PERIPHERY_LOG"
)
append_state STATICS_PERMISSIONED_ROUTER_ADDRESS "$STATICS_PERMISSIONED_ROUTER_ADDRESS"
append_state STATICS_PERMISSIONED_POSITION_MANAGER_ADDRESS "$STATICS_PERMISSIONED_POSITION_MANAGER_ADDRESS"
append_state STATICS_PERMISSIONED_POSITION_CLAIMS_ADDRESS "$STATICS_PERMISSIONED_POSITION_CLAIMS_ADDRESS"
append_state PHASE_ONE_OUT "$PHASE_ONE_OUT"
append_state PHASE_ONE_BUILD_INFO "$PHASE_ONE_BUILD_INFO"
append_state PERIPHERY_OUT "$PERIPHERY_OUT"
append_state PERIPHERY_BUILD_INFO "$PERIPHERY_BUILD_INFO"

append_state STATICS_DIAMOND_RUNTIME_CODE_HASH "$(cast codehash "$STATICS_DIAMOND_ADDRESS" --rpc-url "$RPC_URL")"
append_state STATICS_LIQUIDITY_MANAGER_RUNTIME_CODE_HASH \
    "$(cast codehash "$STATICS_LIQUIDITY_MANAGER_ADDRESS" --rpc-url "$RPC_URL")"
append_state STATICS_SWAP_FEE_HOOK_RUNTIME_CODE_HASH \
    "$(cast codehash "$STATICS_SWAP_FEE_HOOK_ADDRESS" --rpc-url "$RPC_URL")"
append_state STATICS_PERMISSIONED_SWAP_FEE_HOOK_RUNTIME_CODE_HASH \
    "$(cast codehash "$STATICS_PERMISSIONED_SWAP_FEE_HOOK_ADDRESS" --rpc-url "$RPC_URL")"
append_state STATICS_PERMISSIONED_ROUTER_RUNTIME_CODE_HASH \
    "$(cast codehash "$STATICS_PERMISSIONED_ROUTER_ADDRESS" --rpc-url "$RPC_URL")"
append_state STATICS_PERMISSIONED_POSITION_MANAGER_RUNTIME_CODE_HASH \
    "$(cast codehash "$STATICS_PERMISSIONED_POSITION_MANAGER_ADDRESS" --rpc-url "$RPC_URL")"
append_state STATICS_PERMISSIONED_POSITION_CLAIMS_RUNTIME_CODE_HASH \
    "$(cast codehash "$STATICS_PERMISSIONED_POSITION_CLAIMS_ADDRESS" --rpc-url "$RPC_URL")"

export PRIVATE_KEY="$DEPLOYER_KEY"
export MULTISIG="$GOVERNANCE"
export GUARDIAN TREASURY STAKING_TOKEN WETH_ADDRESS
export POSITION_CREATION_FEE_AMOUNT=1000000000000000
export WEEKLY_GAUGE_RELEASE_BPS=400
export STATICS_REVENUE_MAINTENANCE_TIP_BPS=500
export STATICS_POL_OPERATOR="$POL_OPERATOR"
export STATICS_POL_ACTIVATION_FEE=100000000000000000
export STATICS_DIAMOND_ADDRESS STATICS_LIQUIDITY_MANAGER_ADDRESS
export STATICS_SWAP_FEE_HOOK_ADDRESS STATICS_PERMISSIONED_SWAP_FEE_HOOK_ADDRESS
export STATICS_PERMISSIONED_ROUTER_ADDRESS STATICS_PERMISSIONED_POSITION_MANAGER_ADDRESS
export STATICS_DIAMOND_RUNTIME_CODE_HASH STATICS_LIQUIDITY_MANAGER_RUNTIME_CODE_HASH
export STATICS_SWAP_FEE_HOOK_RUNTIME_CODE_HASH STATICS_PERMISSIONED_SWAP_FEE_HOOK_RUNTIME_CODE_HASH
export STATICS_PERMISSIONED_ROUTER_RUNTIME_CODE_HASH STATICS_PERMISSIONED_POSITION_MANAGER_RUNTIME_CODE_HASH
export STATICS_PERMISSIONED_POSITION_CLAIMS_RUNTIME_CODE_HASH
export STATICS_TIMELOCK_ADDRESS

PREPARE_LOG="$RUN_DIR/prepare-phase-one-liquidity.log"
note "preparing the immediate Safe-owned Phase 1 integration batch"
forge script script/ConfigureStaticsPhaseOneLiquidity.s.sol:ConfigureStaticsPhaseOneLiquidity \
    --sig 'runPrepareBootstrap()' \
    --rpc-url "$RPC_URL" \
    -vv \
    2>&1 | tee "$PREPARE_LOG"

mapfile -t SAFE_TARGETS < <(awk '$1 == "SAFE_BATCH_TARGET" {print $2}' "$PREPARE_LOG")
mapfile -t SAFE_VALUES < <(awk '$1 == "SAFE_BATCH_VALUE" {print $2}' "$PREPARE_LOG")
mapfile -t SAFE_CALLDATA < <(awk '$1 == "SAFE_BATCH_CALLDATA" {getline; print $1}' "$PREPARE_LOG")
assert_eq "${#SAFE_TARGETS[@]}" 9 "Safe launch call count"
assert_eq "${#SAFE_VALUES[@]}" 9 "Safe launch value count"
assert_eq "${#SAFE_CALLDATA[@]}" 9 "Safe launch calldata count"
for index in "${!SAFE_TARGETS[@]}"; do
    assert_eq "${SAFE_TARGETS[$index]}" "$STATICS_DIAMOND_ADDRESS" "Safe launch target $index"
    assert_eq "${SAFE_VALUES[$index]}" 0 "Safe launch value $index"
    cast send "${SAFE_TARGETS[$index]}" "${SAFE_CALLDATA[$index]}" \
        --from "$GOVERNANCE" --unlocked --rpc-url "$RPC_URL" --legacy --json \
        >"$RUN_DIR/safe-phase-one-liquidity-$index.json"
done

note "creating the initial public pool before timelock ownership"
LAUNCH_DEADLINE=$(( $(cast block latest --field timestamp --rpc-url "$RPC_URL") + 172800 ))
LAUNCH_PARAMS="($STATICS_TOKEN,$WETH,777,37,79228162514264337593543950336,(5,5),$GOVERNANCE,false,1,$LAUNCH_DEADLINE)"
STATICS_LAUNCH_PUBLIC_POOL_IDS=$(cast call "$STATICS_DIAMOND_ADDRESS" \
    'quotePool((address,address,uint24,int24,uint160,(uint16,uint16),address,bool,uint256,uint256))(((address,address,uint24,int24,address),bytes32,uint160,uint256,uint256,uint256,bytes32))' \
    "$LAUNCH_PARAMS" --rpc-url "$RPC_URL" --json | jq -er '.[0][1]')
export STATICS_LAUNCH_PUBLIC_POOL_IDS
cast send "$STATICS_DIAMOND_ADDRESS" \
    'createPool((address,address,uint24,int24,uint160,(uint16,uint16),address,bool,uint256,uint256),bytes)' \
    "$LAUNCH_PARAMS" 0x --from "$GOVERNANCE" --unlocked --rpc-url "$RPC_URL" --legacy --json \
    >"$RUN_DIR/safe-phase-one-launch-pool.json"
assert_eq "$(cast call "$STATICS_DIAMOND_ADDRESS" 'isProtocolPool(bytes32)(bool)' \
    "$STATICS_LAUNCH_PUBLIC_POOL_IDS" --rpc-url "$RPC_URL")" true "initial public pool"

HANDOFF_LOG="$RUN_DIR/prepare-phase-one-handoff.log"
note "preparing the Safe handoff after initial pool verification"
forge script script/ConfigureStaticsPhaseOneLiquidity.s.sol:ConfigureStaticsPhaseOneLiquidity \
    --sig 'runPrepareHandoff()' --rpc-url "$RPC_URL" -vv 2>&1 | tee "$HANDOFF_LOG"
HANDOFF_TARGET=$(require_label SAFE_HANDOFF_TARGET "$HANDOFF_LOG")
HANDOFF_CALLDATA=$(require_next_label SAFE_HANDOFF_CALLDATA "$HANDOFF_LOG")
assert_eq "$HANDOFF_TARGET" "$STATICS_DIAMOND_ADDRESS" "Safe handoff target"
cast send "$HANDOFF_TARGET" "$HANDOFF_CALLDATA" \
    --from "$GOVERNANCE" --unlocked --rpc-url "$RPC_URL" --legacy --json \
    >"$RUN_DIR/safe-phase-one-handoff.json"
assert_eq "$(cast call "$STATICS_DIAMOND_ADDRESS" 'owner()(address)' --rpc-url "$RPC_URL")" \
    "$STATICS_TIMELOCK_ADDRESS" "post-launch Diamond owner"

append_state DEPLOYED_BLOCK "$(cast block-number --rpc-url "$RPC_URL")"
append_state BASE_SNAPSHOT "$(rpc_snapshot)"
record_result deployment live-genesis-bindings pass "$STATICS_TOKEN"
record_result deployment phase-one pass "$STATICS_DIAMOND_ADDRESS"
record_result deployment liquidity-installation pass "$STATICS_DIAMOND_ADDRESS"
record_result deployment safe-bootstrap-handoff pass "$STATICS_TIMELOCK_ADDRESS"
note "stack deployed and base snapshot recorded"
