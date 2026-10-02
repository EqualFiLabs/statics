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

SCENARIOS=(
    public-pool-creation.sh
    vanilla-v4-gas.sh
    public-market-tape.sh
    managed-lp-lifecycle.sh
    liquidity-manager-replacement.sh
    position-market-transfer.sh
    permissioned-lifecycle.sh
    permissioned-creator-handover.sh
    protocol-pol-lifecycle.sh
    direct-range-rewards.sh
    allocator-rewards.sh
    public-revenue-rewards.sh
    creator-handover.sh
    staking-and-gauges.sh
    multi-pool-gauges.sh
    governance-controls.sh
)
for scenario in "${SCENARIOS[@]}"; do
    note "running ${scenario%.sh}"
    "$SCRIPT_DIR/scenarios/$scenario"
    assert_all_receipts_succeeded "${scenario%.sh}"
done

load_current_run
jq -s \
    --slurpfile vanilla "$RUN_DIR/vanilla-swap-gas.json" \
    --slurpfile public "$RUN_DIR/public-swap-gas.json" \
    --slurpfile permissioned "$RUN_DIR/permissioned-lifecycle.json" '
    {
        results: .,
        counts: (group_by(.status) | map({key: .[0].status, value: length}) | from_entries),
        gas: {
            vanilla: $vanilla[0],
            public: $public[0],
            permissioned: ($permissioned[0] | {coldSwapGas, steadySwapGas})
        }
    }
' "$RUN_DIR/results.jsonl" >"$RUN_DIR/summary.json"

FAILURES=$(jq -r '.counts.fail // 0' "$RUN_DIR/summary.json")
assert_eq "$FAILURES" 0 "rehearsal failure count"
note "complete: $RUN_DIR/summary.json"
