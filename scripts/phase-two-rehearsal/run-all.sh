#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
export STATICS_REHEARSAL_ARTIFACT_ROOT=${STATICS_REHEARSAL_ARTIFACT_ROOT:-"$SCRIPT_DIR/../../artifacts/phase-two-rehearsal"}
export STATICS_REHEARSAL_RPC_URL=${STATICS_REHEARSAL_RPC_URL:-http://127.0.0.1:18545}
source "$SCRIPT_DIR/../phase-one-rehearsal/lib/common.sh"
require_commands anvil cast forge jq git tmux python3 bc
export FOUNDRY_BYTECODE_HASH=ipfs
cd_repo
if [[ "${STATICS_REHEARSAL_QUALIFICATION:-}" == true ]]; then
    python3 - <<'PYTHON'
import subprocess
rows=subprocess.check_output(['git','status','--porcelain','--untracked-files=all'],text=True).splitlines()
changed=[row for row in rows if not row[3:].startswith('.solidity-auditor/')]
if changed:
    raise SystemExit('commit the source candidate before qualification')
PYTHON
fi
python3 -c 'from Crypto.Hash import keccak'
export STATICS_REHEARSAL_FORK_BLOCK=$(jq -er .block test/fixtures/immutable-hooks-phase-one.json)
"$REHEARSAL_DIR/start-fork.sh"
load_current_run
export RUN_DIR RPC_URL HEAD_COMMIT
assert_eq "$FORK_BLOCK_HASH" "$(jq -er .blockHash test/fixtures/immutable-hooks-phase-one.json)" 'original fixture hash'
export STATICS_DIAMOND_ADDRESS=$(jq -er .diamond test/fixtures/immutable-hooks-phase-one.json)
export STATICS_REHEARSAL_CANDIDATE="$RUN_DIR/candidate.json"
export PHASE_TWO_OUT="$ARTIFACT_ROOT/build/out"
mkdir -p "$ARTIFACT_ROOT/build"
# Public disposable Anvil key. No production signer is read by this runner.
forge build test/helpers/UpstreamMorphoCompilation.sol --evm-version paris \
    --out "$ARTIFACT_ROOT/upstream/out" --cache-path "$ARTIFACT_ROOT/upstream/cache" \
    >"$RUN_DIR/upstream-build.log" 2>&1
export PRIVATE_KEY=$(anvil_private_key 0)
forge script script/DeployPhaseTwoRehearsal.s.sol:DeployPhaseTwoRehearsal \
    --rpc-url "$RPC_URL" --broadcast --slow --legacy --disable-code-size-limit \
    --out "$PHASE_TWO_OUT" --cache-path "$ARTIFACT_ROOT/build/cache" \
    --build-info --build-info-path "$ARTIFACT_ROOT/build/info" \
    >"$RUN_DIR/candidate-deployment.log" 2>&1
unset PRIVATE_KEY
export STAKING_TOKEN=$(jq -er '.canonicalPool.poolKey.currency1' deployments/robinhood-mainnet-genesis.json)
export WETH_ADDRESS=$(jq -er '.canonicalPool.poolKey.currency0' deployments/robinhood-mainnet-genesis.json)
export STATICS_DOPPLER_POOL_FEE=$(jq -er '.canonicalPool.poolKey.fee' deployments/robinhood-mainnet-genesis.json)
export STATICS_DOPPLER_POOL_TICK_SPACING=$(jq -er '.canonicalPool.poolKey.tickSpacing' deployments/robinhood-mainnet-genesis.json)
export STATICS_DOPPLER_POOL_INITIALIZER_ADDRESS=$(jq -er '.canonicalPool.poolKey.hooks' deployments/robinhood-mainnet-genesis.json)
acquire_genesis_statics 4 1000000000000000000 phase-two-funding >"$RUN_DIR/funding.txt"
wrap_weth 4 200000000000000000000 phase-two-backing
SAFE=$(jq -er .owner test/fixtures/immutable-hooks-phase-one.json)
for token in "$WETH_ADDRESS" "$STAKING_TOKEN"; do
    cast send "$token" 'transfer(address,uint256)' "$SAFE" 100000000000000000000 \
        --private-key "$(anvil_private_key 4)" --rpc-url "$RPC_URL" --legacy --json >"$RUN_DIR/fund-$token.json"
done
python3 "$REHEARSAL_DIR/helpers/phase-two.py" | tee "$RUN_DIR/scenarios.log"
[[ "$(jq -er .status "$RUN_DIR/summary.json")" == pass ]] || fail "Phase 2 evidence incomplete"
[[ "$(jq -er .status "$RUN_DIR/later-morpho/summary.json")" == pass ]] || fail "later Morpho evidence incomplete"
note "Phase 2 evidence: $RUN_DIR/summary.json"
