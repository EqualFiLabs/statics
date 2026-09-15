#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SLITHER_BIN="${SLITHER_BIN:-slither}"
RESULTS_DIR="${SLITHER_RESULTS_DIR:-$ROOT/slither-results}"
RAW_JSON="$RESULTS_DIR/raw.json"
CURRENT_JSON="$RESULTS_DIR/current.json"
SCOPE_REPORT="$RESULTS_DIR/scope.json"
RUN_LOG="$RESULTS_DIR/run.log"

mkdir -p "$RESULTS_DIR"
cd "$ROOT"

# Keep the build configuration identical when Forge creates build-info and when
# Slither asks the Foundry adapter for project metadata.
export FOUNDRY_PROFILE=slither

python3 "$ROOT/scripts/slither_baseline.py" scope --output "$SCOPE_REPORT"

# Slither's Foundry adapter normally invokes `forge clean` and a forced build.
# Build only the reviewed production roots through the repository-approved path,
# then make Slither consume only that build-info. This keeps test harnesses out of
# detector analysis while preserving every file enforced by scope.json. Slither
# may still call the read-only `forge config --json`.
forge build --build-info src script

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

python3 "$ROOT/scripts/slither_baseline.py" check \
  --raw "$RAW_JSON" \
  --output "$CURRENT_JSON"
printf 'Slither completed with detector exit %s; reviewed baseline is clean.\n' "$slither_status"
