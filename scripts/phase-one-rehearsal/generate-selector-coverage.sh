#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/lib/common.sh"
require_commands python3
load_current_run
python3 "$SCRIPT_DIR/helpers/validate-pol-evidence.py" "$RUN_DIR" "$STATICS_DIAMOND_ADDRESS" >/dev/null
python3 "$SCRIPT_DIR/helpers/selector-coverage.py" "$RUN_DIR" "$STATICS_DIAMOND_ADDRESS"
note "transaction-backed selector coverage: $RUN_DIR/selector-coverage.json"
