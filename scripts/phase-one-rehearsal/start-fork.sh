#!/usr/bin/env bash

set -Eeuo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

require_commands anvil cast jq git tmux

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
tmux new-session -d -s "$ANVIL_SESSION" \
    "exec anvil --fork-url '$ROBINHOOD_MAINNET' --fork-block-number '$FORK_BLOCK' --chain-id 4663 --host 127.0.0.1 --port 8545 --mnemonic '$ANVIL_MNEMONIC' --accounts 20 --balance 1000000 >'$ANVIL_LOG' 2>&1"

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
