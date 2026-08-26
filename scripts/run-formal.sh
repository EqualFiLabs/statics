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
  local match_test="${6:-}"
  local args=(
    --root "$root" \
    --contract "$contract" \
    --solver-timeout-branching 0 \
    --solver-timeout-assertion 0 \
    --solver-threads "${HALMOS_THREADS:-4}" \
    --loop "$loop_bound" \
    --forge-build-out "$build_out" \
    --json-output "$HALMOS_JSON_DIR/$output.json"
  )
  if [[ -n "$match_test" ]]; then
    args+=(--match-test "$match_test")
  fi
  FOUNDRY_PROFILE=formal "$HALMOS_BIN" "${args[@]}"
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
  credit)
    run_halmos "$ROOT" GenesisCreditHalmosTest credit-lifecycle 8 out-formal-genesis \
      '^check_openAndRepayAreExactInverses'
    run_halmos "$ROOT" GenesisCreditHalmosTest credit-extension 8 out-formal-genesis \
      '^check_extensionOnlyChangesMaturityAndFeeAccounting'
    run_halmos "$ROOT" GenesisCreditHalmosTest credit-recovery 8 out-formal-genesis \
      '^check_recoveryConservesResidualAndRemovesWeightBeforeIndexing'
    run_halmos "$ROOT" GenesisCreditHalmosTest credit-fee-split 8 out-formal-genesis \
      '^check_governedFeeSplitAlwaysConservesExactFee'
    ;;
  rewards)
    run_halmos "$ROOT" GlobalRewardsHalmosTest rewards-multiplier 8 out-formal-genesis \
      '^check_multiplierAlwaysDerivesFromRawStake'
    run_halmos "$ROOT" GlobalRewardsHalmosTest rewards-stepwise 8 out-formal-genesis \
      '^check_stepwiseMultiplierMatchesDirectTransition'
    run_halmos "$ROOT" GlobalRewardsHalmosTest rewards-migration 25 out-formal-genesis \
      '^check_lazyMigrationInitializesOneToOneAndIsIdempotent'
    run_halmos "$ROOT" GlobalRewardsHalmosTest rewards-maturity 25 out-formal-genesis \
      '^check_bucketMaturityConservesRawStakeAndWeight'
    ;;
  position)
    run_halmos "$ROOT" GenesisPositionHalmosTest position
    ;;
  genesis-rewards)
    run_halmos "$ROOT" GenesisRewardsHalmosTest genesis-rewards-registration 8 out-formal-genesis \
      '^check_lateRegistrationStartsAtCurrentIndex'
    run_halmos "$ROOT" GenesisRewardsHalmosTest genesis-rewards-allocation 8 out-formal-genesis \
      '^check_allocationCannotCreateRewards'
    run_halmos "$ROOT" GenesisRewardsHalmosTest genesis-rewards-recovery 8 out-formal-genesis \
      '^check_recoveryIndexAllocatesOnlyToRemainingWeight'
    ;;
  all)
    for target in vault fees distributor genesis vesting credit rewards position genesis-rewards; do
      "$0" "$target"
    done
    "$0" geometry
    ;;
  *)
    printf 'unknown formal target: %s\n' "$TARGET" >&2
    exit 2
    ;;
esac
