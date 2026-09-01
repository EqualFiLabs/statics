#!/usr/bin/env bash
set -euo pipefail

readonly ROBINHOOD_TESTNET_CHAIN_ID="46630"
readonly EXPECTED_OWNER="0x6Ae2aD9905FEDC8270b828294D4b9CEC7CBBE316"
readonly CREATE2_DEPLOYER="0x4e59b44847b379578588920cA78FbF26c0B4956C"
readonly CREATE2_DEPLOYER_CODE_HASH="0x2fa86add0aed31f33a762c9d88e807c475bd51d0f52bd0955754b2608f7e4989"
readonly MORPHO_BLUE_COMMIT="731e3f7ed97cf15f8fe00b86e4be5365eb3802ac"
readonly ADAPTIVE_CURVE_IRM_COMMIT="a7d9cce3451b4a106bfd40933ac57a785b5228f3"
readonly IRM_MORPHO_BLUE_COMMIT="55d2d99304fb3fb930c688462ae2ccabb1d533ad"
readonly TRACKED_MANIFEST="deployments/robinhood-testnet-46630-morpho.json"
readonly DEFAULT_VERIFIER_URL="https://explorer.testnet.chain.robinhood.com/api/"

readonly -a ENABLED_LLTVS=(
  0
  385000000000000000
  625000000000000000
  770000000000000000
  860000000000000000
  915000000000000000
  945000000000000000
  965000000000000000
  980000000000000000
)

usage() {
  echo "usage: $0 --broadcast|--check" >&2
  echo "requires ROBINHOOD_TESTNET_RPC_URL; --broadcast also requires PRIVATE_KEY" >&2
}

