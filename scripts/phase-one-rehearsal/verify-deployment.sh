#!/usr/bin/env bash

set -Eeuo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

require_commands cast jq awk find sort
load_current_run
require_local_chain
cd_repo

EXPECTED_FACETS=32
EXPECTED_SELECTORS=226
POOL_MANAGER=$(jq -er '.contracts.poolManager.address' deployments/robinhood-chain-4663.json)
POSITION_MANAGER=$(jq -er '.contracts.positionManager.address' deployments/robinhood-chain-4663.json)
PERMIT2=$(jq -er '.contracts.permit2.address' deployments/robinhood-chain-4663.json)
QUOTER=$(jq -er '.contracts.quoter.address' deployments/robinhood-chain-4663.json)

assert_eq "$(cast chain-id --rpc-url "$RPC_URL")" "4663" "chain ID"
assert_eq \
    "$(cast call "$STATICS_DIAMOND_ADDRESS" 'owner()(address)' --rpc-url "$RPC_URL")" \
    "$STATICS_TIMELOCK_ADDRESS" \
    "Diamond owner"
assert_eq \
    "$(cast call "$STATICS_DIAMOND_ADDRESS" 'guardian()(address)' --rpc-url "$RPC_URL")" \
    "$GUARDIAN" \
    "guardian"
assert_eq \
    "$(cast call "$STATICS_DIAMOND_ADDRESS" 'treasury()(address)' --rpc-url "$RPC_URL")" \
    "$TREASURY" \
    "treasury"
assert_eq \
    "$(cast call "$STATICS_DIAMOND_ADDRESS" 'stakingToken()(address)' --rpc-url "$RPC_URL")" \
    "$STAKING_TOKEN" \
    "staking token"

read -r royalty_receiver royalty_bps <<<"$(
    cast call "$STATICS_DIAMOND_ADDRESS" 'positionRoyalty()(address,uint16)' --rpc-url "$RPC_URL" \
        | tr '\n' ' '
)"
assert_eq "$royalty_receiver" "$TREASURY" "PositionNFT royalty receiver"
assert_eq "$royalty_bps" "500" "PositionNFT royalty BPS"
read -r quoted_royalty_receiver quoted_royalty_amount <<<"$(
    cast call "$STATICS_DIAMOND_ADDRESS" \
        'royaltyInfo(uint256,uint256)(address,uint256)' 1 1000000000000000000 \
        --rpc-url "$RPC_URL" | awk '{print $1}' | tr '\n' ' '
)"
assert_eq "$quoted_royalty_receiver" "$TREASURY" "ERC-2981 royalty receiver"
assert_eq "$quoted_royalty_amount" "50000000000000000" "ERC-2981 royalty amount"

declare -A required_interfaces=(
    [IStaticsBatchRewards]=0xb2eabe68
    [IStaticsAggregatedBatchRewards]=0x23dbb931
    [ERC2981]=0x2a55205a
    [IStaticsPositionRoyalty]=0x4847d81b
    [IStaticsPositionMarket]=0x079c0632
    [IStaticsRewardSelectionTiming]=0x13cfa782
)
for interface_name in "${!required_interfaces[@]}"; do
    assert_eq \
        "$(cast call "$STATICS_DIAMOND_ADDRESS" 'supportsInterface(bytes4)(bool)' \
            "${required_interfaces[$interface_name]}" --rpc-url "$RPC_URL")" \
        "true" \
        "$interface_name support"
done

read -r installed_pool_manager installed_hook public_installed <<<"$(
    cast call "$STATICS_DIAMOND_ADDRESS" 'liquidityIntegration()(address,address,bool)' --rpc-url "$RPC_URL" \
        | tr '\n' ' '
)"
assert_eq "$installed_pool_manager" "$POOL_MANAGER" "public PoolManager"
assert_eq "$installed_hook" "$STATICS_SWAP_FEE_HOOK_ADDRESS" "public hook"
assert_eq "$public_installed" "true" "public integration status"

