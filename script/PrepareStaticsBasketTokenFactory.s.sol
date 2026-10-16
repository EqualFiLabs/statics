// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Script} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IStaticsBasketLiquidity} from "../src/interfaces/IStaticsBasketLiquidity.sol";
import {StaticsBasketTokenFactory} from "../src/liquidity/StaticsBasketTokenFactory.sol";

/// @notice Deploy and replenish the deterministic restricted-token factory.
/// @dev Architecture installation is performed atomically by StaticsPublicHookReleaseInit.
contract PrepareStaticsBasketTokenFactory is Script {
    error InvalidIntegration();
    error InvalidFactory();
    error InvalidSalt(bytes32 salt);

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

    function replenishmentPayload(StaticsBasketTokenFactory factory, bytes32[] calldata salts)
        public
        view
        returns (bytes memory)
    {
        if (salts.length == 0 || salts.length > 128) revert InvalidFactory();
        for (uint256 i; i < salts.length; ++i) {
            if (uint88(uint256(salts[i])) & factory.PREPARED_SALT_BIT() != 0 || !factory.saltAvailable(salts[i])) {
                revert InvalidSalt(salts[i]);
            }
            for (uint256 j; j < i; ++j) {
                if (salts[i] == salts[j]) revert InvalidSalt(salts[i]);
            }
        }
        return abi.encodeCall(StaticsBasketTokenFactory.enqueueSalts, (salts));
    }
}
