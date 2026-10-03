#!/usr/bin/env bash

set -Eeuo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

require_commands anvil cast forge jq tmux
cd_repo

if [[ -f "$CURRENT_RUN_FILE" ]]; then
    "$SCRIPT_DIR/stop-fork.sh"
fi

"$SCRIPT_DIR/start-fork.sh"
"$SCRIPT_DIR/deploy-stack.sh"
"$SCRIPT_DIR/verify-deployment.sh"
load_current_run

SCENARIOS=(
    public-pool-creation.sh
    vanilla-v4-gas.sh
    public-market-tape.sh
    managed-lp-lifecycle.sh
    external-posm-attachment.sh
    liquidity-manager-replacement.sh
    position-market-transfer.sh
    permissioned-lifecycle.sh
    permissioned-creator-handover.sh
    protocol-pol-lifecycle.sh
    direct-range-rewards.sh
    allocator-rewards.sh
    public-revenue-rewards.sh
    fee-configuration.sh
    creator-handover.sh
    staking-and-gauges.sh
    multi-pool-gauges.sh
    configuration-surface.sh
    governance-controls.sh
    composed-soak.sh
)
: >"$RUN_DIR/scenario-summary.jsonl"
for scenario in "${SCENARIOS[@]}"; do
    results_before=$(wc -l <"$RUN_DIR/results.jsonl")
    receipts_before=$(find "$RUN_DIR" -maxdepth 1 -type f -name '*.json' -print0 \
        | xargs -0 -r jq -r 'if type == "object" and has("status") then .status else empty end' 2>/dev/null \
        | wc -l)
    note "running ${scenario%.sh}"
    "$SCRIPT_DIR/scenarios/$scenario"
    assert_all_receipts_succeeded "${scenario%.sh}"
    results_after=$(wc -l <"$RUN_DIR/results.jsonl")
    receipts_after=$(find "$RUN_DIR" -maxdepth 1 -type f -name '*.json' -print0 \
        | xargs -0 -r jq -r 'if type == "object" and has("status") then .status else empty end' 2>/dev/null \
        | wc -l)
    jq -cn \
        --arg scenario "${scenario%.sh}" \
        --argjson assertions "$(( results_after - results_before ))" \
        --argjson receipts "$(( receipts_after - receipts_before ))" \
        --slurpfile results <(tail -n "$(( results_after - results_before ))" "$RUN_DIR/results.jsonl") \
        '{scenario:$scenario,assertions:$assertions,receipts:$receipts,result:"pass",checks:$results}' \
        >>"$RUN_DIR/scenario-summary.jsonl"
done

"$SCRIPT_DIR/generate-selector-coverage.sh"

load_current_run
receipt_statuses=$(find "$RUN_DIR" -maxdepth 1 -type f -name '*.json' -print0 \
    | xargs -0 -r jq -r 'if type == "object" and has("status") then .status else empty end' 2>/dev/null || true)
receipt_total=$(awk 'NF { count++ } END { print count + 0 }' <<<"$receipt_statuses")
receipt_success=$(awk '$0 == "0x1" { count++ } END { print count + 0 }' <<<"$receipt_statuses")
receipt_failed=$(( receipt_total - receipt_success ))
facet_count=$(jq '[.[].facetAddress] | unique | length' "$RUN_DIR/selector-inventory.json")
selector_count=$(jq 'length' "$RUN_DIR/selector-inventory.json")
pr96_base=$(git merge-base "$HEAD_COMMIT" public/feat/staged-phase-one-launch)
jq -s \
    --slurpfile vanilla "$RUN_DIR/vanilla-swap-gas.json" \
    --slurpfile public "$RUN_DIR/public-swap-gas.json" \
    --slurpfile permissioned "$RUN_DIR/permissioned-lifecycle.json" \
    --slurpfile scenarios "$RUN_DIR/scenario-summary.jsonl" \
    --slurpfile selectorCoverage "$RUN_DIR/selector-coverage.json" \
    --slurpfile selectorCounts "$RUN_DIR/selector-coverage-counts.json" \
    --arg commit "$HEAD_COMMIT" \
    --arg phaseOneBase "$pr96_base" \
    --arg forkBlock "$FORK_BLOCK" \
    --arg forkBlockHash "$FORK_BLOCK_HASH" \
    --argjson facetCount "$facet_count" \
    --argjson selectorCount "$selector_count" \
    --argjson receiptTotal "$receipt_total" \
    --argjson receiptSuccess "$receipt_success" \
    --argjson receiptFailed "$receipt_failed" '
    {
        commitTested: $commit,
        phaseOneBaseCommit: $phaseOneBase,
        rehearsalCommit: $commit,
        fork: {block: $forkBlock, blockHash: $forkBlockHash},
        facetCount: $facetCount,
        selectorCount: $selectorCount,
        results: .,
        counts: (group_by(.status) | map({key: .[0].status, value: length}) | from_entries),
        scenarios: $scenarios,
        scenarioCount: ($scenarios | length),
        recordedChecks: length,
        receipts: {mined:$receiptTotal,successful:$receiptSuccess,failed:$receiptFailed},
        selectorCoverage: {
            classifications: $selectorCounts[0],
            unrehearsed: ($selectorCoverage[0] | map(select(.classification == "not-rehearsed"))),
            unqueriedViews: ($selectorCoverage[0] | map(select(.classification == "view" and .successCovered == false)))
        },
        finalSolvencyStatus: (if ((map(select(.suite == "accounting" and .status != "pass")) | length) == 0) then "pass" else "fail" end),
        gas: {
            vanilla: $vanilla[0],
            public: $public[0],
            permissioned: ($permissioned[0] | {coldSwapGas, steadySwapGas})
        }
    }
' "$RUN_DIR/results.jsonl" >"$RUN_DIR/summary.json"

FAILURES=$(jq -r '.counts.fail // 0' "$RUN_DIR/summary.json")
assert_eq "$FAILURES" 0 "rehearsal failure count"
assert_eq "$receipt_failed" 0 "failed mined receipt count"
note "complete: $RUN_DIR/summary.json"
