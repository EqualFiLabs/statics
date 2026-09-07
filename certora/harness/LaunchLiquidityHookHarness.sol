// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

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

    function registrationFees(bytes32 rawPoolId)
        external
        view
        returns (uint16 inputFeeBps, uint16 outputFeeBps, bool registered)
    {
        IStaticsLaunchLiquidityHook.PoolRegistration memory registration = this.poolRegistration(PoolId.wrap(rawPoolId));
        return (registration.inputFeeBps, registration.outputFeeBps, registration.registered);
    }

    function registrationDigest(bytes32 rawPoolId) external view returns (bytes32) {
        return keccak256(abi.encode(this.poolRegistration(PoolId.wrap(rawPoolId))));
    }

    function registrationStructureDigest(bytes32 rawPoolId) external view returns (bytes32) {
        IStaticsLaunchLiquidityHook.PoolRegistration memory registration = this.poolRegistration(PoolId.wrap(rawPoolId));
        return keccak256(
            abi.encode(
                registration.currency0,
                registration.currency1,
                registration.nativeLpFee,
                registration.tickSpacing,
                registration.expectedSqrtPriceX96,
                registration.registered
            )
        );
    }

    function validateHookAddress(BaseHook) internal pure override {}
}