read -r installed_manager manager_installed <<<"$(
    cast call "$STATICS_DIAMOND_ADDRESS" 'liquidityManager()(address,bool)' --rpc-url "$RPC_URL" | tr '\n' ' '
)"
assert_eq "$installed_manager" "$STATICS_LIQUIDITY_MANAGER_ADDRESS" "liquidity manager"
assert_eq "$manager_installed" "true" "liquidity manager status"

read -r permissioned_hook permissioned_router permissioned_position_manager permissioned_quoter permissioned_installed <<<"$(
    cast call "$STATICS_DIAMOND_ADDRESS" \
        'permissionedLiquidityIntegration()(address,address,address,address,bool)' \
        --rpc-url "$RPC_URL" | tr '\n' ' '
)"
assert_eq "$permissioned_hook" "$STATICS_PERMISSIONED_SWAP_FEE_HOOK_ADDRESS" "permissioned hook"
assert_eq "$permissioned_router" "$STATICS_PERMISSIONED_ROUTER_ADDRESS" "permissioned router"
assert_eq "$permissioned_position_manager" "$STATICS_PERMISSIONED_POSITION_MANAGER_ADDRESS" \
    "permissioned position manager"
assert_eq "$permissioned_quoter" "$QUOTER" "permissioned quoter"
assert_eq "$permissioned_installed" "true" "permissioned integration status"

assert_eq \
    "$(cast call "$STATICS_DIAMOND_ADDRESS" 'protocolPolOperator()(address)' --rpc-url "$RPC_URL")" \
    "$POL_OPERATOR" \
    "POL operator"
assert_eq \
    "$(cast call "$STATICS_DIAMOND_ADDRESS" 'protocolPolActivationFee()(uint256)' --rpc-url "$RPC_URL" | awk '{print $1}')" \
    "25000000000000000" \
    "POL activation fee"
assert_eq \
    "$(cast call "$STATICS_DIAMOND_ADDRESS" 'poolCreationFee()(uint256)' --rpc-url "$RPC_URL" | awk '{print $1}')" \
    "10000000000000000" \
    "public pool creation fee"
assert_eq \
    "$(cast call "$STATICS_DIAMOND_ADDRESS" 'positionCreationFee()(uint256)' --rpc-url "$RPC_URL" | awk '{print $1}')" \
    "1000000000000000" \
    "PositionNFT creation fee"
assert_eq \
    "$(cast call "$STATICS_TIMELOCK_ADDRESS" 'getMinDelay()(uint256)' --rpc-url "$RPC_URL" | awk '{print $1}')" \
    "86400" \
    "timelock delay"

assert_eq \
    "$(cast call "$STATICS_LIQUIDITY_MANAGER_ADDRESS" 'staticsDiamond()(address)' --rpc-url "$RPC_URL")" \
    "$STATICS_DIAMOND_ADDRESS" \
    "liquidity manager Diamond binding"
assert_eq \
    "$(cast call "$STATICS_LIQUIDITY_MANAGER_ADDRESS" 'poolManager()(address)' --rpc-url "$RPC_URL")" \
    "$POOL_MANAGER" \
    "liquidity manager PoolManager binding"
assert_eq \
    "$(cast call "$STATICS_LIQUIDITY_MANAGER_ADDRESS" 'positionManager()(address)' --rpc-url "$RPC_URL")" \
    "$POSITION_MANAGER" \
    "liquidity manager PositionManager binding"
assert_eq \
    "$(cast call "$STATICS_LIQUIDITY_MANAGER_ADDRESS" 'permit2()(address)' --rpc-url "$RPC_URL")" \
    "$PERMIT2" \
    "liquidity manager Permit2 binding"
assert_runtime_matches_artifact \
    "$STATICS_LIQUIDITY_MANAGER_ADDRESS" \
    "$PHASE_ONE_OUT/StaticsLiquidityManager.sol/StaticsLiquidityManager.json" \
    "liquidity manager"

assert_eq \
    "$(cast call "$STATICS_SWAP_FEE_HOOK_ADDRESS" 'staticsDiamond()(address)' --rpc-url "$RPC_URL")" \
    "$STATICS_DIAMOND_ADDRESS" \
    "public hook Diamond binding"
