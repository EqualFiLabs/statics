#!/usr/bin/env bash
set -euo pipefail

readonly MAINNET_GENESIS_SOURCE_COMMIT="43018f109006aa2c2eef2808adc2aa74dfc9a6d4"
readonly ROBINHOOD_TESTNET_CHAIN_ID="46630"
readonly CREATE2_DEPLOYER="0x4e59b44847b379578588920cA78FbF26c0B4956C"

usage() {
  echo "usage: $0 --broadcast" >&2
  echo "requires PRIVATE_KEY, ROBINHOOD_TESTNET_RPC_URL, and STATICS_GENESIS_EPOCH_END" >&2
}

if [[ "${1:-}" != "--broadcast" || $# -ne 1 ]]; then
  usage
  exit 2
fi

for command_name in cast forge git jq openssl; do
  command -v "$command_name" >/dev/null || {
    echo "missing required command: $command_name" >&2
    exit 1
  }
done

for variable_name in PRIVATE_KEY ROBINHOOD_TESTNET_RPC_URL STATICS_GENESIS_EPOCH_END; do
  if [[ -z "${!variable_name:-}" ]]; then
    echo "missing required environment variable: $variable_name" >&2
    exit 1
  fi
done

if [[ ! "$STATICS_GENESIS_EPOCH_END" =~ ^[0-9]+$ ]] || (( STATICS_GENESIS_EPOCH_END <= $(date +%s) )); then
  echo "STATICS_GENESIS_EPOCH_END must be a future Unix timestamp" >&2
  exit 1
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
cd "$repo_root"

canonical_paths=(
  script/DeployStaticsGenesis.s.sol
  src/genesis
  src/tokens/StaticsGenesis.sol
  src/metadata/StaticsGenesisRenderer.sol
  src/metadata/StaticsAvatarSVG.sol
  verification/doppler/vendor/doppler
)
git cat-file -e "${MAINNET_GENESIS_SOURCE_COMMIT}^{commit}"
if ! git diff --quiet "$MAINNET_GENESIS_SOURCE_COMMIT" -- "${canonical_paths[@]}"; then
  echo "canonical Genesis sources differ from deployed mainnet commit $MAINNET_GENESIS_SOURCE_COMMIT" >&2
  exit 1
fi

actual_chain_id="$(cast chain-id --rpc-url "$ROBINHOOD_TESTNET_RPC_URL")"
if [[ "$actual_chain_id" != "$ROBINHOOD_TESTNET_CHAIN_ID" ]]; then
  echo "refusing chain $actual_chain_id; expected Robinhood testnet $ROBINHOOD_TESTNET_CHAIN_ID" >&2
  exit 1
fi

chain_manifest="deployments/robinhood-chain-testnet-46630.json"
export ROBINHOOD_POOL_MANAGER="$(jq -er '.contracts.poolManager.address' "$chain_manifest")"
readonly expected_pool_manager_hash="$(jq -er '.contracts.poolManager.runtimeCodeHash' "$chain_manifest")"
readonly weth_address="$(jq -er '.staticsDollarDependencies.weth.address' "$chain_manifest")"
readonly expected_weth_hash="$(jq -er '.staticsDollarDependencies.weth.runtimeCodeHash' "$chain_manifest")"

code_hash() {
  local address="$1"
  local code
  code="$(cast code "$address" --rpc-url "$ROBINHOOD_TESTNET_RPC_URL")"
  if [[ "$code" == "0x" ]]; then
    echo "missing code at $address" >&2
    return 1
  fi
  cast keccak "$code"
}

if [[ "$(code_hash "$ROBINHOOD_POOL_MANAGER")" != "$expected_pool_manager_hash" ]]; then
  echo "Robinhood testnet PoolManager runtime hash mismatch" >&2
  exit 1
fi
if [[ "$(code_hash "$weth_address")" != "$expected_weth_hash" ]]; then
  echo "Robinhood testnet WETH runtime hash mismatch" >&2
  exit 1
fi
code_hash "$CREATE2_DEPLOYER" >/dev/null

deployer="$(cast wallet address --private-key "$PRIVATE_KEY")"
export DOPPLER_FEE_RECIPIENT="${DOPPLER_FEE_RECIPIENT:-$deployer}"
export STATICS_GENESIS_GOVERNANCE="${STATICS_GENESIS_GOVERNANCE:-$deployer}"
export STATICS_GENESIS_TREASURY="${STATICS_GENESIS_TREASURY:-$deployer}"
export STATICS_DOPPLER_INTEGRATOR="${STATICS_DOPPLER_INTEGRATOR:-$deployer}"
export STATICS_DOPPLER_SALT="${STATICS_DOPPLER_SALT:-0x$(openssl rand -hex 32)}"

run_id="$(date -u +%Y%m%dT%H%M%SZ)-$(cast nonce "$deployer" --rpc-url "$ROBINHOOD_TESTNET_RPC_URL")"
artifact_dir="$repo_root/artifacts/genesis-testnet/$run_id"
mkdir -p "$artifact_dir"
export STATICS_TESTNET_DOPPLER_ARTIFACT="$artifact_dir/doppler.json"
export STATICS_GENESIS_TESTNET_ARTIFACT="$artifact_dir/genesis.json"

echo "Deploying disposable Doppler modules on Robinhood testnet from $deployer"
(
  cd verification/doppler
  forge script script/DeployGenesisTestnetDoppler.s.sol:DeployGenesisTestnetDoppler \
    --rpc-url "$ROBINHOOD_TESTNET_RPC_URL" \
    --broadcast \
    --slow \
    -vv
)

jq -e --argjson chainId "$ROBINHOOD_TESTNET_CHAIN_ID" \
  '.chainId == $chainId and .airlock != null and .poolInitializer != null' \
  "$STATICS_TESTNET_DOPPLER_ARTIFACT" >/dev/null

echo "Deploying standalone Statics Genesis replica"
forge script script/DeployStaticsGenesisTestnetReplica.s.sol:DeployStaticsGenesisTestnetReplica \
  --rpc-url "$ROBINHOOD_TESTNET_RPC_URL" \
  --broadcast \
  --slow \
  -vv

jq -e --argjson chainId "$ROBINHOOD_TESTNET_CHAIN_ID" \
  '.chainId == $chainId and .statics != null and .poolId != null and .genesis != null' \
  "$STATICS_GENESIS_TESTNET_ARTIFACT" >/dev/null

echo "Genesis testnet replica complete"
echo "Deployment artifact: $STATICS_GENESIS_TESTNET_ARTIFACT"
