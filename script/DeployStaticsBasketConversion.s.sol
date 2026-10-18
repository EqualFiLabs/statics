// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Script} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {IStaticsBasket} from "../src/interfaces/IStaticsBasket.sol";
import {BasketConversionFacet} from "../src/facets/BasketConversionFacet.sol";
import {StaticsBasketConversionHook} from "../src/liquidity/StaticsBasketConversionHook.sol";
import {StaticsBasketConversionZap} from "../src/liquidity/StaticsBasketConversionZap.sol";
import {StaticsBasketConversionRouter} from "../src/liquidity/StaticsBasketConversionRouter.sol";

/// @notice Deploy only periphery and its bound facet. Does not cut the Diamond or configure distributors.
contract DeployStaticsBasketConversion is Script {
    address private constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function run() external returns (address hook, address zap, address router, address facet) {
        IPoolManager pm = IPoolManager(vm.envAddress("STATICS_POOL_MANAGER"));
        IStaticsBasket core = IStaticsBasket(vm.envAddress("STATICS_DIAMOND"));
        uint160 flags = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
            | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG;
        (, bytes32 salt) = HookMiner.find(
            CREATE2_DEPLOYER, flags, type(StaticsBasketConversionHook).creationCode, abi.encode(pm, core)
        );
        vm.startBroadcast();
        hook = address(new StaticsBasketConversionHook{salt: salt}(pm, core));
        zap = address(new StaticsBasketConversionZap(pm, core, hook));
        router = address(new StaticsBasketConversionRouter(pm, core, hook));
        facet = address(new BasketConversionFacet(hook, zap, router, pm));
        vm.stopBroadcast();
        string memory object = "basketConversionDeployment";
        vm.serializeAddress(object, "diamond", address(core));
        vm.serializeAddress(object, "poolManager", address(pm));
        vm.serializeAddress(object, "hook", hook);
        vm.serializeAddress(object, "zap", zap);
        vm.serializeAddress(object, "router", router);
        vm.serializeBytes32(object, "hookSalt", salt);
        string memory result = vm.serializeAddress(object, "facet", facet);
        vm.writeJson(
            result, vm.envOr("STATICS_CONVERSION_DEPLOYMENT_OUT", string("artifacts/basket-conversion/deployment.json"))
        );
    }
}
