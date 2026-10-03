#!/usr/bin/env bash

set -Eeuo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

load_current_run
[[ "${ANVIL_SESSION:-}" =~ ^statics-p1-[0-9TZ]+$ ]] || fail "recorded Anvil session is invalid"
if tmux has-session -t "$ANVIL_SESSION" 2>/dev/null; then
    tmux kill-session -t "$ANVIL_SESSION"
fi
rm -f "$CURRENT_RUN_FILE"
note "stopped Anvil for run $RUN_ID"
