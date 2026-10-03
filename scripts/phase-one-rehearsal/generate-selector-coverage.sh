#!/usr/bin/env bash

set -Eeuo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

require_commands jq rg awk sort
load_current_run

INVENTORY="$RUN_DIR/selector-inventory.json"
[[ -f "$INVENTORY" ]] || fail "selector inventory is missing: $INVENTORY"
OUTPUT_JSONL="$RUN_DIR/selector-coverage.jsonl"
OUTPUT_JSON="$RUN_DIR/selector-coverage.json"
: >"$OUTPUT_JSONL"

is_indirect() {
    case "$1" in
        afterStaticsPoolSwap|recordMarketObservation|routeProtocolSwapFees|createPositionForModule|activatePositionModule|deactivatePositionModule|syncGaugeAllocationsAfterStakeLoss)
            return 0
            ;;
    esac
    return 1
}

is_deployment_only() {
    case "$1" in
        diamondCut|installCanonicalPoolIntegration|installLiquidityIntegration|installLiquidityManager|installPermissionedLiquidityIntegration|installPermissionedPoolIntegration|setInterfaces|transferOwnership)
            return 0
            ;;
    esac
    return 1
}

while IFS= read -r item; do
    selector=$(jq -r '.selector' <<<"$item")
    signature=$(jq -r '.signatures[0]' <<<"$item")
    facet=$(jq -r '.facet' <<<"$item")
    facet_address=$(jq -r '.facetAddress' <<<"$item")
    mutability=$(jq -r '.stateMutability' <<<"$item")
    function_name=${signature%%(*}
    success=false
    revert=false
    scenarios=()

    while IFS= read -r file; do
        [[ -n "$file" ]] || continue
        scenario=$(basename "$file" .sh)
        scenarios+=("$scenario")
        read -r file_success file_revert <<<"$(
            awk -v target="$signature" '
                BEGIN { success = 0; reverted = 0; in_revert = 0 }
                /expect_call_revert/ { in_revert = 1 }
                index($0, target) {
                    if (in_revert) reverted = 1
                    else success = 1
                }
                in_revert && $0 !~ /\\[[:space:]]*$/ { in_revert = 0 }
                END { print success, reverted }
            ' "$file"
        )"
        [[ "$file_success" == 1 ]] && success=true
        [[ "$file_revert" == 1 ]] && revert=true
    done < <(rg -l -F --glob '*.sh' -- "$signature" "$SCRIPT_DIR/scenarios" 2>/dev/null | sort -u || true)

    if rg -q -F --glob '*.sh' -- "$signature" \
        "$SCRIPT_DIR/deploy-stack.sh" "$SCRIPT_DIR/verify-deployment.sh" 2>/dev/null; then
        scenarios+=(deployment)
        success=true
    fi

    if [[ "$mutability" == view || "$mutability" == pure ]]; then
        classification=view
    elif is_indirect "$function_name"; then
        classification=indirect-hook
        success=true
        scenarios+=(hook-callback)
    elif is_deployment_only "$function_name"; then
        classification=deployment-only
        success=true
        scenarios+=(deployment)
    elif [[ "$success" == true ]]; then
        classification=direct-success
    elif [[ "$revert" == true ]]; then
        classification=direct-revert
    else
        classification=not-rehearsed
    fi

    scenario_json=$(printf '%s\n' "${scenarios[@]:-}" | awk 'NF' | sort -u | jq -R . | jq -s .)
    note=""
    if [[ "$classification" == not-rehearsed ]]; then
        note="Installed and route-verified; no direct fork scenario"
    elif [[ "$classification" == view && "$success" == false ]]; then
        note="Installed view; not queried by the rehearsal"
    fi
    jq -cn \
        --arg selector "$selector" \
        --arg signature "$signature" \
        --arg facet "$facet" \
        --arg facetAddress "$facet_address" \
        --arg classification "$classification" \
        --argjson scenarios "$scenario_json" \
        --argjson success "$success" \
        --argjson revert "$revert" \
        --arg notes "$note" \
        '{selector:$selector,signature:$signature,facet:$facet,facetAddress:$facetAddress,
          scenarios:$scenarios,successCovered:$success,revertCovered:$revert,
          classification:$classification,notes:$notes}' >>"$OUTPUT_JSONL"
done < <(jq -c '.[]' "$INVENTORY")

jq -s '.' "$OUTPUT_JSONL" >"$OUTPUT_JSON"
assert_eq "$(jq 'length' "$OUTPUT_JSON")" "$(jq 'length' "$INVENTORY")" "selector coverage row count"
jq -n \
    --slurpfile coverage "$OUTPUT_JSON" '
    $coverage[0]
    | group_by(.classification)
    | map({key: .[0].classification, value: length})
    | from_entries
' >"$RUN_DIR/selector-coverage-counts.json"
unrehearsed_count=$(jq '[.[] | select(.classification == "not-rehearsed")] | length' "$OUTPUT_JSON")
unqueried_view_count=$(jq \
    '[.[] | select(.classification == "view" and .successCovered == false)] | length' "$OUTPUT_JSON")
assert_eq "$unrehearsed_count" 0 "unrehearsed state-changing selector count"
assert_eq "$unqueried_view_count" 0 "unqueried view selector count"
note "selector coverage: $OUTPUT_JSON"