assert_eq \
    "$(cast call "$STATICS_SWAP_FEE_HOOK_ADDRESS" 'poolManager()(address)' --rpc-url "$RPC_URL")" \
    "$POOL_MANAGER" \
    "public hook PoolManager binding"
assert_eq \
    "$(cast call "$STATICS_SWAP_FEE_HOOK_ADDRESS" 'weth()(address)' --rpc-url "$RPC_URL")" \
    "$WETH_ADDRESS" \
    "public hook reward WETH binding"
assert_eq \
    "$(cast call "$POSITION_MANAGER" 'WETH9()(address)' --rpc-url "$RPC_URL")" \
    "$WETH_ADDRESS" \
    "public PositionManager WETH binding"
assert_runtime_matches_artifact \
    "$STATICS_SWAP_FEE_HOOK_ADDRESS" \
    "$PHASE_ONE_OUT/StaticsSwapFeeHook.sol/StaticsSwapFeeHook.json" \
    "public hook"
assert_runtime_matches_artifact \
    "$STATICS_PERMISSIONED_SWAP_FEE_HOOK_ADDRESS" \
    "$PHASE_ONE_OUT/StaticsPermissionedSwapFeeHook.sol/StaticsPermissionedSwapFeeHook.json" \
    "permissioned hook"

position_market_facet=$(
    cast call "$STATICS_DIAMOND_ADDRESS" 'facetAddress(bytes4)(address)' 0x2a55205a --rpc-url "$RPC_URL"
)
assert_nonzero_address "$position_market_facet" "PositionMarket facet"
assert_runtime_matches_artifact \
    "$position_market_facet" \
    "$PHASE_ONE_OUT/PositionMarketFacet.sol/PositionMarketFacet.json" \
    "PositionMarket facet"
for selector in 0x2a55205a 0x24840dbe 0x4696f5ff 0xff05754e 0x38c8ae38; do
    assert_eq \
        "$(cast call "$STATICS_DIAMOND_ADDRESS" 'facetAddress(bytes4)(address)' "$selector" --rpc-url "$RPC_URL")" \
        "$position_market_facet" \
        "PositionMarket route for $selector"
done
assert_runtime_matches_build_context \
    "$STATICS_PERMISSIONED_ROUTER_ADDRESS" \
    "$PERIPHERY_OUT/DeployStaticsPermissionedPeriphery.s.sol/DeployStaticsPermissionedPeriphery.json" \
    "script/DeployStaticsPermissionedPeriphery.s.sol" \
    "DeployStaticsPermissionedPeriphery" \
    "src/permissioned/StaticsPermissionedRouter.sol" \
    "StaticsPermissionedRouter" \
    "$PERIPHERY_BUILD_INFO" \
    "permissioned router"
assert_runtime_matches_build_context \
    "$STATICS_PERMISSIONED_POSITION_MANAGER_ADDRESS" \
    "$PERIPHERY_OUT/DeployStaticsPermissionedPeriphery.s.sol/DeployStaticsPermissionedPeriphery.json" \
    "script/DeployStaticsPermissionedPeriphery.s.sol" \
    "DeployStaticsPermissionedPeriphery" \
    "src/permissioned/StaticsPermissionedPositionManager.sol" \
    "StaticsPermissionedPositionManager" \
    "$PERIPHERY_BUILD_INFO" \
    "permissioned position manager"
assert_runtime_matches_build_context \
    "$STATICS_PERMISSIONED_POSITION_CLAIMS_ADDRESS" \
    "$PERIPHERY_OUT/DeployStaticsPermissionedPeriphery.s.sol/DeployStaticsPermissionedPeriphery.json" \
    "script/DeployStaticsPermissionedPeriphery.s.sol" \
    "DeployStaticsPermissionedPeriphery" \
    "src/permissioned/PermissionedPositionClaims.sol" \
    "PermissionedPositionClaims" \
    "$PERIPHERY_BUILD_INFO" \
    "permissioned position claims"
