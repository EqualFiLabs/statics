#!/usr/bin/env bash
set -euo pipefail

readonly ROBINHOOD_TESTNET_CHAIN_ID="46630"
readonly CLAIM_AMOUNT="200000000000000000000000"

usage() {
  echo "usage: STATICS_GENESIS_TESTNET_ARTIFACT=... ROBINHOOD_TESTNET_RPC_URL=... $0 --broadcast|--check" >&2
  echo "--broadcast also requires PRIVATE_KEY; --check requires STATICS_GENESIS_FAUCET_ADDRESS" >&2
}

[[ $# -eq 1 ]] || { usage; exit 2; }
mode=$1
[[ "$mode" == "--broadcast" || "$mode" == "--check" ]] || { usage; exit 2; }

for command_name in bc cast forge jq; do
  command -v "$command_name" >/dev/null || { echo "missing required command: $command_name" >&2; exit 1; }
done

rpc_url=${ROBINHOOD_TESTNET_RPC_URL:?ROBINHOOD_TESTNET_RPC_URL is required}
genesis_artifact=${STATICS_GENESIS_TESTNET_ARTIFACT:?STATICS_GENESIS_TESTNET_ARTIFACT is required}
[[ -f "$genesis_artifact" ]] || { echo "missing Genesis artifact: $genesis_artifact" >&2; exit 1; }
[[ $(cast chain-id --rpc-url "$rpc_url") == "$ROBINHOOD_TESTNET_CHAIN_ID" ]] || {
  echo "Robinhood testnet chain $ROBINHOOD_TESTNET_CHAIN_ID is required" >&2; exit 1;
}

statics=$(jq -er '.statics' "$genesis_artifact")
[[ $(cast code "$statics" --rpc-url "$rpc_url") != 0x ]] || { echo "STATICS has no runtime code" >&2; exit 1; }

uint_ge() { [[ $(echo "$1 >= $2" | bc) == 1 ]]; }

verify_faucet() {
  local faucet=$1
  [[ $(cast code "$faucet" --rpc-url "$rpc_url") != 0x ]] || { echo "faucet has no runtime code" >&2; exit 1; }
  local actual_statics
  actual_statics=$(cast call "$faucet" 'STATICS()(address)' --rpc-url "$rpc_url")
  [[ "${actual_statics,,}" == "${statics,,}" ]] || { echo "faucet STATICS binding mismatch" >&2; exit 1; }
  [[ $(cast call "$faucet" 'CLAIM_AMOUNT()(uint256)' --rpc-url "$rpc_url" | awk '{print $1}') == "$CLAIM_AMOUNT" ]] || {
    echo "faucet claim amount mismatch" >&2; exit 1;
  }
  [[ $(cast call "$faucet" 'COOLDOWN()(uint256)' --rpc-url "$rpc_url" | awk '{print $1}') == 86400 ]] || {
    echo "faucet cooldown mismatch" >&2; exit 1;
  }
  local balance
  balance=$(cast call "$statics" 'balanceOf(address)(uint256)' "$faucet" --rpc-url "$rpc_url" | awk '{print $1}')
  uint_ge "$balance" "$CLAIM_AMOUNT" || { echo "faucet is not funded for one claim" >&2; exit 1; }
}

if [[ "$mode" == "--check" ]]; then
  faucet=${STATICS_GENESIS_FAUCET_ADDRESS:?STATICS_GENESIS_FAUCET_ADDRESS is required for --check}
  verify_faucet "$faucet"
  echo "Genesis testnet faucet verified: $faucet"
  exit 0
fi

private_key=${PRIVATE_KEY:?PRIVATE_KEY is required for --broadcast}
deployer=$(cast wallet address --private-key "$private_key")
balance_before=$(cast balance "$deployer" --rpc-url "$rpc_url")
[[ "$balance_before" -ge 12000000000000000 ]] || {
  echo "deployer balance is below the 0.012 ETH swap cap before gas" >&2; exit 1;
}

export PRIVATE_KEY=$private_key
forge script script/DeployStaticsGenesisTestnetFaucet.s.sol:DeployStaticsGenesisTestnetFaucet \
  --rpc-url "$rpc_url" --chain-id "$ROBINHOOD_TESTNET_CHAIN_ID" --broadcast --slow \
  --gas-estimate-multiplier 200 -vv

broadcast="broadcast/DeployStaticsGenesisTestnetFaucet.s.sol/$ROBINHOOD_TESTNET_CHAIN_ID/run-latest.json"
faucet=$(jq -er '.transactions[] | select(.contractName == "StaticsGenesisTestnetFaucet") | .contractAddress' "$broadcast" | tail -n 1)
deploy_tx=$(jq -er '.transactions[] | select(.contractName == "StaticsGenesisTestnetFaucet") | .hash' "$broadcast" | tail -n 1)
mapfile -t transaction_hashes < <(jq -er '.transactions[].hash' "$broadcast")

verify_faucet "$faucet"
runtime_hash=$(cast keccak "$(cast code "$faucet" --rpc-url "$rpc_url")")
deployment_block=$(cast receipt "$deploy_tx" blockNumber --rpc-url "$rpc_url")
timestamp=$(date -u +%Y%m%dT%H%M%SZ)
artifact_dir="artifacts/genesis-testnet-faucet/$timestamp"
mkdir -p "$artifact_dir"
jq -n \
  --arg address "$faucet" \
  --arg statics "$statics" \
  --arg runtimeCodeHash "$runtime_hash" \
  --arg deployTransaction "$deploy_tx" \
  --arg deploymentBlock "$deployment_block" \
  --arg claimAmount "$CLAIM_AMOUNT" \
  --argjson transactions "$(printf '%s\n' "${transaction_hashes[@]}" | jq -R . | jq -s .)" \
  '{schemaVersion:1,address:$address,statics:$statics,runtimeCodeHash:$runtimeCodeHash,deployTransaction:$deployTransaction,deploymentBlock:$deploymentBlock,claimAmount:$claimAmount,cooldownSeconds:86400,fundedClaims:1,transactions:$transactions}' \
  > "$artifact_dir/faucet.json"

echo "Genesis testnet faucet deployed and funded: $faucet"
echo "Record: $artifact_dir/faucet.json"
