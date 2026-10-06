// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Script} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IStaticsSwapFeeHook} from "../src/interfaces/IStaticsSwapFeeHook.sol";
import {IStaticsBasketLiquidity} from "../src/interfaces/IStaticsBasketLiquidity.sol";
import {IStaticsBasketPreparation} from "../src/interfaces/IStaticsBasketPreparation.sol";
import {StaticsBasketFactory} from "../src/liquidity/StaticsBasketFactory.sol";

/// @notice Deploy the approved factory after v4 integration and prepare its separate owner action.
/// Salt mining and permissionless queue replenishment are offchain workflows, not deployment loops.
contract PrepareStaticsBasketFactory is Script {
    error InvalidIntegration();
    error InvalidFactory();
    error InvalidSalt(bytes32 salt);

    function deployFactory(address diamond) public returns (StaticsBasketFactory factory) {
        (address manager, address policy, bool installed) = IStaticsBasketLiquidity(diamond).liquidityIntegration();
        if (!installed || diamond.code.length == 0) revert InvalidIntegration();
        factory = new StaticsBasketFactory(diamond, IPoolManager(manager), IStaticsSwapFeeHook(policy));
    }

    function installationPayload(address diamond, address factoryAddress, bytes32 expectedRuntimeHash)
        public
        view
        returns (bytes memory)
    {
        (address manager, address policy, bool installed) = IStaticsBasketLiquidity(diamond).liquidityIntegration();
        StaticsBasketFactory factory = StaticsBasketFactory(factoryAddress);
        if (
            !installed || factoryAddress.code.length == 0 || expectedRuntimeHash == bytes32(0)
                || factoryAddress.codehash != expectedRuntimeHash || factory.staticsDiamond() != diamond
                || address(factory.poolManager()) != manager || address(factory.feePolicy()) != policy
                || factory.VERSION() != 1 || factory.CREATE_X().codehash != factory.CREATE_X_CODE_HASH()
        ) revert InvalidFactory();
        return abi.encodeCall(IStaticsBasketPreparation.installBasketFactory, (factoryAddress));
    }

    function replenishmentPayload(StaticsBasketFactory factory, bytes32[] calldata salts, bool hooks)
        public
        view
        returns (bytes memory)
    {
        if (salts.length == 0 || salts.length > 128) revert InvalidFactory();
        for (uint256 i; i < salts.length; ++i) {
            if (!factory.saltAvailable(salts[i])) revert InvalidSalt(salts[i]);
            if (hooks) {
                (address predicted,) = factory.predict(salts[i]);
                if (uint160(predicted) & ((1 << 14) - 1) != factory.HOOK_PERMISSION_MASK()) {
                    revert InvalidSalt(salts[i]);
                }
            }
            for (uint256 j; j < i; ++j) {
                if (salts[i] == salts[j]) revert InvalidSalt(salts[i]);
            }
        }
        return abi.encodeCall(StaticsBasketFactory.enqueueSalts, (salts, hooks));
    }
}
