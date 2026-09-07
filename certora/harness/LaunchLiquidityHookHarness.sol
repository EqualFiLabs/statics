// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IStaticsLaunchLiquidityHook} from "../../src/interfaces/IStaticsLaunchLiquidityHook.sol";
import {StaticsLaunchLiquidityHook} from "../../src/liquidity/StaticsLaunchLiquidityHook.sol";

contract LaunchLiquidityHookHarness is StaticsLaunchLiquidityHook {
    constructor(IPoolManager manager, IPositionManager positionManager_, address initialOwner, address receiver)
        StaticsLaunchLiquidityHook(manager, positionManager_, initialOwner, receiver)
    {}

    function registrationFeesWithinCap(bytes32 rawPoolId) external view returns (bool) {
        IStaticsLaunchLiquidityHook.PoolRegistration memory registration = this.poolRegistration(PoolId.wrap(rawPoolId));
        return !registration.registered
            || (registration.inputFeeBps <= MAX_HOOK_FEE_BPS && registration.outputFeeBps <= MAX_HOOK_FEE_BPS);
    }

    function registrationDigest(bytes32 rawPoolId) external view returns (bytes32) {
        return keccak256(abi.encode(this.poolRegistration(PoolId.wrap(rawPoolId))));
    }

    function registrationDigestTyped(PoolId poolId) external view returns (bytes32) {
        return keccak256(abi.encode(this.poolRegistration(poolId)));
    }

    function registrationInitialized(bytes32 rawPoolId) external view returns (bool) {
        return this.poolRegistration(PoolId.wrap(rawPoolId)).initialized;
    }

    function registrationActive(bytes32 rawPoolId) external view returns (bool) {
        return this.poolRegistration(PoolId.wrap(rawPoolId)).active;
    }

    function registrationLaunchOperator(bytes32 rawPoolId) external view returns (address) {
        return this.poolRegistration(PoolId.wrap(rawPoolId)).launchOperator;
    }

    function registrationInputFee(PoolId poolId) external view returns (uint16) {
        return this.poolRegistration(poolId).inputFeeBps;
    }

    function registrationOutputFee(PoolId poolId) external view returns (uint16) {
        return this.poolRegistration(poolId).outputFeeBps;
    }

    function registrationLifecycleIsCoherent(bytes32 rawPoolId) external view returns (bool) {
        IStaticsLaunchLiquidityHook.PoolRegistration memory registration = this.poolRegistration(PoolId.wrap(rawPoolId));
        return !registration.active || (registration.registered && registration.initialized);
    }

    function activatePoolRaw(bytes32 rawPoolId) external {
        _activatePool(PoolId.wrap(rawPoolId));
    }

    function validateHookAddress(BaseHook) internal pure override {}
}
