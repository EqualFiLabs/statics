#!/usr/bin/env bash

set -Eeuo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

require_commands cast jq awk
load_current_run
require_local_chain
reset_to_base

NEW_GUARDIAN=$(anvil_address 20)
NEW_TREASURY=$(anvil_address 21)
TRUSTED_PERIPHERY=$STATICS_DEFAULT_VENUE_CONTROLLER_FACTORY

timelock_call "$STATICS_DIAMOND_ADDRESS" 0 \
    "$(cast calldata 'setGuardian(address)' "$NEW_GUARDIAN")" configuration-guardian
assert_eq \
    "$(cast call "$STATICS_DIAMOND_ADDRESS" 'guardian()(address)' --rpc-url "$RPC_URL")" \
    "$NEW_GUARDIAN" \
    "guardian update"

timelock_call "$STATICS_DIAMOND_ADDRESS" 0 \
    "$(cast calldata 'setPositionCreationFee(uint256)' 2000000000000000)" configuration-position-fee
assert_eq \
    "$(cast call "$STATICS_DIAMOND_ADDRESS" 'positionCreationFee()(uint256)' --rpc-url "$RPC_URL" | awk '{print $1}')" \
    2000000000000000 \
    "position creation fee"

timelock_call "$STATICS_DIAMOND_ADDRESS" 0 \
    "$(cast calldata 'increaseMaxRewardAssetsPerPosition(uint8)' 13)" configuration-reward-limit
assert_eq \
    "$(cast call "$STATICS_DIAMOND_ADDRESS" 'maxRewardAssetsPerPosition()(uint256)' --rpc-url "$RPC_URL" | awk '{print $1}')" \
    13 \
    "maximum reward assets"

timelock_call "$STATICS_DIAMOND_ADDRESS" 0 \
    "$(cast calldata 'setProtocolPoolMaintenanceConfig((uint16))' '(750)')" configuration-maintenance
MAINTENANCE=$(cast call "$STATICS_DIAMOND_ADDRESS" 'protocolPoolMaintenanceConfig()((uint16))' \
    --rpc-url "$RPC_URL" --json)
assert_eq "$(jq -r '.[0][0]' <<<"$MAINTENANCE")" 750 "maintenance tip"

timelock_call "$STATICS_DIAMOND_ADDRESS" 0 \
    "$(cast calldata 'setProtocolPolActivationFee(uint256)' 200000000000000000)" configuration-pol-fee
assert_eq \
    "$(cast call "$STATICS_DIAMOND_ADDRESS" 'protocolPolActivationFee()(uint256)' --rpc-url "$RPC_URL" | awk '{print $1}')" \
    200000000000000000 \
    "POL activation fee"

timelock_call "$STATICS_DIAMOND_ADDRESS" 0 \
    "$(cast calldata 'setGaugeRewardDuration(uint40)' 691200)" configuration-gauge-duration
assert_eq \
    "$(cast call "$STATICS_DIAMOND_ADDRESS" 'gaugeRewardDuration()(uint40)' --rpc-url "$RPC_URL" | awk '{print $1}')" \
    691200 \
    "gauge reward duration"

timelock_call "$STATICS_DIAMOND_ADDRESS" 0 \
    "$(cast calldata 'scheduleGaugeReleaseBps(uint16)' 500)" configuration-gauge-release
RESERVE=$(cast call "$STATICS_DIAMOND_ADDRESS" \
    'gaugeReserve()((bool,uint16,uint16,uint40,uint40,uint40,uint40,uint40,uint40,uint64,uint40,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256))' \
    --rpc-url "$RPC_URL" --json)
assert_eq "$(jq -r '.[0][1]' <<<"$RESERVE")" 500 "pre-activation gauge release"

timelock_call "$STATICS_DIAMOND_ADDRESS" 0 \
    "$(cast calldata 'setGaugeAllocationCooldown(uint40)' 7200)" configuration-gauge-cooldown
assert_eq \
    "$(cast call "$STATICS_DIAMOND_ADDRESS" 'gaugeAllocationCooldown()(uint40)' --rpc-url "$RPC_URL" | awk '{print $1}')" \
    7200 \
    "gauge allocation cooldown"

timelock_call "$STATICS_DIAMOND_ADDRESS" 0 \
    "$(cast calldata 'setPermissionedTrustedPeriphery(address,bool)' "$TRUSTED_PERIPHERY" true)" \
    configuration-trusted-periphery
assert_eq \
    "$(cast call "$STATICS_PERMISSIONED_SWAP_FEE_HOOK_ADDRESS" 'trustedPeriphery(address)(bool)' \
        "$TRUSTED_PERIPHERY" --rpc-url "$RPC_URL")" \
    true \
    "permissioned trusted periphery"

timelock_call "$STATICS_DIAMOND_ADDRESS" 0 \
    "$(cast calldata 'setTreasury(address)' "$NEW_TREASURY")" configuration-treasury
assert_eq \
    "$(cast call "$STATICS_DIAMOND_ADDRESS" 'treasury()(address)' --rpc-url "$RPC_URL")" \
    "$NEW_TREASURY" \
    "treasury update"

record_result configuration governance-surface pass \
    "guardian, Treasury, fees, limits, gauges, and trusted periphery"
note "governed Phase 1 configuration surface passed"
