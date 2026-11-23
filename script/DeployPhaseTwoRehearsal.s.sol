// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {console2} from "forge-std/console2.sol";
import {Script} from "forge-std/Script.sol";
import {DeployStaticsProtocol} from "./dollar/DeployStaticsProtocol.s.sol";
import {PrepareStaticsPublicHookUpgrade} from "./PrepareStaticsPublicHookUpgrade.s.sol";
import {StaticsProtocolParts} from "./libraries/StaticsProtocolPlan.sol";
import {StaticsPublicHookReleaseInit} from "../src/diamond/StaticsPublicHookReleaseInit.sol";
import {StaticsLiquidityManager} from "../src/liquidity/StaticsLiquidityManager.sol";
import {IStaticsLiquidityManager} from "../src/interfaces/IStaticsLiquidityManager.sol";
import {IStaticsBasketLiquidity} from "../src/interfaces/IStaticsBasketLiquidity.sol";
import {IStaticsSwapFeeHook} from "../src/interfaces/IStaticsSwapFeeHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IERC173} from "../src/interfaces/IERC173.sol";
import {
    PhaseTwoRehearsalActor,
    PhaseTwoRehearsalAsset,
    PhaseTwoRehearsalBatch,
    PhaseTwoRehearsalRouter
} from "../scripts/phase-one-rehearsal/helpers/PhaseTwoRehearsalActors.sol";

import {IStaticsBasketConversion} from "../src/interfaces/IStaticsBasketConversion.sol";
import {DeployBasketConversion} from "./libraries/DeployBasketConversion.sol";

/// @dev Local Anvil candidate deployments only. Never accepts a production node.
contract DeployPhaseTwoRehearsal is Script, DeployStaticsProtocol {
    address private constant FOUNDRY_CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    struct Candidate {
        address diamond;
        address generalHook;
        address basketHook;
        address conversionHook;
        address conversionZap;
        address conversionRouter;
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
        _run(false);
    }

    /// @notice Export a complete Phase 2 candidate from a fresh or existing Phase 1 fixture.
    function runCombined() external {
        _run(true);
    }

    function _run(bool withConversion) private {
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
        if (withConversion) parts.basketConversion = _deployConversion(c, pool);
        c.generalHook = legacyHook;
        (c.basketHook, c.basketTokenFactory) = DeployBasketConversion.deployBasketLiquidity(
            c.diamond, pool, IStaticsSwapFeeHook(legacyHook).weth(), FOUNDRY_CREATE2_DEPLOYER
        );
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

    function _deployConversion(Candidate memory c, IPoolManager manager) private returns (address) {
        (address facet, IStaticsBasketConversion.Configuration memory conversion) =
            DeployBasketConversion.deploy(c.diamond, manager, FOUNDRY_CREATE2_DEPLOYER);
        c.conversionHook = conversion.hook;
        c.conversionZap = conversion.zap;
        c.conversionRouter = conversion.router;
        return facet;
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
        if (parts.basketConversion != address(0)) {
            vm.serializeAddress(key, "conversionFacet", parts.basketConversion);
            vm.serializeAddress(key, "conversionHook", c.conversionHook);
            vm.serializeAddress(key, "conversionZap", c.conversionZap);
            vm.serializeAddress(key, "conversionRouter", c.conversionRouter);
        }
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
