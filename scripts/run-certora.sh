#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="${1:-all}"
CERTORA_BIN="${CERTORA_BIN:-certoraRun}"

cd "$ROOT"

run_spec() {
  local config="$1"
  "$CERTORA_BIN" "$ROOT/certora/conf/$config.conf"
}

case "$TARGET" in
  vault)
    run_spec GenesisVault
    ;;
  fees)
    run_spec FeeReceiver
    ;;
  distributor)
    run_spec GenesisDistributor
    ;;
  all)
    run_spec GenesisVault
    run_spec FeeReceiver
    run_spec GenesisDistributor
    ;;
  *)
    printf 'unknown Certora target: %s\n' "$TARGET" >&2
    exit 2
    ;;
esac
