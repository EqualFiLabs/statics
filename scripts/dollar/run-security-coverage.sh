#!/usr/bin/env bash
set -euo pipefail

: "${BASE_RPC_URL:?BASE_RPC_URL is required for pre-launch security coverage}"

FOUNDRY_PROFILE=security forge test --match-path 'test/dollar/properties/*.t.sol' -vv
forge test --match-path 'test/dollar/unit/*.t.sol' -vv
forge test --match-path 'test/dollar/integration/*.t.sol' -vv
REQUIRE_BASE_FORK=1 forge test --match-path test/dollar/fork/BaseOracleFork.t.sol -vv
