// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {
    DeployStaticsGenesis,
    StaticsGenesisDeployment,
    StaticsGenesisDeploymentConfig
} from "../../script/DeployStaticsGenesis.s.sol";
import {IStaticsV4Hook} from "../../src/interfaces/IStaticsV4Hook.sol";
import {StaticsGenesisVault} from "../../src/genesis/StaticsGenesisVault.sol";
import {StaticsHookController} from "../../src/genesis/StaticsHookController.sol";
import {StaticsV4Hook} from "../../src/liquidity/StaticsV4Hook.sol";
import {StaticsGenesis} from "../../src/tokens/StaticsGenesis.sol";
import {StaticsToken} from "../../src/tokens/StaticsToken.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

contract GenesisPoolManagerFixture {}

contract DeployStaticsGenesisTest is Test {
    function testDeploysCompleteInertGenesisStackWithExactAllocations() public {
        address governance = makeAddr("governance");
        address treasury = makeAddr("treasury");
        MockERC20 weth = new MockERC20("Wrapped Ether", "WETH", 18);
        GenesisPoolManagerFixture manager = new GenesisPoolManagerFixture();
        DeployStaticsGenesis deployer = new DeployStaticsGenesis();

        StaticsGenesisDeployment memory deployment = deployer.deploy(
            StaticsGenesisDeploymentConfig({
                governance: governance,
                treasury: treasury,
                weth: address(weth),
                poolManager: address(manager),
                inputFeeBps: 50,
                outputFeeBps: 50
            })
        );

        StaticsToken statics = StaticsToken(deployment.statics);
        StaticsGenesis genesis = StaticsGenesis(deployment.genesis);
        StaticsGenesisVault vault = StaticsGenesisVault(deployment.genesisVault);
        StaticsHookController controller = StaticsHookController(deployment.hookController);
        StaticsV4Hook hook = StaticsV4Hook(deployment.v4Hook);

        assertEq(statics.totalSupply(), 999_955_550 ether);
        assertEq(statics.balanceOf(deployment.genesisVault), 99_905_550 ether);
        assertEq(statics.balanceOf(treasury), 90_005_000 ether);
        assertEq(statics.balanceOf(deployment.v4Hook), 810_045_000 ether);
        assertEq(statics.balanceOf(address(deployer)), 0);

        assertEq(genesis.balanceOf(treasury), 555);
        assertEq(genesis.balanceOf(deployment.genesisVault), 500);
        assertEq(genesis.mintedSupply(), 1_055);
        assertEq(vault.tokenBacking(), 99_905_550 ether);
        assertEq(vault.requiredBacking(), 99_905_550 ether);

        assertEq(controller.owner(), governance);
        assertEq(controller.hook(), deployment.v4Hook);
        assertEq(controller.hookBinder(), address(0));
        assertEq(hook.controller(), deployment.hookController);
        assertEq(hook.statics(), deployment.statics);
        assertEq(hook.weth(), address(weth));
        assertFalse(hook.launchInventoryInstalled());

        PoolId poolId = hook.canonicalPoolId();
        IStaticsV4Hook.PoolConfigurationView memory configuration = hook.poolConfiguration(poolId);
        assertTrue(configuration.registered);
        assertFalse(configuration.initialized);
        assertFalse(configuration.externalLiquidityEnabled);
        assertEq(configuration.initializer, deployment.hookController);
        assertEq(configuration.fees.inputFeeBps, 50);
        assertEq(configuration.fees.outputFeeBps, 50);
        assertEq(configuration.fees.polShareBps, 2_500);
        assertEq(configuration.fees.treasuryShareBps, 7_500);
        assertEq(configuration.recipients.treasury, treasury);

        uint160 requiredFlags = Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
            | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_DONATE_FLAG | Hooks.BEFORE_SWAP_FLAG
            | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
        assertEq(uint160(deployment.v4Hook) & Hooks.ALL_HOOK_MASK, requiredFlags);
    }

    function testRejectsInvalidDeploymentConfiguration() public {
        MockERC20 weth = new MockERC20("Wrapped Ether", "WETH", 18);
        GenesisPoolManagerFixture manager = new GenesisPoolManagerFixture();
        DeployStaticsGenesis deployer = new DeployStaticsGenesis();
        StaticsGenesisDeploymentConfig memory config = StaticsGenesisDeploymentConfig({
            governance: makeAddr("governance"),
            treasury: makeAddr("treasury"),
            weth: address(weth),
            poolManager: address(manager),
            inputFeeBps: 150,
            outputFeeBps: 51
        });

        vm.expectRevert(abi.encodeWithSelector(DeployStaticsGenesis.InvalidFeeRate.selector, 201));
        deployer.deploy(config);

        config.inputFeeBps = 50;
        config.outputFeeBps = 50;
        config.poolManager = address(0);
        vm.expectRevert(DeployStaticsGenesis.ZeroAddress.selector);
        deployer.deploy(config);
    }
}
