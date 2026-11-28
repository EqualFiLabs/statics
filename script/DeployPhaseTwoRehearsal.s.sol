// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {console2} from "forge-std/console2.sol";
import {Script} from "forge-std/Script.sol";
import {DeployStaticsProtocol} from "./dollar/DeployStaticsProtocol.s.sol";
import {PrepareStaticsPublicHookUpgrade} from "./PrepareStaticsPublicHookUpgrade.s.sol";
import {StaticsProtocolParts} from "./libraries/StaticsProtocolPlan.sol";
import {StaticsPublicHookReleaseInit} from "../src/diamond/StaticsPublicHookReleaseInit.sol";
import {StaticsBasketHook} from "../src/liquidity/StaticsBasketHook.sol";
import {StaticsBasketTokenFactory} from "../src/liquidity/StaticsBasketTokenFactory.sol";
import {StaticsLiquidityManager} from "../src/liquidity/StaticsLiquidityManager.sol";
import {IStaticsLiquidityManager} from "../src/interfaces/IStaticsLiquidityManager.sol";
import {IStaticsBasketLiquidity} from "../src/interfaces/IStaticsBasketLiquidity.sol";
import {IStaticsSwapFeeHook} from "../src/interfaces/IStaticsSwapFeeHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {IERC173} from "../src/interfaces/IERC173.sol";
import {
    PhaseTwoRehearsalActor,
    PhaseTwoRehearsalAsset,
    PhaseTwoRehearsalBatch,
    PhaseTwoRehearsalRouter
} from "../scripts/phase-one-rehearsal/helpers/PhaseTwoRehearsalActors.sol";

/// @dev Local Anvil candidate deployments only. Never accepts a production node.
contract DeployPhaseTwoRehearsal is Script, DeployStaticsProtocol {
    address private constant FOUNDRY_CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    uint160 private constant PUBLIC_HOOK_FLAGS = Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG
        | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        | Hooks.BEFORE_DONATE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG
        | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG;

    struct Candidate {
        address diamond;
        address generalHook;
        address basketHook;
        address basketTokenFactory;
        address manager;
        address initializer;
        address batch;
        address actor;
        address router;
        address[] maxAssets;
        address impairmentAsset;
    }

    function run() external {
        vm.rpc("anvil_nodeInfo", "[]");
        require(block.chainid == 4663, "wrong rehearsal chain");
        Candidate memory c;
        c.diamond = vm.envAddress("STATICS_DIAMOND_ADDRESS");
        (address oldManager,) = IStaticsBasketLiquidity(c.diamond).liquidityManager();
        (, address legacyHook,) = IStaticsBasketLiquidity(c.diamond).liquidityIntegration();
        IStaticsLiquidityManager old = IStaticsLiquidityManager(oldManager);
        IPoolManager pool = IPoolManager(old.poolManager());
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        StaticsProtocolParts memory parts = _deployPhaseTwoProtocolParts(_deployPhaseOneProtocolParts());
        c.generalHook = legacyHook;
        c.basketHook = _deployBasket(pool, c.diamond, IStaticsSwapFeeHook(legacyHook).weth());
        c.basketTokenFactory = address(new StaticsBasketTokenFactory(c.diamond, pool));
        c.manager = address(new StaticsLiquidityManager(c.diamond, old.positionManager(), address(pool), old.permit2()));
        c.initializer = address(new StaticsPublicHookReleaseInit());
        c.batch = address(new PhaseTwoRehearsalBatch());
        c.actor = address(new PhaseTwoRehearsalActor());
        c.router = address(new PhaseTwoRehearsalRouter(pool));
        address owner = IERC173(c.diamond).owner();
        c.impairmentAsset = address(new PhaseTwoRehearsalAsset(owner));
        c.maxAssets = new address[](16);
        for (uint256 i; i < c.maxAssets.length; ++i) {
            c.maxAssets[i] = address(new PhaseTwoRehearsalAsset(owner));
        }
        vm.stopBroadcast();
        _write(c, parts);
    }

    function _deployBasket(IPoolManager manager, address diamond, address weth) private returns (address result) {
        bytes memory args = abi.encode(manager, diamond, uint16(0), uint16(0), weth);
        (address predicted, bytes32 salt) =
            HookMiner.find(FOUNDRY_CREATE2_DEPLOYER, PUBLIC_HOOK_FLAGS, type(StaticsBasketHook).creationCode, args);
        result = address(new StaticsBasketHook{salt: salt}(manager, diamond, 0, 0, weth));
        require(result == predicted, "basket hook mismatch");
    }

    function _write(Candidate memory c, StaticsProtocolParts memory parts) private {
        PrepareStaticsPublicHookUpgrade.Configuration memory config;
        config.diamond = c.diamond;
        config.initializer = c.initializer;
        config.basketHook = c.basketHook;
        config.basketTokenFactory = c.basketTokenFactory;
        config.liquidityManager = c.manager;
        config.flashFeeBps = 5;
        PrepareStaticsPublicHookUpgrade builder = new PrepareStaticsPublicHookUpgrade();
        string memory key = "rehearsal";
        vm.serializeAddress(key, "diamond", c.diamond);
        vm.serializeAddress(key, "generalHook", c.generalHook);
        vm.serializeAddress(key, "basketHook", c.basketHook);
        vm.serializeAddress(key, "basketTokenFactory", c.basketTokenFactory);
        vm.serializeAddress(key, "manager", c.manager);
        vm.serializeAddress(key, "initializer", c.initializer);
        vm.serializeAddress(key, "batch", c.batch);
        vm.serializeAddress(key, "actor", c.actor);
        vm.serializeAddress(key, "router", c.router);
        vm.serializeAddress(key, "maxAssets", c.maxAssets);
        vm.serializeAddress(key, "impairmentAsset", c.impairmentAsset);
        vm.serializeBytes(key, "parts", abi.encode(parts));
        string memory result = vm.serializeString(key, "safeJson", builder.buildSafeJson(config, parts));
        vm.writeJson(result, vm.envString("STATICS_REHEARSAL_CANDIDATE"));
        console2.log("PHASE_TWO_REHEARSAL_CANDIDATE", vm.envString("STATICS_REHEARSAL_CANDIDATE"));
    }
}