if [[ $# -ne 1 || ( "$1" != "--broadcast" && "$1" != "--check" ) ]]; then
  usage
  exit 2
fi
readonly mode="$1"

for command_name in cast forge git jq; do
  command -v "$command_name" >/dev/null || {
    echo "missing required command: $command_name" >&2
    exit 1
  }
done

if [[ -z "${ROBINHOOD_TESTNET_RPC_URL:-}" ]]; then
  echo "missing required environment variable: ROBINHOOD_TESTNET_RPC_URL" >&2
  exit 1
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
cd "$repo_root"

require_commit() {
  local path="$1"
  local expected="$2"
  local actual
  actual="$(git -C "$path" rev-parse HEAD)"
  if [[ "$actual" != "$expected" ]]; then
    echo "dependency drift at $path: expected $expected, found $actual" >&2
    exit 1
  fi
}

require_commit verification/morpho/vendor/morpho-blue "$MORPHO_BLUE_COMMIT"
require_commit verification/morpho/vendor/morpho-blue-irm "$ADAPTIVE_CURVE_IRM_COMMIT"
require_commit verification/morpho/vendor/morpho-blue-irm/lib/morpho-blue "$IRM_MORPHO_BLUE_COMMIT"

compiler_config="$(forge config --root verification/morpho --json)"
jq -e '
  .solc == "0.8.19"
  and .evm_version == "paris"
  and .via_ir == true
  and .optimizer == true
  and .optimizer_runs == 999999
  and .bytecode_hash == "none"
' <<<"$compiler_config" >/dev/null || {
  echo "Morpho compiler configuration no longer matches the Robinhood mainnet deployment" >&2
  exit 1
}

actual_chain_id="$(cast chain-id --rpc-url "$ROBINHOOD_TESTNET_RPC_URL")"
if [[ "$actual_chain_id" != "$ROBINHOOD_TESTNET_CHAIN_ID" ]]; then
  echo "refusing chain $actual_chain_id; expected Robinhood testnet $ROBINHOOD_TESTNET_CHAIN_ID" >&2
  exit 1
fi

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

if [[ "$(code_hash "$CREATE2_DEPLOYER")" != "$CREATE2_DEPLOYER_CODE_HASH" ]]; then
  echo "Robinhood testnet CREATE2 deployer runtime hash mismatch" >&2
  exit 1
fi

normalize_address() {
  tr '[:upper:]' '[:lower:]' <<<"$1"
}

validate_deployment() {
  local manifest="$1"
  local morpho irm expected actual lltv

  jq -e --argjson chainId "$ROBINHOOD_TESTNET_CHAIN_ID" \
    '.schemaVersion == 1 and .chainId == $chainId and .morpho != null and .adaptiveCurveIrm != null' \
    "$manifest" >/dev/null

  morpho="$(jq -er '.morpho' "$manifest")"
  irm="$(jq -er '.adaptiveCurveIrm' "$manifest")"

  expected="$(jq -er '.morphoRuntimeCodeHash' "$manifest")"
  actual="$(code_hash "$morpho")"
  [[ "$actual" == "$expected" ]] || {
    echo "Morpho runtime hash mismatch: expected $expected, found $actual" >&2
    return 1
  }

  expected="$(jq -er '.adaptiveCurveIrmRuntimeCodeHash' "$manifest")"
  actual="$(code_hash "$irm")"
  [[ "$actual" == "$expected" ]] || {
    echo "AdaptiveCurveIrm runtime hash mismatch: expected $expected, found $actual" >&2
    return 1
  }

  actual="$(cast call "$morpho" 'owner()(address)' --rpc-url "$ROBINHOOD_TESTNET_RPC_URL")"
  [[ "$(normalize_address "$actual")" == "$(normalize_address "$EXPECTED_OWNER")" ]] || {
    echo "unexpected Morpho owner: $actual" >&2
    return 1
  }

  actual="$(cast call "$morpho" 'feeRecipient()(address)' --rpc-url "$ROBINHOOD_TESTNET_RPC_URL")"
  [[ "$(normalize_address "$actual")" == "0x0000000000000000000000000000000000000000" ]] || {
    echo "unexpected Morpho fee recipient: $actual" >&2
    return 1
  }

  actual="$(cast call "$irm" 'MORPHO()(address)' --rpc-url "$ROBINHOOD_TESTNET_RPC_URL")"
  [[ "$(normalize_address "$actual")" == "$(normalize_address "$morpho")" ]] || {
    echo "AdaptiveCurveIrm is bound to unexpected Morpho address: $actual" >&2
    return 1
  }

  [[ "$(cast call "$morpho" 'isIrmEnabled(address)(bool)' "$irm" --rpc-url "$ROBINHOOD_TESTNET_RPC_URL")" == "true" ]]
  [[ "$(cast call "$morpho" 'isIrmEnabled(address)(bool)' 0x0000000000000000000000000000000000000000 \
    --rpc-url "$ROBINHOOD_TESTNET_RPC_URL")" == "true" ]]

  for lltv in "${ENABLED_LLTVS[@]}"; do
    [[ "$(cast call "$morpho" 'isLltvEnabled(uint256)(bool)' "$lltv" \
      --rpc-url "$ROBINHOOD_TESTNET_RPC_URL")" == "true" ]] || {
      echo "LLTV is not enabled: $lltv" >&2
      return 1
    }
  done
}

if [[ "$mode" == "--check" ]]; then
  if [[ ! -f "$TRACKED_MANIFEST" ]]; then
    echo "missing tracked Morpho deployment manifest: $TRACKED_MANIFEST" >&2
    exit 1
  fi
  validate_deployment "$TRACKED_MANIFEST"
  echo "Reusable Robinhood testnet Morpho deployment is valid"
  exit 0
fi

if [[ -z "${PRIVATE_KEY:-}" ]]; then
  echo "missing required environment variable: PRIVATE_KEY" >&2
  exit 1
fi

deployer="$(cast wallet address --private-key "$PRIVATE_KEY")"
if [[ "$(normalize_address "$deployer")" != "$(normalize_address "$EXPECTED_OWNER")" ]]; then
  echo "refusing deployer $deployer; expected reusable testnet owner $EXPECTED_OWNER" >&2
  exit 1
fi

if [[ -f "$TRACKED_MANIFEST" ]]; then
  validate_deployment "$TRACKED_MANIFEST"
  echo "Reusable Robinhood testnet Morpho deployment already exists; no transactions sent"
  exit 0
fi

run_id="$(date -u +%Y%m%dT%H%M%SZ)-$(cast nonce "$deployer" --rpc-url "$ROBINHOOD_TESTNET_RPC_URL")"
artifact_dir="$repo_root/artifacts/morpho-testnet/$run_id"
mkdir -p "$artifact_dir"
export MORPHO_TESTNET_ARTIFACT="$artifact_dir/deployment.json"

forge script \
  --root verification/morpho \
  script/DeployMorphoTestnet.s.sol:DeployMorphoTestnet \
  --rpc-url "$ROBINHOOD_TESTNET_RPC_URL" \
  --broadcast \
  --slow \
  -vv

validate_deployment "$MORPHO_TESTNET_ARTIFACT"

morpho="$(jq -er '.morpho' "$MORPHO_TESTNET_ARTIFACT")"
irm="$(jq -er '.adaptiveCurveIrm' "$MORPHO_TESTNET_ARTIFACT")"
verifier_url="${ROBINHOOD_TESTNET_VERIFIER_URL:-$DEFAULT_VERIFIER_URL}"

forge verify-contract \
  --root verification/morpho \
  --watch \
  --chain-id "$ROBINHOOD_TESTNET_CHAIN_ID" \
  --verifier blockscout \
  --verifier-url "$verifier_url" \
  --compiler-version 0.8.19 \
  --num-of-optimizations 999999 \
  --via-ir \
  --evm-version paris \
  --constructor-args "$(cast abi-encode 'constructor(address)' "$deployer")" \
  "$morpho" \
  vendor/morpho-blue/src/Morpho.sol:Morpho

forge verify-contract \
  --root verification/morpho \
  --watch \
  --chain-id "$ROBINHOOD_TESTNET_CHAIN_ID" \
  --verifier blockscout \
  --verifier-url "$verifier_url" \
  --compiler-version 0.8.19 \
  --num-of-optimizations 999999 \
  --via-ir \
  --evm-version paris \
  --constructor-args "$(cast abi-encode 'constructor(address)' "$morpho")" \
  "$irm" \
  vendor/morpho-blue-irm/src/AdaptiveCurveIrm.sol:AdaptiveCurveIrm

echo "Reusable Robinhood testnet Morpho deployment complete"
echo "Deployment artifact: $MORPHO_TESTNET_ARTIFACT"
