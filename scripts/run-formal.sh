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
    --solver-timeout-branching "${HALMOS_BRANCH_TIMEOUT:-0}" \
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
    run_halmos "$ROOT" GenesisCreditHalmosTest credit-repeated-utilization 8 out-formal-genesis \
      '^check_repeatedDrawRepayRestoresCapacity'
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
  launch-liquidity)
    run_halmos "$ROOT" StaticsLaunchLiquidityHookHalmosTest launch-liquidity-before-swap 8 out-formal-genesis \
      '^check_beforeSwapRoutesExactSpecifiedFee'
    run_halmos "$ROOT" StaticsLaunchLiquidityHookHalmosTest launch-liquidity-balance-delta-packing 8 \
      out-formal-genesis '^check_balanceDeltaHighHalfRoundTrips'
    run_halmos "$ROOT" StaticsLaunchLiquidityHookHalmosTest launch-liquidity-after-swap-exact-input-zero-for-one \
      8 out-formal-genesis '^check_afterSwapRoutesExactUnspecifiedFeeExactInputZeroForOne'
    run_halmos "$ROOT" StaticsLaunchLiquidityHookHalmosTest launch-liquidity-after-swap-exact-input-one-for-zero \
      8 out-formal-genesis '^check_afterSwapRoutesExactUnspecifiedFeeExactInputOneForZero'
    run_halmos "$ROOT" StaticsLaunchLiquidityHookHalmosTest launch-liquidity-after-swap-exact-output-zero-for-one \
      8 out-formal-genesis '^check_afterSwapRoutesExactUnspecifiedFeeExactOutputZeroForOne'
    run_halmos "$ROOT" StaticsLaunchLiquidityHookHalmosTest launch-liquidity-after-swap-exact-output-one-for-zero \
      8 out-formal-genesis '^check_afterSwapRoutesExactUnspecifiedFeeExactOutputOneForZero'
    run_halmos "$ROOT" StaticsLaunchLiquidityHookHalmosTest launch-liquidity-pool-isolation 8 out-formal-genesis \
      '^check_feeUpdatesRemainPoolLocal'
    run_halmos "$ROOT" StaticsLaunchLiquidityHookHalmosTest launch-liquidity-receiver 8 out-formal-genesis \
      '^check_receiverUpdatePreservesEveryPool'
    run_halmos "$ROOT" StaticsLaunchLiquidityHookHalmosTest launch-liquidity-initialization 8 out-formal-genesis \
      '^check_initializationAcceptsOnlyBoundManagerAndPrice'
    run_halmos "$ROOT" StaticsLaunchLiquidityHookHalmosTest launch-liquidity-authorization 8 out-formal-genesis \
      '^check_unauthorizedCallerCannotChangeConfiguration'
    run_halmos "$ROOT" StaticsLaunchLiquidityHookHalmosTest launch-liquidity-active-state 8 out-formal-genesis \
      '^check_initializedPoolsStayActiveAfterConfigurationChanges'
    run_halmos "$ROOT" StaticsLaunchLiquidityHookHalmosTest launch-liquidity-full-fill 8 out-formal-genesis \
      '^check_incompleteSpecifiedFillRevertsBeforeUnspecifiedClaim'
    run_halmos "$ROOT" StaticsLaunchLiquidityGovernanceHalmosTest launch-liquidity-registration-authority 8 \
      out-formal-genesis '^check_registrationTracksCurrentProposerRole'
    run_halmos "$ROOT" StaticsLaunchLiquidityGovernanceHalmosTest launch-liquidity-owner-registration 8 \
      out-formal-genesis '^check_ownerCanRegisterDirectly'
    run_halmos "$ROOT" StaticsLaunchLiquidityGovernanceHalmosTest launch-liquidity-proposer-revocation 8 \
      out-formal-genesis '^check_revokedProposerCannotRegister'
    run_halmos "$ROOT" StaticsLaunchLiquidityGovernanceHalmosTest launch-liquidity-proposer-boundary 8 \
      out-formal-genesis '^check_proposerCannotChangeOwnerOnlyConfiguration'
    ;;
  permanent-liquidity)
    # Unknown branch-feasibility results are conservatively explored on both sides by Halmos.
    # Bound those pruning queries so full-precision mulDiv internals cannot monopolize the job.
    HALMOS_BRANCH_TIMEOUT="${HALMOS_PERMANENT_BRANCH_TIMEOUT:-100ms}"
    run_halmos "$ROOT" StaticsPermanentLiquidityHookHalmosTest permanent-liquidity-allocation 8 \
      out-formal-genesis '^check_specifiedFeeAllocationEqualsMintedClaim'
    run_halmos "$ROOT" StaticsPermanentLiquidityHookHalmosTest permanent-liquidity-compounding 8 \
      out-formal-genesis '^check_claimFundedCompoundingConservesLiabilities'
    run_halmos "$ROOT" StaticsPermanentLiquidityHookHalmosTest permanent-liquidity-overspend 8 \
      out-formal-genesis '^check_claimFundedCompoundingRejectsOverspend'
    ;;
  phase-one)
    run_halmos "$ROOT" PhaseOneEmergencyControlsHalmosTest phase-one-swap-pause-authority 8 \
      out-formal-genesis '^check_onlyGuardianOrOwnerCanStopAllProtocolSwaps'
    run_halmos "$ROOT" PhaseOneEmergencyControlsHalmosTest phase-one-swap-restore-authority 8 \
      out-formal-genesis '^check_guardianCannotRestoreProtocolSwaps'
    run_halmos "$ROOT" PhaseOneEmergencyControlsHalmosTest phase-one-pool-quarantine-isolation 8 \
      out-formal-genesis '^check_poolQuarantineRemainsIsolatedUntilGlobalPause'
    run_halmos "$ROOT" PhaseOneEmergencyControlsHalmosTest phase-one-stake-pause-separation 8 \
      out-formal-genesis '^check_guardianStakePauseCannotSetOwnerOnlyAction'
    run_halmos "$ROOT" PhaseOnePermissionedPolicyHalmosTest phase-one-reward-restriction-add-authority 8 \
      out-formal-genesis '^check_onlyGuardianOrOwnerCanAddRewardRestriction'
    run_halmos "$ROOT" PhaseOnePermissionedPolicyHalmosTest phase-one-reward-restriction-remove-authority 8 \
      out-formal-genesis '^check_onlyOwnerCanRemoveRewardRestriction'
    # The minimum nonzero rate is the hardest configured fee to keep above zero. Prove that
    # boundary across every uint64 gross output; uint128 amounts and general rates are fuzz-covered.
    HALMOS_BRANCH_TIMEOUT="${HALMOS_PERMISSIONED_FEE_BRANCH_TIMEOUT:-100ms}" \
      run_halmos "$ROOT" PhaseOnePermissionedPolicyHalmosTest phase-one-permissioned-both-restricted-split 8 \
        out-formal-genesis '^check_bothRestrictedDistributionConservesFee'
    HALMOS_BRANCH_TIMEOUT="${HALMOS_PERMISSIONED_FEE_BRANCH_TIMEOUT:-100ms}" \
      run_halmos "$ROOT" PhaseOnePermissionedPolicyHalmosTest phase-one-permissioned-minimum-fee-nonzero 8 \
        out-formal-genesis '^check_minimumGrossFeeNeverRoundsToZero'
    ;;
  range-gauges)
    # Full-precision mulDiv and modular-growth branches can make feasibility refinement
    # dominate otherwise small rules. As in the permanent-liquidity suite, unknown
    # branch feasibility is conservatively explored on both sides while assertions
    # retain their unbounded solver timeout.
    HALMOS_BRANCH_TIMEOUT="${HALMOS_RANGE_GAUGE_BRANCH_TIMEOUT:-100ms}"
    run_halmos "$ROOT" RangeGaugeAccountingHalmosTest range-gauge-stream-conservation 8 \
      out-formal-genesis '^check_streamEmitsEntireBudgetAtFinish'
    run_halmos "$ROOT" RangeGaugeAccountingHalmosTest range-gauge-zero-liquidity-pause 8 \
      out-formal-genesis '^check_zeroLiquidityPausesWithoutEmitting'
    run_halmos "$ROOT" RangeGaugeAccountingHalmosTest range-gauge-top-up-conservation 8 \
      out-formal-genesis '^check_topUpPreservesFinishAndConservesBudget'
    run_halmos "$ROOT" RangeGaugeAccountingHalmosTest range-gauge-lifetime-index-capacity 8 \
      out-formal-genesis '^check_lifetimeIndexCapacityTracksConsecutivePeriods'
    run_halmos "$ROOT" RangeGaugeAccountingHalmosTest range-gauge-position-remainder 8 \
      out-formal-genesis '^check_positionRemainderCarryConservesNumerator'
    run_halmos "$ROOT" RangeGaugeAccountingHalmosTest range-gauge-final-reconciliation-gate 8 \
      out-formal-genesis '^check_finalReconciliationRequiresResolvedLiabilities'
    run_halmos "$ROOT" GaugeReserveHalmosTest range-gauge-reserve-commitment 8 \
      out-formal-genesis '^check_releaseCommitmentPreservesReservePartition'
    run_halmos "$ROOT" GaugeReserveHalmosTest range-gauge-reserve-recycling 8 \
      out-formal-genesis '^check_claimAndRecycleConserveBackedReserve'
    run_halmos "$ROOT" RangeGaugeBoundaryHalmosTest range-gauge-boundary-symmetry 8 \
      out-formal-genesis '^check_boundaryAddRemoveSymmetry'
    run_halmos "$ROOT" RangeGaugeBoundaryHalmosTest range-gauge-right-crossing-inversion 8 \
      out-formal-genesis '^check_rightThenLeftCrossingRestoresLiquidity'
    run_halmos "$ROOT" RangeGaugeBoundaryHalmosTest range-gauge-left-crossing-inversion 8 \
      out-formal-genesis '^check_leftThenRightCrossingRestoresLiquidity'
    run_halmos "$ROOT" RangeGaugeBoundaryHalmosTest range-gauge-topology-restoration 8 \
      out-formal-genesis '^check_registerThenUnregisterRestoresTopology'
    run_halmos "$ROOT" RangeGaugeBoundaryHalmosTest range-gauge-inside-growth 8 \
      out-formal-genesis '^check_insideGrowthMatchesRegionIdentity'
    ;;
  established)
    for target in vault fees distributor genesis vesting credit rewards position genesis-rewards launch-liquidity; do
      "$0" "$target"
    done
    "$0" geometry
    ;;
  all)
    "$0" established
    "$0" permanent-liquidity
    "$0" phase-one
    "$0" range-gauges
    ;;
  *)
    printf 'unknown formal target: %s\n' "$TARGET" >&2
    exit 2
    ;;
esac
