// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {DeployStaticsLaunchLiquidity} from "../../script/DeployStaticsLaunchLiquidity.s.sol";
import {StaticsLaunchLiquidityHook} from "../../src/liquidity/StaticsLaunchLiquidityHook.sol";

contract LaunchBindingMock {
    address public immutable poolManager;
    address public immutable permit2;

    constructor(address poolManager_, address permit2_) {
        poolManager = poolManager_;
        permit2 = permit2_;
    }
}

contract LaunchDependencyMock {}

contract DeployStaticsLaunchLiquidityTest is Test {
    uint160 private constant SQRT_PRICE_1_1 = 1 << 96;

    address private governance = makeAddr("governance");
    address private feeReceiver = makeAddr("feeReceiver");
    address private liquidityReceiver = makeAddr("liquidityReceiver");
    address private outsider = makeAddr("outsider");
    DeployStaticsLaunchLiquidity private script;
    DeployStaticsLaunchLiquidity.Config private config;

    function setUp() public {
        LaunchDependencyMock manager = new LaunchDependencyMock();
        LaunchDependencyMock permit2 = new LaunchDependencyMock();
        LaunchBindingMock positionManager = new LaunchBindingMock(address(manager), address(permit2));
        MockERC20 statics = new MockERC20("STATICS", "STATICS", 18);
        MockERC20 weth = new MockERC20("Wrapped Ether", "WETH", 18);
        script = new DeployStaticsLaunchLiquidity();
        config = DeployStaticsLaunchLiquidity.Config({
            chainId: block.chainid,
            poolManager: address(manager),
            positionManager: address(positionManager),
            permit2: address(permit2),
            statics: address(statics),
            weth: address(weth),
            governance: governance,
            feeReceiver: feeReceiver,
            liquidityReceiver: liquidityReceiver,
            liquidityAdmin: address(this),
            tickSpacing: 60,
            sqrtPriceX96: SQRT_PRICE_1_1,
            poolManagerCodeHash: address(manager).codehash,
            positionManagerCodeHash: address(positionManager).codehash,
            permit2CodeHash: address(permit2).codehash,
            staticsCodeHash: address(statics).codehash,
            wethCodeHash: address(weth).codehash
        });
    }

    function testDeploysStandaloneHookOwnedByDedicatedTimelock() public {
        DeployStaticsLaunchLiquidity.Deployment memory deployment = script.deploy(config, address(script));

        assertEq(deployment.hook.owner(), address(deployment.timelock));
        assertEq(deployment.hook.feeReceiver(), feeReceiver);
        assertEq(deployment.hook.liquidityReceiver(), liquidityReceiver);
        assertEq(deployment.hook.liquidityAdmin(), address(this));
        assertEq(deployment.key.fee, 3_000);
        assertEq(deployment.key.tickSpacing, 60);
        assertEq(uint160(address(deployment.hook)) & Hooks.ALL_HOOK_MASK, script.REQUIRED_HOOK_FLAGS());
        assertTrue(deployment.timelock.hasRole(deployment.timelock.PROPOSER_ROLE(), governance));
        assertTrue(deployment.timelock.hasRole(deployment.timelock.EXECUTOR_ROLE(), address(0)));
    }

    function testReceiverChangeMustExecuteThroughTimelock() public {
        DeployStaticsLaunchLiquidity.Deployment memory deployment = script.deploy(config, address(script));
        StaticsLaunchLiquidityHook hook = deployment.hook;
        address replacement = makeAddr("replacement");

        vm.expectRevert();
        hook.setFeeReceiver(replacement);

        bytes memory data = abi.encodeCall(StaticsLaunchLiquidityHook.setFeeReceiver, (replacement));
        bytes32 salt = keccak256("replace launch fee receiver");
        uint256 delay = deployment.timelock.getMinDelay();
        vm.prank(governance);
        deployment.timelock.schedule(address(hook), 0, data, bytes32(0), salt, delay);
        vm.warp(block.timestamp + delay);
        vm.prank(outsider);
        deployment.timelock.execute(address(hook), 0, data, bytes32(0), salt);

        assertEq(hook.feeReceiver(), replacement);
    }

    function testRejectsPinnedDependencyHashMismatch() public {
        config.poolManagerCodeHash = bytes32(uint256(1));
        vm.expectRevert();
        script.deploy(config, address(script));
    }

    function testWritesDedicatedInitializationArtifact() public {
        DeployStaticsLaunchLiquidity.Deployment memory deployment = script.deploy(config, address(script));
        string memory path = "artifacts/launch-liquidity/test-deployment.json";
        vm.createDir("artifacts/launch-liquidity", true);
        script.writeArtifact(path, config, deployment, address(this));

        string memory artifact = vm.readFile(path);
        assertEq(vm.parseJsonAddress(artifact, ".hook"), address(deployment.hook));
        assertEq(vm.parseJsonAddress(artifact, ".timelock"), address(deployment.timelock));
        assertEq(vm.parseJsonUint(artifact, ".nativeLpFeePips"), 3_000);
        assertEq(vm.parseJsonUint(artifact, ".inputFeeBps"), 50);
        assertEq(vm.parseJsonUint(artifact, ".outputFeeBps"), 50);
        assertEq(vm.parseJsonUint(artifact, ".polShareBps"), 4_000);
        assertEq(vm.parseJsonUint(artifact, ".hookPermissionMask"), script.REQUIRED_HOOK_FLAGS());
        assertEq(vm.parseJsonBytes32(artifact, ".hookRuntimeCodeHash"), address(deployment.hook).codehash);
        bytes memory initialization = vm.parseJsonBytes(artifact, ".registerAndInitializeCalldata");
        assertEq(bytes4(initialization), StaticsLaunchLiquidityHook.registerAndInitialize.selector);
        vm.removeFile(path);
    }
}
