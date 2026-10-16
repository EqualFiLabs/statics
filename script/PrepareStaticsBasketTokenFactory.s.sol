// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Script} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IStaticsBasketLiquidity} from "../src/interfaces/IStaticsBasketLiquidity.sol";
import {StaticsBasketTokenFactory} from "../src/liquidity/StaticsBasketTokenFactory.sol";

/// @notice Deploy and validate the deterministic restricted-token factory.
/// @dev Architecture installation is performed atomically by StaticsPublicHookReleaseInit.
contract PrepareStaticsBasketTokenFactory is Script {
    error InvalidIntegration();
    error InvalidFactory();

    function deployFactory(address diamond) public returns (StaticsBasketTokenFactory factory) {
        (address manager,, bool installed) = IStaticsBasketLiquidity(diamond).liquidityIntegration();
        if (!installed || diamond.code.length == 0) revert InvalidIntegration();
        factory = new StaticsBasketTokenFactory(diamond, IPoolManager(manager));
    }

    function validateFactory(address diamond, address factoryAddress, bytes32 expectedRuntimeHash) public view {
        (address manager,, bool installed) = IStaticsBasketLiquidity(diamond).liquidityIntegration();
        StaticsBasketTokenFactory factory = StaticsBasketTokenFactory(factoryAddress);
        if (
            !installed || factoryAddress.code.length == 0 || expectedRuntimeHash == bytes32(0)
                || factoryAddress.codehash != expectedRuntimeHash || factory.staticsDiamond() != diamond
                || address(factory.poolManager()) != manager || factory.VERSION() != 1
                || factory.CREATE_X().codehash != factory.CREATE_X_CODE_HASH()
        ) revert InvalidFactory();
    }
}