read -r input_fee output_fee <<<"$(
    cast call "$STATICS_SWAP_FEE_HOOK_ADDRESS" 'defaultFeeRate()(uint16,uint16)' --rpc-url "$RPC_URL" | tr '\n' ' '
)"
assert_eq "$input_fee" "5" "public input fee"
assert_eq "$output_fee" "5" "public output fee"

declare -a facets
mapfile -t facets < <(
    cast call "$STATICS_DIAMOND_ADDRESS" 'facetAddresses()(address[])' --rpc-url "$RPC_URL" \
        | tr -d '[],' \
        | tr ' ' '\n' \
        | awk '/^0x[0-9a-fA-F]{40}$/'
)
assert_eq "${#facets[@]}" "$EXPECTED_FACETS" "Phase 1 facet count"
FACET_DETAILS=$(cast call "$STATICS_DIAMOND_ADDRESS" 'facets()((address,bytes4[])[])' \
    --rpc-url "$RPC_URL" --json)
assert_eq "$(jq -r '.[0] | length' <<<"$FACET_DETAILS")" "$EXPECTED_FACETS" \
    "Phase 1 facet detail count"

ONCHAIN_TSV="$RUN_DIR/onchain-selectors.tsv"
: >"$ONCHAIN_TSV"
for facet in "${facets[@]}"; do
    code=$(cast code "$facet" --rpc-url "$RPC_URL")
    [[ "$code" != "0x" ]] || fail "facet has no code: $facet"
    mapfile -t selectors < <(
        cast call "$STATICS_DIAMOND_ADDRESS" 'facetFunctionSelectors(address)(bytes4[])' "$facet" \
            --rpc-url "$RPC_URL" \
            | tr -d '[],' \
            | tr ' ' '\n' \
            | awk '/^0x[0-9a-fA-F]{8}$/'
    )
    for selector in "${selectors[@]}"; do
        routed=$(cast call "$STATICS_DIAMOND_ADDRESS" 'facetAddress(bytes4)(address)' "$selector" --rpc-url "$RPC_URL")
        assert_eq "$routed" "$facet" "route for $selector"
        printf '%s\t%s\n' "${selector,,}" "$facet" >>"$ONCHAIN_TSV"
    done
done

selector_count=$(wc -l <"$ONCHAIN_TSV" | tr -d ' ')
unique_selector_count=$(cut -f1 "$ONCHAIN_TSV" | sort -u | wc -l | tr -d ' ')
assert_eq "$selector_count" "$EXPECTED_SELECTORS" "Phase 1 selector count"
assert_eq "$unique_selector_count" "$EXPECTED_SELECTORS" "unique Phase 1 selector count"

