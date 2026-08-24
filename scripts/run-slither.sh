#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SLITHER_BIN="${SLITHER_BIN:-slither}"
RESULTS_DIR="${SLITHER_RESULTS_DIR:-$ROOT/slither-results}"
RAW_JSON="$RESULTS_DIR/raw.json"
RUN_LOG="$RESULTS_DIR/run.log"

mkdir -p "$RESULTS_DIR"
cd "$ROOT"

# Slither's Foundry adapter normally invokes `forge clean` and a forced build.
# Build once through the repository-approved path, then make Slither consume only
# the resulting build-info. It may still call the read-only `forge config --json`.
forge build --build-info

set +e
"$SLITHER_BIN" . \
  --compile-force-framework foundry \
  --foundry-ignore-compile \
  --exclude-dependencies \
  --json "$RAW_JSON" \
  >"$RUN_LOG" 2>&1
slither_status=$?
set -e

if [[ ! -s "$RAW_JSON" ]]; then
  printf 'Slither produced no JSON (exit %s). See %s\n' "$slither_status" "$RUN_LOG" >&2
  exit 1
fi

python3 "$ROOT/scripts/slither_baseline.py" check --raw "$RAW_JSON"
printf 'Slither completed with detector exit %s; reviewed baseline is clean.\n' "$slither_status"
