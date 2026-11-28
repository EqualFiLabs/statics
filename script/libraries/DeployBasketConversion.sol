// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {BasketConversionFacet} from "../../src/facets/BasketConversionFacet.sol";
import {IStaticsBasket} from "../../src/interfaces/IStaticsBasket.sol";
import {IStaticsBasketConversion} from "../../src/interfaces/IStaticsBasketConversion.sol";
import {StaticsBasketConversionHook} from "../../src/liquidity/StaticsBasketConversionHook.sol";
import {StaticsBasketConversionZap} from "../../src/liquidity/StaticsBasketConversionZap.sol";
import {StaticsBasketConversionRouter} from "../../src/liquidity/StaticsBasketConversionRouter.sol";
import {StaticsBasketHook} from "../../src/liquidity/StaticsBasketHook.sol";
import {StaticsBasketTokenFactory} from "../../src/liquidity/StaticsBasketTokenFactory.sol";

library DeployBasketConversion {
    function deployBasketLiquidity(address diamond, IPoolManager manager, address weth, address create2Deployer)
        internal
        returns (address hook, address factory)
    {
        uint160 flags = Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
            | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_DONATE_FLAG
            | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
            | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG;
        bytes memory args = abi.encode(manager, diamond, uint16(0), uint16(0), weth);
        (address expected, bytes32 salt) =
            HookMiner.find(create2Deployer, flags, type(StaticsBasketHook).creationCode, args);
        hook = address(new StaticsBasketHook{salt: salt}(manager, diamond, 0, 0, weth));
        require(hook == expected, "basket hook mismatch");
        factory = address(new StaticsBasketTokenFactory(diamond, manager));
    }

    function deploy(address diamond, IPoolManager manager, address create2Deployer)
        internal
        returns (address facet, IStaticsBasketConversion.Configuration memory configuration)
    {
        IStaticsBasket core = IStaticsBasket(diamond);
        uint160 flags = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
            | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG;
        (address expected, bytes32 salt) = HookMiner.find(
            create2Deployer, flags, type(StaticsBasketConversionHook).creationCode, abi.encode(manager, core)
        );
        address hook = address(new StaticsBasketConversionHook{salt: salt}(manager, core));
        require(hook == expected, "conversion hook mismatch");
        address zap = address(new StaticsBasketConversionZap(manager, core, hook));
        address router = address(new StaticsBasketConversionRouter(manager, core, hook));
        facet = address(new BasketConversionFacet(hook, zap, router, manager));
        configuration = IStaticsBasketConversion.Configuration(hook, zap, router, address(manager));
    }
}