METHOD_TSV="$RUN_DIR/compiled-methods.tsv"
find "$PHASE_ONE_OUT" -name '*.json' -type f -print0 \
    | while IFS= read -r -d '' artifact; do
        jq -r '
            def abi_type:
                if (.type | startswith("tuple")) then
                    ([.components[] | abi_type] | join(",")) as $components
                    | (.type | sub("^tuple"; "(" + $components + ")"))
                else .type
                end;
            def signature:
                .name + "(" + ([.inputs[] | abi_type] | join(",")) + ")";
            ([.abi[]? | select(.type == "function") | {(signature): .stateMutability}] | add // {}) as $mutability
            | (.methodIdentifiers // {})
            | to_entries[]
            | ["0x" + (.value | ascii_downcase), .key, ($mutability[.key] // "unknown")]
            | @tsv
        ' "$artifact"
    done \
    | sort -u >"$METHOD_TSV"

FACET_NAMES_TSV="$RUN_DIR/facet-names.tsv"
jq -r '
    .transactions[]
    | select(.transactionType == "CREATE" and .contractAddress != null and .contractName != null)
    | [(.contractAddress | ascii_downcase), .contractName]
    | @tsv
' broadcast/DeployStaticsPhaseOne.s.sol/4663/run-latest.json | sort -u >"$FACET_NAMES_TSV"

MAPPED_TSV="$RUN_DIR/selector-inventory.tsv"
awk -F '\t' '
    NR == FNR {
        key = tolower($1)
        if (signatures[key] == "") {
            signatures[key] = $2
            mutability[key] = $3
        } else if (index("|" signatures[key] "|", "|" $2 "|") == 0) {
            signatures[key] = signatures[key] "|" $2
        }
        next
    }
    {
        key = tolower($1)
        print key "\t" $2 "\t" signatures[key] "\t" mutability[key]
    }
' "$METHOD_TSV" "$ONCHAIN_TSV" >"$MAPPED_TSV"

unmapped=$(awk -F '\t' '$3 == "" { count++ } END { print count + 0 }' "$MAPPED_TSV")
assert_eq "$unmapped" "0" "unmapped selector count"

awk -F '\t' '
    NR == FNR { facetName[tolower($1)] = $2; next }
    { print $0 "\t" facetName[tolower($2)] }
' "$FACET_NAMES_TSV" "$MAPPED_TSV" >"$MAPPED_TSV.named"
mv "$MAPPED_TSV.named" "$MAPPED_TSV"

jq -Rn '
    [inputs
        | split("\t")
        | {
            selector: .[0],
            facetAddress: .[1],
            signatures: (.[2] | split("|")),
            stateMutability: .[3],
            facet: .[4]
        }
    ]
' <"$MAPPED_TSV" >"$RUN_DIR/selector-inventory.json"

jq -n \
    --arg commit "$HEAD_COMMIT" \
    --argjson forkBlock "$FORK_BLOCK" \
    --arg forkBlockHash "$FORK_BLOCK_HASH" \
    --arg genesisToken "$STAKING_TOKEN" \
    --arg genesisNft "$STATICS_GENESIS_NFT_ADDRESS" \
    --arg diamond "$STATICS_DIAMOND_ADDRESS" \
    --arg timelock "$STATICS_TIMELOCK_ADDRESS" \
    --arg publicHook "$STATICS_SWAP_FEE_HOOK_ADDRESS" \
    --arg permissionedHook "$STATICS_PERMISSIONED_SWAP_FEE_HOOK_ADDRESS" \
    --arg liquidityManager "$STATICS_LIQUIDITY_MANAGER_ADDRESS" \
    --arg permissionedRouter "$STATICS_PERMISSIONED_ROUTER_ADDRESS" \
    --arg permissionedPositionManager "$STATICS_PERMISSIONED_POSITION_MANAGER_ADDRESS" \
    --arg positionMarketFacet "$position_market_facet" \
    --arg royaltyReceiver "$royalty_receiver" \
    --argjson royaltyBps "$royalty_bps" \
    --argjson facets "$EXPECTED_FACETS" \
    --argjson selectors "$EXPECTED_SELECTORS" \
    '{
        commit: $commit,
        fork: {chainId: 4663, block: $forkBlock, blockHash: $forkBlockHash},
        genesis: {staticsToken: $genesisToken, genesisNft: $genesisNft},
        phaseOne: {
            diamond: $diamond,
            timelock: $timelock,
            publicHook: $publicHook,
            permissionedHook: $permissionedHook,
            liquidityManager: $liquidityManager,
            permissionedRouter: $permissionedRouter,
            permissionedPositionManager: $permissionedPositionManager,
            positionMarketFacet: $positionMarketFacet,
            positionRoyalty: {receiver: $royaltyReceiver, bps: $royaltyBps},
            facets: $facets,
            selectors: $selectors
        }
    }' >"$RUN_DIR/deployment.json"

BATCH_LIMITS=$(cast call "$STATICS_DIAMOND_ADDRESS" 'batchClaimLimits()(uint256,uint256)' --rpc-url "$RPC_URL" --json)
assert_eq "$(jq -r '.[0]' <<<"$BATCH_LIMITS")" 16 "batch group limit"
assert_eq "$(jq -r '.[1]' <<<"$BATCH_LIMITS")" 64 "batch entry limit"

record_result verification immutable-bindings pass "canonical Robinhood dependencies"
record_result verification selector-routes pass "$EXPECTED_SELECTORS selectors across $EXPECTED_FACETS facets"
note "verified $EXPECTED_SELECTORS selectors across $EXPECTED_FACETS facets"
note "selector inventory: $RUN_DIR/selector-inventory.json"
