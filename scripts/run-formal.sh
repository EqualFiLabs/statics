#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="${1:-all}"
HALMOS_BIN="${HALMOS_BIN:-halmos}"
HALMOS_JSON_DIR="${HALMOS_JSON_DIR:-$ROOT/formal-results}"

mkdir -p "$HALMOS_JSON_DIR"

run_halmos() {
  local root="$1"
  local contract="$2"
  local output="$3"
  FOUNDRY_PROFILE=formal "$HALMOS_BIN" \
    --root "$root" \
    --contract "$contract" \
    --solver-timeout-branching 0 \
    --solver-timeout-assertion 0 \
    --solver-threads "${HALMOS_THREADS:-4}" \
    --forge-build-out out-formal \
    --json-output "$HALMOS_JSON_DIR/$output.json"
}

case "$TARGET" in
  geometry)
    run_halmos "$ROOT/verification/doppler" DopplerLaunchGeometryHalmosTest geometry
    ;;
  vault)
    run_halmos "$ROOT" StaticsGenesisVaultHalmosTest vault
    ;;
  fees)
    run_halmos "$ROOT" StaticsFeeReceiverHalmosTest fees
    ;;
  distributor)
    run_halmos "$ROOT" GenesisLaunchDistributorHalmosTest distributor
    ;;
  genesis)
    run_halmos "$ROOT" StaticsGenesisHalmosTest genesis
    ;;
  escrow)
    run_halmos "$ROOT" StaticsLaunchAllocationEscrowHalmosTest escrow
    ;;
  all)
    for target in vault fees distributor genesis escrow; do
      "$0" "$target"
    done
    "$0" geometry
    ;;
  *)
    printf 'unknown formal target: %s\n' "$TARGET" >&2
    exit 2
    ;;
esac
