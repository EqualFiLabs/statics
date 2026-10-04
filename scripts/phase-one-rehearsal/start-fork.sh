#!/usr/bin/env bash

set -Eeuo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

require_commands anvil cast jq git tmux python3

RPC_ENV=/home/hooftly/.openclaw/workspace/.rpc
[[ -r "$RPC_ENV" ]] || fail "canonical RPC environment is unavailable"
set -a
# shellcheck disable=SC1090
source "$RPC_ENV"
set +a
[[ -n "${ROBINHOOD_MAINNET:-}" ]] || fail "ROBINHOOD_MAINNET is not configured"

if cast chain-id --rpc-url "$RPC_URL" >/dev/null 2>&1; then
    fail "an RPC is already responding at $RPC_URL; stop it or choose STATICS_REHEARSAL_RPC_URL"
fi

cd_repo
# The configured provider prunes historical trie proofs, so capture its current
# executable state and pin the exact block and hash in this run's artifacts.
FORK_BLOCK=$(cast block-number --rpc-url "$ROBINHOOD_MAINNET")
EXPECTED_BLOCK_HASH=$(cast block "$FORK_BLOCK" --field hash --rpc-url "$ROBINHOOD_MAINNET")
RUN_ID=$(date -u +%Y%m%dT%H%M%SZ)
RUN_DIR="$ARTIFACT_ROOT/$RUN_ID"
mkdir -p "$RUN_DIR"

ANVIL_LOG="$RUN_DIR/anvil.log"
ANVIL_SESSION="statics-p1-$RUN_ID"
ANVIL_PORT=$(python3 -c 'import sys; from urllib.parse import urlsplit
p=urlsplit(sys.argv[1])
assert p.scheme=="http" and p.hostname=="127.0.0.1" and p.port and not p.username and not p.password
print(p.port)' "$RPC_URL")
# The detached command contains the variable name, never its secret value.
# Load the canonical environment in that shell and redact even error output.
printf -v launch_command 'set -o pipefail; set -a; source %q; set +a; anvil --silent --fork-url "$ROBINHOOD_MAINNET" --fork-block-number %q --chain-id 4663 --host 127.0.0.1 --port %q --mnemonic %q --accounts 20 --balance 1000000 2>&1 | python3 %q >%q' \
    "$RPC_ENV" "$FORK_BLOCK" "$ANVIL_PORT" "$ANVIL_MNEMONIC" "$SCRIPT_DIR/helpers/redact-rpc.py" "$ANVIL_LOG"
printf -v tmux_command 'exec bash --noprofile --norc -c %q' "$launch_command"
tmux new-session -d -s "$ANVIL_SESSION" "$tmux_command"

ready=0
for _ in $(seq 1 120); do
    if cast chain-id --rpc-url "$RPC_URL" >/dev/null 2>&1; then
        ready=1
        break
    fi
    sleep 0.25
done
if [[ "$ready" != "1" ]]; then
    tmux kill-session -t "$ANVIL_SESSION" 2>/dev/null || true
    fail "Anvil did not become ready; inspect $ANVIL_LOG"
fi

CHAIN_ID=$(cast chain-id --rpc-url "$RPC_URL")
BLOCK_NUMBER=$(cast block-number --rpc-url "$RPC_URL")
BLOCK_HASH=$(cast block "$BLOCK_NUMBER" --field hash --rpc-url "$RPC_URL")
assert_eq "$CHAIN_ID" "4663" "fork chain ID"
assert_eq "$BLOCK_NUMBER" "$FORK_BLOCK" "fork block"
assert_eq "$BLOCK_HASH" "$EXPECTED_BLOCK_HASH" "fork block hash"
cast rpc --rpc-url "$RPC_URL" anvil_nodeInfo >/dev/null

GENESIS_MANIFEST="$REPO_ROOT/deployments/robinhood-mainnet-genesis.json"
GENESIS_FINALIZE_BLOCK=$(jq -er '.network.finalizeEndBlock' "$GENESIS_MANIFEST")
[[ "$FORK_BLOCK" -ge "$GENESIS_FINALIZE_BLOCK" ]] \
    || fail "fork block predates the deployed Genesis finalization"
GENESIS_STATICS=$(jq -er '.contracts.staticsToken.address' "$GENESIS_MANIFEST")
[[ "$(cast code "$GENESIS_STATICS" --rpc-url "$RPC_URL")" != "0x" ]] \
    || fail "deployed Genesis STATICS is unavailable at the pinned fork block"

# The public Anvil mnemonic addresses may already have EIP-7702 delegation code
# at the pinned fork block. They are local test actors here, so restore ordinary
# EOA semantics before any deployment or ERC-721 receiver checks.
for account_index in $(seq 0 19); do
    cast rpc --rpc-url "$RPC_URL" anvil_setCode "$(anvil_address "$account_index")" 0x >/dev/null
done

GENESIS_GOVERNANCE=$(jq -er '.roles.governance' "$GENESIS_MANIFEST")
cast rpc --rpc-url "$RPC_URL" anvil_impersonateAccount "$GENESIS_GOVERNANCE" >/dev/null
cast rpc --rpc-url "$RPC_URL" anvil_setBalance "$GENESIS_GOVERNANCE" 0x3635c9adc5dea00000 >/dev/null

HEAD_COMMIT=$(git rev-parse HEAD)
cat >"$RUN_DIR/state.env" <<EOF
RUN_ID=$RUN_ID
RUN_DIR=$RUN_DIR
RPC_URL=$RPC_URL
ANVIL_SESSION=$ANVIL_SESSION
FORK_BLOCK=$FORK_BLOCK
FORK_BLOCK_HASH=$BLOCK_HASH
HEAD_COMMIT=$HEAD_COMMIT
EOF
cat >"$CURRENT_RUN_FILE" <<EOF
RUN_DIR=$RUN_DIR
EOF
: >"$RUN_DIR/results.jsonl"

note "fork ready at $RPC_URL"
note "run $RUN_ID, block $FORK_BLOCK, commit $HEAD_COMMIT"
note "artifacts: $RUN_DIR"
