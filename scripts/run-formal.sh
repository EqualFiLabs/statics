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
  local loop_bound="${4:-${HALMOS_LOOP_BOUND:-8}}"
  local build_out="${5:-out-formal-genesis}"
  FOUNDRY_PROFILE=formal "$HALMOS_BIN" \
    --root "$root" \
    --contract "$contract" \
    --solver-timeout-branching 0 \
    --solver-timeout-assertion 0 \
    --solver-threads "${HALMOS_THREADS:-4}" \
    --loop "$loop_bound" \
    --forge-build-out "$build_out" \
    --json-output "$HALMOS_JSON_DIR/$output.json"
}

run_halmos_match() {
  local root="$1"
  local contract_regex="$2"
  local output="$3"
  local loop_bound="${4:-${HALMOS_LOOP_BOUND:-8}}"
  local build_out="${5:-out-formal-genesis}"
  FOUNDRY_PROFILE=formal "$HALMOS_BIN" \
    --root "$root" \
    --match-contract "$contract_regex" \
    --solver-timeout-branching 0 \
    --solver-timeout-assertion 0 \
    --solver-threads "${HALMOS_THREADS:-4}" \
    --loop "$loop_bound" \
    --forge-build-out "$build_out" \
    --json-output "$HALMOS_JSON_DIR/$output.json"
}

case "$TARGET" in
  geometry)
    run_halmos "$ROOT/verification/doppler" DopplerLaunchGeometryHalmosTest geometry 8 out-formal
    forge test \
      --root "$ROOT/verification/doppler" \
      --match-path test/DopplerLaunchGeometry.halmos.t.sol
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
  vesting)
    run_halmos "$ROOT" StaticsTreasuryVestingHalmosTest vesting
    ;;
  all)
    run_halmos_match "$ROOT" \
      '^(StaticsGenesisVaultHalmosTest|StaticsFeeReceiverHalmosTest|GenesisLaunchDistributorHalmosTest|StaticsGenesisHalmosTest|StaticsTreasuryVestingHalmosTest)$' \
      genesis-all
    "$0" geometry
    ;;
  *)
    printf 'unknown formal target: %s\n' "$TARGET" >&2
    exit 2
    ;;
esac
