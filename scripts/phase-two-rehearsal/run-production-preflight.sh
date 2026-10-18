#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
export STATICS_REHEARSAL_ARTIFACT_ROOT=${STATICS_REHEARSAL_ARTIFACT_ROOT:-"$SCRIPT_DIR/../../artifacts/phase-two-production-preflight"}
export STATICS_REHEARSAL_RPC_URL=${STATICS_REHEARSAL_RPC_URL:-http://127.0.0.1:18546}
source "$SCRIPT_DIR/../phase-one-rehearsal/lib/common.sh"
require_commands anvil cast forge jq git tmux python3
for input in STATICS_PHASE_TWO_RELEASE_DIR STATICS_PHASE_TWO_PRODUCTION_CANDIDATE \
    STATICS_PHASE_TWO_SAFE_JSON STATICS_PHASE_TWO_SMOKE_JSON; do
    [[ -n "${!input:-}" ]] || fail "missing required production preflight input: $input"
done
cd_repo
python3 - <<'PYTHON'
import subprocess
rows = subprocess.check_output(['git', 'status', '--porcelain', '--untracked-files=all'], text=True).splitlines()
changed = [row for row in rows if not row[3:].startswith('.solidity-auditor/')]
if changed:
    raise SystemExit('commit the complete source candidate before production preflight')
PYTHON
unset STATICS_REHEARSAL_FORK_BLOCK
"$REHEARSAL_DIR/start-fork.sh"
load_current_run
export RUN_DIR RPC_URL HEAD_COMMIT FORK_BLOCK FORK_BLOCK_HASH
export STATICS_PHASE_TWO_PREFLIGHT_HELPER="$RUN_DIR/helper.json"
export PRIVATE_KEY=$(anvil_private_key 0)
forge script script/DeployPhaseTwoPreflightHelper.s.sol:DeployPhaseTwoPreflightHelper \
    --rpc-url "$RPC_URL" --broadcast --slow --legacy \
    --out "$ARTIFACT_ROOT/build/out" --cache-path "$ARTIFACT_ROOT/build/cache" \
    >"$RUN_DIR/helper-deployment.log" 2>&1
unset PRIVATE_KEY
python3 "$SCRIPT_DIR/production-preflight.py" | tee "$RUN_DIR/preflight.log"
[[ "$(jq -er .status "$RUN_DIR/summary.json")" == pass ]] || fail "production preflight evidence incomplete"
note "production preflight evidence: $RUN_DIR/summary.json"
