#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: STATICS_REHEARSAL_MANIFEST=... ROBINHOOD_TESTNET_RPC_URL=... PRIVATE_KEY=... $0 --broadcast|--check" >&2
}

[[ $# -eq 1 ]] || { usage; exit 2; }
mode=$1
[[ "$mode" == "--broadcast" || "$mode" == "--check" ]] || { usage; exit 2; }

manifest=${STATICS_REHEARSAL_MANIFEST:-deployments/robinhood-testnet-46630-rehearsal-20260903T033729Z.json}
rpc_url=${ROBINHOOD_TESTNET_RPC_URL:?ROBINHOOD_TESTNET_RPC_URL is required}
[[ -f "$manifest" ]] || { echo "missing rehearsal manifest: $manifest" >&2; exit 1; }
[[ $(cast chain-id --rpc-url "$rpc_url") == 46630 ]] || { echo "Robinhood testnet chain 46630 is required" >&2; exit 1; }

read_manifest() { jq -er "$1" "$manifest"; }
uint_add() { echo "$1 + $2" | bc; }
uint_sub() { echo "$1 - $2" | bc; }
uint_mul() { echo "$1 * $2" | bc; }
uint_ge() { [[ $(echo "$1 >= $2" | bc) == 1 ]]; }
uint_gt() { [[ $(echo "$1 > $2" | bc) == 1 ]]; }

usdg=$(read_manifest '.peggedProfile.collateralToken')
usdstx=$(read_manifest '.protocol.usdStx.address')
statics=$(read_manifest '.genesisReplica.statics')
diamond=$(read_manifest '.protocol.staticsDiamond.address')
tsla=$(read_manifest '.basket.assets[0].token')
pltr=$(read_manifest '.basket.assets[1].token')
amd=$(read_manifest '.basket.assets[2].token')

assets=("$usdg" "$usdstx" "$statics" "$tsla" "$pltr" "$amd")
amounts=(5000000000 5000000000000000000000 1000000000000000000000 1000000000000000 1000000000000000 1000000000000000)
claims=100

verify_faucet() {
  local faucet=$1
  [[ $(cast code "$faucet" --rpc-url "$rpc_url") != 0x ]] || { echo "faucet has no runtime code" >&2; exit 1; }
  [[ $(cast call "$faucet" 'ASSET_COUNT()(uint256)' --rpc-url "$rpc_url" | awk '{print $1}') == 6 ]] || {
    echo "faucet asset count mismatch" >&2; exit 1;
  }
  [[ $(cast call "$faucet" 'COOLDOWN()(uint256)' --rpc-url "$rpc_url" | awk '{print $1}') == 86400 ]] || {
    echo "faucet cooldown mismatch" >&2; exit 1;
  }
  for index in "${!assets[@]}"; do
    read -r actual_asset actual_amount < <(
      cast call "$faucet" 'asset(uint256)(address,uint256)' "$index" --rpc-url "$rpc_url" |
        awk 'NR == 1 { asset=$1 } NR == 2 { print asset, $1 }'
    )
    [[ "${actual_asset,,}" == "${assets[$index],,}" && "$actual_amount" == "${amounts[$index]}" ]] || {
      echo "faucet asset $index mismatch" >&2; exit 1;
    }
    target=$(uint_mul "${amounts[$index]}" "$claims")
    balance=$(cast call "${assets[$index]}" 'balanceOf(address)(uint256)' "$faucet" --rpc-url "$rpc_url" | awk '{print $1}')
    uint_ge "$balance" "$target" || { echo "faucet asset $index is underfunded" >&2; exit 1; }
  done
}

if [[ "$mode" == "--check" ]]; then
  faucet=${STATICS_FAUCET_ADDRESS:?STATICS_FAUCET_ADDRESS is required for --check}
  verify_faucet "$faucet"
  echo "rehearsal faucet verified: $faucet"
  exit 0
fi

private_key=${PRIVATE_KEY:?PRIVATE_KEY is required for --broadcast}
deployer=$(cast wallet address --private-key "$private_key")

for index in 3 4 5; do
  target=$(uint_mul "${amounts[$index]}" "$claims")
  balance=$(cast call "${assets[$index]}" 'balanceOf(address)(uint256)' "$deployer" --rpc-url "$rpc_url" | awk '{print $1}')
  uint_ge "$balance" "$target" || { echo "deployer lacks stock inventory for faucet asset $index" >&2; exit 1; }
done

target_usdstx=$(uint_mul "${amounts[1]}" "$claims")
current_usdstx=$(cast call "$usdstx" 'balanceOf(address)(uint256)' "$deployer" --rpc-url "$rpc_url" | awk '{print $1}')
missing_usdstx=0
uint_gt "$target_usdstx" "$current_usdstx" && missing_usdstx=$(uint_sub "$target_usdstx" "$current_usdstx")
collateral_in=0
if uint_gt "$missing_usdstx" 0; then
  preview=$(cast call "$diamond" 'previewPeggedMint(uint256,uint256)((uint256,address,uint256,uint256,uint256,uint256,uint256))' 2 "$missing_usdstx" --rpc-url "$rpc_url")
  collateral_in=$(sed -E 's/^\([^,]+,[^,]+,[^,]+,[^,]+,[^,]+, ([0-9]+).*/\1/' <<<"$preview")
  [[ "$collateral_in" =~ ^[0-9]+$ ]] || { echo "could not decode pegged mint preview" >&2; exit 1; }
fi

target_usdg=$(uint_mul "${amounts[0]}" "$claims")
current_usdg=$(cast call "$usdg" 'balanceOf(address)(uint256)' "$deployer" --rpc-url "$rpc_url" | awk '{print $1}')
required_usdg=$(uint_add "$target_usdg" "$collateral_in")
if ! uint_ge "$current_usdg" "$required_usdg"; then
  usdg_owner=$(cast call "$usdg" 'owner()(address)' --rpc-url "$rpc_url")
  [[ "${usdg_owner,,}" == "${deployer,,}" ]] || { echo "deployer cannot mint the required USDG inventory" >&2; exit 1; }
fi

target_statics=$(uint_mul "${amounts[2]}" "$claims")
current_statics=$(cast call "$statics" 'balanceOf(address)(uint256)' "$deployer" --rpc-url "$rpc_url" | awk '{print $1}')
if ! uint_ge "$current_statics" "$target_statics"; then
  releasable=$(cast call "$statics" 'computeAvailableVestedAmount(address,uint256)(uint256)' "$deployer" 0 --rpc-url "$rpc_url" | awk '{print $1}')
  uint_ge "$(uint_add "$current_statics" "$releasable")" "$target_statics" || {
    echo "deployer lacks releasable STATICS inventory" >&2; exit 1;
  }
fi

export STATICS_FAUCET_USDG=$usdg
export STATICS_FAUCET_USDSTX=$usdstx
export STATICS_FAUCET_STATICS=$statics
export STATICS_FAUCET_TSLA=$tsla
export STATICS_FAUCET_PLTR=$pltr
export STATICS_FAUCET_AMD=$amd
export PRIVATE_KEY=$private_key

forge script script/DeployStaticsTestnetFaucet.s.sol:DeployStaticsTestnetFaucet \
  --rpc-url "$rpc_url" --chain-id 46630 --broadcast -vv

broadcast=broadcast/DeployStaticsTestnetFaucet.s.sol/46630/run-latest.json
faucet=$(jq -er '.transactions[] | select(.contractName == "StaticsTestnetFaucet") | .contractAddress' "$broadcast" | tail -n 1)
deploy_tx=$(jq -er '.transactions[] | select(.contractName == "StaticsTestnetFaucet") | .hash' "$broadcast" | tail -n 1)

mint_usdstx_tx=0x
mint_usdg_tx=0x
if ! uint_ge "$current_usdg" "$required_usdg"; then
  mint_usdg_tx=$(cast send "$usdg" 'mint(address,uint256)' "$deployer" "$(uint_sub "$required_usdg" "$current_usdg")" \
    --private-key "$private_key" --rpc-url "$rpc_url" --json | jq -er '.transactionHash')
fi

if uint_gt "$missing_usdstx" 0; then
  cast send "$usdg" 'approve(address,uint256)(bool)' "$diamond" "$collateral_in" \
    --private-key "$private_key" --rpc-url "$rpc_url" >/dev/null
  mint_usdstx_tx=$(cast send "$diamond" 'mintPegged(uint256,uint256,uint256,address)(uint256)' \
    2 "$missing_usdstx" "$collateral_in" "$deployer" --private-key "$private_key" --rpc-url "$rpc_url" --json | jq -er '.transactionHash')
fi

release_statics_tx=0x
if ! uint_ge "$current_statics" "$target_statics"; then
  release_statics_tx=$(cast send "$statics" 'releaseFor(address,uint256,uint256)' "$deployer" 0 0 \
    --private-key "$private_key" --rpc-url "$rpc_url" --json | jq -er '.transactionHash')
fi

funding_txs=()
for index in "${!assets[@]}"; do
  target=$(uint_mul "${amounts[$index]}" "$claims")
  tx=$(cast send "${assets[$index]}" 'transfer(address,uint256)(bool)' "$faucet" "$target" \
    --private-key "$private_key" --rpc-url "$rpc_url" --json | jq -er '.transactionHash')
  funding_txs+=("$tx")
done

verify_faucet "$faucet"
runtime_hash=$(cast keccak "$(cast code "$faucet" --rpc-url "$rpc_url")")
block=$(cast receipt "$deploy_tx" blockNumber --rpc-url "$rpc_url")
timestamp=$(date -u +%Y%m%dT%H%M%SZ)
artifact_dir="artifacts/rehearsal-faucet/$timestamp"
mkdir -p "$artifact_dir"
jq -n \
  --arg address "$faucet" --arg runtimeCodeHash "$runtime_hash" --arg deployTransaction "$deploy_tx" \
  --arg deploymentBlock "$block" --arg mintUsdgTransaction "$mint_usdg_tx" \
  --arg mintUsdStxTransaction "$mint_usdstx_tx" --arg releaseStaticsTransaction "$release_statics_tx" \
  --argjson assets "$(printf '%s\n' "${assets[@]}" | jq -R . | jq -s .)" \
  --argjson amounts "$(printf '%s\n' "${amounts[@]}" | jq -R . | jq -s .)" \
  --argjson fundingTransactions "$(printf '%s\n' "${funding_txs[@]}" | jq -R . | jq -s .)" \
  '{schemaVersion:1,address:$address,runtimeCodeHash:$runtimeCodeHash,deployTransaction:$deployTransaction,deploymentBlock:$deploymentBlock,claimBundles:100,assets:$assets,amounts:$amounts,mintUsdgTransaction:$mintUsdgTransaction,mintUsdStxTransaction:$mintUsdStxTransaction,releaseStaticsTransaction:$releaseStaticsTransaction,fundingTransactions:$fundingTransactions}' \
  > "$artifact_dir/faucet.json"

echo "rehearsal faucet deployed and funded: $faucet"
echo "record: $artifact_dir/faucet.json"
