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
STATICS_LAUNCH_USDG_ADDRESS=$(jq -er '.contracts.usdg.address' "$REPO_ROOT/deployments/robinhood-chain-4663.json")
STATICS_LAUNCH_NVDA_ADDRESS=0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC
require_launch_pool_inputs
export STATICS_LAUNCH_USDG_ADDRESS STATICS_LAUNCH_NVDA_ADDRESS
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
POOL_CREATION_FEE_AMOUNT=0 \
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
assert_eq "$(cast call "$STATICS_DIAMOND_ADDRESS" 'owner()(address)' --rpc-url "$RPC_URL")" \
    "$(cast wallet address --private-key "$DEPLOYER_KEY")" "temporary deployment owner"

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
export POOL_CREATION_FEE_AMOUNT=0
export WEEKLY_GAUGE_RELEASE_BPS=400
export STATICS_REVENUE_MAINTENANCE_TIP_BPS=100
export STATICS_POL_OPERATOR="$POL_OPERATOR"
export STATICS_POL_ACTIVATION_FEE=25000000000000000
append_state STATICS_POL_ACTIVATION_FEE "$STATICS_POL_ACTIVATION_FEE"
export STATICS_DIAMOND_ADDRESS STATICS_LIQUIDITY_MANAGER_ADDRESS
export STATICS_SWAP_FEE_HOOK_ADDRESS STATICS_PERMISSIONED_SWAP_FEE_HOOK_ADDRESS
export STATICS_PERMISSIONED_ROUTER_ADDRESS STATICS_PERMISSIONED_POSITION_MANAGER_ADDRESS
export STATICS_DIAMOND_RUNTIME_CODE_HASH STATICS_LIQUIDITY_MANAGER_RUNTIME_CODE_HASH
export STATICS_SWAP_FEE_HOOK_RUNTIME_CODE_HASH STATICS_PERMISSIONED_SWAP_FEE_HOOK_RUNTIME_CODE_HASH
export STATICS_PERMISSIONED_ROUTER_RUNTIME_CODE_HASH STATICS_PERMISSIONED_POSITION_MANAGER_RUNTIME_CODE_HASH
export STATICS_PERMISSIONED_POSITION_CLAIMS_RUNTIME_CODE_HASH
export STATICS_TIMELOCK_ADDRESS

PREPARE_LOG="$RUN_DIR/finalize-phase-one-deployment.log"
note "configuring Phase 1 while the deployment signer retains ownership"
forge script script/ConfigureStaticsPhaseOneLiquidity.s.sol:ConfigureStaticsPhaseOneLiquidity \
    --sig 'runFinalizeDeployment()' \
    --rpc-url "$RPC_URL" \
    --broadcast --legacy --slow \
    -vv \
    2>&1 | tee "$PREPARE_LOG"
assert_eq "$(cast call "$STATICS_DIAMOND_ADDRESS" 'owner()(address)' --rpc-url "$RPC_URL")" \
    "$(cast wallet address --private-key "$DEPLOYER_KEY")" "configured Diamond owner"
assert_eq "$(cast call "$STATICS_DIAMOND_ADDRESS" 'poolCreationFee()(uint256)' --rpc-url "$RPC_URL" | awk '{print $1}')" \
    0 "owner-only pool creation fee"

note "creating all five launch pools at zero creation fee, then enabling 0.01 ETH and transferring to the Safe"
LAUNCH_LOG="$RUN_DIR/launch-phase-one-pools.log"
forge script script/LaunchStaticsPhaseOnePools.s.sol:LaunchStaticsPhaseOnePools \
    --sig 'run()' --rpc-url "$RPC_URL" --broadcast --legacy --slow -vv \
    2>&1 | tee "$LAUNCH_LOG"
STATICS_LAUNCH_PUBLIC_POOL_IDS=$(require_label STATICS_LAUNCH_PUBLIC_POOL_IDS "$LAUNCH_LOG")
export STATICS_LAUNCH_PUBLIC_POOL_IDS
append_state STATICS_LAUNCH_PUBLIC_POOL_IDS "$STATICS_LAUNCH_PUBLIC_POOL_IDS"
assert_eq "$(tr ',' '\n' <<<"$STATICS_LAUNCH_PUBLIC_POOL_IDS" | wc -l)" 5 "five launch pool IDs"
assert_eq "$(cast call "$STATICS_DIAMOND_ADDRESS" 'poolCreationFee()(uint256)' --rpc-url "$RPC_URL" | awk '{print $1}')" \
    10000000000000000 "public creation fee enabled after launch pools"
assert_eq "$(cast call "$STATICS_DIAMOND_ADDRESS" 'owner()(address)' --rpc-url "$RPC_URL")" \
    "$GOVERNANCE" "post-launch Diamond owner"

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
record_result deployment deployer-bootstrap-safe-handoff pass "$STATICS_TIMELOCK_ADDRESS"
note "stack deployed and base snapshot recorded"
